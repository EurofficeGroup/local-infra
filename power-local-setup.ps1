<#
.SYNOPSIS
    Points the IIS-hosted Power sites at this machine's local infrastructure.
    Run it AFTER WebConfigPicker's "Do the Magic!", every time - or on its own
    whenever the web.config files were reset (git checkout, a picker run for
    another environment) and you just want the local settings back.

.DESCRIPTION
    WHAT WEBCONFIGPICKER ALREADY DOES

    It copies each site's web.config from the chosen environment's server share
    and rewrites a handful of endpoints. With the local options ticked:

        Cache / Redis.ConnectionString  localhost:6379,allowAdmin=true,abortConnect=false
        Rabbit                          host=localhost
        UseAzureServiceBus              false
        ConfigurationUrl                http://localhost:8080/configuration

    Those ports are exactly the ones docker-compose.yml publishes, so the tool
    and this stack already agree. This script writes the same values again
    (a no-op after the picker), so a web.config that never went through the
    picker - e.g. the one committed in the power repo - ends up local too.

    WHAT IT DOES NOT DO

    1. It never touches the database. It cannot: the Power sites have no
       connection string of their own. They ask the Configuration API, and the
       Configuration API answers from whichever support centre it was pointed
       at. So "use my local database" is not a picker setting - it follows
       automatically once ConfigurationUrl is local, because our container reads
       the restored dev_uk_supportcentre and returns Data Source=mssql,1433.

       Which means: tick "Configuration API - Use local", or the site will read
       TEST4's configuration and go straight to the test database, no matter
       what else is set.

    2. Generic.ForceIntegratedSecurity is left at true, and it is fatal here.
       PlaceholderDealerSepcificConnectionProviderConfigApi strips the user and
       password off the connection string and switches to Windows auth - which
       a Linux SQL Server container cannot accept. The site then fails to open
       any connection at all. This script sets it to false.

    3. The dealer, group and environment are whatever the source config had -
       the committed one says DealerId=POW, which is the group, not a dealer, so
       the site asks for a dev_uk_POW database that does not exist. This script
       takes them from .env / .env.local, the same values setup-local.bat
       restored the databases with:

           Environment   <- INFRA_ENVIRONMENT   (all sites)
           DealerGroup   <- INFRA_DEALER_GROUP  (all sites)
           DealerId      <- INFRA_DEALER_CODE   (wfe and portal only)

       DealerId goes only to wfe and portal: their ContextsInstaller uses it as
       the default dealer database. admin and cdn run without one today, and
       giving them one would change which database they open.

    Run as administrator: reading site paths out of IIS needs it, which is why
    WebConfigPicker asks for the same.

.EXAMPLE
    .\power-local-setup.ps1

.EXAMPLE
    .\power-local-setup.ps1 -WhatIf

.EXAMPLE
    .\power-local-setup.ps1 -DealerCode idl
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # IIS site names, as WebConfigPicker looks them up (GetLocalPath).
    #
    # 'cdn' belongs here despite serving static content: EurofficeGroup.Web.Static
    # has its own PlaceholderDealerSpecificConnectionProviderConfigApi and opens a
    # database connection while starting up. Leave it out and every request to it,
    # including plain .css, answers 500 - which looks like missing styles rather
    # than a database problem.
    [string[]] $Sites = @('wfe', 'portal', 'admin', 'cdn'),

    [string] $ConfigurationUrl = 'http://localhost:8080/Configuration',

    # Leave the sites calling TEST4's APIs over the VPN. Use this if the "apis"
    # compose profile is not running - a site pointed at a dead local port fails
    # harder than one that is merely slow.
    [switch] $KeepRemoteApis,

    # Default: INFRA_DEALER_CODE / INFRA_DEALER_GROUP / INFRA_ENVIRONMENT from
    # .env, overridden by .env.local - the values the databases were restored with.
    [string] $DealerCode,
    [string] $DealerGroup,
    [string] $Environment
)

