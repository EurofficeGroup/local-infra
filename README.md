# Local infrastructure for Power + Noodles + DB

Local EurofficeGroup stack: SQL Server, RabbitMQ, Redis, Mailpit, Configuration API, and Noodles services in Docker. Power (.NET Framework 4.7.2) runs on the host under IIS / Rider — **not** in compose.

## Quick start

1. Place the group's `.bak` files in `sql\backup\` (original TEST4 names, e.g. `test4_power_supportcentre.bak`).
2. Copy `.env.local.example` → `.env.local` and set **`MSSQL_SA_PASSWORD`** (gitignored; required). The password must meet SQL Server complexity rules or the `mssql` container will not start.
3. Check the group switch in `.env` (`INFRA_DB_PREFIX`, `INFRA_DEALER_GROUP`, `INFRA_ENVIRONMENT`).
4. Run **as Administrator**:

```bat
setup-local.bat
```

After any failed attempt, wipe volumes and start from zero:

```bat
setup-local.bat --wipe
```

The script runs steps 1–7 below in order. Power (step 8) stays manual — WebConfigPicker + `power-local-setup.ps1`.

Options:

| Flag | Effect |
|---|---|
| `--wipe` | `docker compose --profile all down -v` first, then full setup from a clean slate |
| `--skip-hosts` | Skip `hosts-setup.ps1` |
| `--skip-restore` | Skip restore / overrides (DB already present) |
| `--skip-build` | Skip image builds (already built) |
| `--skip-noodles` | Core + SQL only; no config-api / noodles |
| `--apis` | Also bring up satellite APIs (`clone-apis` + profile `apis`) |
| `--power` | Run `power-local-setup.ps1` at the end (needs IIS sites + WebConfigPicker) |

---

## Layout

Repos are **siblings** under one workspace root (e.g. `C:\workspace`), not nested:

| Folder | Role |
|---|---|
| `local-infra` | Orchestration: compose, `.env` / `.env.local`, SQL, setup scripts |
| `noodles` | 16 microservices, NServiceBus + RabbitMQ, .NET 8 |
| `api.configuration` | Configuration API (`config-api`) |
| `power` | Portal / FrontEnd / Static / Support — on the host |
| `events`, `common`, `database` | Contracts / shared / migrations |
| `webconfigpicker` | Switches Web.config (local / test / prod) |

Runtime config for DB-driven keys is **not** read from `appsettings.json` — it comes from `dbo.cfg_Configurations` in the support-centre database, fetched at startup via the Configuration API.

---

## Scripts

| Script | When | What it does |
|---|---|---|
| `hosts-setup.ps1` | Once (elevated) | Maps hosts → `127.0.0.1`; writes `LOCAL_HOSTNAME` (lower-case) into `.env` |
| `.env.local.example` → `.env.local` | Once per machine | Set `MSSQL_SA_PASSWORD` (required; gitignored) |
| `sql/init/00-login-and-databases.sql` | After mssql is healthy | Creates `EuroWebsite` / `EuroService` logins |
| `sql/test4/02-restore-local.sql` | After `.bak` files are in `sql/backup` | Restores under original database names |
| `sql/init/20-docker-overrides.sql` | After restore, **against support-centre** | Repoints config at containers + `EnableInstallers` / `Environment=local` |
| `reset-scheduled-tasks.ps1` | After overrides + noodles | Clears stale NSB reply addresses, recreates noodles |
| `clone-apis.ps1` | Optional | Clones satellite API repos |
| `power-local-setup.ps1` | After WebConfigPicker (elevated) | Sets `ConfigurationUrl`, `ForceIntegratedSecurity=false`, local API URLs |
| `setup-local.bat` | From scratch | Runs the above in order (except manual Power) |
| `ops-local.bat` | Day-to-day | Rebuild/restart noodles, config-api, APIs; re-run overrides; reset tasks |

---

## Bring-up order (do not skip or reorder)

### Prerequisites

- Docker Desktop (Linux containers)
- .NET 8 SDK (noodles, config-api); .NET Framework 4.7.2 + IIS/Rider (power)
- VPN — for NuGet `build.euroffice.co.uk` on first build
- `.env.local` with `MSSQL_SA_PASSWORD` (copy from `.env.local.example`)
- Group backup: e.g. `test4_power_supportcentre`, `_idl`, `_jst`, `_nservicebus`, `_productcatalogue`

