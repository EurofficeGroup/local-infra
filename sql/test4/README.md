# Local databases: TEST4 backups restored as dev_uk_*

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

Backups keep their TEST4 names in `sql/backup`; the databases are restored
under local names. Three values in `.env` drive it:

```
INFRA_BACKUP_PREFIX=test4_power   ->  test4_power_{0}.bak
INFRA_DB_PREFIX=dev_uk            ->  dev_uk_{0}
INFRA_DEALER_CODE=jst             ->  the main dealer (Power's DealerId)
```

`{0}` is the database role (`supportcentre`, `productcatalogue`,
`nservicebus`) or the dealer code, exactly as the configuration uses it:

```
Generic              = ...Initial Catalog=dev_uk_{0}
SupportCentreSchema  = dev_uk_supportcentre.dbo
ProductCatalogueSchema = dev_uk_productcatalogue.dbo
DealerSchema         = dev_uk_{0}.dbo        ({0} = jst -> dev_uk_jst)
```

Every dealer backup of the group is restored (`dev_uk_idl`, `dev_uk_jst`): the
support centre's dealer views are `UNION ALL` over all of them.

`dev_uk_{0}` is also the prefix the Configuration API repo ships for local use.
The restored configuration still says `test4_power_*`; `20-docker-overrides.sql`
rewrites that prefix. Dealer codes are never changed.

The trade-off: every group lands under the same names, so only one group is
on the instance at a time.

Code inside the backups names the TEST4 databases too: synonyms in the dealer
and support centre databases point at `test4_power_productcatalogue`, and the
support centre's dealer views (`dlr_Dealers`, `cus_Customers`, `orh_OrderHeaders`,
`vmv_*` - 94 of them) are `UNION ALL` over every dealer of the group.
`30-rename-db-references.sql` rewrites the names. That is why every dealer
backup must be there: a view whose dealer database is missing cannot be
recompiled and is listed by the script.

## Switching group

Put the other group's backups in `sql/backup`, set in `.env`, then
`setup-local.bat --wipe`:

| Group | `INFRA_BACKUP_PREFIX` | `INFRA_DEALER_GROUP` | `INFRA_DEALER_CODE` |
|---|---|---|---|
| power | `test4_power` | `pow` | `jst` or `idl` |
| euroffice | `test4_eo` | `eog` | `eo0` / `od0` |
| ei | `test4_ei` | `ei0` | |

Template: [`../../config-samples/api.configuration.appsettings.local.json`](../../config-samples/api.configuration.appsettings.local.json).

On the Power side the matching values are `DealerGroup` and `DealerId` in
`Web.config` — see
[`../../config-samples/power.Web.config.local.appSettings.xml`](../../config-samples/power.Web.config.local.appSettings.xml).
`DealerId` should be `INFRA_DEALER_CODE`; any restored dealer of the group works.

## Adding a dealer later

A dealer is one more backup, `test4_power_<dealer>.bak`. Drop it in
`sql/backup` and run `setup-local.bat --wipe`; it is restored as
`dev_uk_<dealer>`, and the support centre views pick it up.
The dealer must also exist in `dlr_Dealers` in that group's support centre, which
it will, since the support centre came from the same environment.

## Run order

```bash
docker compose --profile db up -d
```

| # | Script | Connect to | Notes |
|---|---|---|---|
| 1 | [`../init/00-login-and-databases.sql`](../init/00-login-and-databases.sql) | `localhost,1433` | Creates the `EuroWebsite` login. Creates no group databases. |
| 2 | [`02-restore-local.sql`](02-restore-local.sql) | `localhost,1433` | Restores the shared databases and the `INFRA_DEALER_CODE` dealer as `dev_uk_*` |
| 3 | [`../init/30-rename-db-references.sql`](../init/30-rename-db-references.sql) | `localhost,1433` | Repoints synonyms / views / procedures from `test4_power_*` to `dev_uk_*`. |
| 4 | [`../init/20-docker-overrides.sql`](../init/20-docker-overrides.sql) | `-d dev_uk_supportcentre` | Repoints endpoints and the catalog prefix. |

Both scripts start at `@WhatIf = 1` and only print what they would do.

### Step 3 is not optional

A restored support centre still holds TEST4's configuration: RabbitMQ on
`10.2.34.12`, `MSSQL-TEST-QA`, `eo-web-cache.euroffice.co.uk`, the real SMTP
relay. Start a service before repointing it and it talks to the test environment
for real, including sending email to real addresses.

The override script changes **endpoints only** — which server, which broker,
which cache, which mail host. It rebuilds each connection string token by token
so only `Data Source` is swapped, then rewrites the catalog prefix
`test4_power_` -> `dev_uk_` in every value (connection strings and the `*Schema`
keys). It also strips `Integrated Security`, which
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
