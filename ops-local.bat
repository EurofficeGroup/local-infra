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
rem    reset-tasks             Clear stale scheduled tasks + recreate noodles
rem    core-restart            Restart mssql rabbit redis mailpit
rem    help                    Show this list
rem ======================================================================

cd /d "%~dp0"

set "ACTION=%~1"
set "SVC_ARG=%~2"

if "%ACTION%"=="" goto show_help
if /i "%ACTION%"=="help" goto show_help
if /i "%ACTION%"=="-h" goto show_help
if /i "%ACTION%"=="--help" goto show_help

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

call :read_env MSSQL_SA_PASSWORD
call :read_env INFRA_DB_PREFIX
if not defined MSSQL_SA_PASSWORD (
  echo ERROR: MSSQL_SA_PASSWORD is not set in .env.local
  call :fail_pause
  exit /b 1
)
if not defined INFRA_DB_PREFIX set "INFRA_DB_PREFIX=test4_power"
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
if /i "%ACTION%"=="reset-tasks"     goto act_reset_tasks
if /i "%ACTION%"=="core-restart"    goto act_core_restart

echo Unknown action: %ACTION%
echo.
goto show_help

rem ---------- actions ----------

:act_noodles_rebuild
echo Rebuilding noodles image VPN / NuGet may be required ...
docker compose build noodles-build
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
docker compose build config-api
if errorlevel 1 (
  echo ERROR: config-api build failed.
  call :fail_pause
  exit /b 1
)
echo Recreating config-api ...
docker compose up -d --force-recreate --no-deps config-api
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
goto success

:act_config_restart
echo Recreating config-api ...
docker compose up -d --force-recreate --no-deps config-api
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
goto success

:act_apis_rebuild
echo Rebuilding satellite APIs ...
docker compose --profile apis build
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
echo Recreating satellite APIs ...
docker compose --profile apis up -d --force-recreate
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
goto success

:act_apis_restart
echo Recreating satellite APIs ...
docker compose --profile apis up -d --force-recreate
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
goto success

:act_overrides
echo Applying 20-docker-overrides.sql against [%SUPPORT_CENTRE%] ...
docker exec -i mssql %SQLCMD% -S localhost -U sa -P "%MSSQL_SA_PASSWORD%" -C -d "%SUPPORT_CENTRE%" -i /init/20-docker-overrides.sql
if errorlevel 1 (
  echo ERROR: overrides failed. Is mssql up and [%SUPPORT_CENTRE%] restored?
  call :fail_pause
  exit /b 1
)
echo.
echo Tip: if Environment / hostname changed, also run: ops-local.bat reset-tasks
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
docker compose restart mssql rabbit redis mailpit
if errorlevel 1 (
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
  "$svcs = docker compose config --services | Where-Object { $_ -like 'noodles-*' };" ^
  "if (-not $svcs) { throw 'No noodles-* services found in compose.' };" ^
  "Write-Host ('  ' + ($svcs -join ', '));" ^
  "docker compose up -d --force-recreate --no-deps @svcs;" ^
  "if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }"
exit /b %ERRORLEVEL%

:recreate_one_noodles
set "ONE=noodles-%~1"
echo Recreating %ONE% ...
docker compose up -d --force-recreate --no-deps %ONE%
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
echo   reset-tasks              reset-scheduled-tasks.ps1
echo   core-restart             Restart mssql rabbit redis mailpit
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
