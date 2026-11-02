[CmdletBinding()]
param(
    [switch] $Preview,
    [switch] $Restart,
    [string[]] $Database,
    [switch] $SkipBuild,
    [string] $Workspace
)

$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath $PSScriptRoot -ErrorAction Stop

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

$SaPassword  = Read-EnvValue 'MSSQL_SA_PASSWORD' $null
$DbPrefix    = Read-EnvValue 'INFRA_DB_PREFIX' 'dev_uk'
$DealerCode  = Read-EnvValue 'INFRA_DEALER_CODE' 'jst'
$DealerGroup = Read-EnvValue 'INFRA_DEALER_GROUP' 'pow'
$Environment = Read-EnvValue 'INFRA_ENVIRONMENT' 'local'
$SqlPort     = Read-EnvValue 'MSSQL_PORT' '1433'
$SqlCmd      = '/opt/mssql-tools18/bin/sqlcmd'

if (-not $SaPassword) { throw 'MSSQL_SA_PASSWORD is not set in .env.local.' }

foreach ($pair in @(@('INFRA_DB_PREFIX', $DbPrefix), @('INFRA_DEALER_CODE', $DealerCode),
                    @('INFRA_DEALER_GROUP', $DealerGroup), @('INFRA_ENVIRONMENT', $Environment))) {
    if ($pair[1] -notmatch '^[A-Za-z0-9_]+$') { throw "$($pair[0]) '$($pair[1])' in .env must be letters, digits or _ only." }
}

if ($SqlPort -notmatch '^[0-9]+$') { throw "MSSQL_PORT '$SqlPort' in .env must be a number." }

$ProductCatalogue = "${DbPrefix}_productcatalogue"
$SupportCentre    = "${DbPrefix}_supportcentre"
$NServiceBus      = "${DbPrefix}_nservicebus"

if (-not $Workspace) { $Workspace = Split-Path -Parent $PSScriptRoot }
$DatabaseRepo = Join-Path $Workspace 'database'
$MigratorSrc  = Join-Path $DatabaseRepo 'src'

$env:COMPOSE_ENV_FILES = '.env,.env.local'

$IisSites = @('wfe', 'portal', 'admin', 'cdn')

$Projects = [ordered]@{
    ProductCatalogue = 'EurofficeGroup.Database.Migrator.ProductCatalogue'
    Dealer           = 'EurofficeGroup.Database.Migrator.Dealer'
    SupportCentre    = 'EurofficeGroup.Database.Migrator.SupportCentre'
}

function Write-Step([string] $Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }

function Get-BinFolder([string] $Kind) {
    return Join-Path $MigratorSrc "$($Projects[$Kind])\bin\Debug\net472"
}

function Get-LocalDatabases {
    $query = "SET NOCOUNT ON; SELECT name + '|' + CASE WHEN OBJECT_ID(QUOTENAME(name) + '.dbo.cus_Customers') IS NULL THEN '0' ELSE '1' END FROM sys.databases WHERE state_desc = 'ONLINE' ORDER BY name;"
    $rows = & docker exec mssql $SqlCmd -S localhost -U sa -P $SaPassword -C -b -h -1 -W -Q $query
    if ($LASTEXITCODE -ne 0) { throw "Listing the databases failed (sqlcmd exit code $LASTEXITCODE). Is the mssql container up?" }

    $prefix = "${DbPrefix}_"
    $targets = @()
    foreach ($row in $rows) {
        $parts = "$row".Trim().Split('|')
        if ($parts.Count -ne 2 -or -not $parts[0].StartsWith($prefix)) { continue }

        $name = $parts[0]
        if ($name -eq $ProductCatalogue) {
            $targets += [pscustomobject]@{ Order = 1; Name = $name; Kind = 'ProductCatalogue'; DealerRef = $DealerCode }
        }
        elseif ($name -eq $SupportCentre) {
            $targets += [pscustomobject]@{ Order = 3; Name = $name; Kind = 'SupportCentre'; DealerRef = $DealerCode }
        }
        elseif ($name -ne $NServiceBus -and $parts[1] -eq '1') {
            $targets += [pscustomobject]@{ Order = 2; Name = $name; Kind = 'Dealer'; DealerRef = $name.Substring($prefix.Length) }
        }
    }

    return $targets | Sort-Object Order, Name
}

