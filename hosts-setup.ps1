<#
.SYNOPSIS
    Points the container hostnames at 127.0.0.1 in the Windows hosts file, so one
    configuration works both inside containers and on this machine.

.DESCRIPTION
    THE PROBLEM THIS SOLVES

    The configuration is stored once, in cfg_Configurations, and read by two
    different kinds of process:

      - Noodles services in containers, which reach SQL Server at `mssql`
        and cannot reach `localhost` (inside a container that is the container)
      - Power sites on this machine under IIS, .NET Framework 4.7.2, which can
        never be containerised and reach SQL Server at 127.0.0.1

    One config value cannot be both `mssql` and `localhost`... unless `mssql`
    also resolves to 127.0.0.1 here. That is all this script does.

    Container ports are published unchanged - 1433, 5672, 6379, 1025, 8080 - so
    the same host:port works from either side.

    The project already uses this pattern: power/InitialSetup.ps1 adds wfe,
    portal, admin and cdn the same way.

.EXAMPLE
    .\hosts-setup.ps1

.EXAMPLE
    .\hosts-setup.ps1 -Remove
#>

[CmdletBinding()]
param(
    [switch] $Remove,
    [string] $HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
)

$ErrorActionPreference = 'Stop'

# LOCAL_HOSTNAME: every noodles/config-api container's `hostname:` in
# docker-compose.yml reads this from .env, and Power on this same machine
# computes its own NServiceBus endpoint address from $env:COMPUTERNAME too
# (Multitenancy.Common.cs's GetCuratedEnvironment). Windows always reports
# COMPUTERNAME upper-case, but the noodles code lower-cases it before using it
# in a RabbitMQ routing key while at least one other shared endpoint (the
# config-api-side NServiceBus setup) does not - so two containers computing
# the "same" name in different case end up with routing keys that never
# match, and events between them silently stop being delivered. Writing an
# already-lower-cased value here means every container starts from an
# identical string and no service-side code has to be trusted to normalise
# it. Doesn't need admin rights, so it runs before the elevation check below.
$envFile = Join-Path $PSScriptRoot '.env'
$localHostname = $env:COMPUTERNAME.ToLowerInvariant()
$hostnameLine = "LOCAL_HOSTNAME=$localHostname"
if (Test-Path $envFile) {
    $envContent = Get-Content $envFile
    if ($envContent -match '^LOCAL_HOSTNAME=') {
        $envContent = $envContent -replace '^LOCAL_HOSTNAME=.*$', $hostnameLine
    }
    else {
        $envContent += ''
        $envContent += '# Written by hosts-setup.ps1 - the lower-cased machine name every'
        $envContent += '# container''s hostname is pinned to, so routing keys match across services.'
        $envContent += $hostnameLine
    }
    Set-Content -Path $envFile -Value $envContent -Encoding ASCII
    Write-Host "Set $hostnameLine in .env"
}
else {
    Write-Warning ".env not found next to this script - skipped writing $hostnameLine"
}

$marker = '# --- euroffice local-infra ---'
$endMarker = '# --- end euroffice local-infra ---'

$entries = @(
    @{ Name = 'mssql';      Why = 'SQL Server container' }
    @{ Name = 'rabbit';     Why = 'RabbitMQ container' }
    @{ Name = 'redis';      Why = 'Redis container' }
    @{ Name = 'mailpit';    Why = 'Mailpit SMTP container' }
    @{ Name = 'config-api'; Why = 'Configuration API container' }
    @{ Name = 'elastic';    Why = 'Elasticsearch container (search profile)' }
)

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this in an elevated PowerShell (Run as administrator).'
}

$content = Get-Content $HostsFile -ErrorAction SilentlyContinue
if (-not $content) { $content = @() }

# Always strip our previous block first, so this is idempotent and -Remove is
# just the same operation without the re-add.
$start = [array]::IndexOf($content, $marker)
if ($start -ge 0) {
    $end = [array]::IndexOf($content, $endMarker)
    if ($end -lt $start) { $end = $content.Count - 1 }
    $content = @($content[0..($start - 1)]) + @($content[($end + 1)..($content.Count - 1)])
    $content = $content | Where-Object { $_ -ne $null }
}

if ($Remove) {
    Set-Content -Path $HostsFile -Value $content -Encoding ASCII
    Write-Host 'Removed the local-infra host entries.'
    return
}

# Warn about names already mapped elsewhere - overriding someone else's entry
# silently would be a nasty surprise.
foreach ($e in $entries) {
    $clash = $content | Where-Object { $_ -match "^\s*[^#\s]+\s+.*\b$($e.Name)\b" }
    if ($clash) {
        Write-Warning "'$($e.Name)' already appears in the hosts file: $clash"
    }
}

$block = @($marker)
foreach ($e in $entries) {
    $block += ('127.0.0.1       {0,-12} # {1}' -f $e.Name, $e.Why)
}
$block += $endMarker

Set-Content -Path $HostsFile -Value (@($content) + $block) -Encoding ASCII

Write-Host 'Added:'
$block | Select-Object -Skip 1 | Select-Object -SkipLast 1 | ForEach-Object { Write-Host "  $_" }
Write-Host ''
Write-Host 'Check it resolves:  ping -n 1 mssql'
Write-Host 'Undo with:          .\hosts-setup.ps1 -Remove'
