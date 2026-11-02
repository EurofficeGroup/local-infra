<#
.SYNOPSIS
    Switches the local stack between TEST4's search and a local one, in the
    only order that is safe.

.DESCRIPTION
    Profile 'search' = three containers:
      elastic           Elasticsearch, same version as TEST4 (docker-compose.yml)
      search-api        the search API on :9012, repo eurofficegroup.search (docker-compose.api.yml)
      noodles-searches  the indexer Noodles.SearchEs, repo eurofficegroup.integrations (docker-compose.noodles.yml)

    -Mode On
        1. clones ../search and ../integrations if they are missing (never pulls)
        2. starts elastic (+ kibana) and waits until it is healthy
        3. runs sql/init/40-search-local.sql: SearchApiServiceUrl, the Elasticsearch
           connection strings and the synonym transport now point at this machine
        4. recreates config-api, so services read the new values
        5. builds search-api / noodles-searches if their images are missing, then
           starts them
        6. checks that 'search-api' resolves on this machine (hosts-setup.ps1)
        7. starts a product index rebuild for INFRA_DEALER_CODE: sends the
           StartDealerReindexMessage that "Start Product index Export" on
           http://admin/Dev/SearchEngine sends. -SkipIndex leaves this out.
    -Mode Rebuild   the same, but always rebuilds the two images (after a pull or
                    a code change in ../search or ../integrations)
    -Mode Off       stops noodles-searches and search-api, runs
                    41-search-remote.sql (TEST4 values back), recreates config-api,
                    stops elastic/kibana. The index stays in the volume.
    -Mode Status    containers, configuration values, indices
    -Mode Reset     unsticks the indexer: stops noodles-searches, empties its
                    queues, deletes the product-reindex saga rows and clears the
                    UpdatesLocked flag of the product-index upkeep saga, then
                    starts it again. Needed after an aborted rebuild (otherwise
                    a new one is refused with EX007 and live updates stay
                    postponed) and after a restore, which brings TEST4's saga
                    rows along. Indices are left alone.

    The containers never depend on step 3 for safety: compose pins the
    Elasticsearch connection strings of search-api and noodles-searches to
    http://elastic:9200 through environment variables, which the configuration
    client ranks above config-api. Step 3 is for Power (SearchApiServiceUrl) and
    noodles-transport (where the synonym file goes).

    Normally called through  ops-local.bat search-on | search-off | search-rebuild
    | search-status  and  setup-local.bat --search.

.EXAMPLE
    .\search-local.ps1 -Mode On
.EXAMPLE
    .\search-local.ps1 -Mode On -SkipIndex
.EXAMPLE
    .\search-local.ps1 -Mode Status
#>

[CmdletBinding()]
param(
    [ValidateSet('On', 'Off', 'Rebuild', 'Status', 'Reset')]
    [string] $Mode = 'Status',
    [switch] $SkipIndex
)

# Not 'Stop': docker and docker compose write progress and warnings to stderr,
# and Windows PowerShell 5.1 turns every such line into a terminating
# NativeCommandError as soon as the output is redirected. Failures are caught
# from $LASTEXITCODE instead, and the few cmdlets below use -ErrorAction Stop.
$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath $PSScriptRoot -ErrorAction Stop

# ---------------------------------------------------------------------------
# Settings from .env / .env.local - same lookup as :read_env in the .bat files.
# The process environment wins, so values set by ops-local.bat are reused.
# ---------------------------------------------------------------------------
function Read-EnvValue {
    param([string] $Key, [string] $Default)

    $fromProcess = [Environment]::GetEnvironmentVariable($Key)
    if ($fromProcess) { return $fromProcess }

    $value = $null
    foreach ($file in @('.env', '.env.local')) {
        $path = Join-Path $PSScriptRoot $file
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($line in Get-Content -LiteralPath $path -ErrorAction Stop) {
            if ($line.StartsWith("$Key=")) { $value = $line.Substring($Key.Length + 1).Trim() }
        }
    }
    if ($value) { return $value }
    return $Default
}

