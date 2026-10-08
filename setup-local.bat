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
rem    setup-local.bat --power
rem
rem  On failure the script prints the concrete cause, how to fix it, recent
rem  container logs where relevant, and the right command to retry with.
rem ======================================================================

cd /d "%~dp0"

set "DO_WIPE=0"
set "SKIP_HOSTS=0"
set "SKIP_RESTORE=0"
set "SKIP_BUILD=0"
set "SKIP_NOODLES=0"
set "DO_APIS=0"
set "SKIP_PULL=0"
set "DO_POWER=0"

rem Error report fields, read by :fail (see Helpers).
set "ORIG_ARGS=%*"
set "ERR_MSG="
set "ERR_HINT="
set "ERR_HINT2="
set "ERR_LOGS="
set "ERR_WIPE=0"
set "REASON_FILE=%TEMP%\local-infra-setup-reason.txt"

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--wipe"         set "DO_WIPE=1"      & shift & goto parse_args
if /i "%~1"=="--skip-hosts"   set "SKIP_HOSTS=1"   & shift & goto parse_args
if /i "%~1"=="--skip-restore" set "SKIP_RESTORE=1" & shift & goto parse_args
if /i "%~1"=="--skip-build"   set "SKIP_BUILD=1"   & shift & goto parse_args
if /i "%~1"=="--skip-noodles" set "SKIP_NOODLES=1" & shift & goto parse_args
if /i "%~1"=="--apis"         set "DO_APIS=1"      & shift & goto parse_args
if /i "%~1"=="--skip-pull"    set "SKIP_PULL=1"    & shift & goto parse_args
if /i "%~1"=="--power"        set "DO_POWER=1"     & shift & goto parse_args
set "ERR_MSG=Unknown argument: %~1"
set "ERR_HINT=Usage: setup-local.bat [--wipe] [--skip-hosts] [--skip-restore] [--skip-build] [--skip-noodles] [--skip-pull] [--apis] [--power]"
set "ORIG_ARGS="
goto fail
:args_done

rem ---------- .env.local / password ----------
if not exist "%~dp0.env.local" (
  set "ERR_MSG=File .env.local is missing in %~dp0"
  set "ERR_HINT=Run:  Copy-Item .env.local.example .env.local   then set MSSQL_SA_PASSWORD in it."
  if not exist "%~dp0.env.local.example" set "ERR_HINT2=.env.local.example is missing too - restore it with:  git checkout -- .env.local.example"
  goto fail
)

rem Compose interpolates ${MSSQL_SA_PASSWORD} from .env.local (not from .env).
set "COMPOSE_ENV_FILES=.env,.env.local"

rem Three compose projects = three groups in Docker Desktop:
rem   power      docker-compose.yml          mssql rabbit redis mailpit (+ search)
rem   api-power  docker-compose.api.yml      config-api + satellite APIs
rem   noodles    docker-compose.noodles.yml  noodles-*
set "DC_POWER=docker compose -f docker-compose.yml"
set "DC_API=docker compose -f docker-compose.api.yml"
set "DC_NOODLES=docker compose -f docker-compose.noodles.yml"

call :read_env MSSQL_SA_PASSWORD
call :read_env INFRA_DB_PREFIX
call :read_env INFRA_BACKUP_PREFIX
call :read_env INFRA_DEALER_CODE
if not defined MSSQL_SA_PASSWORD (
  findstr /c:"MSSQL_SA_PASSWORD" "%~dp0.env.local" >nul 2>&1
  if errorlevel 1 (
    set "ERR_MSG=.env.local has no MSSQL_SA_PASSWORD line."
    set "ERR_HINT=Add a line  MSSQL_SA_PASSWORD=YourStrongPassword  - see .env.local.example."
  ) else (
    set "ERR_MSG=MSSQL_SA_PASSWORD in .env.local is empty or unreadable."
    set "ERR_HINT=The line must start at column 1 as MSSQL_SA_PASSWORD=value, with no spaces around '='."
    set "ERR_HINT2=If it already looks right, re-save .env.local as UTF-8 without BOM, e.g. in Notepad."
  )
  goto fail
)
call :check_password
if errorlevel 1 goto fail

