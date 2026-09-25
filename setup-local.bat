@echo off
setlocal EnableExtensions
rem Do NOT enable delayed expansion: MSSQL_SA_PASSWORD may contain '!'.

rem ======================================================================
rem  Bring up the local-infra stack from scratch (Windows).
rem  Run from an elevated Command Prompt / PowerShell when possible:
rem  hosts-setup.ps1 and --power need Administrator.
rem
rem  Usage:
rem    setup-local.bat
rem    setup-local.bat --wipe
rem    setup-local.bat --skip-hosts --skip-build
rem    setup-local.bat --apis --power
rem ======================================================================

cd /d "%~dp0"

set "DO_WIPE=0"
set "SKIP_HOSTS=0"
set "SKIP_RESTORE=0"
set "SKIP_BUILD=0"
set "SKIP_NOODLES=0"
set "DO_APIS=0"
set "DO_POWER=0"

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--wipe"         set "DO_WIPE=1"      & shift & goto parse_args
if /i "%~1"=="--skip-hosts"   set "SKIP_HOSTS=1"   & shift & goto parse_args
if /i "%~1"=="--skip-restore" set "SKIP_RESTORE=1" & shift & goto parse_args
if /i "%~1"=="--skip-build"   set "SKIP_BUILD=1"   & shift & goto parse_args
if /i "%~1"=="--skip-noodles" set "SKIP_NOODLES=1" & shift & goto parse_args
if /i "%~1"=="--apis"         set "DO_APIS=1"      & shift & goto parse_args
if /i "%~1"=="--power"        set "DO_POWER=1"     & shift & goto parse_args
echo Unknown argument: %~1
echo Usage: setup-local.bat [--wipe] [--skip-hosts] [--skip-restore] [--skip-build] [--skip-noodles] [--apis] [--power]
call :fail_pause
exit /b 1
:args_done

if not exist "%~dp0.env.local" (
  echo ERROR: Missing .env.local
  echo Copy .env.local.example to .env.local and set MSSQL_SA_PASSWORD.
  call :fail_pause
  exit /b 1
)

rem Compose interpolates ${MSSQL_SA_PASSWORD} from .env.local (not from .env).
set "COMPOSE_ENV_FILES=.env,.env.local"

call :read_env MSSQL_SA_PASSWORD
call :read_env INFRA_DB_PREFIX
if not defined MSSQL_SA_PASSWORD (
  echo ERROR: MSSQL_SA_PASSWORD is not set in .env.local
  echo Copy .env.local.example to .env.local and set the password.
  call :fail_pause
  exit /b 1
)
if not defined INFRA_DB_PREFIX set "INFRA_DB_PREFIX=test4_power"
set "SUPPORT_CENTRE=%INFRA_DB_PREFIX%_supportcentre"
set "SQLCMD=/opt/mssql-tools18/bin/sqlcmd"

echo.
echo === local-infra setup ===
echo Support centre DB: %SUPPORT_CENTRE%
echo.

rem ---------- prerequisites ----------
where docker >nul 2>&1
if errorlevel 1 (
  echo ERROR: docker is not on PATH. Install Docker Desktop and try again.
  call :fail_pause
  exit /b 1
)
docker info >nul 2>&1
if errorlevel 1 (
  echo ERROR: Docker daemon is not running. Start Docker Desktop and try again.
  call :fail_pause
  exit /b 1
)

rem ---------- 0. wipe to zero optional / on every failed retry ----------
if "%DO_WIPE%"=="1" (
  echo [0/8] Wiping stack and volumes to zero ...
  docker compose --profile all down -v --remove-orphans
  if errorlevel 1 (
    echo ERROR: wipe failed.
    call :fail_pause
    exit /b 1
  )
  echo   Stack removed. Starting from a clean slate.
  echo.
)

rem ---------- 1. hosts + LOCAL_HOSTNAME ----------
if "%SKIP_HOSTS%"=="1" (
  echo [1/8] Skipping hosts-setup.ps1
) else (
  echo [1/8] Running hosts-setup.ps1 ...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hosts-setup.ps1"
  if errorlevel 1 (
    echo.
    echo ERROR: hosts-setup.ps1 failed. Re-run this .bat from an elevated prompt,
    echo        or pass --skip-hosts if the hosts file and LOCAL_HOSTNAME are already set.
    call :fail_pause
    exit /b 1
  )
)

