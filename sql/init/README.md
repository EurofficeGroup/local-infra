# Where to put your database

The `mssql` container mounts two folders:

- `./sql/init`   → `/init`   (read-only) — put `.sql` scripts here
- `./sql/backup` → `/backup` (rw)        — put `.bak` files here for restore

Nothing runs automatically, on purpose: it is not yet known which database
this is or in what order it should be applied. Once you drop the files in,
tell me and I will add an init container that applies them on `docker compose up -d`.

## For now — manually, after the container is up

Restore from a backup:

```bash
docker exec -it mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '<MSSQL_SA_PASSWORD from .env.local>' -C -Q "RESTORE DATABASE [Euroffice] FROM DISK='/backup/Euroffice.bak' WITH MOVE 'Euroffice' TO '/var/opt/mssql/data/Euroffice.mdf', MOVE 'Euroffice_log' TO '/var/opt/mssql/data/Euroffice_log.ldf', REPLACE"
```

Run a script:

```bash
docker exec -it mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '<MSSQL_SA_PASSWORD from .env.local>' -C -i /init/01-schema.sql
```

## Migrations

The workspace contains `C:\workspace\database` (EurofficeGroup.Database.Migrator) —
most likely that is what should apply the schema to the local instance.