if not defined INFRA_DB_PREFIX set "INFRA_DB_PREFIX=dev_uk"
if not defined INFRA_BACKUP_PREFIX set "INFRA_BACKUP_PREFIX=test4_power"
if not defined INFRA_DEALER_CODE set "INFRA_DEALER_CODE=jst"
call :check_db_vars
if errorlevel 1 (
  set "ERR_MSG=INFRA_DB_PREFIX / INFRA_BACKUP_PREFIX / INFRA_DEALER_CODE in .env contain invalid characters."
  set "ERR_HINT=Use letters, digits and _ only, e.g. INFRA_DB_PREFIX=dev_uk  INFRA_DEALER_CODE=jst."
  goto fail
)
set "SUPPORT_CENTRE=%INFRA_DB_PREFIX%_supportcentre"
set "SQLCMD=/opt/mssql-tools18/bin/sqlcmd"

echo.
echo === local-infra setup ===
echo Support centre DB: %SUPPORT_CENTRE%
echo Main dealer DB:    %INFRA_DB_PREFIX%_%INFRA_DEALER_CODE%   from %INFRA_BACKUP_PREFIX%_%INFRA_DEALER_CODE%.bak
echo Other dealers:     every %INFRA_BACKUP_PREFIX%_*.bak in sql\backup
echo.

rem ---------- prerequisites ----------
where docker >nul 2>&1
if errorlevel 1 (
  set "ERR_MSG=docker is not on PATH."
  set "ERR_HINT=Install Docker Desktop, then open a new terminal so PATH is refreshed."
  goto fail
)
docker info >nul 2>&1
if errorlevel 1 (
  set "ERR_MSG=Docker daemon is not reachable - Docker Desktop is not running or still starting."
  set "ERR_HINT=Start Docker Desktop and wait until it shows 'Engine running', then retry."
  goto fail
)
docker info --format "{{.OSType}}" 2>nul | findstr /i "linux" >nul
if errorlevel 1 (
  set "ERR_MSG=Docker is in Windows-containers mode; this stack needs Linux containers."
  set "ERR_HINT=Docker Desktop tray icon - 'Switch to Linux containers...', then retry."
  goto fail
)

rem ---------- 0. wipe to zero optional / on every failed retry ----------
if "%DO_WIPE%"=="1" (
  echo [0/8] Wiping stack and volumes to zero ...
  %DC_NOODLES% --profile build down -v --remove-orphans
  %DC_API% down -v --remove-orphans
  %DC_POWER% --profile search down -v --remove-orphans
  if errorlevel 1 (
    set "ERR_MSG=[0/8] Wipe failed: docker compose down -v - see docker output above."
    set "ERR_HINT=A container or volume may be locked: restart Docker Desktop and retry."
    goto fail
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
    set "ERR_MSG=[1/8] hosts-setup.ps1 failed - see its output above."
    set "ERR_HINT=Pass --skip-hosts if the hosts file and LOCAL_HOSTNAME in .env are already set."
    net session >nul 2>&1
    if errorlevel 1 set "ERR_HINT2=This console is NOT elevated: re-run from PowerShell opened 'As Administrator'."
    goto fail
  )
)

rem ---------- 2. core ----------
echo [2/8] Starting group power: mssql rabbit redis mailpit ...
%DC_POWER% up -d
if errorlevel 1 (
  set "ERR_MSG=[2/8] docker compose up -d of docker-compose.yml failed - the docker error is printed above."
  set "ERR_HINT=Common causes: a port already in use, e.g. a local SQL Server on 1433 - or an image pull failure, check network/VPN."
  goto fail
)