# Sites whose ContextsInstaller reads DealerId as the default dealer database.
$DealerSites = @('wfe', 'portal')

# What WebConfigPicker writes with "Use local cache" / "Use local RabbitMQ"
# (MainWindow.xaml.cs, OverrideConfigFile). Keep the strings identical, so that
# running this after the picker changes nothing.
$LocalEndpoints = [ordered] @{
    'Cache'                  = 'localhost:6379,allowAdmin=true,abortConnect=false'
    'Redis.ConnectionString' = 'localhost:6379,allowAdmin=true,abortConnect=false'
    'UseAzureServiceBus'     = 'false'
    'Rabbit'                 = 'host=localhost'
}

# The satellite APIs, at the ports docker-compose.yml publishes for them.
#
# WebConfigPicker writes most of these itself when you tick "Use local", so for
# those this is only a guarantee rather than a change. Two reasons to do it here
# anyway: the picker's Payments URL is wrong (it writes :9052 while configuring
# the service itself on :9050 - MainWindow.xaml.cs:620 vs :798, and :9050 is the
# fallback compiled into PaymentsApiInstaller), and the picker has to be re-run
# in full to change one of them.
#
# SearchApiServiceUrl is absent on purpose: Elasticsearch stays on TEST4.
$LocalApis = [ordered] @{
    'PricingApiServiceUrl'        = 'http://localhost:9000/pricing'
    'TaxApiServiceUrl'            = 'http://localhost:9005/tax'
    'ProductApiServiceUrl'        = 'http://localhost:9020/Product'
    'DeliveryChargeApiServiceUrl' = 'http://localhost:9020/DeliveryCharge'
    'PaymentsApiServiceUrl'       = 'http://localhost:9050/Payments'
    'AudienceApiServiceUrl'       = 'http://localhost:9100/audience'
}

$ErrorActionPreference = 'Stop'

# Same lookup as :read_env in setup-local.bat / ops-local.bat: KEY=value at the
# start of a line, .env.local wins over .env. Only reads the keys asked for.
function Read-EnvValue {
    param([string] $Key)

    $value = $null
    foreach ($file in @('.env', '.env.local')) {
        $path = Join-Path $PSScriptRoot $file
        if (-not (Test-Path $path)) { continue }
        foreach ($line in Get-Content -LiteralPath $path) {
            if ($line.StartsWith("$Key=")) { $value = $line.Substring($Key.Length + 1).Trim() }
        }
    }
    return $value
}

if (-not $DealerCode)  { $DealerCode  = Read-EnvValue 'INFRA_DEALER_CODE' }
if (-not $DealerGroup) { $DealerGroup = Read-EnvValue 'INFRA_DEALER_GROUP' }
if (-not $Environment) { $Environment = Read-EnvValue 'INFRA_ENVIRONMENT' }
# The defaults setup-local.bat and .env ship with.
if (-not $DealerCode)  { $DealerCode  = 'jst' }
if (-not $DealerGroup) { $DealerGroup = 'pow' }
if (-not $Environment) { $Environment = 'local' }

# WebConfigPicker lower-cases DealerId; the dealer database is dev_uk_<code>.
$DealerCode = $DealerCode.ToLowerInvariant()

foreach ($pair in @(@('DealerCode', $DealerCode), @('DealerGroup', $DealerGroup), @('Environment', $Environment))) {
    if ($pair[1] -notmatch '^[A-Za-z0-9_]+$') {
        throw "$($pair[0]) '$($pair[1])' must be letters, digits or _ only - check INFRA_* in .env / .env.local."
    }
}

Write-Host "Dealer $DealerCode, group $DealerGroup, environment $Environment"

$id =[Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this in an elevated PowerShell (Run as administrator).'
}

Import-Module WebAdministration -ErrorAction Stop

