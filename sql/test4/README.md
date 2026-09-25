# Local databases: a mirror of TEST4, not a rename

Source server: **vm-tstdb-uks-02.datacentre.euroffice.com** (VPN required).
The DBA is producing these five backups:

1. `test4_power_supportcentre`
2. `test4_power_productcatalogue`
3. `test4_power_nservicebus`
4. `test4_power_idl`
5. `test4_power_jst`

**Put the `.bak` files in `C:\workspace\local-infra\sql\backup`.**
The container sees that folder as `/backup` (`docker-compose.yml:159`).
Do not rename them.

## The principle

Databases keep their real names. Real environments are laid out as
`<env>_<group>_<db>`, and the configuration addresses them through a prefix:

```
Generic              = ...Initial Catalog=test4_power_{0}
SupportCentreSchema  = test4_power_supportcentre.dbo
ProductCatalogueSchema = test4_power_productcatalogue.dbo
DealerSchema         = test4_power_{0}.dbo
```

Keep the names and the local instance has the same shape as TEST4: switching
group is a configuration change, and adding a group or a dealer is one more
`.bak` in the folder plus a re-run of the restore. That is the whole design.

An earlier draft of these scripts renamed everything into a single `dev_uk_*`
namespace, following the `local_sc.sql` seed in the Configuration API repo. That
seed assumes one hardcoded group and would have made switching impossible — it
is gone.

## Switching group

Restore the other group's backups into the same instance, then change two values
in the Configuration API's `appsettings.json` and restart it:

| Group | `Generic` catalog | `DealerGroup` |
|---|---|---|
| power | `test4_power_{0}` | `pow` |
| euroffice | `test4_eo_{0}` | `eog` |
| ei | `test4_ei_{0}` | `ei0` |

Template: [`../../config-samples/api.configuration.appsettings.local.json`](../../config-samples/api.configuration.appsettings.local.json).

On the Power side the matching values are `DealerGroup` and `DealerId` in
`Web.config` — see
[`../../config-samples/power.Web.config.local.appSettings.xml`](../../config-samples/power.Web.config.local.appSettings.xml).
`DealerId` must be a dealer of the selected group: `idl` or `jst` for power,
`eo0`/`od0` for euroffice.

## Adding a dealer later

A dealer is just another database, `test4_power_<dealer>`. Get the `.bak`, drop
it in `sql/backup`, re-run the restore script — it discovers new files by itself.
The dealer must also exist in `dlr_Dealers` in that group's support centre, which
it will, since the support centre came from the same environment.

## Run order

```bash
docker compose --profile db up -d
```

| # | Script | Connect to | Notes |
|---|---|---|---|
| 1 | [`../init/00-login-and-databases.sql`](../init/00-login-and-databases.sql) | `localhost,1433` | Creates the `EuroWebsite` login. Creates no group databases. |
| 2 | [`02-restore-local.sql`](02-restore-local.sql) | `localhost,1433` | Restores everything in `/backup` under its original name |
| 3 | [`../init/20-docker-overrides.sql`](../init/20-docker-overrides.sql) | `-d test4_power_supportcentre` | Repoints endpoints. **Once per group.** |

Both scripts start at `@WhatIf = 1` and only print what they would do.

### Step 3 is not optional

A restored support centre still holds TEST4's configuration: RabbitMQ on
`10.2.34.12`, `MSSQL-TEST-QA`, `eo-web-cache.euroffice.co.uk`, the real SMTP
relay. Start a service before repointing it and it talks to the test environment
for real, including sending email to real addresses.

The override script changes **endpoints only** — which server, which broker,
which cache, which mail host. It rebuilds each connection string token by token
so the `test4_power_{0}` catalog is preserved and only `Data Source` is swapped.
Group prefixes are never touched. It also strips `Integrated Security`, which
cannot work from the Windows host against a Linux container, and substitutes the
`EuroWebsite` login.

It ends with a query listing anything still pointing off this machine. Some of
those are fine — public CDN URLs, payment gateway endpoints. A database, broker
or mail host in that list is not.

## Backing the databases up yourself

If you ever need to take the backups rather than receive them:
[`01-backup-test4.sql`](01-backup-test4.sql) (runs on TEST4, `COPY_ONLY`, changes
nothing) and [`00-find-service-account.sql`](00-find-service-account.sql) +
[`share-setup.ps1`](share-setup.ps1) for writing straight onto this machine.
[`03-export-bacpac.ps1`](03-export-bacpac.ps1) is the fallback when the server
cannot reach your machine over SMB. Details are in the headers of those files.

## Sizes

| Database | Data | Compressed (approx) |
|---|---|---|
| `test4_power_supportcentre` | 4.8 GB | 1.6 GB |
| `test4_power_jst` | 3.8 GB | 1.3 GB |
| `test4_power_productcatalogue` | 3.0 GB | 1.0 GB |
| `test4_power_idl` | 3.0 GB | 1.0 GB |
| `test4_power_nservicebus` | 1.0 GB | 0.3 GB |

~15.6 GB restored. The whole of TEST4 would be 254 GB, so plan disk before adding
the `eo` group — `test4_eo_od0` alone is 46 GB.

## Worth knowing

- **`test4_noodles_configuration` does not exist on that instance.** Every
  group's config references it (`Configuration` key), but the 14 databases on
  TEST4 are 4 `ei` + 5 `eo` + 5 `power`, with no noodles_configuration among
  them. `00-login-and-databases.sql` creates an empty one; if a service needs
  the schema, it comes from the migrator in `C:\workspace\database`.
- **Restored databases are set to SIMPLE recovery** so their logs do not grow
  unbounded on a dev box.
- **Test data leaves the test environment.** These hold real customer records and
  will sit unencrypted on your laptop. Worth a word with whoever owns data
  handling before this becomes routine.