function Invoke-Migrator($Target) {
    $bin = Get-BinFolder $Target.Kind
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = "localhost,$SqlPort"
    $builder['Initial Catalog'] = $Target.Name
    $builder['User ID'] = 'sa'
    $builder['Password'] = $SaPassword

    $context = "{'dealer_ref':'$($Target.DealerRef)', 'dealer_database_prefix':'${DbPrefix}_', " +
               "'productcatalogue_database':'$ProductCatalogue', 'supportcentre_database':'$SupportCentre', " +
               "'nservicebus_database':'$NServiceBus', 'environment':'$Environment', 'dealer_group':'$DealerGroup'}"

    $arguments = @('/connection', $builder.ConnectionString, '/db', 'SQLserver2014', '/timeout', '600',
                   '/target', (Join-Path $bin "$($Projects[$Target.Kind]).dll"), '/tag', 'DbMigration', '/context', $context)
    if ($Preview) { $arguments += '/preview' }

    $lines = New-Object System.Collections.Generic.List[string]
    & (Join-Path $bin 'Migrate.exe') @arguments 2>&1 | ForEach-Object { $line = "$_"; $lines.Add($line); Write-Host $line }
    if ($LASTEXITCODE -ne 0) { throw "Migrate.exe failed on [$($Target.Name)] (exit code $LASTEXITCODE) - see the output above. Databases after it were not migrated." }

    return @($lines | Where-Object { $_ -match '^\d{12,}: .+ migrated$' } | ForEach-Object { ($_ -split ': ')[1] -replace ' migrated$', '' })
}

function Invoke-Compose {
    param([string[]] $Arguments, [string] $What)

    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$What failed (docker exit code $LASTEXITCODE) - see the output above." }
}

function Restart-Containers {
    Write-Step 'Recreating config-api'
    Invoke-Compose @('compose', '-f', 'docker-compose.api.yml', 'up', '-d', '--force-recreate', '--no-deps', 'config-api') 'Recreating config-api'

    Write-Step 'Recreating noodles-* containers'
    $services = @(& docker compose -f docker-compose.noodles.yml config --services | Where-Object { $_ -like 'noodles-*' -and $_ -ne 'noodles-build' })
    if (-not $services) { throw 'No noodles-* services found in docker-compose.noodles.yml.' }

    Write-Host ('  ' + ($services -join ', '))
    Invoke-Compose (@('compose', '-f', 'docker-compose.noodles.yml', 'up', '-d', '--force-recreate', '--no-deps') + $services) 'Recreating noodles'
}

function Restart-IisAppPools {
    Write-Step "Recycling the IIS app pools of $($IisSites -join ', ')"
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warning 'Not an elevated prompt - app pools not recycled. Recycle them in IIS Manager or rerun from an elevated prompt.'
        return
    }

    Import-Module WebAdministration -ErrorAction Stop
    foreach ($siteName in $IisSites) {
        $site = Get-Item "IIS:\Sites\$siteName" -ErrorAction SilentlyContinue
        if (-not $site) {
            Write-Warning "IIS site '$siteName' not found - skipped."
            continue
        }

        $pool = $site.applicationPool
        if ((Get-WebAppPoolState -Name $pool).Value -ne 'Started') {
            Write-Warning "App pool '$pool' of $siteName is not running - skipped."
            continue
        }

        Restart-WebAppPool -Name $pool -ErrorAction Stop
        Write-Host "  $siteName -> app pool '$pool' recycled"
    }
}

