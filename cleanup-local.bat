@echo off
setlocal EnableExtensions

rem ======================================================================
rem  Free disk used by THIS stack only (COMPOSE_PROJECT_NAME).
rem
rem  Does NOT run global docker system/builder prune - other Docker
rem  projects on the machine are left alone.
rem
rem  Keeps: running containers, their images, and ALL volumes
rem         (mssql-data, rabbit-data, redis-data, ...).
rem  Removes (local-infra label only):
rem         - BuildKit cache for this compose project
rem         - stopped containers for this project
rem         - unused images built by this project (incl. old rebuilds)
rem
rem  Usage:  cleanup-local.bat
rem ======================================================================

cd /d "%~dp0"

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

rem The stack is three compose projects, one Docker Desktop group each.
set "PROJECTS=power api-power noodles"

echo.
echo === local-infra cleanup ^(projects: %PROJECTS%^) ===
echo.
echo Scoped to compose labels com.docker.compose.project=[%PROJECTS%].
echo Other Docker projects, volumes, and running containers are not touched.
echo.
echo Before:
docker system df
echo.

echo [1/4] Checking core containers are still up ...
call :require_running mssql
if errorlevel 1 goto fail_core
call :require_running rabbit
if errorlevel 1 goto fail_core
call :require_running redis
if errorlevel 1 goto fail_core
echo   mssql, rabbit, redis - running
echo.

echo [2/4] Pruning BuildKit cache ...
for %%P in (%PROJECTS%) do (
  docker builder prune -af --filter "label=com.docker.compose.project=%%P"
  if errorlevel 1 (
    echo ERROR: builder prune failed for %%P.
    call :fail_pause
    exit /b 1
  )
)
echo.

echo [3/4] Removing stopped containers ...
for %%P in (%PROJECTS%) do (
  docker container prune -f --filter "label=com.docker.compose.project=%%P"
  if errorlevel 1 (
    echo ERROR: container prune failed for %%P.
    call :fail_pause
    exit /b 1
  )
)
echo.

echo [4/4] Removing unused images ...
for %%P in (%PROJECTS%) do (
  docker image prune -af --filter "label=com.docker.compose.project=%%P"
  if errorlevel 1 (
    echo ERROR: image prune failed for %%P.
    call :fail_pause
    exit /b 1
  )
)
echo.

echo After:
docker system df
echo.

echo Verifying core containers still running ...
call :require_running mssql
if errorlevel 1 goto fail_core
call :require_running rabbit
if errorlevel 1 goto fail_core
call :require_running redis
if errorlevel 1 goto fail_core
echo   mssql, rabbit, redis - still running
echo.

powershell -NoProfile -Command "Write-Host 'Done. Only unused build data of %PROJECTS% removed.' -ForegroundColor Green"
echo.
pause
exit /b 0

:require_running
docker inspect -f "{{.State.Running}}" "%~1" 2>nul | findstr /i "true" >nul
if errorlevel 1 (
  echo ERROR: container '%~1' is not running. Start the stack first, then re-run cleanup.
  exit /b 1
)
exit /b 0

:read_env
set "KEY=%~1"
set "%KEY%="
if exist "%~dp0.env" (
  for /f "usebackq tokens=1,* delims==" %%A in (`findstr /b /c:"%KEY%=" "%~dp0.env" 2^>nul`) do (
    set "%KEY%=%%B"
  )
)
if exist "%~dp0.env.local" (
  for /f "usebackq tokens=1,* delims==" %%A in (`findstr /b /c:"%KEY%=" "%~dp0.env.local" 2^>nul`) do (
    set "%KEY%=%%B"
  )
)
exit /b 0

:fail_core
call :fail_pause
exit /b 1

:fail_pause
echo.
powershell -NoProfile -Command "Write-Host 'Cleanup aborted.' -ForegroundColor Red"
echo.
pause
exit /b 0
