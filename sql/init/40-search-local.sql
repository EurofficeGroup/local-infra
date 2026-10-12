/* =====================================================================
   Switch a restored support centre to the LOCAL search stack
   (profile 'search': elastic, search-api, noodles-searches).

   RUN ON: localhost,1433, with the support centre database as the context.
   Normally through  ops-local.bat search-on  (search-local.ps1), which also
   starts the containers in the right order. By hand:

     docker exec -i mssql /opt/mssql-tools18/bin/sqlcmd \
       -S localhost -U sa -P '<MSSQL_SA_PASSWORD from .env.local>' -C \
       -d dev_uk_supportcentre -i /init/40-search-local.sql

   Undo with 41-search-remote.sql (ops-local.bat search-off).

   WHAT CHANGES
     cfg ElasticSearchConnectionString        -> http://elastic:9200
     cfg ElasticSearchUpdateConnectionString  -> http://elastic:9200  (only rows that exist)
     cfg SearchApiServiceUrl                  -> http://search-api:9012/Search/
     cfg ElasticSearch.SynonymFilePathOnNodes -> eo/synonyms.txt
     cfg ElasticSearch.ProductIndexPrefix     -> local<group>, e.g. test4pow -> localpow
     tra_Transports rows with Method ElasticNodes -> Method File into /files/elastic

   The original cfg values are saved once in dbo.zz_LocalInfraSearchBackup, so
   running this again never overwrites the TEST4 values with local ones, and
   41-search-remote.sql can put them back.

   WHY THE TRANSPORT ROW. The synonym file for the product indices is pushed by
   noodles-transport to every node of the cluster named in tra_Host, over SFTP.
   The restored row names TEST4's cluster (elastic-test-lb), so the first
   synonym upload from this machine would overwrite the file on TEST4's nodes.
   Here it becomes a plain file write into /files/elastic, the folder the local
   elastic container reads as config/eo. 41-search-remote.sql deliberately
   leaves this row local: nothing needs it while search is off, and restoring it
   would only bring back a way to write to TEST4.

   WHY THE INDEX PREFIX. Product indices are named product_<prefix>_<dealer>_<n>
   and the restored prefix is TEST4's (test4pow). On the local node that only
   misleads - a local index called product_test4pow_jst_1 reads like TEST4's.
   The indexer and the search API both read this key, so they stay in step;
   indices built under the old prefix are simply no longer used.

   Idempotent.
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @ElasticUrl   NVARCHAR(200) = N'http://elastic:9200';
DECLARE @SearchApiUrl NVARCHAR(200) = N'http://search-api:9012/Search/';
-- Relative to the node's config folder (/usr/share/elasticsearch/config).
DECLARE @SynonymPath  NVARCHAR(200) = N'eo/synonyms.txt';
-- Container path; ./files is mounted at /files in noodles-transport.
DECLARE @SynonymDir   NVARCHAR(200) = N'/files/elastic';
DECLARE @SynonymFile  NVARCHAR(200) = N'synonyms.txt';

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
    CREATE TABLE dbo.zz_LocalInfraSearchBackup
    (
        cfg_Key   INT           NOT NULL PRIMARY KEY,
        cfg_Name  NVARCHAR(200) NOT NULL,
        old_value NVARCHAR(MAX) NULL,
        -- 1 = the row did not exist and was added here; search-off deletes it.
        inserted  BIT           NOT NULL,
        saved_at  DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
    );

-- local + the group part of the restored prefix: test4pow -> localpow,
-- test4eog -> localeog. Taken from the saved original when this already ran,
-- so a second run does not produce 'locallocalpow'.
DECLARE @OrigPrefix NVARCHAR(200) =
    COALESCE((SELECT TOP 1 b.old_value FROM dbo.zz_LocalInfraSearchBackup b
               JOIN dbo.cfg_Configurations c ON c.cfg_Key = b.cfg_Key
              WHERE b.cfg_Name = N'ElasticSearch.ProductIndexPrefix' AND b.inserted = 0
                AND c.cfg_Dealer IS NULL AND c.cfg_Service IS NULL),
             (SELECT TOP 1 cfg_Value FROM dbo.cfg_Configurations
               WHERE cfg_Name = N'ElasticSearch.ProductIndexPrefix' AND cfg_Dealer IS NULL AND cfg_Service IS NULL),
             N'pow');
DECLARE @Group NVARCHAR(200) = @OrigPrefix;
IF @OrigPrefix LIKE N'test[0-9]%' AND PATINDEX(N'%[^0-9]%', SUBSTRING(@OrigPrefix, 5, 200)) > 0
    SET @Group = SUBSTRING(@OrigPrefix, 4 + PATINDEX(N'%[^0-9]%', SUBSTRING(@OrigPrefix, 5, 200)), 200);
IF @Group LIKE N'local%' SET @Group = SUBSTRING(@Group, 6, 200);
DECLARE @IndexPrefix NVARCHAR(200) = N'local' + @Group;

IF OBJECT_ID('tempdb..#target') IS NOT NULL DROP TABLE #target;
CREATE TABLE #target
(
    name      NVARCHAR(200) COLLATE DATABASE_DEFAULT PRIMARY KEY,
    value     NVARCHAR(MAX) NOT NULL,
    -- 1 = add a global row when the key is missing altogether
    add_if_missing BIT NOT NULL
);

INSERT INTO #target (name, value, add_if_missing) VALUES
    (N'ElasticSearchConnectionString',        @ElasticUrl,   1),
    -- Read by the indexer before ElasticSearchConnectionString. Absent in the
    -- TEST4 restore; if a backup ever has it, it must not keep pointing away.
    (N'ElasticSearchUpdateConnectionString',  @ElasticUrl,   0),
    (N'SearchApiServiceUrl',                  @SearchApiUrl, 1),
    (N'ElasticSearch.SynonymFilePathOnNodes', @SynonymPath,  1),
    (N'ElasticSearch.ProductIndexPrefix',     @IndexPrefix,  1);

BEGIN TRANSACTION;

-- Save the originals once. A row already in the backup keeps its first value.
INSERT INTO dbo.zz_LocalInfraSearchBackup (cfg_Key, cfg_Name, old_value, inserted)
SELECT c.cfg_Key, c.cfg_Name, c.cfg_Value, 0
  FROM dbo.cfg_Configurations c
  JOIN #target t ON t.name = c.cfg_Name
 WHERE NOT EXISTS (SELECT 1 FROM dbo.zz_LocalInfraSearchBackup b WHERE b.cfg_Key = c.cfg_Key);

-- Every row of these keys, whatever its dealer/service scope.
UPDATE c
   SET c.cfg_Value = t.value
  FROM dbo.cfg_Configurations c
  JOIN #target t ON t.name = c.cfg_Name;

PRINT N'Search configuration rows set: ' + CAST(@@ROWCOUNT AS NVARCHAR(10));

DECLARE @added TABLE (cfg_Key INT, cfg_Name NVARCHAR(200));

INSERT INTO dbo.cfg_Configurations (cfg_Dealer, cfg_Service, cfg_Name, cfg_Value)
OUTPUT inserted.cfg_Key, inserted.cfg_Name INTO @added
SELECT NULL, NULL, t.name, t.value
  FROM #target t
 WHERE t.add_if_missing = 1
   AND NOT EXISTS (SELECT 1 FROM dbo.cfg_Configurations c WHERE c.cfg_Name = t.name);

INSERT INTO dbo.zz_LocalInfraSearchBackup (cfg_Key, cfg_Name, old_value, inserted)
SELECT cfg_Key, cfg_Name, NULL, 1 FROM @added;

PRINT N'Search configuration rows added: ' + CAST(@@ROWCOUNT AS NVARCHAR(10));

IF OBJECT_ID('dbo.tra_Transports') IS NOT NULL
BEGIN
    UPDATE dbo.tra_Transports
       SET tra_Method = N'File',
           tra_Folder = @SynonymDir,
           tra_TargetFileName = @SynonymFile
     WHERE tra_Method = N'ElasticNodes';

    PRINT N'Synonym transports switched to ' + @SynonymDir + N'/' + @SynonymFile + N': ' + CAST(@@ROWCOUNT AS NVARCHAR(10));
END

COMMIT;

SELECT c.cfg_Name, c.cfg_Dealer, c.cfg_Service, c.cfg_Value
  FROM dbo.cfg_Configurations c
  JOIN #target t ON t.name = c.cfg_Name
 ORDER BY c.cfg_Name;

IF OBJECT_ID('dbo.tra_Transports') IS NOT NULL
    SELECT tra_Key, tra_Name, tra_Method, tra_Folder, tra_TargetFileName
      FROM dbo.tra_Transports
     WHERE tra_Folder = @SynonymDir;
