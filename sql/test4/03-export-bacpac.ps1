<#
.SYNOPSIS
    Fallback route: pull TEST4 databases to this machine without any file access
    to the server, using sqlpackage.

.DESCRIPTION
    This is the closest thing SQL Server has to pg_dump. sqlpackage runs HERE,
    connects the same way SSMS does, and writes a .bacpac on THIS machine. The
    server never writes a file, so no share, no admin share, no RDP.

    Read-only against TEST4: it reads schema and data, and creates nothing.

    THE CATCH, and it is a real one. A .bacpac is not a backup - it is schema
    plus data, and the export validates the schema first. If any view, procedure
    or function references another database by a three-part name, the export
    fails with "unresolved reference". These databases very likely do that:
    local_sc.sql sets SupportCentreSchema = dev_uk_supportcentre.dbo and
    DealerSchema = dev_uk_{0}.dbo, which is exactly that pattern.

    So try one small database first (-Databases test4_power_nservicebus). If it
    fails on unresolved references, this route is closed and you are back to
    getting a .bak onto a share - see README.md.

    Also: the export is not transactionally consistent on a live database. For a
    local dev copy of a test environment that is acceptable. Do not use a bacpac
    taken this way as a real backup of anything.

.EXAMPLE
    .\03-export-bacpac.ps1 -Databases test4_power_nservicebus

.EXAMPLE
    .\03-export-bacpac.ps1
#>

[CmdletBinding()]
param(
    [string]   $Server    = 'vm-tstdb-uks-02.datacentre.euroffice.com',
    [string[]] $Databases = @(
        'test4_power_supportcentre',
        'test4_power_productcatalogue',
        'test4_power_nservicebus',
        'test4_power_idl',
        'test4_power_jst'
    ),
    [string]   $OutDir    = 'C:\workspace\local-infra\sql\backup'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
# sqlpackage
# ---------------------------------------------------------------------
$cmd = Get-Command sqlpackage -ErrorAction SilentlyContinue
$sqlpackage = if ($cmd) { $cmd.Source } else { $null }

if (-not $sqlpackage) {
    $candidates = @(
        "$env:ProgramFiles\Microsoft SQL Server\170\DAC\bin\sqlpackage.exe",
        "$env:ProgramFiles\Microsoft SQL Server\160\DAC\bin\sqlpackage.exe",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server\160\DAC\bin\sqlpackage.exe",
        "$env:USERPROFILE\.dotnet\tools\sqlpackage.exe"
    )
    $sqlpackage = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $sqlpackage) {
    Write-Host 'sqlpackage not found. Install it with the dotnet SDK you already have:'
    Write-Host ''
    Write-Host '    dotnet tool install -g microsoft.sqlpackage'
    Write-Host ''
    Write-Host 'Or use the SSMS wizard instead, which does the same thing:'
    Write-Host '    right-click the database -> Tasks -> Export Data-tier Application'
    throw 'sqlpackage is required.'
}

Write-Host "Using $sqlpackage"

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

# ---------------------------------------------------------------------
# Export loop - one failure must not stop the rest
# ---------------------------------------------------------------------
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$results = @()

foreach ($db in $Databases) {
    $target = Join-Path $OutDir "$($db)_$stamp.bacpac"
    Write-Host ''
    Write-Host "=== $db -> $target"

    $started = Get-Date
    try {
        & $sqlpackage `
            /Action:Export `
            /SourceServerName:$Server `
            /SourceDatabaseName:$db `
            /TargetFile:$target `
            /SourceTrustServerCertificate:True `
            /p:Storage=File `
            /p:CommandTimeout=0 `
            /p:VerifyExtraction=False

        if ($LASTEXITCODE -ne 0) {
            throw "sqlpackage exited with $LASTEXITCODE"
        }

        $sizeMb = [math]::Round((Get-Item $target).Length / 1MB, 1)
        $results += [pscustomobject]@{
            Database = $db
            Status   = 'OK'
            SizeMB   = $sizeMb
            Minutes  = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
            Detail   = ''
        }
    }
    catch {
        $results += [pscustomobject]@{
            Database = $db
            Status   = 'FAILED'
            SizeMB   = $null
            Minutes  = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
            Detail   = $_.Exception.Message
        }
        Write-Warning "$db failed: $($_.Exception.Message)"
        if (Test-Path $target) { Remove-Item $target -Force }   # no half-written files
    }
}

Write-Host ''
$results | Format-Table -AutoSize

if ($results.Status -contains 'FAILED') {
    Write-Host ''
    Write-Host 'If the failures mention unresolved references to another database,'
    Write-Host 'the bacpac route will not work for these schemas. See README.md -'
    Write-Host 'you need the .bak on a share the server can write to.'
}