$SaPassword    = Read-EnvValue 'MSSQL_SA_PASSWORD' $null
$DbPrefix      = Read-EnvValue 'INFRA_DB_PREFIX' 'dev_uk'
$SupportCentre = "${DbPrefix}_supportcentre"
$NServiceBusDb = "${DbPrefix}_nservicebus"
$SqlCmd        = '/opt/mssql-tools18/bin/sqlcmd'
$DealerCode    = (Read-EnvValue 'INFRA_DEALER_CODE' 'jst').ToLower()
$DealerGroup   = (Read-EnvValue 'INFRA_DEALER_GROUP' 'pow').ToLower()
$Environment   = Read-EnvValue 'INFRA_ENVIRONMENT' 'local'
$LocalHostName = Read-EnvValue 'LOCAL_HOSTNAME' $env:COMPUTERNAME.ToLower()
$RabbitUser    = Read-EnvValue 'RABBIT_USER' 'guest'
$RabbitPass    = Read-EnvValue 'RABBIT_PASS' 'guest'
$RabbitUi      = Read-EnvValue 'RABBIT_UI_PORT' '15672'

# The endpoint's queue name, as the NServiceBus log prints it:
# <Environment>_<hostname>.<group>.noodles.searches, plus the instance queue.
$IndexerQueue  = "${Environment}_${LocalHostName}.${DealerGroup}.noodles.searches"
$RabbitAuth    = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${RabbitUser}:${RabbitPass}")) }

if (-not $SaPassword) { throw 'MSSQL_SA_PASSWORD is not set in .env.local.' }
if ($DbPrefix -notmatch '^[A-Za-z0-9_]+$') { throw "INFRA_DB_PREFIX '$DbPrefix' contains invalid characters." }
if ($DealerCode -notmatch '^[a-z0-9_]+$') { throw "INFRA_DEALER_CODE '$DealerCode' contains invalid characters." }

# Compose interpolates the password from .env.local; keep identical to the .bat files.
$env:COMPOSE_ENV_FILES = '.env,.env.local'

$ComposePower   = @('compose', '-f', 'docker-compose.yml', '--profile', 'search')
$ComposeApi     = @('compose', '-f', 'docker-compose.api.yml', '--profile', 'search')
$ComposeNoodles = @('compose', '-f', 'docker-compose.noodles.yml', '--profile', 'search')


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step([string] $Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }

function Invoke-Docker {
    param([string[]] $Arguments, [string] $What)

    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$What failed (docker exit code $LASTEXITCODE) - see the output above." }
}

function Get-ContainerHealth([string] $Name) {
    $out = & docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return 'missing' }
    return ($out | Select-Object -First 1)
}

function Wait-Healthy([string] $Name, [int] $TimeoutSeconds) {
    Write-Host "Waiting for $Name to become healthy (up to $TimeoutSeconds s) ..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = Get-ContainerHealth $Name
        if ($state -eq 'healthy') { Write-Host "  $Name is healthy."; return }
        if ($state -in @('missing', 'exited', 'dead')) { break }
        Start-Sleep -Seconds 5
    }
    & docker logs --tail 40 $Name 2>&1 | Out-Host
    throw "$Name is not healthy (state: $(Get-ContainerHealth $Name)) - see its log above."
}

function Wait-Http([string] $Url, [int] $TimeoutSeconds) {
    Write-Host "Waiting for $Url (up to $TimeoutSeconds s) ..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
            Write-Host '  answering.'
            return
        } catch {
            Start-Sleep -Seconds 5
        }
    }
    throw "$Url did not answer in $TimeoutSeconds s."
}

function Invoke-SupportCentreSql([string] $FileName) {
    Write-Host "Running $FileName against [$SupportCentre] ..."
    # Read inside the container from the ./sql/init:/init mount rather than piped
    # in: a pipe from PowerShell re-encodes the text with whatever $OutputEncoding
    # the session has, and a UTF-8 BOM in front of the first line is a syntax
    # error for sqlcmd. -b: a SQL error becomes a non-zero exit code.
    & docker exec mssql $SqlCmd -S localhost -U sa -P $SaPassword -C -b -d $SupportCentre -i "/init/$FileName"
    if ($LASTEXITCODE -ne 0) { throw "$FileName failed (sqlcmd exit code $LASTEXITCODE). Is mssql up and [$SupportCentre] restored?" }
}

function Restart-ConfigApi {
    Write-Host 'Recreating config-api so every service reads the new values ...'
    Invoke-Docker -Arguments @('compose', '-f', 'docker-compose.api.yml', 'up', '-d', '--force-recreate', '--no-deps', 'config-api') -What 'Recreating config-api'
    Wait-Http 'http://localhost:8080/Configuration/1/Configuration/service=api.configuration' 180
}

function Test-ImageExists([string] $Image) {
    & docker image inspect $Image *> $null
    return ($LASTEXITCODE -eq 0)
}

