@echo off
setlocal EnableExtensions
rem Do NOT enable delayed expansion: MSSQL_SA_PASSWORD contains '!'.

rem ======================================================================
rem  Day-to-day ops against an already-running local-infra stack.
rem  Not a from-scratch install - use setup-local.bat for that.
rem
rem  Usage:
rem    ops-local.bat <action> [service]
rem
rem  Actions:
rem    noodles-rebuild [name]  Rebuild infra/noodles:local, recreate noodles
rem                            Optional name: sales -> noodles-sales only
rem    noodles-restart [name]  Recreate noodles containers (no rebuild)
rem    config-rebuild          Rebuild and recreate config-api
rem    config-restart          Recreate config-api only
rem    apis-rebuild            Rebuild and recreate satellite APIs
rem    apis-restart            Recreate satellite APIs only
rem    overrides               Re-run 20-docker-overrides.sql on support-centre
rem    rename-refs             Re-run 30-rename-db-references.sql
rem    reset-tasks             Clear stale scheduled tasks + recreate noodles
rem    core-restart            Restart mssql rabbit redis mailpit
rem    power                   Re-apply local settings to the Power web.configs
rem                            power-local-setup.ps1 - needs Administrator
rem    help                    Show this list
rem ======================================================================

cd /d "%~dp0"

set "ACTION=%~1"
set "SVC_ARG=%~2"

if "%ACTION%"=="" goto show_help
if /i "%ACTION%"=="help" goto show_help
if /i "%ACTION%"=="-h" goto show_help
if /i "%ACTION%"=="--help" goto show_help
rem Only edits files on the host - no Docker or .env.local password needed.
if /i "%ACTION%"=="power" goto act_power

where docker >nul 2>&1
if errorlevel 1 (
  echo ERROR: docker is not on PATH.
  call :fail_pause
  exit /b 1
)
docker info >nul 2>&1
if errorlevel 1 (
  echo ERROR: Docker daemon is not running.
  call :fail_pause
  exit /b 1
)

if not exist "%~dp0.env.local" (
  echo ERROR: Missing .env.local
  echo Copy .env.local.example to .env.local and set MSSQL_SA_PASSWORD.
  call :fail_pause
  exit /b 1
)
set "COMPOSE_ENV_FILES=.env,.env.local"

rem Three compose projects = three groups in Docker Desktop:
rem   power      docker-compose.yml          mssql rabbit redis mailpit (+ search)
rem   api-power  docker-compose.api.yml      config-api + satellite APIs
rem   noodles    docker-compose.noodles.yml  noodles-*
set "DC_POWER=docker compose -f docker-compose.yml"
set "DC_API=docker compose -f docker-compose.api.yml"
set "DC_NOODLES=docker compose -f docker-compose.noodles.yml"
set "API_SERVICES=api-tax api-pricing api-product api-payments api-audience"

call :read_env MSSQL_SA_PASSWORD
call :read_env INFRA_DB_PREFIX
call :read_env INFRA_BACKUP_PREFIX
call :read_env INFRA_DEALER_CODE
if not defined MSSQL_SA_PASSWORD (
  echo ERROR: MSSQL_SA_PASSWORD is not set in .env.local
  call :fail_pause
  exit /b 1
)
if not defined INFRA_DB_PREFIX set "INFRA_DB_PREFIX=dev_uk"
if not defined INFRA_BACKUP_PREFIX set "INFRA_BACKUP_PREFIX=test4_power"
if not defined INFRA_DEALER_CODE set "INFRA_DEALER_CODE=jst"
call :check_db_vars
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
set "SUPPORT_CENTRE=%INFRA_DB_PREFIX%_supportcentre"
set "SQLCMD=/opt/mssql-tools18/bin/sqlcmd"

echo.
echo === local-infra ops: %ACTION% ===
echo.