Write-Step 'Checks'
if (-not (Test-Path -LiteralPath (Join-Path $MigratorSrc "$($Projects['Dealer'])\$($Projects['Dealer']).csproj"))) {
    throw "The database repository is not at $DatabaseRepo. Clone EurofficeGroup database there or pass -Workspace."
}

$health = & docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' mssql 2>$null | Select-Object -First 1
if ($LASTEXITCODE -ne 0 -or $health -ne 'healthy') { throw "The mssql container is not healthy (state: $health). Start the stack first: setup-local.bat or ops-local.bat core-restart." }

$branch = & git -C $DatabaseRepo rev-parse --abbrev-ref HEAD 2>$null
Write-Host "  database repo: $DatabaseRepo (branch: $branch)"
Write-Host "  SQL Server:    localhost,$SqlPort   prefix: ${DbPrefix}_   environment: $Environment   dealer group: $DealerGroup"
if ($Preview) { Write-Host '  PREVIEW: nothing is written to the databases.' -ForegroundColor Yellow }

if ($SkipBuild) {
    Write-Step 'Build skipped (-SkipBuild)'
}
else {
    foreach ($kind in $Projects.Keys) {
        Write-Step "Building $($Projects[$kind]) (Debug)"
        & dotnet build (Join-Path $MigratorSrc "$($Projects[$kind])\$($Projects[$kind]).csproj") -c Debug -nologo -v minimal
        if ($LASTEXITCODE -ne 0) { throw "Building $($Projects[$kind]) failed (dotnet exit code $LASTEXITCODE) - see the output above." }
    }
}

foreach ($kind in $Projects.Keys) {
    if (-not (Test-Path -LiteralPath (Join-Path (Get-BinFolder $kind) 'Migrate.exe'))) { throw "Migrate.exe is missing in $(Get-BinFolder $kind) - run without -SkipBuild." }
}

Write-Step 'Databases'
$targets = @(Get-LocalDatabases)
if ($Database) {
    $unknown = @($Database | Where-Object { $_ -notin $targets.Name })
    if ($unknown) { throw "Not a local product catalogue, dealer or support centre database: $($unknown -join ', '). Found: $($targets.Name -join ', ')." }

    $targets = @($targets | Where-Object { $_.Name -in $Database })
}

if (-not $targets) { throw "No databases with the prefix ${DbPrefix}_ found. Has the restore run (setup-local.bat)?" }

$targets | ForEach-Object { Write-Host ("  {0,-30} {1}" -f $_.Name, $_.Kind) }

$summary = @()
foreach ($target in $targets) {
    Write-Step "Migrating $($target.Name) ($($target.Kind))"
    $applied = @(Invoke-Migrator $target)
    $summary += [pscustomobject]@{ Database = $target.Name; Migrations = $applied }
}

Write-Step $(if ($Preview) { 'Summary - PREVIEW, would apply' } else { 'Summary - applied' })
foreach ($row in $summary) {
    if ($row.Migrations.Count -eq 0) {
        Write-Host ("  {0,-30} up to date" -f $row.Database)
    }
    else {
        Write-Host ("  {0,-30} {1} migration(s)" -f $row.Database, $row.Migrations.Count)
        $row.Migrations | ForEach-Object { Write-Host "      $_" }
    }
}

$appliedCount = ($summary | ForEach-Object { $_.Migrations.Count } | Measure-Object -Sum).Sum
if ($Preview) {
    if ($Restart) { Write-Host ''; Write-Host '-Restart ignored in preview mode.' }
}
elseif (-not $Restart) {
    Write-Host ''
    Write-Host 'Tip: Power and noodles cache configuration and CMS content - if a change is not visible,'
    Write-Host '     run ops-local.bat db-migrate restart (or config-restart / noodles-restart and recycle the IIS app pools).'
}
elseif ($appliedCount -eq 0) {
    Write-Host ''
    Write-Host 'Nothing was applied - restart skipped.'
}
else {
    Restart-Containers
    Restart-IisAppPools
    Write-Host ''
    Write-Host 'Redis was not flushed: CMS content Power caches there stays until it expires.'
}
