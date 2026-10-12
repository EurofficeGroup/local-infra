/* =====================================================================
   Undo 40-search-local.sql: put the search configuration back to the values
   the restore came with (TEST4's search API and cluster).

   RUN ON: localhost,1433, with the support centre database as the context.
   Normally through  ops-local.bat search-off  (search-local.ps1), which stops
   noodles-searches and search-api first. By hand:

     docker exec -i mssql /opt/mssql-tools18/bin/sqlcmd \
       -S localhost -U sa -P '<MSSQL_SA_PASSWORD from .env.local>' -C \
       -d dev_uk_supportcentre -i /init/41-search-remote.sql

   Restores the cfg rows saved in dbo.zz_LocalInfraSearchBackup, deletes the
   rows 40 added, and drops the backup table. The tra_Transports synonym row is
   left on the local file write on purpose - see 40-search-local.sql.

   Idempotent: with no backup table there is nothing to do.
   ===================================================================== */

SET NOCOUNT ON;

IF OBJECT_ID('dbo.cfg_Configurations') IS NULL
BEGIN
    RAISERROR (N'No dbo.cfg_Configurations here. Connect with -d <prefix>_supportcentre.', 16, 1);
    RETURN;
END

IF SERVERPROPERTY('HostPlatform') <> N'Linux'
BEGIN
    RAISERROR (N'This is not the Linux container. Refusing to rewrite configuration.', 16, 1);
    RETURN;
END

PRINT N'Support centre: ' + DB_NAME();

IF OBJECT_ID('dbo.zz_LocalInfraSearchBackup') IS NULL
BEGIN
    PRINT N'No dbo.zz_LocalInfraSearchBackup - search is not switched to local here. Nothing to restore.';
    RETURN;
END

BEGIN TRANSACTION;

UPDATE c
   SET c.cfg_Value = b.old_value
  FROM dbo.cfg_Configurations c
  JOIN dbo.zz_LocalInfraSearchBackup b ON b.cfg_Key = c.cfg_Key
 WHERE b.inserted = 0;

PRINT N'Search configuration rows restored: ' + CAST(@@ROWCOUNT AS NVARCHAR(10));

DELETE c
  FROM dbo.cfg_Configurations c
  JOIN dbo.zz_LocalInfraSearchBackup b ON b.cfg_Key = c.cfg_Key
 WHERE b.inserted = 1;

PRINT N'Search configuration rows removed: ' + CAST(@@ROWCOUNT AS NVARCHAR(10));

DROP TABLE dbo.zz_LocalInfraSearchBackup;

COMMIT;

SELECT cfg_Name, cfg_Dealer, cfg_Service, cfg_Value
  FROM dbo.cfg_Configurations
 WHERE cfg_Name IN (N'ElasticSearchConnectionString', N'ElasticSearchUpdateConnectionString',
                    N'SearchApiServiceUrl', N'ElasticSearch.SynonymFilePathOnNodes',
                    N'ElasticSearch.ProductIndexPrefix')
 ORDER BY cfg_Name;