### 1. Hosts + LOCAL_HOSTNAME

```powershell
# Elevated PowerShell
cd C:\workspace\local-infra
.\hosts-setup.ps1
```

Maps `mssql`, `rabbit`, `redis`, `mailpit`, `config-api`, `elastic` → `127.0.0.1` and writes `LOCAL_HOSTNAME=<machine name lower-cased>` into `.env`.

**Why:** every noodles container, config-api, and Power must use the **same** hostname string. It becomes part of the RabbitMQ topic-exchange routing key. A different hostname or different case means events are **silently** dropped.

### 2. Group switch in `.env` and SQL `sa` password in `.env.local`

Shared defaults stay in `.env`:

```
INFRA_DB_PREFIX=test4_power
INFRA_DEALER_GROUP=pow
INFRA_ENVIRONMENT=local
```

Other groups: `test4_eo` / `eog`, `test4_ei` / `ei0`.

The SQL `sa` password is **not** in `.env`. Create a gitignored local file once:

```bat
copy .env.local.example .env.local
```

Edit `.env.local` and set `MSSQL_SA_PASSWORD=...` (SQL Server complexity rules apply). `setup-local.bat` / `ops-local.bat` refuse to run without it. For manual `docker compose` commands, load both env files:

```bat
set COMPOSE_ENV_FILES=.env,.env.local
docker compose up -d
```

### 3. Core infrastructure

```bat
set COMPOSE_ENV_FILES=.env,.env.local
docker compose up -d
```

Starts **mssql, rabbit, redis, mailpit**. Wait until `mssql` and `rabbit` are healthy.

### 4. SQL: login → restore → overrides

Use the password from `.env.local` as `MSSQL_SA_PASSWORD` in the examples below (or prefer `setup-local.bat`, which reads it for you).

```bash
docker exec -i mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "<MSSQL_SA_PASSWORD>" -C -i /init/00-login-and-databases.sql
```

Put `.bak` files in `sql\backup\` (container path `/backup`), then restore. The script defaults to `@WhatIf = 1` (dry-run). For a real restore temporarily use `@WhatIf = 0` (or use `setup-local.bat`, which substitutes `0` in the pipe only and does not edit the file):

```powershell
Get-Content .\sql\test4\02-restore-local.sql |
  ForEach-Object { $_ -replace 'DECLARE @WhatIf\s+BIT = 1', 'DECLARE @WhatIf    BIT = 0' } |
  docker exec -i mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "<MSSQL_SA_PASSWORD>" -C
```

Overrides are **mandatory** — without them services talk to real TEST4 (including SMTP):

```bash
docker exec -i mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "<MSSQL_SA_PASSWORD>" -C -d test4_power_supportcentre -i /init/20-docker-overrides.sql
```

Verify:

```sql
SELECT cfg_Name, cfg_Value FROM dbo.cfg_Configurations
WHERE cfg_Dealer IS NULL AND cfg_Service IS NULL
  AND cfg_Name IN ('Environment', 'EnableInstallers', 'Rabbit', 'Cache', 'ConfigurationUrl');
```

Expect: `Environment=local`, `EnableInstallers=true`, Rabbit/Cache pointing at `rabbit` / `redis`.

### 5. Build images (once, VPN required)

```bash
docker compose build noodles-build config-api
```

All sixteen noodles services share one image `infra/noodles:local`. Without `noodles-build`, a cold `up` would fan out into sixteen identical builds.

### 6. Config API + Noodles

```bash
docker compose --profile noodles up -d
```

`config-api` depends on healthy `mssql` + `rabbit`. Noodles depend on `config-api`.

Check:

```text
http://localhost:8080/Configuration/1/Configuration/service=api.configuration
```

Optional satellite APIs (Pricing, Tax, Product, Payments, Audience):

```powershell
.\clone-apis.ps1
docker compose --profile apis build
docker compose --profile apis up -d
```

### 7. Reset scheduled tasks

```powershell
.\reset-scheduled-tasks.ps1
```

After every restore: `sta_ScheduledTasks` still holds TEST4 addresses (`test4.pow.noodles.*`). The script clears those tables and `--force-recreate`s noodles so services re-register with local addresses.

### 8. Power (on the host)

Power sites are **not** containerised. They run under IIS (.NET Framework 4.7.2) and have **no** business-database connection string of their own. They call the Configuration API; that API reads `dbo.cfg_Configurations` from the restored support-centre DB and returns connection strings. Local data follows automatically once `ConfigurationUrl` points at the local `config-api` (which already sees `Data Source=mssql,1433` after `20-docker-overrides.sql`).

#### Checklist

1. **IIS sites and aliases** — run `power/InitialSetup.ps1` (elevated) so `wfe`, `portal`, `admin`, `cdn` exist and resolve to `127.0.0.1`. That lives in the `power` repo, not here.

2. **WebConfigPicker** (`C:\workspace\webconfigpicker`) — “Do the Magic!” with local options ticked:
   - **Configuration API → Use local** (required; otherwise the site loads TEST4 config and hits the remote DB no matter what else you set)
   - Use local RabbitMQ
   - Use local cache

   That writes into each site’s `Web.config` roughly:
   - `ConfigurationUrl` = `http://localhost:8080/configuration`
   - `Rabbit` / `Cache` / `Redis.ConnectionString` → localhost
   - `UseAzureServiceBus` = `false`