function Show-Status {
    Write-Step 'Containers'
    foreach ($name in @('elastic', 'kibana', 'search-api', 'noodles-searches')) {
        Write-Host ('  {0,-17} {1}' -f $name, (Get-ContainerHealth $name))
    }

    Write-Step "Configuration in [$SupportCentre]"
    $query = "SET NOCOUNT ON; SELECT cfg_Name, ISNULL(cfg_Service, '-') AS svc, cfg_Value FROM dbo.cfg_Configurations " +
             "WHERE cfg_Name IN ('ElasticSearchConnectionString','ElasticSearchUpdateConnectionString','SearchApiServiceUrl','ElasticSearch.SynonymFilePathOnNodes','ElasticSearch.ProductIndexPrefix') ORDER BY cfg_Name; " +
             "SELECT CASE WHEN OBJECT_ID('dbo.zz_LocalInfraSearchBackup') IS NULL THEN 'search is on TEST4 (no backup table)' ELSE 'search is LOCAL (ops-local.bat search-on applied)' END AS state;"
    & docker exec mssql $SqlCmd -S localhost -U sa -P $SaPassword -C -d $SupportCentre -W -s ' | ' -Q $query
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not read the configuration - is mssql running?' }

    Write-Step 'Product and smart-search indices on the local node (Kibana: http://localhost:5601)'
    try {
        (Invoke-WebRequest -Uri 'http://localhost:9200/_cat/indices/product_*,smart_*?v&s=index&h=index,docs.count,store.size' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop).Content | Out-Host
        (Invoke-WebRequest -Uri 'http://localhost:9200/_cat/aliases/product_*,smart_*?v&h=alias,index' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop).Content | Out-Host
    } catch {
        Write-Host '  elastic is not answering on http://localhost:9200.'
    }
}

function Test-SearchApiHostname {
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses('search-api')
        if ($addresses | Where-Object { $_.ToString() -in @('127.0.0.1', '::1') }) { return $true }
    } catch { }
    return $false
}

function Test-ReindexMarkedRunning {
    $query = "SET NOCOUNT ON; " +
             "IF OBJECT_ID('dbo.ProductReindexFromDbSagaData') IS NULL SELECT 0 " +
             "ELSE SELECT COUNT(*) FROM dbo.ProductReindexFromDbSagaData WHERE IsRunning = 1 AND DealerNumber = '$DealerCode';"
    $out = & docker exec mssql $SqlCmd -S localhost -U sa -P $SaPassword -C -b -h -1 -W -d $NServiceBusDb -Q $query
    if ($LASTEXITCODE -ne 0) { throw "Reading the product-reindex saga state in [$NServiceBusDb] failed (sqlcmd exit code $LASTEXITCODE)." }
    return ([int](($out | Where-Object { $_.Trim() }) | Select-Object -Last 1) -gt 0)
}

function Send-StartDealerReindex([int] $TimeoutSeconds) {
    $messageId = [guid]::NewGuid().ToString()
    $body = @{
        routing_key      = $IndexerQueue
        payload          = (@{ DealerNumber = $DealerCode } | ConvertTo-Json -Compress)
        payload_encoding = 'string'
        properties       = @{
            message_id    = $messageId
            content_type  = 'application/json'
            delivery_mode = 2
            headers       = @{
                'NServiceBus.MessageId'            = $messageId
                'NServiceBus.MessageIntent'        = 'Send'
                'NServiceBus.ContentType'          = 'application/json'
                'NServiceBus.TimeSent'             = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss:ffffff', [Globalization.CultureInfo]::InvariantCulture) + ' Z'
                'NServiceBus.EnclosedMessageTypes' = 'Noodles.SearchEs.Messages.StartDealerReindexMessage, Noodles.SearchEs.Messages'
                'Euroffice.DealerName'             = $DealerCode
                'Euroffice.DealerGroup'            = $DealerGroup
            }
        }
    } | ConvertTo-Json -Depth 5

    Write-Host "Sending StartDealerReindexMessage for '$DealerCode' to $IndexerQueue (up to $TimeoutSeconds s for the queue) ..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $result = Invoke-RestMethod -Method Post -Uri "http://localhost:$RabbitUi/api/exchanges/%2F/amq.default/publish" `
                -Headers $RabbitAuth -ContentType 'application/json' -Body $body -ErrorAction Stop
            if ($result.routed) { Write-Host '  sent.'; return }
        } catch { }
        Start-Sleep -Seconds 5
    }
    throw "Could not deliver StartDealerReindexMessage to $IndexerQueue in $TimeoutSeconds s - is noodles-searches running (docker logs noodles-searches)?"
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
& docker info *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker daemon is not running.' }

