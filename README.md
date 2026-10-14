# Local infrastructure for Power + Noodles + DB

Local EurofficeGroup stack: SQL Server, RabbitMQ, Redis, Mailpit, Configuration API, and Noodles services in Docker. Power (.NET Framework 4.7.2) runs on the host under IIS / Rider — **not** in compose.

## Three Docker Desktop groups

The stack is three compose projects, so Docker Desktop shows three groups:

| Group (project) | File | Containers |
|---|---|---|
| `power` | `docker-compose.yml` | mssql, rabbit, redis, mailpit; elastic, kibana with `--profile search` |
| `api-power` | `docker-compose.api.yml` | config-api, api-tax, api-pricing, api-product, api-payments, api-audience; search-api with `--profile search` |
| `noodles` | `docker-compose.noodles.yml` | the sixteen `noodles-*` (`noodles-build` with `--profile build`); noodles-searches with `--profile search` |

They share the external network `hostnet`, created by `power`, so start `power` first. `depends_on` cannot cross projects; `setup-local.bat` waits for mssql/rabbit and config-api itself.

Docker Desktop has no nested groups, so there is no common parent group above the three.

The `search` profile (Elasticsearch, the search API and its indexer) is off by default; see [Local search](#local-search-elasticsearch).

## Quick start

1. Place the group's `.bak` files in `sql\backup\` (original TEST4 names, e.g. `test4_power_supportcentre.bak`, `test4_power_jst.bak`). They are restored as `dev_uk_*` — see step 2 below.
2. Copy `.env.local.example` → `.env.local` and set **`MSSQL_SA_PASSWORD`** (gitignored; required). The password must meet SQL Server complexity rules or the `mssql` container will not start.
3. Check the group switch in `.env` (`INFRA_DB_PREFIX`, `INFRA_BACKUP_PREFIX`, `INFRA_DEALER_CODE`, `INFRA_DEALER_GROUP`, `INFRA_ENVIRONMENT`).
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
| `--wipe` | `docker compose down -v` of all three projects first, then full setup from a clean slate |
| `--skip-hosts` | Skip `hosts-setup.ps1` |
| `--skip-restore` | Skip restore / overrides (DB already present) |
| `--skip-build` | Skip image builds (already built) |
| `--skip-noodles` | Core + SQL only; no config-api / noodles |
| `--skip-pull` | Step 5 clones missing repos but does not `git pull` the existing ones |
| `--apis` | No longer needed - the satellite APIs are always cloned (if missing), built and started. Still accepted. |
| `--power` | Run `power-local-setup.ps1` at the end (needs IIS sites + WebConfigPicker) |
| `--search` | Also bring up the local search stack after noodles (`search-local.ps1 -Mode On`, see [Local search](#local-search-elasticsearch)). Needed again after every restore |

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
| `search`, `integrations` | Only for the `search` profile: the search API (`eurofficegroup.search`) and the indexer `Noodles.SearchEs` (`eurofficegroup.integrations`). Cloned by `ops-local.bat search-on` / `clone-apis.ps1 -Search` |

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
| `clone-apis.ps1` | Step 5 of `setup-local.bat` | Clones `noodles`, `api.configuration` and the five API repos if missing; `git pull --ff-only` on clean ones, never touches local changes (`-NoPull` / `--skip-pull` to skip). `-Search` adds `search` and `integrations` |
| `power-local-setup.ps1` | After WebConfigPicker, or whenever the Power `web.config`s were reset (elevated) | Sets `ConfigurationUrl`, `ForceIntegratedSecurity=false`, local API URLs, local Redis/RabbitMQ, and `Environment` / `DealerGroup` / `DealerId` from `.env`. Also `ops-local.bat power` |
| `sql/init/40-search-local.sql` / `41-search-remote.sql` | Through `search-local.ps1` only | Switch the search configuration (`SearchApiServiceUrl`, Elasticsearch connection strings, synonym transport) to the local containers and back |
| `search-local.ps1` | `ops-local.bat search-*`, `setup-local.bat --search` | Local search stack on / off / rebuild / status, in the safe order - see [Local search](#local-search-elasticsearch) |
| `migrate-local.ps1` | After writing or pulling a migration in `../database` | Builds the three migrator projects of `../database` (Debug) and applies their pending migrations to `<prefix>_productcatalogue`, every dealer database and `<prefix>_supportcentre`; `-Preview` writes nothing, `-Restart` then restarts config-api, noodles and the IIS app pools. Also `ops-local.bat db-migrate [preview|restart]` - see [Database migrations](#database-migrations) |
| `setup-local.bat` | From scratch | Runs the above in order (except manual Power) |
| `ops-local.bat` | Day-to-day | Rebuild/restart noodles, config-api, APIs; re-run overrides; reset tasks; local search on/off |
| `cleanup-local.bat` | When disk is full | Prunes **this project's** build cache + unused images (compose label); never touches volumes, running containers, or other Docker apps |

---

## Bring-up order (do not skip or reorder)

### Prerequisites

- Docker Desktop (Linux containers)
- .NET 8 SDK (noodles, config-api); .NET Framework 4.7.2 + IIS/Rider (power)
- VPN — for NuGet `build.euroffice.co.uk` on first build
- `.env.local` with `MSSQL_SA_PASSWORD` (copy from `.env.local.example`)
- Group backup: `test4_power_supportcentre`, `_productcatalogue`, `_nservicebus` and every dealer (`_idl`, `_jst`)

### 1. Hosts + LOCAL_HOSTNAME

```powershell
# Elevated PowerShell
cd C:\workspace\local-infra
.\hosts-setup.ps1
```

Maps `mssql`, `rabbit`, `redis`, `mailpit`, `config-api`, `elastic`, `search-api` → `127.0.0.1` and writes `LOCAL_HOSTNAME=<machine name lower-cased>` into `.env`.

**Why:** every noodles container, config-api, and Power must use the **same** hostname string. It becomes part of the RabbitMQ topic-exchange routing key. A different hostname or different case means events are **silently** dropped.

### 2. Group switch in `.env` and SQL `sa` password in `.env.local`

Shared defaults stay in `.env`:

```
INFRA_DB_PREFIX=dev_uk            # local databases: dev_uk_{0}
INFRA_BACKUP_PREFIX=test4_power   # backups:         test4_power_{0}.bak
INFRA_DEALER_CODE=jst             # the dealer:      {0} = jst
INFRA_DEALER_GROUP=pow
INFRA_ENVIRONMENT=local
```

`{0}` is the database role or the dealer code:

| Backup in `sql\backup\` | Local database |
|---|---|
| `test4_power_supportcentre.bak` | `dev_uk_supportcentre` |
| `test4_power_productcatalogue.bak` | `dev_uk_productcatalogue` |
| `test4_power_nservicebus.bak` | `dev_uk_nservicebus` |
| `test4_power_<dealer>.bak` (each one) | `dev_uk_<dealer>`, e.g. `dev_uk_idl`, `dev_uk_jst` |

Every dealer backup of the group in `sql\backup` is restored: the support centre's dealer views (`dlr_Dealers`, `cus_Customers`, ...) are `UNION ALL` over all dealers and fail if one is missing. `INFRA_DEALER_CODE` is the main dealer - its backup is required and it is Power's `DealerId`. The three values can be overridden per machine in `.env.local` (see `.env.local.example`).

Other groups: `INFRA_BACKUP_PREFIX=test4_eo` / `eog`, `test4_ei` / `ei0`. All groups land under the same `dev_uk_*` names, so switching group needs `setup-local.bat --wipe`.

The SQL `sa` password is **not** in `.env`. Create a gitignored local file once:

```bat
copy .env.local.example .env.local
```

Edit `.env.local` and set `MSSQL_SA_PASSWORD=...` (SQL Server complexity rules apply). `setup-local.bat` / `ops-local.bat` refuse to run without it. For manual `docker compose` commands, load both env files:

```bat
set COMPOSE_ENV_FILES=.env,.env.local
docker compose up -d
```

### 3. Core infrastructure (group `power`)

```bat
set COMPOSE_ENV_FILES=.env,.env.local
docker compose up -d
```

Starts **mssql, rabbit, redis, mailpit** (`docker-compose.yml` is the default file). Wait until `mssql` and `rabbit` are healthy.

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
docker exec -i mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "<MSSQL_SA_PASSWORD>" -C -d dev_uk_supportcentre -i /init/20-docker-overrides.sql
```

After the restore, `sql/init/30-rename-db-references.sql` repoints synonyms / views / procedures inside the databases from `test4_power_*` to `dev_uk_*` (`ops-local.bat rename-refs` re-runs it).

Run by hand, the scripts use the defaults written in their `DECLARE @SourcePrefix / @TargetPrefix / @DealerCode` lines (`test4_power` / `dev_uk` / `jst`); edit those if `.env` differs. `setup-local.bat` and `ops-local.bat overrides` substitute the `.env` values for you, and also set `@HostFileRoot` in `20-docker-overrides.sql` to this repo's `files\` folder (left empty by hand, Power then keeps the container paths).

Verify:

```sql
SELECT cfg_Name, cfg_Value FROM dbo.cfg_Configurations
WHERE cfg_Dealer IS NULL AND cfg_Service IS NULL
  AND cfg_Name IN ('Environment', 'EnableInstallers', 'Rabbit', 'Cache', 'ConfigurationUrl');
```

Expect: `Environment=local`, `EnableInstallers=true`, Rabbit/Cache pointing at `rabbit` / `redis`,
and `SiteContentCdnUrl` / `Content.StaticContentUrl` = `//cdn` (the local Static site — otherwise Power pages render without styles, because TEST4's `test4-pow-static.office-power.net` is unreachable).

### 5. Build images (once, VPN required)

```bash
docker compose -f docker-compose.noodles.yml build noodles-build
docker compose -f docker-compose.api.yml build config-api
```

All sixteen noodles services share one image `infra/noodles:local`. Without `noodles-build`, a cold `up` would fan out into sixteen identical builds.

### 6. Config API + Noodles (groups `api-power`, `noodles`)

```bash
docker compose -f docker-compose.api.yml up -d config-api
docker compose -f docker-compose.noodles.yml up -d
```

Start `config-api` only after `mssql` and `rabbit` are healthy, and Noodles after `config-api` answers. These are separate projects, so compose does not enforce the order. A Noodles service started too early exits and is restarted by `restart: unless-stopped`.

Check:

```text
http://localhost:8080/Configuration/1/Configuration/service=api.configuration
```

The satellite APIs (Pricing, Tax, Product, Payments, Audience) start with config-api; by hand:

```powershell
.\clone-apis.ps1
docker compose -f docker-compose.api.yml build
docker compose -f docker-compose.api.yml up -d
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
   - writes the picker's local Redis / RabbitMQ values again (`Cache`, `Redis.ConnectionString`, `Rabbit`, `UseAzureServiceBus=false`) — a no-op after the picker
   - **group / dealer** from `.env` (`.env.local` wins), see step 4

   Or pass `--power` to `setup-local.bat` after the sites already exist.

   **Configs got reset** (git checkout, a picker run for another environment)? Just run, elevated:
   `ops-local.bat power` (same script). No picker needed - the committed `web.config` becomes local too.
   Rollback: `web.config.before-local` next to each site's `web.config`.

4. **Group / dealer in `<appSettings>`** — set by `power-local-setup.ps1`:
   - `Environment` = `INFRA_ENVIRONMENT` (`local`), all four sites
   - `DealerGroup` = `INFRA_DEALER_GROUP` (e.g. `pow`, lower-case), all four sites
   - `DealerId` = `INFRA_DEALER_CODE` (default `jst`) — the main dealer; FrontEnd (`wfe`) and Portal only.
     Support and Static run without one. `DealerId=POW` (the committed value) is the group, not a dealer,
     and fails with *Cannot open database "dev_uk_POW"*.
   - Another dealer for one run: `.\power-local-setup.ps1 -DealerCode idl`

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
| `docker compose up -d` | Group `power`: mssql, rabbit, redis, mailpit |
| `docker compose --profile search up -d` | + Elasticsearch + Kibana (group `power`) only - for the whole search stack use `ops-local.bat search-on` |
| `docker compose -f docker-compose.api.yml up -d config-api` | Group `api-power`: config-api only |
| `docker compose -f docker-compose.api.yml up -d` | config-api + satellite APIs |
| `docker compose -f docker-compose.noodles.yml up -d` | Group `noodles`: all 16 |
| `docker compose -f docker-compose.noodles.yml up -d noodles-sales` | One Noodles service |
| `docker compose -f <file> down` | Stop one group (stop `power` last - it owns `hostnet`) |
| `setup-local.bat --wipe` | Wipe all three groups + volumes (queues, Redis, DB) |

RAM/CPU limits live in `.env`; `MSSQL_SA_PASSWORD` lives in `.env.local` — leave the compose file alone.

---

## Database migrations

Schema and data changes live in the sibling repo `../database` (FluentMigrator). After you write or pull a migration there:

```bat
ops-local.bat db-migrate preview
ops-local.bat db-migrate
ops-local.bat db-migrate restart
```

| Command | What it does | Changes the databases? |
|---|---|---|
| `ops-local.bat db-migrate preview` | Dry run: lists, per database, the migrations that are not applied yet and prints their SQL. Ends with "Summary - PREVIEW, would apply" | No - nothing is executed, `dbo.VersionInfo` stays as it is |
| `ops-local.bat db-migrate` | Real run: executes those migrations and records them in `dbo.VersionInfo`. Ends with "Summary - applied" | Yes. Running it again applies nothing that is already there |
| `ops-local.bat db-migrate restart` | The real run, then - only if something was applied - recreates `config-api` and the `noodles-*` containers and recycles the app pools of the IIS sites `wfe`, `portal`, `admin`, `cdn`, so cached configuration and CMS content are read again | Yes, same as `db-migrate` |

Run `preview` first, check the list (a TEST4 restore also brings master migrations TEST4 did not have yet), then run `db-migrate`.

`migrate-local.ps1` (what `db-migrate` runs):

1. builds `EurofficeGroup.Database.Migrator.ProductCatalogue`, `.Dealer` and `.SupportCentre` in Debug (public NuGet only, no VPN);
2. finds the local databases by `INFRA_DB_PREFIX`: `<prefix>_productcatalogue`, every `<prefix>_<dealer>` that has `dbo.cus_Customers` (dealer code = the name after the prefix), `<prefix>_supportcentre`;
3. runs `Migrate.exe` against each of them in that order (as `../database/src/LocalDeploy.ps1` does) with the deploy context: `dealer_ref`, the database names, `environment` = `INFRA_ENVIRONMENT`, `dealer_group` = `INFRA_DEALER_GROUP`;
4. prints which migrations each database got.

- **Not only yours.** A database restored from TEST4 also gets every master migration TEST4 did not have yet. Run `preview` first to see the list.
- Re-running is safe: FluentMigrator only applies what is missing from `dbo.VersionInfo`.
- Stops at the first failing database; the ones after it are not migrated.
- Options when calling the script directly: `-Database dev_uk_jst` (only these databases), `-SkipBuild`, `-Workspace <folder>` (default: the parent of `local-infra`).
- Power and noodles cache configuration and CMS content. Most migrations (schema, indexes) need no restart; one that changes `cfg_Configurations` or CMS content does - use `db-migrate restart`. Recycling the app pools needs an elevated prompt; without one that step is skipped with a warning (recycle them in IIS Manager). Redis is not flushed: what Power cached there stays until it expires. Restarting noodles takes a minute or two, and the recycle drops Power's in-process sessions (log in again).

---

## Local search (Elasticsearch)

By default the sites use **TEST4's** search: `SearchApiServiceUrl` points at the search API on `vm-test-uks-04:9012`, and that API reads TEST4's cluster. Anything created only in the local databases - a custom list uploaded through the PSP, a new item - therefore shows its name on the storefront but **no products** ("0 of 0 products / No items"): the storefront asks the search API for the list's products, and TEST4 has never heard of the list.

The `search` profile replaces that with three local containers:

| Container | What | Source |
|---|---|---|
| `elastic` (+ `kibana`) | Elasticsearch `ELASTIC_VERSION` from `.env` (8.15.0, the same as TEST4's `elastic-test-lb`), single node, no security | image |
| `search-api` | The search API on `:9012` - read-only, what the storefront / PSP call | `../search` (repo `eurofficegroup.search`) |
| `noodles-searches` | The indexer `Noodles.SearchEs`: full rebuild from the dealer DB, then live updates from events (`ItemDetailChangedDealerEvent`, ...) | `../integrations` (repo `eurofficegroup.integrations`) |

One dealer's product index is ~120k documents / ~300 MB, so it fits comfortably. Extra memory actually used (`docker stats`, JST indexed, idle): about 1.8 GB (elastic: the 1 GB heap is fixed by `ELASTIC_HEAP`, plus off-heap) + 0.6 GB (Kibana) + 0.2 GB (indexer) + 0.15 GB (search API), so ~2.7 GB in total. The `*_MEM` values in `.env` are caps, not usage: 2 GB / 1 GB / 1 GB / 512 MB.

### Switch on

```bat
ops-local.bat search-on
```

It clones `../search` and `../integrations` if missing, creates `files\elastic\synonyms.txt`, starts `elastic`, runs `sql/init/40-search-local.sql`, recreates config-api, builds the two images if missing (VPN), and starts `search-api` and `noodles-searches`. Then, once:

1. If you set up before this existed: re-run `.\hosts-setup.ps1` elevated, so `search-api` resolves to `127.0.0.1` (the script warns if it does not).
2. Recycle the app pools of `wfe`, `portal` and `admin` - Power caches `SearchApiServiceUrl`.
3. Build the index: http://admin → select the dealer (Dealer Map → Just Office, or http://admin/Dealer/Impersonate/1700000000 for JST) → http://admin/Dev/SearchEngine → **Start Product index Export**. Follow `docker logs -f noodles-searches`; `ops-local.bat search-status` lists the indices (`product_localpow_jst_<n>` behind the alias `product_localpow_jst`; green, no replicas - `search-on` puts an index template `local-infra-single-node` with `number_of_replicas: 0` on `product_*` / `smart_*`).
4. Optional, same page: **Populate Synonym File For Product Index** writes the real synonym list into `files\elastic\synonyms.txt`.

From then on the indexer keeps the index current: a custom list uploaded in the PSP appears on the storefront with its products.

### Stuck indexer: `ops-local.bat search-reset`

A rebuild runs as a saga in `<prefix>_nservicebus`. It refuses to start while another one is marked running (`EX007` in `docker logs noodles-searches`), and while it runs it sets `UpdatesLocked` on the product-index upkeep saga, which postpones every live update (custom list uploads included) until the rebuild finishes. A restore brings TEST4's saga rows along, with whatever state TEST4 had at backup time; a rebuild aborted halfway (container stopped, `search-off`) leaves `UpdatesLocked=1` behind. `search-reset` stops `noodles-searches`, empties its queues, deletes the product-reindex saga rows, clears `UpdatesLocked` and starts it again; then start a rebuild. Indices are not touched.

### Switch off

```bat
ops-local.bat search-off
```

Stops `noodles-searches` and `search-api`, puts the TEST4 values back (`41-search-remote.sql`), recreates config-api and stops `elastic` / `kibana`. The index stays in the volume `power_elastic-data-8` for the next `search-on`. Recycle the Power app pools again.

### What `40-search-local.sql` changes

| Row | Local value |
|---|---|
| `ElasticSearchConnectionString` (and `ElasticSearchUpdateConnectionString` if present) | `http://elastic:9200` |
| `SearchApiServiceUrl` | `http://search-api:9012/Search/` |
| `ElasticSearch.SynonymFilePathOnNodes` | `eo/synonyms.txt` (relative to the node's config folder; `./files/elastic` is mounted as `config/eo`) |
| `ElasticSearch.ProductIndexPrefix` | `local<group>` (`test4pow` -> `localpow`), so local indices are `product_localpow_<dealer>_<n>` and cannot be mistaken for TEST4's |
| `tra_Transports` rows with `Method=ElasticNodes` | `Method=File`, folder `/files/elastic`, file `synonyms.txt` |

The original cfg values are saved once in `dbo.zz_LocalInfraSearchBackup`; `41-search-remote.sql` restores them and drops the table. The transport row stays local after `search-off` on purpose.

### Why the order and the pinning matter

A product index rebuild **creates a new index, moves the alias and deletes the old index**. The restored configuration points at TEST4's shared cluster, so an indexer started against it would replace TEST4's index with this machine's data, and the restored synonym transport would copy a file onto TEST4's nodes over SFTP. Two guards:

- `search-api` and `noodles-searches` get `ElasticSearchConnectionString` / `ElasticSearchUpdateConnectionString` = `http://elastic:9200` as **environment variables** in compose. The configuration client lets the process environment win over config-api, so these containers can only reach the local node whatever the database says. Do not remove them.
- `search-local.ps1` switches the database (connection strings, `SearchApiServiceUrl`, synonym transport) **before** it starts the containers.

After `setup-local.bat --wipe` or any restore the database is TEST4's again: run `ops-local.bat search-on` again (or pass `--search` to `setup-local.bat`).

---

## Addresses

| Service | URL / connection |
|---|---|
| RabbitMQ UI | http://localhost:15672 (`guest` / `guest`) |
| Mailpit UI | http://localhost:8025 |
| Config API | http://localhost:8080/Configuration |
| Elasticsearch / Kibana (`search` profile) | http://localhost:9200 / http://localhost:5601 |
| Search API (`search` profile) | http://search-api:9012/Search/ (= `localhost:9012`) |
| Redis | `localhost:6379` |
| SQL | `localhost,1433`, `sa` / password from `.env.local` (`MSSQL_SA_PASSWORD`) |
| App logins | `EuroWebsite` / `pensandpencils`, `EuroService` / `0*lEVEL*gIVES?` |

Full table: [`config-samples/connection-strings.md`](config-samples/connection-strings.md).

---

## Health checks

```bash
docker compose ps
docker compose -f docker-compose.api.yml ps
docker compose -f docker-compose.noodles.yml ps
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
10. **Power and noodles share one data bus folder.** File uploads from the PSP and PDFs travel as NServiceBus data bus files. Noodles reads `/files/...`; Power on Windows gets the same folder as `<local-infra>\files\...` through `cfg_Service` rows for `portal`, `frontend`, `support`, `suppliers` (the Support site's `ServiceName` in its Web.config), `static`, `datamanagement` and `genericprocess` (section 4 of `20-docker-overrides.sql`, path substituted by `setup-local.bat` / `ops-local.bat`). Power writes keys as `yyyy-MM-dd_HH\guid`; noodles (`DataBusKeySeparatorBehaviour`) turns the `\` into `/` by itself when `Environment` is `local` (`INFRA_ENVIRONMENT=local`) and it is not running on Windows, i.e. in Docker; no configuration key needed. Run from Rider on Windows, it reads the `\` keys as they are. Symptom without it: uploads never finish and `noodles-uploaders` logs `DirectoryNotFoundException ... /files/fshare-...\<guid>`.

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
| `cleanup-local.bat` | **Free disk space** — only this compose project's unused build cache/images; keeps volumes, running infra, and other Docker apps |

`ops-local.bat` does **not** restore databases, does **not** wipe volumes, and does **not** replace a failed install. After a broken setup, use `setup-local.bat --wipe` instead.

### Disk cleanup (`cleanup-local.bat`)

After repeated `noodles-rebuild` / `apis-rebuild`, this project's BuildKit cache and superseded `infra/*:local` images grow inside `%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx`. Run:

```bat
cleanup-local.bat
```

Requires `mssql`, `rabbit`, and `redis` to already be running. Cleanup is scoped with  
`label=com.docker.compose.project=` power, api-power, noodles:

- `docker builder prune` — only the build cache of `power`, `api-power`, `noodles`
- `docker container prune` — only stopped containers of those projects
- `docker image prune` — only unused images built by those projects

It does **not** run global `docker system prune`. Volumes and other stacks on the machine stay untouched.

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
| Only cfg endpoints in SQL (Rabbit/Redis/CDN/…) | `ops-local.bat overrides`, then `ops-local.bat config-restart` and restart the Power sites — they cache configuration until the app restarts |
| Stale scheduled-task reply addresses | `ops-local.bat reset-tasks` |
| Core infra only (SQL / Rabbit / Redis / Mailpit) | `ops-local.bat core-restart` |
| Power `web.config`s lost their local settings (elevated prompt) | `ops-local.bat power` |
| Want list/search products from the local DB on the storefront | `ops-local.bat search-on`, then the product index export - see [Local search](#local-search-elasticsearch) |
| `../search` or `../integrations` source | `ops-local.bat search-rebuild` |
| Rebuild refused (`EX007`), or list uploads never reach the storefront | `ops-local.bat search-reset`, then the product index export again |
| Wrote or pulled a migration in `../database` | `ops-local.bat db-migrate preview`, then `ops-local.bat db-migrate` (or `db-migrate restart` if it changes configuration or CMS content) - see [Database migrations](#database-migrations) |

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
ops-local.bat power
ops-local.bat search-on
ops-local.bat search-status
ops-local.bat search-off
ops-local.bat search-rebuild
ops-local.bat search-reset
ops-local.bat db-migrate preview
ops-local.bat db-migrate
ops-local.bat db-migrate restart
```

4. The window prints progress, then a green `Done.` and waits for a keypress.

### Notes

- `noodles-rebuild` rebuilds the shared image `infra/noodles:local` (VPN may be required for NuGet), then recreates `noodles-*` containers. **`config-api` is left alone.**
- Short service names map to compose services: `sales` → `noodles-sales`.
- `noodles-rebuild` needs the internal NuGet feed; if restore fails, connect VPN and retry.
- Prefer `ops-local.bat` over hand-rolled `docker compose` so recreate flags stay consistent (`--force-recreate --no-deps` where needed).