3. **Elevated:** `.\power-local-setup.ps1` (after every WebConfigPicker run). Covers what the picker does not:
   - **`Generic.ForceIntegratedSecurity` = `false`** — otherwise Power strips SQL credentials and uses Windows auth, which the Linux SQL container rejects
   - guarantees `ConfigurationUrl` and local satellite API URLs (Pricing, Tax, Product, Payments, Audience)

   Or pass `--power` to `setup-local.bat` after the sites already exist.

4. **Group / dealer in `<appSettings>`** (each of Portal, FrontEnd, Support, Static):
   - `Environment` = `local`
   - `DealerGroup` = same as `.env` `INFRA_DEALER_GROUP` (e.g. `pow`)
   - `DealerId` = a **real dealer number** from the restored DB (`idl` / `jst`)

   ```sql
   SELECT dlr_DealerNumber FROM dbo.dlr_Dealers;  -- against support-centre
   ```

5. **Stack prerequisites** (normally already done by `setup-local.bat`):
   - restore + `20-docker-overrides.sql` so cfg points at `mssql` / `rabbit` / `redis`
   - `config-api` is up (`http://localhost:8080/Configuration/...`)
   - `hosts-setup.ps1` so `mssql` (and friends) resolve to `127.0.0.1` from the Windows host

Sample appSettings: [`config-samples/power.Web.config.local.appSettings.xml`](config-samples/power.Web.config.local.appSettings.xml).

Do **not** hand-edit `Web.config` for day-to-day env switches — use WebConfigPicker, then `power-local-setup.ps1`.

---

## Compose profiles

| Command | Brings up |
|---|---|
| `docker compose up -d` | Core: mssql, rabbit, redis, mailpit |
| `docker compose --profile noodles up -d` | + config-api + all 16 noodles |
| `docker compose up -d noodles-sales` | One service (naming it enables its profile) |
| `docker compose --profile apis up -d` | + satellite APIs (+ config-api) |
| `docker compose --profile search up -d` | Elasticsearch + Kibana |
| `docker compose --profile all down` | Stop everything |
| `docker compose --profile all down -v` | + wipe volumes (queues, Redis, DB) |

RAM/CPU limits live in `.env`; `MSSQL_SA_PASSWORD` lives in `.env.local` — leave the compose file alone.

---

## Addresses

| Service | URL / connection |
|---|---|
| RabbitMQ UI | http://localhost:15672 (`guest` / `guest`) |
| Mailpit UI | http://localhost:8025 |
| Config API | http://localhost:8080/Configuration |
| Redis | `localhost:6379` |
| SQL | `localhost,1433`, `sa` / password from `.env.local` (`MSSQL_SA_PASSWORD`) |
| App logins | `EuroWebsite` / `pensandpencils`, `EuroService` / `0*lEVEL*gIVES?` |

Full table: [`config-samples/connection-strings.md`](config-samples/connection-strings.md).

---

## Health checks

```bash
docker compose ps
docker inspect <container> --format "{{.RestartCount}}"
```

- All noodles / config-api: `running`, `RestartCount=0` a few minutes after start.
- RabbitMQ Connections: every endpoint uses the same lower-case `local_<hostname>` prefix (e.g. `local_rix3267.pow.noodles.actions`). Mixed case / `test4.*` / `local-dev` means broken routing.
- E2E: perform an action in the Power UI → a new row in an audit table (e.g. `dbo.chl_ChangeLogs`) within a few seconds. Green RabbitMQ connections alone do **not** prove delivery.

