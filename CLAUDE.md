# local-infra — rules for AI agents

Local Docker stack (SQL Server, RabbitMQ, Redis, Mailpit, config-api, noodles) for the
EurofficeGroup repos. Layout, scripts and bring-up order: `README.md`.

## Main rule

**Every infrastructure change ships together with the script changes it requires.**
If you change compose, a Dockerfile, `.env*`, SQL, RabbitMQ config or any name, port or path,
fix, add or delete the affected scripts in the same change, so that every script keeps working.
Do not leave that for later.

## Hidden dependencies: names hardcoded in scripts

These names live in more than one file. Renaming one without the others breaks scripts silently:

| What | Where it is used besides `docker-compose.yml` |
|---|---|
| Compose files and project names (`docker-compose.yml`=power, `docker-compose.api.yml`=api-power, `docker-compose.noodles.yml`=noodles) | `DC_POWER` / `DC_API` / `DC_NOODLES` in `setup-local.bat` and `ops-local.bat`, `reset-scheduled-tasks.ps1`, `clone-apis.ps1`, `cleanup-local.bat` (`PROJECTS`) |
| Container/service names (`mssql`, `rabbit`, `noodles-*`, `noodles-build`) | `setup-local.bat` (`wait_healthy`, `docker exec`), `ops-local.bat`, `reset-scheduled-tasks.ps1` |
| Profiles (`search`, `build`) and the API service list (`API_SERVICES` in `ops-local.bat`) | `setup-local.bat` (`--wipe` = `down -v` of all three files), `ops-local.bat` |
| `DECLARE @SourcePrefix / @TargetPrefix / @DealerCode / @WhatIf` lines in `02-restore-local.sql`, `20-docker-overrides.sql` and `30-rename-db-references.sql` | `:run_sql` in `setup-local.bat` and `ops-local.bat` rewrites them by regex - keep the `DECLARE @Name ... = N'value'` shape |
| Mount path `/init/` and SQL file names (`20-docker-overrides.sql`, `30-rename-db-references.sql`, `02-restore-local.sql`) | `setup-local.bat`, `ops-local.bat` |
| Variables `MSSQL_SA_PASSWORD`, `INFRA_DB_PREFIX`, `INFRA_BACKUP_PREFIX`, `INFRA_DEALER_CODE`, `INFRA_DEALER_GROUP`, `INFRA_ENVIRONMENT`, `LOCAL_HOSTNAME` | `.env`, `.env.local.example`, `setup-local.bat`, `ops-local.bat`, `hosts-setup.ps1`, SQL |
| `COMPOSE_ENV_FILES=.env,.env.local` | `setup-local.bat`, `ops-local.bat`: keep both identical |
| Ports and hostnames (for example config-api `localhost:8080`) | `setup-local.bat` (`wait_http`), `power-local-setup.ps1`, `config-samples/*`, `sql/init/20-docker-overrides.sql` |
| Script file names | `setup-local.bat`, `ops-local.bat`, `README.md` |

This table is not exhaustive. Always grep.

## How to make a change

1. **Find all usages** of what you are changing: in this repo, and in the sibling repos
   (`noodles`, `api.configuration`, `power`, `webconfigpicker`, `database`). If you cannot list
   every consumer (teammates' `.env.local`, Power on IIS), say so explicitly.
2. **Prefer additive changes.** A new variable or flag with a default that keeps today's behaviour
   beats renaming in place.
3. **Keep the scripts consistent:**
   - New step: wire it into `setup-local.bat` at the right place in the bring-up order, and into
     `ops-local.bat` if it is needed day to day.
   - Deleted script: remove its calls and its row in `README.md`.
   - Scripts stay idempotent and safe to re-run.
4. **Update `README.md`** (scripts table, flags, bring-up order) and `config-samples/*` if affected.
5. **Validate:** run `docker compose -f <file> --profile all config` for each of the three compose files, parse-check
   any edited `.ps1`, and read through `.bat` control flow (`goto`, labels, `exit /b`, `%~dp0`).
   Say what you could not verify.
6. **Report breaking effects for existing users:** do they need `--wipe`, an `.env.local` edit,
   or a re-run of `hosts-setup.ps1`?

## Invariants: do not break

- `setup-local.bat` / `ops-local.bat`: **no** `EnableDelayedExpansion`, because the password may
  contain `!`. Keep the flags `--wipe`, `--skip-hosts`, `--skip-restore`, `--skip-build`,
  `--skip-noodles`, `--skip-pull`, `--apis` and `--power` working.
- `cleanup-local.bat` only touches this project's images and build cache. Never volumes,
  running containers or other Docker projects.
- `.env.local` and `.bak` files are never committed. A new required secret goes into
  `.env.local.example`.
- Local environment only: scripts never point at test, staging or production servers.