function Set-AppSetting {
    param([xml] $Xml, [string] $Key, [string] $Value)

    $appSettings = $Xml.configuration.appSettings
    if (-not $appSettings) {
        throw "No <appSettings> section - is this really a site web.config?"
    }

    $node = $appSettings.add | Where-Object { $_.key -eq $Key }
    if ($node) {
        # Case-sensitive: DealerGroup POW -> pow must count as a change.
        if ($node.value -ceq $Value) { return $false }
        $node.value = $Value
    }
    else {
        $new = $Xml.CreateElement('add')
        $new.SetAttribute('key', $Key)
        $new.SetAttribute('value', $Value)
        [void] $appSettings.AppendChild($new)
    }
    return $true
}

foreach ($siteName in $Sites) {
    $site = Get-Item "IIS:\Sites\$siteName" -ErrorAction SilentlyContinue
    if (-not $site) {
        Write-Warning "IIS site '$siteName' not found - skipped."
        continue
    }

    $root = $site.physicalPath
    # IIS stores paths with environment variables unexpanded.
    $root = [Environment]::ExpandEnvironmentVariables($root)
    $configPath = Join-Path $root 'web.config'

    if (-not (Test-Path $configPath)) {
        Write-Warning "No web.config under '$root' - run WebConfigPicker first."
        continue
    }

    Write-Host ''
    Write-Host "$siteName  ->  $configPath"

    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($configPath)

    $changes = @()

    # The one that makes the difference between your database and TEST4's.
    if (Set-AppSetting -Xml $xml -Key 'ConfigurationUrl' -Value $ConfigurationUrl) {
        $changes += "  ConfigurationUrl            = $ConfigurationUrl"
    }

    # Windows auth cannot reach the Linux container; the restored configuration
    # already carries EuroWebsite/pensandpencils, so let it through untouched.
    if (Set-AppSetting -Xml $xml -Key 'Generic.ForceIntegratedSecurity' -Value 'false') {
        $changes += '  Generic.ForceIntegratedSecurity = false'
    }

    if (-not $KeepRemoteApis) {
        foreach ($key in $LocalApis.Keys) {
            if (Set-AppSetting -Xml $xml -Key $key -Value $LocalApis[$key]) {
                $changes += "  {0,-28} = {1}" -f $key, $LocalApis[$key]
            }
        }
    }

    # Redis and RabbitMQ from docker-compose.yml, as the picker's local options.
    foreach ($key in $LocalEndpoints.Keys) {
        if (Set-AppSetting -Xml $xml -Key $key -Value $LocalEndpoints[$key]) {
            $changes += "  {0,-28} = {1}" -f $key, $LocalEndpoints[$key]
        }
    }

    # Which databases the site opens: dev_uk_supportcentre plus dev_uk_<DealerId>.
    $dealerSettings = [ordered] @{ 'Environment' = $Environment; 'DealerGroup' = $DealerGroup }
    if ($DealerSites -contains $siteName) { $dealerSettings['DealerId'] = $DealerCode }
    foreach ($key in $dealerSettings.Keys) {
        if (Set-AppSetting -Xml $xml -Key $key -Value $dealerSettings[$key]) {
            $changes += "  {0,-28} = {1}" -f $key, $dealerSettings[$key]
        }
    }

    if ($changes.Count -eq 0) {
        Write-Host '  already correct'
        continue
    }

    if ($PSCmdlet.ShouldProcess($configPath, 'update web.config')) {
        # Keep one rollback copy per run, not a pile of them.
        Copy-Item $configPath "$configPath.before-local" -Force
        $xml.Save($configPath)
    }

    $changes | ForEach-Object { Write-Host $_ }
}

Write-Host ''
$dbPrefix = Read-EnvValue 'INFRA_DB_PREFIX'
if (-not $dbPrefix) { $dbPrefix = 'dev_uk' }
Write-Host "Dealer database expected:  ${dbPrefix}_$DealerCode"
Write-Host 'Check the sites resolve:   ping -n 1 mssql'
Write-Host 'If that fails, run:        .\hosts-setup.ps1'
Write-Host 'Rollback a site:           copy web.config.before-local over web.config'
