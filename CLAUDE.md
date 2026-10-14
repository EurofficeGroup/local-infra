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
| Compose files and project names (`docker-compose.yml`=power, `docker-compose.api.yml`=api-power, `docker-compose.noodles.yml`=noodles) | `DC_POWER` / `DC_API` / `DC_NOODLES` in `setup-local.bat` and `ops-local.bat`, `reset-scheduled-tasks.ps1`, `clone-apis.ps1`, `cleanup-local.bat` (`PROJECTS`), `migrate-local.ps1` (`-Restart`: api and noodles files) |
| Container/service names (`mssql`, `rabbit`, `noodles-*`, `noodles-build`) | `setup-local.bat` (`wait_healthy`, `docker exec`), `ops-local.bat`, `reset-scheduled-tasks.ps1`, `migrate-local.ps1` (`mssql`; `-Restart`: `config-api`, `noodles-*` except `noodles-build`) |
| Profiles (`search`, `build`) and the API service list (`API_SERVICES` in `ops-local.bat`) | `setup-local.bat` (`--wipe` = `down -v` of all three files), `ops-local.bat` |
| `DECLARE @SourcePrefix / @TargetPrefix / @DealerCode / @WhatIf / @HostFileRoot` lines in `02-restore-local.sql`, `20-docker-overrides.sql` and `30-rename-db-references.sql` | `:run_sql` in `setup-local.bat` and `ops-local.bat` rewrites them by regex - keep the `DECLARE @Name ... = N'value'` shape |
| Mount `./files:/files` and `@FileRoot` / `@HostFileRoot` in `20-docker-overrides.sql` | Power (Windows) and noodles must resolve to the same folder for the NServiceBus data bus; noodles `DataBusKeySeparatorBehaviour` turns Power's `\` keys into `/` only when `INFRA_ENVIRONMENT=local` and noodles is not on Windows (it checks `Environment = local` and the OS) |
| Mount path `/init/` and SQL file names (`20-docker-overrides.sql`, `30-rename-db-references.sql`, `02-restore-local.sql`) | `setup-local.bat`, `ops-local.bat` |
| Search profile: services `elastic`, `kibana`, `search-api`, `noodles-searches`; files `40-search-local.sql` / `41-search-remote.sql`; table `dbo.zz_LocalInfraSearchBackup`; index template `local-infra-single-node`; saga tables `ProductReindexFromDbSagaData` / `ProductIndexUpkeepSagaData` (search-reset); folder `./files/elastic` mounted as the node's `config/eo`; hostname `search-api` | `search-local.ps1` (all of it), `ops-local.bat` (`search-*`), `setup-local.bat` (`--search`, `--wipe` profiles), `hosts-setup.ps1`, `clone-apis.ps1 -Search` (folders `search`, `integrations`), README "Local search" |
| `ElasticSearchConnectionString` / `ElasticSearchUpdateConnectionString` = `http://elastic:9200` in the `environment:` of `search-api` and `noodles-searches` | **Safety, not convenience**: they keep a product-index rebuild (create, alias swap, delete the old index) off TEST4's shared cluster whatever `cfg_Configurations` says. Never remove them |
| Sibling repo `../database`: project folders `src/EurofficeGroup.Database.Migrator.{ProductCatalogue,Dealer,SupportCentre}`, output `bin/Debug/net472/Migrate.exe`; context keys of `src/LocalDeploy.ps1`; dealer databases detected by `dbo.cus_Customers` | `migrate-local.ps1`, `ops-local.bat db-migrate`, README "Database migrations" |
| IIS site names `wfe`, `portal`, `admin`, `cdn` | `power-local-setup.ps1` (`$Sites`), `migrate-local.ps1` (`$IisSites`, recycled by `-Restart`), README |
| Variables `MSSQL_SA_PASSWORD`, `INFRA_DB_PREFIX`, `INFRA_BACKUP_PREFIX`, `INFRA_DEALER_CODE`, `INFRA_DEALER_GROUP`, `INFRA_ENVIRONMENT`, `LOCAL_HOSTNAME` | `.env`, `.env.local.example`, `setup-local.bat`, `ops-local.bat`, `hosts-setup.ps1`, `migrate-local.ps1`, SQL |
| `COMPOSE_ENV_FILES=.env,.env.local` | `setup-local.bat`, `ops-local.bat`: keep both identical |
| Ports and hostnames (for example config-api `localhost:8080`) | `setup-local.bat` (`wait_http`), `power-local-setup.ps1`, `config-samples/*`, `sql/init/20-docker-overrides.sql`, `migrate-local.ps1` (`MSSQL_PORT`: Migrate.exe runs on the host and connects to `localhost,<port>`) |
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
