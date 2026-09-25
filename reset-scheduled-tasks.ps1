<#
    Reset stale scheduled-task registrations after restoring a backup.

    WHY: Noodles.ScheduleCoordinator stores the NServiceBus ReplyToAddress
    of whichever service registers a scheduled task in
    dbo.sta_ScheduledTasks (column sta_OriginatingEndpoint), and reuses
    that literal string as the RabbitMQ destination every time the task
    runs. A database restored from a real environment (e.g. TEST4) has
    rows that still say something like 'test4.pow.noodles.actions', while
    the local container creates its own queue as
    'local_<container-id>.pow.noodles.actions' - so sends fail with
    "NOT_FOUND - no exchange 'test4.pow.noodles.actions'".

    WHAT THIS SCRIPT DOES:
      1. Finds every database on the local mssql container that has a
         column named sta_OriginatingEndpoint (i.e. holds
         dbo.sta_ScheduledTasks - this lives in the group's support
         centre database, e.g. test4_power_supportcentre).
      2. Empties dbo.sts_ScheduledTaskSchedules and dbo.sta_ScheduledTasks
         in each one found (safe - every Noodles service re-registers all
         of its scheduled tasks on startup, repopulating these tables
         with the current, correct address).
      3. Recreates the noodles-* containers so they re-register right away.

    WHEN TO RUN: once, right after restoring/repointing a group's database
    (i.e. right after 20-docker-overrides.sql). Safe to re-run any time -
    it is a no-op if the tables are already empty.

    USAGE: run this script from PowerShell, no arguments needed:
        .\reset-scheduled-tasks.ps1
#>

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Get-DotEnvValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [string[]]$Files = @('.env', '.env.local')
    )
    foreach ($file in $Files) {
        $path = Join-Path $PSScriptRoot $file
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($line in Get-Content -LiteralPath $path) {
            if ($line -match "^\s*#" -or $line -notmatch '=') { continue }
            $name, $value = $line.Split('=', 2)
            if ($name.Trim() -eq $Key) {
                return $value.Trim()
            }
        }
    }
    return $null
}

$envLocalPath = Join-Path $PSScriptRoot '.env.local'
if (-not (Test-Path -LiteralPath $envLocalPath)) {
    throw "Missing .env.local. Copy .env.local.example to .env.local and set MSSQL_SA_PASSWORD."
}

$env:COMPOSE_ENV_FILES = '.env,.env.local'

$sqlUser = 'sa'
$sqlPassword = Get-DotEnvValue -Key 'MSSQL_SA_PASSWORD'
if (-not $sqlPassword) {
    throw "MSSQL_SA_PASSWORD is not set in .env.local"
}
$sqlCmdPath = '/opt/mssql-tools18/bin/sqlcmd'

function Invoke-Sql {
    param(
        [string]$Database,
        [string]$Query
    )
    $sqlArgs = @('exec', '-i', 'mssql', $sqlCmdPath, '-S', 'localhost', '-U', $sqlUser, '-P', $sqlPassword, '-C', '-h', '-1', '-W')
    if ($Database) { $sqlArgs += @('-d', $Database) }
    $sqlArgs += @('-Q', $Query)
    docker @sqlArgs
}

Write-Host 'Looking for databases containing dbo.sta_ScheduledTasks (column sta_OriginatingEndpoint) ...'

$discoverQuery = @"
EXEC sp_MSforeachdb 'IF DB_ID(''?'') IS NOT NULL BEGIN
    USE [?];
    IF EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE COLUMN_NAME = ''sta_OriginatingEndpoint'')
        PRINT ''?'';
END'
"@
$rawOutput = Invoke-Sql -Database $null -Query $discoverQuery
$databases = $rawOutput | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\(\d+ rows? affected\)$' -and $_ -ne 'NULL' }

if (-not $databases) {
    Write-Warning 'No database with dbo.sta_ScheduledTasks was found. Has the group support-centre backup been restored yet?'
    exit 1
}

foreach ($db in $databases) {
    Write-Host "Clearing scheduled-task registrations in [$db] ..."

    $resetQuery = @"
SET NOCOUNT ON;
DECLARE @scheduleCount INT = 0, @taskCount INT = 0;
IF OBJECT_ID('dbo.sts_ScheduledTaskSchedules') IS NOT NULL
BEGIN
    SELECT @scheduleCount = COUNT(*) FROM dbo.sts_ScheduledTaskSchedules;
    DELETE FROM dbo.sts_ScheduledTaskSchedules;
END
SELECT @taskCount = COUNT(*) FROM dbo.sta_ScheduledTasks;
DELETE FROM dbo.sta_ScheduledTasks;
PRINT N'  sts_ScheduledTaskSchedules rows removed: ' + CAST(@scheduleCount AS NVARCHAR(10));
PRINT N'  sta_ScheduledTasks rows removed: ' + CAST(@taskCount AS NVARCHAR(10));
"@

    Invoke-Sql -Database $db -Query $resetQuery
}

Write-Host 'Recreating noodles-* containers so they re-register with their current address ...'
docker compose --profile noodles up -d --force-recreate

Write-Host 'Done.'