if ($Mode -eq 'Status') {
    Show-Status
    exit 0
}

if ((Get-ContainerHealth 'mssql') -ne 'healthy') {
    throw 'mssql is not running/healthy. Start the core first: docker compose up -d  (or setup-local.bat).'
}

if ($Mode -eq 'Reset') {
    Write-Step 'Stopping noodles-searches'
    Invoke-Docker -Arguments ($ComposeNoodles + @('stop', 'noodles-searches')) -What 'Stopping noodles-searches'

    Write-Step "Emptying $IndexerQueue"
    foreach ($q in @($IndexerQueue, "$IndexerQueue-$LocalHostName")) {
        try {
            Invoke-RestMethod -Method Delete -Uri "http://localhost:$RabbitUi/api/queues/%2F/$q/contents" `
                -Headers $RabbitAuth -ErrorAction Stop | Out-Null
            Write-Host "  purged $q"
        } catch {
            Write-Host "  $q - not purged ($($_.Exception.Message))"
        }
    }

    Write-Step "Saga state in [$NServiceBusDb]"
    $sql = "SET NOCOUNT ON; " +
           "IF OBJECT_ID('dbo.ProductReindexFromDbSagaData') IS NOT NULL BEGIN DELETE FROM dbo.ProductReindexFromDbSagaData; PRINT 'Product reindex sagas deleted: ' + CAST(@@ROWCOUNT AS varchar(10)); END; " +
           "IF OBJECT_ID('dbo.ProductIndexUpkeepSagaData') IS NOT NULL BEGIN UPDATE dbo.ProductIndexUpkeepSagaData SET UpdatesLocked = 0 WHERE UpdatesLocked = 1; PRINT 'Upkeep locks cleared: ' + CAST(@@ROWCOUNT AS varchar(10)); END;"
    & docker exec mssql $SqlCmd -S localhost -U sa -P $SaPassword -C -b -d $NServiceBusDb -Q $sql
    if ($LASTEXITCODE -ne 0) { throw "Resetting the saga state in [$NServiceBusDb] failed (sqlcmd exit code $LASTEXITCODE)." }

    Write-Step 'Starting noodles-searches'
    Invoke-Docker -Arguments ($ComposeNoodles + @('up', '-d', '--no-deps', 'noodles-searches')) -What 'Starting noodles-searches'

    Write-Host ''
    Write-Host 'Indexer reset. Start a rebuild again: ops-local.bat search-on, or http://admin/Dev/SearchEngine.' -ForegroundColor Green
    exit 0
}

if ($Mode -eq 'Off') {
    Write-Step 'Stopping noodles-searches and search-api'
    Invoke-Docker -Arguments ($ComposeNoodles + @('rm', '-s', '-f', 'noodles-searches')) -What 'Removing noodles-searches'
    Invoke-Docker -Arguments ($ComposeApi + @('rm', '-s', '-f', 'search-api')) -What 'Removing search-api'

    Write-Step 'Configuration back to TEST4'
    Invoke-SupportCentreSql '41-search-remote.sql'
    Restart-ConfigApi

    Write-Step 'Stopping elastic and kibana (the index stays in volume power_elastic-data-8)'
    Invoke-Docker -Arguments ($ComposePower + @('stop', 'elastic', 'kibana')) -What 'Stopping elastic/kibana'

    Write-Host ''
    Write-Host 'Search is back on TEST4.' -ForegroundColor Green
    Write-Host 'Power caches its configuration: recycle the app pools of wfe, portal and admin (or iisreset, elevated).'
    exit 0
}

# On / Rebuild
Write-Step 'Repositories ../search and ../integrations'
try {
    & (Join-Path $PSScriptRoot 'clone-apis.ps1') -Search -NoPull
} catch {
    throw "clone-apis.ps1 failed: $($_.Exception.Message)"
}

Write-Step 'Elasticsearch'
Invoke-Docker -Arguments ($ComposePower + @('up', '-d', 'elastic', 'kibana')) -What 'Starting elastic/kibana'
Wait-Healthy 'elastic' 300

# One node cannot hold replicas. The indexer creates product indices without a
# replica count, so they get the default of 1 and the cluster stays yellow.
# An index template with priority 1 gives them 0; settings sent with an
# index-create request still win over it. Idempotent (PUT replaces).
Write-Host 'Index template local-infra-single-node: product_*, smart_* without replicas ...'
$template = '{"index_patterns":["product_*","smart_*"],"priority":1,"template":{"settings":{"number_of_replicas":0}}}'
try {
    Invoke-RestMethod -Method Put -Uri 'http://localhost:9200/_index_template/local-infra-single-node' `
        -ContentType 'application/json' -Body $template -ErrorAction Stop | Out-Null
} catch {
    throw "Could not create the index template on http://localhost:9200: $($_.Exception.Message)"
}

Write-Step 'Configuration to the local search stack'
Invoke-SupportCentreSql '40-search-local.sql'
Restart-ConfigApi

Write-Step 'Images'
$searchApiImage = Read-EnvValue 'SEARCH_API_IMAGE' 'infra/api-search:local'
$indexerImage   = Read-EnvValue 'NOODLES_SEARCHES_IMAGE' 'infra/noodles-searches:local'
if ($Mode -eq 'Rebuild' -or -not (Test-ImageExists $searchApiImage)) {
    Write-Host "Building $searchApiImage (VPN / NuGet needed) ..."
    Invoke-Docker -Arguments ($ComposeApi + @('build', 'search-api')) -What 'Building search-api'
} else {
    Write-Host "  $searchApiImage exists (search-rebuild to rebuild it)"
}
if ($Mode -eq 'Rebuild' -or -not (Test-ImageExists $indexerImage)) {
    Write-Host "Building $indexerImage (VPN / NuGet needed) ..."
    Invoke-Docker -Arguments ($ComposeNoodles + @('build', 'noodles-searches')) -What 'Building noodles-searches'
} else {
    Write-Host "  $indexerImage exists (search-rebuild to rebuild it)"
}

Write-Step 'search-api and noodles-searches'
Invoke-Docker -Arguments ($ComposeApi + @('up', '-d', '--force-recreate', '--no-deps', 'search-api')) -What 'Starting search-api'
Invoke-Docker -Arguments ($ComposeNoodles + @('up', '-d', '--force-recreate', '--no-deps', 'noodles-searches')) -What 'Starting noodles-searches'
Wait-Healthy 'search-api' 240

$hostsOk = Test-SearchApiHostname
if (-not $hostsOk) {
    Write-Host ''
    Write-Warning ("'search-api' does not resolve to 127.0.0.1 on this machine, so the IIS sites cannot reach " +
                   "SearchApiServiceUrl=http://search-api:9012/Search/. Run once, elevated:  .\hosts-setup.ps1")
}

$indexStarted = $false
if ($SkipIndex) {
    Write-Step 'Product index rebuild skipped (-SkipIndex)'
} else {
    Write-Step "Product index rebuild for '$DealerCode'"
    if (Test-ReindexMarkedRunning) {
        Write-Warning ("A product index rebuild for '$DealerCode' is already marked running in [$NServiceBusDb] " +
                       "(restored from TEST4, or an aborted rebuild), so the indexer would refuse a new one (EX007). " +
                       "Run  ops-local.bat search-reset , then  ops-local.bat search-on  again.")
    } else {
        Send-StartDealerReindex 180
        $indexStarted = $true
    }
}

Show-Status

Write-Host ''
Write-Host 'Local search stack is up.' -ForegroundColor Green
Write-Host 'Next:'
Write-Host '  1. Recycle the app pools of wfe, portal and admin (or iisreset, elevated) - Power caches SearchApiServiceUrl.'
if ($indexStarted) {
    Write-Host "  2. The product index for '$DealerCode' is being built. Follow it with:"
    Write-Host '     docker logs -f noodles-searches   and   ops-local.bat search-status'
} else {
    Write-Host '  2. Build the product index once: http://admin -> select the dealer (Dealer Map, or'
    Write-Host '     http://admin/Dealer/Impersonate/<dlr_Key>) -> http://admin/Dev/SearchEngine -> "Start Product index Export".'
    Write-Host '     Follow it with:  docker logs -f noodles-searches   and   ops-local.bat search-status'
}
Write-Host '  3. Optional: "Populate Synonym File For Product Index" on http://admin/Dev/SearchEngine fills files\elastic\synonyms.txt.'
Write-Host 'Back to TEST4 search:  ops-local.bat search-off'
exit 0
