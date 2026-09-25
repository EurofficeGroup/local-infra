<#
.SYNOPSIS
    Points the IIS-hosted Power sites at this machine's local infrastructure.
    Run it AFTER WebConfigPicker's "Do the Magic!", every time.

.DESCRIPTION
    WHAT WEBCONFIGPICKER ALREADY DOES

    It copies each site's web.config from the chosen environment's server share
    and rewrites a handful of endpoints. With the local options ticked:

        Cache / Redis.ConnectionString  localhost:6379
        Rabbit                          host=localhost
        UseAzureServiceBus              false
        ConfigurationUrl                http://localhost:8080/configuration

    Those ports are exactly the ones docker-compose.yml publishes, so the tool
    and this stack already agree. Nothing to change there.

    WHAT IT DOES NOT DO

    1. It never touches the database. It cannot: the Power sites have no
       connection string of their own. They ask the Configuration API, and the
       Configuration API answers from whichever support centre it was pointed
       at. So "use my local database" is not a picker setting - it follows
       automatically once ConfigurationUrl is local, because our container reads
       the restored test4_power_supportcentre and returns Data Source=mssql,1433.

       Which means: tick "Configuration API - Use local", or the site will read
       TEST4's configuration and go straight to the test database, no matter
       what else is set.

    2. Generic.ForceIntegratedSecurity is left at true, and it is fatal here.
       PlaceholderDealerSepcificConnectionProviderConfigApi strips the user and
       password off the connection string and switches to Windows auth - which
       a Linux SQL Server container cannot accept. The site then fails to open
       any connection at all. This script sets it to false.

    Run as administrator: reading site paths out of IIS needs it, which is why
    WebConfigPicker asks for the same.

.EXAMPLE
    .\power-local-setup.ps1

.EXAMPLE
    .\power-local-setup.ps1 -WhatIf
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
    [switch] $KeepRemoteApis
)

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

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
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
        if ($node.value -eq $Value) { return $false }
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
Write-Host 'Check the sites resolve:   ping -n 1 mssql'
Write-Host 'If that fails, run:        .\hosts-setup.ps1'
Write-Host 'Rollback a site:           copy web.config.before-local over web.config'
