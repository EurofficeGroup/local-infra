<#
.SYNOPSIS
    Shares the local backup folder so the TEST4 SQL Server can write .bak files
    straight onto this machine.

.DESCRIPTION
    SQL Server has no client-side dump like pg_dump. BACKUP DATABASE always
    writes from the server. The only way the file lands here directly is if the
    server writes it to a share this machine exposes.

    This script:
      1. creates C:\workspace\local-infra\sql\backup if it is missing
      2. shares it as \\<this machine>\sqlbackup
      3. grants the SQL Server service account Change on the share and Modify
         on the filesystem
      4. opens inbound SMB (445) for the server's address only
      5. prints the UNC path to paste into @BackupRoot

    Run it in an ELEVATED PowerShell. Nothing here touches TEST4.

.PARAMETER ServiceAccount
    The account from 00-find-service-account.sql, e.g. EUROFFICE\VM-TSTDB-UKS-02$
    or EUROFFICE\svc-sql.

.PARAMETER ServerAddress
    The TEST4 server, used to scope the firewall rule.

.EXAMPLE
    .\share-setup.ps1 -ServiceAccount 'EUROFFICE\VM-TSTDB-UKS-02$'

.EXAMPLE
    # undo everything afterwards
    .\share-setup.ps1 -Remove
#>

[CmdletBinding()]
param(
    [string] $ServiceAccount,
    [string] $ShareName     = 'sqlbackup',
    [string] $Path          = 'C:\workspace\local-infra\sql\backup',
    [string] $ServerAddress = 'vm-tstdb-uks-02.datacentre.euroffice.com',
    [string] $FirewallRule  = 'SQL backup inbound from TEST4',
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this in an elevated PowerShell (Run as administrator).'
    }
}

Assert-Elevated

# ---------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------
if ($Remove) {
    if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) {
        Remove-SmbShare -Name $ShareName -Force
        Write-Host "Removed share $ShareName"
    }
    if (Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName $FirewallRule
        Write-Host "Removed firewall rule '$FirewallRule'"
    }
    Write-Host 'Done. The .bak files themselves were left alone.'
    return
}

if (-not $ServiceAccount) {
    throw 'Pass -ServiceAccount. Get it by running 00-find-service-account.sql on the TEST4 server.'
}

# ---------------------------------------------------------------------
# Folder
# ---------------------------------------------------------------------
if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Write-Host "Created $Path"
}

$free = (Get-PSDrive -Name (Split-Path $Path -Qualifier).TrimEnd(':')).Free / 1GB
Write-Host ("Free space on that drive: {0:N1} GB" -f $free)
if ($free -lt 20) {
    Write-Warning 'Under 20 GB free. The power set needs roughly 5 GB compressed; check before backing up more than that.'
}

# ---------------------------------------------------------------------
# Share
# ---------------------------------------------------------------------
$share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
if ($share) {
    Write-Host "Share $ShareName already exists -> $($share.Path)"
    if ($share.Path -ne $Path) {
        throw "Share $ShareName points at $($share.Path), not $Path. Remove it first or pick another -ShareName."
    }
} else {
    New-SmbShare -Name $ShareName -Path $Path -FullAccess $ServiceAccount | Out-Null
    Write-Host "Created share $ShareName with full access for $ServiceAccount"
}

Grant-SmbShareAccess -Name $ShareName -AccountName $ServiceAccount `
                     -AccessRight Change -Force | Out-Null

# NTFS on top of the share permission - both have to allow the write.
$acl  = Get-Acl $Path
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $ServiceAccount,
            'Modify',
            'ContainerInherit,ObjectInherit',
            'None',
            'Allow')
$acl.SetAccessRule($rule)
Set-Acl -Path $Path -AclObject $acl
Write-Host "Granted Modify on $Path to $ServiceAccount"

# ---------------------------------------------------------------------
# Firewall - scoped to the one server, not opened to the network
# ---------------------------------------------------------------------
$addresses = @()
try {
    $addresses = [System.Net.Dns]::GetHostAddresses($ServerAddress) |
                 Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                 ForEach-Object { $_.IPAddressToString }
} catch {
    Write-Warning "Could not resolve $ServerAddress - are you on the VPN? Firewall rule skipped."
}

if ($addresses) {
    if (Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName $FirewallRule
    }
    New-NetFirewallRule -DisplayName $FirewallRule `
                        -Direction Inbound -Protocol TCP -LocalPort 445 `
                        -RemoteAddress $addresses -Action Allow `
                        -Profile Any | Out-Null
    Write-Host "Opened inbound TCP 445 from $($addresses -join ', ')"
}

# ---------------------------------------------------------------------
# What to paste into the backup script
# ---------------------------------------------------------------------
$unc = "\\$($env:COMPUTERNAME)\$ShareName\"

Write-Host ''
Write-Host '--------------------------------------------------------------'
Write-Host 'Put this in 01-backup-test4.sql:'
Write-Host ''
Write-Host "    DECLARE @BackupRoot NVARCHAR(500) = N'$unc';"
Write-Host ''
Write-Host 'Then, on the TEST4 server, prove the path works before backing up'
Write-Host 'anything large - master is a few MB:'
Write-Host ''
Write-Host "    BACKUP DATABASE master TO DISK = N'${unc}smoketest.bak' WITH COPY_ONLY, INIT;"
Write-Host ''
Write-Host 'If that fails with "Operating system error 5 (Access is denied)" or'
Write-Host '53 (network path not found), the server cannot reach this machine.'
Write-Host 'That is normal on a VPN that blocks inbound SMB to clients - use the'
Write-Host 'bacpac route in README.md instead.'
Write-Host '--------------------------------------------------------------'

Write-Host ''
Write-Host "Undo with: .\share-setup.ps1 -Remove"