echo Waiting for mssql and rabbit to become healthy ...
call :wait_healthy mssql 180
if errorlevel 1 (
  set "ERR_LOGS=mssql"
  set "ERR_HINT=Check the mssql log above. 'Password validation failed' = MSSQL_SA_PASSWORD too weak."
  set "ERR_HINT2=If the volume was created earlier with a different password, the sa login fails - wipe it."
  set "ERR_WIPE=1"
  goto fail
)
call :wait_healthy rabbit 120
if errorlevel 1 (
  set "ERR_LOGS=rabbit"
  set "ERR_HINT=Check the rabbit log above, e.g. a broken rabbitmq\rabbitmq.conf or ports 5672/15672 in use."
  set "ERR_WIPE=1"
  goto fail
)

rem ---------- 3-4. SQL login / restore / overrides ----------
if "%SKIP_RESTORE%"=="1" (
  echo [3/8] Skipping SQL login / restore / overrides
) else (
  echo [3/8] Creating application logins 00-login-and-databases.sql ...
  docker exec -i mssql %SQLCMD% -S localhost -U sa -P "%MSSQL_SA_PASSWORD%" -C -i /init/00-login-and-databases.sql
  if errorlevel 1 (
    set "ERR_MSG=[3/8] sql/init/00-login-and-databases.sql failed - the sqlcmd error is printed above."
    set "ERR_HINT=Login failed for user 'sa' = the mssql volume has a different password than .env.local."
    set "ERR_WIPE=1"
    goto fail
  )

  dir /b "%~dp0sql\backup\%INFRA_BACKUP_PREFIX%_supportcentre*.bak" >nul 2>&1
  if errorlevel 1 (
    set "ERR_MSG=[4/8] No %INFRA_BACKUP_PREFIX%_supportcentre.bak in %~dp0sql\backup\"
    set "ERR_HINT=Copy the group backups there with their original TEST4 names, or fix INFRA_BACKUP_PREFIX in .env."
    set "ERR_HINT2=Or pass --skip-restore if the databases are already restored."
    goto fail
  )
  dir /b "%~dp0sql\backup\%INFRA_BACKUP_PREFIX%_%INFRA_DEALER_CODE%*.bak" >nul 2>&1
  if errorlevel 1 (
    set "ERR_MSG=[4/8] No dealer backup %INFRA_BACKUP_PREFIX%_%INFRA_DEALER_CODE%.bak in %~dp0sql\backup\"
    set "ERR_HINT=Copy that dealer's backup there, or set INFRA_DEALER_CODE in .env to a dealer whose .bak you have."
    goto fail
  )

  echo [4/8] Restoring backups from sql\backup ...
  echo.
  powershell -NoProfile -Command "Write-Host 'NOTE: Database restore can take a long time (tens of minutes for ~15 GB).' -ForegroundColor Yellow; Write-Host 'The console will look frozen until sqlcmd finishes - that is normal. Just wait.' -ForegroundColor Yellow"
  echo.
  call :run_sql "%~dp0sql\test4\02-restore-local.sql" "" apply
  if errorlevel 1 (
    set "ERR_MSG=[4/8] Restore failed: sql/test4/02-restore-local.sql - the sqlcmd error is printed above."
    set "ERR_HINT=Check the .bak names match INFRA_BACKUP_PREFIX / INFRA_DEALER_CODE and Docker Desktop has enough disk space."
    set "ERR_LOGS=mssql"
    set "ERR_WIPE=1"
    goto fail
  )

  echo Rewriting test4 database names inside synonyms / views / procedures ...
  call :run_sql "%~dp0sql\init\30-rename-db-references.sql" ""
  if errorlevel 1 (
    set "ERR_MSG=[4/8] sql/init/30-rename-db-references.sql failed - the sqlcmd error is printed above."
    goto fail
  )

  echo Applying 20-docker-overrides.sql against [%SUPPORT_CENTRE%] ...
  call :run_sql "%~dp0sql\init\20-docker-overrides.sql" "%SUPPORT_CENTRE%"
  if errorlevel 1 (
    set "ERR_MSG=[4/8] sql/init/20-docker-overrides.sql failed against [%SUPPORT_CENTRE%]."
    set "ERR_HINT=Was [%SUPPORT_CENTRE%] restored? Its name is INFRA_DB_PREFIX in .env plus _supportcentre."
    goto fail
  )
)