rem ---------- 2. core ----------
echo [2/8] Starting core containers mssql rabbit redis mailpit ...
docker compose up -d
if errorlevel 1 (
  echo ERROR: docker compose up -d failed.
  call :fail_pause
  exit /b 1
)

echo Waiting for mssql and rabbit to become healthy ...
call :wait_healthy mssql 180
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)
call :wait_healthy rabbit 120
if errorlevel 1 (
  call :fail_pause
  exit /b 1
)

rem ---------- 3-4. SQL login / restore / overrides ----------
if "%SKIP_RESTORE%"=="1" (
  echo [3/8] Skipping SQL login / restore / overrides
) else (
  echo [3/8] Creating application logins 00-login-and-databases.sql ...
  docker exec -i mssql %SQLCMD% -S localhost -U sa -P "%MSSQL_SA_PASSWORD%" -C -i /init/00-login-and-databases.sql
  if errorlevel 1 (
    echo ERROR: 00-login-and-databases.sql failed.
    call :fail_pause
    exit /b 1
  )

  dir /b "%~dp0sql\backup\*.bak" >nul 2>&1
  if errorlevel 1 (
    echo.
    echo ERROR: No .bak files found in sql\backup\.
    echo Place the group backups there first, then re-run without --skip-restore.
    call :fail_pause
    exit /b 1
  )

  echo [4/8] Restoring backups from sql\backup ...
  echo.
  powershell -NoProfile -Command "Write-Host 'NOTE: Database restore can take a long time (tens of minutes for ~15 GB).' -ForegroundColor Yellow; Write-Host 'The console will look frozen until sqlcmd finishes - that is normal. Just wait.' -ForegroundColor Yellow"
  echo.
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$ErrorActionPreference='Stop';" ^
    "Get-Content -LiteralPath '%~dp0sql\test4\02-restore-local.sql' |" ^
    "  ForEach-Object { $_ -replace 'DECLARE @WhatIf\s+BIT = 1','DECLARE @WhatIf    BIT = 0' } |" ^
    "  docker exec -i mssql %SQLCMD% -S localhost -U sa -P '%MSSQL_SA_PASSWORD%' -C"
  if errorlevel 1 (
    echo ERROR: restore failed.
    call :fail_pause
    exit /b 1
  )

  echo Applying 20-docker-overrides.sql against [%SUPPORT_CENTRE%] ...
  docker exec -i mssql %SQLCMD% -S localhost -U sa -P "%MSSQL_SA_PASSWORD%" -C -d "%SUPPORT_CENTRE%" -i /init/20-docker-overrides.sql
  if errorlevel 1 (
    echo ERROR: 20-docker-overrides.sql failed. Is [%SUPPORT_CENTRE%] restored?
    call :fail_pause
    exit /b 1
  )
)

rem ---------- 5. build ----------
if "%SKIP_BUILD%"=="1" (
  echo [5/8] Skipping image build
) else (
  echo [5/8] Building noodles-build and config-api VPN / NuGet required ...
  docker compose build noodles-build config-api
  if errorlevel 1 (
    echo ERROR: build failed. Check VPN and access to the internal NuGet feed.
    call :fail_pause
    exit /b 1
  )
)

rem ---------- 6. noodles / apis ----------
if "%SKIP_NOODLES%"=="1" (
  echo [6/8] Skipping config-api / noodles
) else (
  echo [6/8] Starting config-api and noodles ...
  docker compose --profile noodles up -d
  if errorlevel 1 (
    echo ERROR: noodles profile failed to start.
    call :fail_pause
    exit /b 1
  )

  echo Waiting for config-api on http://localhost:8080 ...
  call :wait_http "http://localhost:8080/Configuration/1/Configuration/service=api.configuration" 180
  if errorlevel 1 (
    echo WARNING: config-api did not answer in time. Check: docker logs config-api
  )
)