---

## Known pitfalls

1. **Hostname must match and be lower-case** across every process that does NSB pub/sub. `hosts-setup.ps1` writes `LOCAL_HOSTNAME` → compose `hostname:`. Never hardcode a hostname.
2. **`EnableInstallers=true`** on the global `cfg_Configurations` row — otherwise crash-loop `NOT_FOUND - no queue/exchange`. Set by `20-docker-overrides.sql`.
3. **`Environment=local` in the DB**, not only in appsettings/Web.config. Otherwise the endpoint's own queue looks fine but subscription bindings use `test4-...` — events vanish with no error.
4. **Stale scheduled tasks** after every restore → run `reset-scheduled-tasks.ps1`.
5. **RabbitMQ debris** after a hostname/Environment change — old durable exchanges/queues remain. Clean via the HTTP API; use PowerShell `-cmatch` (case-sensitive) when filtering names, or you will delete the fresh topology too.
6. **DealerId is not the group name.** For pow: `IDL` / `JST`.
7. **Power without explicit Rabbit/Cache** can still fall back to remote values from the DB.
8. **`power/docker-compose.yml` and this stack** share ports — do not run both.
9. No local Azure Files equivalent; paths are repointed to `/files` inside containers.

---

## Restore / backups (details)

See [`sql/test4/README.md`](sql/test4/README.md) — COPY_ONLY from TEST4, restore, DB sizes, group switching.

Init scripts: [`sql/init/README.md`](sql/init/README.md).

---

## Debugging one Noodles service

Stop its container and run the project from Rider — same hostnames (`hosts-setup.ps1`), same ports.

---

## Day-to-day ops (`ops-local.bat`)

### What this is

Two batch files cover two different jobs:

| Script | Purpose |
|---|---|
| `setup-local.bat` | **First-time / from-zero install** — hosts, core Docker, SQL restore, image build, noodles, scheduled tasks |
| `ops-local.bat` | **Everyday maintenance** when the stack is already running — rebuild or restart only what changed |

`ops-local.bat` does **not** restore databases, does **not** wipe volumes, and does **not** replace a failed install. After a broken setup, use `setup-local.bat --wipe` instead.

### When to use which action

Typical loop after the stack is healthy:

1. Change code in `noodles/` (or `api.configuration`, or a satellite API).
2. Run the matching `ops-local.bat` action below.
3. Wait for the green `Done.` message, then verify with `docker compose ps` / RabbitMQ UI.

| You changed… | Run |
|---|---|
| Any Noodles service source | `ops-local.bat noodles-rebuild` |
| One Noodles service only (faster) | `ops-local.bat noodles-rebuild sales` (or `actions`, `email`, …) |
| Need a container bounce, same image | `ops-local.bat noodles-restart` |
| `api.configuration` source | `ops-local.bat config-rebuild` |
| Satellite APIs (pricing, tax, …) | `ops-local.bat apis-rebuild` |
| Only cfg endpoints in SQL (Rabbit/Redis/…) | `ops-local.bat overrides` |
| Stale scheduled-task reply addresses | `ops-local.bat reset-tasks` |
| Core infra only (SQL / Rabbit / Redis / Mailpit) | `ops-local.bat core-restart` |

### How to run

1. Open a terminal in `C:\workspace\local-infra` (Administrator only needed for hosts/Power — not for these ops).
2. Confirm the stack is up: `docker compose ps`.
3. Run an action:

```bat
ops-local.bat help
ops-local.bat noodles-rebuild
ops-local.bat noodles-rebuild sales
ops-local.bat noodles-restart
ops-local.bat config-rebuild
ops-local.bat config-restart
ops-local.bat apis-rebuild
ops-local.bat apis-restart
ops-local.bat overrides
ops-local.bat reset-tasks
ops-local.bat core-restart
```

4. The window prints progress, then a green `Done.` and waits for a keypress.

### Notes

- `noodles-rebuild` rebuilds the shared image `infra/noodles:local` (VPN may be required for NuGet), then recreates `noodles-*` containers. **`config-api` is left alone.**
- Short service names map to compose services: `sales` → `noodles-sales`.
- `noodles-rebuild` needs the internal NuGet feed; if restore fails, connect VPN and retry.
- Prefer `ops-local.bat` over hand-rolled `docker compose` so recreate flags stay consistent (`--force-recreate --no-deps` where needed).