rem ---------- 5. build ----------
if "%SKIP_BUILD%"=="1" (
  echo [5/8] Skipping image build
) else (
  echo [5/8] Cloning / pulling noodles and API repos, then building VPN / NuGet required ...
  set "PULL_ARG="
  if "%SKIP_PULL%"=="1" set "PULL_ARG=-NoPull"
  call :clone_repos
  if errorlevel 1 (
    set "ERR_MSG=[5/8] clone-apis.ps1 failed - see its output above."
    set "ERR_HINT=Check git access to the EurofficeGroup repos on GitHub."
    goto fail
  )
  %DC_NOODLES% build noodles-build
  if not errorlevel 1 %DC_API% build
  if errorlevel 1 (
    set "ERR_MSG=[5/8] Image build failed: noodles-build / config-api / APIs - the build error is printed above."
    set "ERR_HINT='Unable to load the service index' / 401 / timeout = VPN is off or no access to build.euroffice.co.uk NuGet."
    set "ERR_HINT2=Compile errors = a sibling repo noodles / api.* is on a broken branch."
    goto fail
  )
)

rem ---------- 6. noodles / apis ----------
if "%SKIP_NOODLES%"=="1" (
  echo [6/8] Skipping config-api / APIs / noodles
) else (
  echo [6/8] Starting group api-power: config-api ...
  %DC_API% up -d config-api
  if errorlevel 1 (
    set "ERR_MSG=[6/8] docker compose up -d config-api failed - the docker error is printed above."
    set "ERR_HINT=If an image is missing, re-run without --skip-build."
    goto fail
  )

  rem depends_on cannot cross projects, so wait here before starting noodles.
  echo Waiting for config-api on http://localhost:8080 ...
  call :wait_http "http://localhost:8080/Configuration/1/Configuration/service=api.configuration" 180
  if errorlevel 1 (
    call :show_logs config-api
    powershell -NoProfile -Command "Write-Host 'WARNING: config-api did not answer in time - see the reason and log above. Continuing.' -ForegroundColor Yellow"
  )

  echo Starting the satellite APIs in group api-power ...
  %DC_API% up -d
  if errorlevel 1 (
    set "ERR_MSG=[6/8] docker compose -f docker-compose.api.yml up -d failed - the docker error is printed above."
    set "ERR_HINT=If an image is missing, re-run without --skip-build."
    goto fail
  )

  echo Starting group noodles ...
  %DC_NOODLES% up -d
  if errorlevel 1 (
    set "ERR_MSG=[6/8] docker compose -f docker-compose.noodles.yml up -d failed - the docker error is printed above."
    set "ERR_HINT=If an image is missing, re-run without --skip-build."
    goto fail
  )
)

rem --apis is still accepted so old command lines keep working; the APIs now
rem start with every run, like config-api.
if "%DO_APIS%"=="1" echo Note: --apis is no longer needed - the APIs are always started.

rem ---------- 7. scheduled tasks ----------
if "%SKIP_NOODLES%"=="1" (
  echo [7/8] Skipping reset-scheduled-tasks.ps1 noodles not started
) else if "%SKIP_RESTORE%"=="1" (
  echo [7/8] Running reset-scheduled-tasks.ps1 anyway safe / idempotent ...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0reset-scheduled-tasks.ps1"
  if errorlevel 1 (
    echo WARNING: reset-scheduled-tasks.ps1 failed - see its output above. Re-run later: ops-local.bat reset-tasks
  )
) else (
  echo [7/8] Resetting scheduled-task registrations ...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0reset-scheduled-tasks.ps1"
  if errorlevel 1 (
    echo WARNING: reset-scheduled-tasks.ps1 failed - see its output above. Re-run later: ops-local.bat reset-tasks
  )
)