if /i "%ACTION%"=="noodles-rebuild" goto act_noodles_rebuild
if /i "%ACTION%"=="noodles-restart" goto act_noodles_restart
if /i "%ACTION%"=="config-rebuild"  goto act_config_rebuild
if /i "%ACTION%"=="config-restart"  goto act_config_restart
if /i "%ACTION%"=="apis-rebuild"    goto act_apis_rebuild
if /i "%ACTION%"=="apis-restart"    goto act_apis_restart
if /i "%ACTION%"=="overrides"       goto act_overrides
if /i "%ACTION%"=="rename-refs"     goto act_rename_refs
if /i "%ACTION%"=="reset-tasks"     goto act_reset_tasks
if /i "%ACTION%"=="core-restart"    goto act_core_restart

echo Unknown action: %ACTION%
echo.
goto show_help

rem ---------- actions ----------

:act_noodles_rebuild
echo Rebuilding noodles image VPN / NuGet may be required ...
%DC_NOODLES% build noodles-build
if errorlevel 1 (
  echo ERROR: noodles-build failed.
  call :fail_pause
  exit /b 1
)
call :recreate_noodles
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
goto success

:act_noodles_restart
call :recreate_noodles
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
goto success

:act_config_rebuild
echo Rebuilding config-api ...
%DC_API% build config-api
if errorlevel 1 (
  echo ERROR: config-api build failed.
  call :fail_pause
  exit /b 1
)
echo Recreating config-api ...
%DC_API% up -d --force-recreate --no-deps config-api
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
goto success

:act_config_restart
echo Recreating config-api ...
%DC_API% up -d --force-recreate --no-deps config-api
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
goto success

:act_apis_rebuild
echo Rebuilding satellite APIs ...
%DC_API% build %API_SERVICES%
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
echo Recreating satellite APIs ...
%DC_API% up -d --force-recreate --no-deps %API_SERVICES%
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
goto success

:act_apis_restart
echo Recreating satellite APIs ...
%DC_API% up -d --force-recreate --no-deps %API_SERVICES%
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
goto success

:act_rename_refs
echo Rewriting test4 database names inside synonyms / views / procedures ...
call :run_sql "%~dp0sql\init\30-rename-db-references.sql" ""
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
goto success

:act_overrides
echo Applying 20-docker-overrides.sql against [%SUPPORT_CENTRE%] ...
call :run_sql "%~dp0sql\init\20-docker-overrides.sql" "%SUPPORT_CENTRE%"
if errorlevel 1 (
  echo ERROR: overrides failed. Is mssql up and [%SUPPORT_CENTRE%] restored?
  call :fail_pause
  exit /b 1
)
echo.
echo Tip: if Environment / hostname changed, also run: ops-local.bat reset-tasks
echo Tip: config-api and the Power sites cache configuration - run ops-local.bat config-restart
echo      and restart the IIS sites wfe, portal, admin, cdn or recycle their app pools.
goto success

:act_reset_tasks
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0reset-scheduled-tasks.ps1"
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
goto success

:act_core_restart
echo Restarting core containers mssql rabbit redis mailpit ...
%DC_POWER% restart mssql rabbit redis mailpit
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
goto success

:act_power
echo.
echo === local-infra ops: power ===
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0power-local-setup.ps1"
if errorlevel 1 (
  echo ERROR: power-local-setup.ps1 failed - run ops-local.bat from an elevated prompt.
  call :fail_pause
  exit /b 1
)
goto success

rem ---------- helpers ----------

:recreate_noodles
if not "%SVC_ARG%"=="" (
  call :recreate_one_noodles "%SVC_ARG%"
  exit /b %ERRORLEVEL%
)

echo Recreating all noodles-* containers config-api left alone ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$svcs = docker compose -f docker-compose.noodles.yml config --services | Where-Object { $_ -like 'noodles-*' -and $_ -ne 'noodles-build' };" ^
  "if (-not $svcs) { throw 'No noodles-* services found in compose.' };" ^
  "Write-Host ('  ' + ($svcs -join ', '));" ^
  "docker compose -f docker-compose.noodles.yml up -d --force-recreate --no-deps @svcs;" ^
  "if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }"
exit /b %ERRORLEVEL%

:recreate_one_noodles
set "ONE=noodles-%~1"
echo Recreating %ONE% ...
%DC_NOODLES% up -d --force-recreate --no-deps %ONE%
exit /b %ERRORLEVEL%