if "%DO_APIS%"=="1" (
  echo Cloning / building satellite APIs ...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clone-apis.ps1"
  if errorlevel 1 (
    echo ERROR: clone-apis.ps1 failed.
    call :fail_pause
    exit /b 1
  )
  docker compose --profile apis build
  if errorlevel 1 (
    call :fail_pause
    exit /b 1
  )
  docker compose --profile apis up -d
  if errorlevel 1 (
    call :fail_pause
    exit /b 1
  )
)

rem ---------- 7. scheduled tasks ----------
if "%SKIP_NOODLES%"=="1" (
  echo [7/8] Skipping reset-scheduled-tasks.ps1 noodles not started
) else if "%SKIP_RESTORE%"=="1" (
  echo [7/8] Running reset-scheduled-tasks.ps1 anyway safe / idempotent ...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0reset-scheduled-tasks.ps1"
  if errorlevel 1 (
    echo WARNING: reset-scheduled-tasks.ps1 failed.
  )
) else (
  echo [7/8] Resetting scheduled-task registrations ...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0reset-scheduled-tasks.ps1"
  if errorlevel 1 (
    echo WARNING: reset-scheduled-tasks.ps1 failed.
  )
)

rem ---------- 8. Power optional ----------
echo [8/8] Power sites
if "%DO_POWER%"=="1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0power-local-setup.ps1"
  if errorlevel 1 (
    echo ERROR: power-local-setup.ps1 failed. Run WebConfigPicker first, then re-run with --power from an elevated prompt.
    call :fail_pause
    exit /b 1
  )
) else (
  echo   Manual next steps:
  echo     1. WebConfigPicker - select local Configuration API / Rabbit / Redis
  echo     2. Elevated: .\power-local-setup.ps1
  echo     3. Confirm Environment=local, DealerGroup matches .env, DealerId is a real dealer idl/jst
)

echo.
echo === Done ===
echo RabbitMQ UI:  http://localhost:15672  guest/guest
echo Mailpit UI:   http://localhost:8025
echo Config API:   http://localhost:8080/Configuration
echo Details:      README.md
echo.
powershell -NoProfile -Command "Write-Host 'Everything started successfully.' -ForegroundColor Green"
echo.
pause
exit /b 0

rem ======================================================================
rem  Helpers
rem ======================================================================

:fail_pause
echo.
powershell -NoProfile -Command "Write-Host 'Setup failed. Wipe to zero and retry with:' -ForegroundColor Red; Write-Host '  setup-local.bat --wipe' -ForegroundColor Yellow"
echo.
pause
exit /b 0

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

:wait_healthy
rem Docker on Windows emits a trailing CR; findstr /x "healthy" never matches.
rem Poll every 5s and print status so the window does not look frozen.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Continue';" ^
  "$name='%~1'; $left=[int]%~2;" ^
  "while ($left -gt 0) {" ^
  "  $raw = docker inspect -f '{{.State.Health.Status}}' $name 2>$null;" ^
  "  $status = if ($raw) { $raw.ToString().Trim() } else { 'unknown' };" ^
  "  Write-Host ('  {0}: {1}  ({2}s left)' -f $name, $status, $left);" ^
  "  if ($status -eq 'healthy') { Write-Host ('  {0} is healthy' -f $name); exit 0 };" ^
  "  Start-Sleep -Seconds 5; $left -= 5" ^
  "};" ^
  "Write-Host ('ERROR: timed out waiting for {0} to become healthy.' -f $name);" ^
  "exit 1"
exit /b %ERRORLEVEL%

:wait_http
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Continue';" ^
  "$url='%~1'; $left=[int]%~2;" ^
  "while ($left -gt 0) {" ^
  "  $ok = $false;" ^
  "  try {" ^
  "    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5;" ^
  "    if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { $ok = $true }" ^
  "  } catch { }" ^
  "  if ($ok) { Write-Host '  config-api responded'; exit 0 };" ^
  "  Write-Host ('  waiting for config-api ... ({0}s left)' -f $left);" ^
  "  Start-Sleep -Seconds 5; $left -= 5" ^
  "};" ^
  "exit 1"
exit /b %ERRORLEVEL%