rem ---------- 8. Power optional ----------
echo [8/8] Power sites
if "%DO_POWER%"=="1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0power-local-setup.ps1"
  if errorlevel 1 (
    set "ERR_MSG=[8/8] power-local-setup.ps1 failed - see its output above."
    set "ERR_HINT=Run WebConfigPicker first, then re-run with --power from an elevated prompt."
    goto fail
  )
) else (
  echo   Manual next steps:
  echo     1. WebConfigPicker - select local Configuration API / Rabbit / Redis
  echo     2. Elevated: .\power-local-setup.ps1 - also sets Environment, DealerGroup and DealerId %INFRA_DEALER_CODE% from .env
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

:fail
rem Prints the concrete cause and how to fix it, then stops the script.
rem Set before 'goto fail':
rem   ERR_MSG    what went wrong (required)
rem   ERR_HINT   how to fix it; ERR_HINT2 an optional second line
rem   ERR_LOGS   space-separated container names whose recent logs to show
rem   ERR_WIPE=1 the retry needs --wipe; otherwise a plain re-run is suggested
rem Values are printed via PowerShell from the environment, so they may contain
rem any characters; keep & | < > out of them only because of 'set' parsing.
if not defined ERR_LOGS goto fail_report
for %%C in (%ERR_LOGS%) do call :show_logs %%C
:fail_report
echo.
powershell -NoProfile -Command ^
  "Write-Host ('ERROR: ' + $env:ERR_MSG) -ForegroundColor Red;" ^
  "if ($env:ERR_HINT)  { Write-Host ('Fix:   ' + $env:ERR_HINT)  -ForegroundColor Yellow };" ^
  "if ($env:ERR_HINT2) { Write-Host ('       ' + $env:ERR_HINT2) -ForegroundColor Yellow };" ^
  "if ($env:ERR_WIPE -eq '1') { $r = 'Retry: setup-local.bat --wipe   (deletes local containers, volumes and restored databases)' }" ^
  "else { $r = ('Retry: setup-local.bat ' + $env:ORIG_ARGS).TrimEnd() };" ^
  "Write-Host $r -ForegroundColor Yellow"
echo.
pause
exit /b 1

:show_logs
echo.
echo ----- %~1: last 40 log lines -----
docker logs --tail 40 %~1 2>&1
echo ----- end of %~1 log -----
exit /b 0

:read_reason
rem Loads ERR_MSG (line 1) and ERR_HINT (line 2) written by a PowerShell check.
set "ERR_MSG="
set "ERR_HINT="
if not exist "%REASON_FILE%" exit /b 0
< "%REASON_FILE%" (
  set /p "ERR_MSG="
  set /p "ERR_HINT="
)
del "%REASON_FILE%" >nul 2>&1
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

:check_password
rem Catches the password problems that otherwise surface later as an unhealthy
rem mssql container or a broken sqlcmd call. Never prints the password itself.
if exist "%REASON_FILE%" del "%REASON_FILE%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p = $env:MSSQL_SA_PASSWORD; $m = $null; $h = $null;" ^
  "$groups = @(@('[A-Z]','[a-z]','[0-9]','[^A-Za-z0-9]') | Where-Object { $p -cmatch $_ }).Count;" ^
  "if ($p -ceq 'YourPassword') { $m = 'MSSQL_SA_PASSWORD in .env.local is still the placeholder YourPassword.'; $h = 'Set a real password: 8+ characters using 3 of upper case, lower case, digit, symbol.' }" ^
  "elseif ($p -ne $p.Trim()) { $m = 'MSSQL_SA_PASSWORD in .env.local has leading/trailing spaces.'; $h = 'Remove the spaces around the value in .env.local.' }" ^
  "elseif ($p.Contains([string][char]34) -or $p.Contains([string][char]39)) { $m = 'MSSQL_SA_PASSWORD in .env.local contains a quote character, which breaks the sqlcmd calls in this script.'; $h = 'Use a password without double or single quotes.' }" ^
  "elseif ($p.Length -lt 8 -or $groups -lt 3) { $m = ('MSSQL_SA_PASSWORD in .env.local is too weak ({0} chars, {1} of 4 character groups) - SQL Server will refuse to start.' -f $p.Length, $groups); $h = 'Use 8+ characters with 3 of: upper case, lower case, digit, symbol.' };" ^
  "if ($m) { Set-Content -LiteralPath $env:REASON_FILE -Value @($m, $h); exit 1 }; exit 0"
if errorlevel 1 (
  call :read_reason
  exit /b 1
)
exit /b 0

:clone_repos
rem Outside the if-block on purpose: PULL_ARG is set inside it, and without
rem delayed expansion a %%PULL_ARG%% in the same block would still be empty.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clone-apis.ps1" %PULL_ARG%
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

:wait_healthy
rem Polls every 5s and prints status so the window does not look frozen.
rem Fails fast if the container is missing, exited or crash-looping; on timeout
rem reports the last healthcheck output. The reason ends up in ERR_MSG.
if exist "%REASON_FILE%" del "%REASON_FILE%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Continue';" ^
  "$name='%~1'; $total=[int]%~2; $left=$total; $reason=$null; $health='unknown';" ^
  "while ($left -gt 0) {" ^
  "  $raw = docker inspect -f '{{.State.Status}};{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}};{{.State.ExitCode}};{{.RestartCount}}' $name 2>$null;" ^
  "  if (-not $raw) { $reason = ('Container {0} does not exist - docker compose did not create it.' -f $name); break };" ^
  "  $state, $health, $code, $restarts = $raw.ToString().Trim().Split(';');" ^
  "  Write-Host ('  {0}: {1} / {2}  ({3}s left)' -f $name, $state, $health, $left);" ^
  "  if ($health -eq 'healthy') { Write-Host ('  {0} is healthy' -f $name); exit 0 };" ^
  "  if ($state -eq 'exited' -or $state -eq 'dead') { $reason = ('Container {0} stopped with exit code {1} instead of becoming healthy.' -f $name, $code); break };" ^
  "  if ([int]$restarts -ge 2) { $reason = ('Container {0} keeps crashing and restarting ({1} restarts).' -f $name, $restarts); break };" ^
  "  Start-Sleep -Seconds 5; $left -= 5" ^
  "};" ^
  "if (-not $reason) {" ^
  "  $reason = ('{0} did not become healthy within {1}s (last status: {2}).' -f $name, $total, $health);" ^
  "  $log = docker inspect -f '{{if .State.Health}}{{json .State.Health.Log}}{{end}}' $name 2>$null;" ^
  "  if ($log) { $last = @($log | ConvertFrom-Json) | Select-Object -Last 1;" ^
  "    if ($last -and $last.Output) { $out = ($last.Output -replace '\s+', ' ').Trim(); if ($out.Length -gt 300) { $out = $out.Substring(0, 300) + '...' }; $reason += ' Last healthcheck: ' + $out } }" ^
  "};" ^
  "Set-Content -LiteralPath $env:REASON_FILE -Value $reason; exit 1"
if errorlevel 1 (
  call :read_reason
  exit /b 1
)
exit /b 0

:wait_http
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Continue';" ^
  "$url='%~1'; $total=[int]%~2; $left=$total; $last='no response';" ^
  "while ($left -gt 0) {" ^
  "  $ok = $false;" ^
  "  try {" ^
  "    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5;" ^
  "    if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { $ok = $true }" ^
  "  } catch { $last = $_.Exception.Message }" ^
  "  if ($ok) { Write-Host '  config-api responded'; exit 0 };" ^
  "  Write-Host ('  waiting for config-api ... ({0}s left)' -f $left);" ^
  "  Start-Sleep -Seconds 5; $left -= 5" ^
  "};" ^
  "Write-Host ('  config-api did not answer at {0} within {1}s. Last error: {2}' -f $url, $total, $last) -ForegroundColor Yellow;" ^
  "exit 1"
exit /b %ERRORLEVEL%