:run_sql
rem Pipes a SQL script into sqlcmd in the mssql container, substituting the
rem database switch from .env into its DECLARE lines first:
rem   @SourcePrefix <- INFRA_BACKUP_PREFIX   @TargetPrefix <- INFRA_DB_PREFIX
rem   @DealerCode   <- INFRA_DEALER_CODE     @WhatIf 1 -> 0 when arg 3 is apply
rem   arg 1 = script path on the host, arg 2 = database ("" = master)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$db = '%~2'; $dbArgs = @(); if ($db) { $dbArgs = @('-d', $db) };" ^
  "$set = { param($line, $name, $value) $line -replace ('^(DECLARE @' + $name + '\s.*?=\s*)N''[^'']*'''), ('${1}N''' + $value + '''') };" ^
  "Get-Content -LiteralPath '%~1' | ForEach-Object {" ^
  "  $l = $_;" ^
  "  if ('%~3' -eq 'apply') { $l = $l -replace 'DECLARE @WhatIf\s+BIT = 1','DECLARE @WhatIf    BIT = 0' };" ^
  "  $l = & $set $l 'SourcePrefix' $env:INFRA_BACKUP_PREFIX;" ^
  "  $l = & $set $l 'TargetPrefix' $env:INFRA_DB_PREFIX;" ^
  "  & $set $l 'DealerCode' $env:INFRA_DEALER_CODE" ^
  "} | docker exec -i mssql %SQLCMD% -S localhost -U sa -P $env:MSSQL_SA_PASSWORD -C @dbArgs;" ^
  "exit $LASTEXITCODE"
exit /b %ERRORLEVEL%

:check_db_vars
rem The three names end up inside SQL string literals and database names, so
rem allow only letters, digits and underscores.
powershell -NoProfile -Command ^
  "$bad = @('INFRA_DB_PREFIX','INFRA_BACKUP_PREFIX','INFRA_DEALER_CODE') | Where-Object { [Environment]::GetEnvironmentVariable($_) -notmatch '^[A-Za-z0-9_]+$' };" ^
  "if ($bad) { Write-Host ('ERROR: ' + ($bad -join ', ') + ' in .env must be letters, digits or _ only.') -ForegroundColor Red; exit 1 }; exit 0"
exit /b %ERRORLEVEL%

:read_env
set "KEY=%~1"
set "%KEY%="
for /f "usebackq tokens=1,* delims==" %%A in (`findstr /b /c:"%KEY%=" "%~dp0.env" 2^>nul`) do (
  set "%KEY%=%%B"
)
for /f "usebackq tokens=1,* delims==" %%A in (`findstr /b /c:"%KEY%=" "%~dp0.env.local" 2^>nul`) do (
  set "%KEY%=%%B"
)
exit /b 0

:show_help
echo Day-to-day ops for local-infra already set up by setup-local.bat.
echo.
echo Usage:  ops-local.bat ^<action^> [service]
echo.
echo Actions:
echo   noodles-rebuild [name]   Rebuild noodles image + recreate containers
echo                            Example: ops-local.bat noodles-rebuild sales
echo   noodles-restart [name]   Recreate noodles only no rebuild
echo   config-rebuild           Rebuild + recreate config-api
echo   config-restart           Recreate config-api
echo   apis-rebuild             Rebuild + recreate satellite APIs
echo   apis-restart             Recreate satellite APIs
echo   overrides                Re-run 20-docker-overrides.sql
echo   rename-refs              Re-run 30-rename-db-references.sql
echo   reset-tasks              reset-scheduled-tasks.ps1
echo   core-restart             Restart mssql rabbit redis mailpit
echo   power                    Re-apply local settings to Power web.configs - elevated
echo   help                     This list
echo.
echo Full from-scratch install:  setup-local.bat
echo Wipe and reinstall:         setup-local.bat --wipe
echo.
pause
exit /b 0

:success
echo.
powershell -NoProfile -Command "Write-Host 'Done.' -ForegroundColor Green"
echo.
pause
exit /b 0

:fail_pause
echo.
powershell -NoProfile -Command "Write-Host 'Operation failed.' -ForegroundColor Red"
echo.
pause
exit /b 0
