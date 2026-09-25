/* =====================================================================
   Restore TEST4 backups into the LOCAL Docker SQL Server.

   WHERE TO RUN: against localhost,1433 - the `mssql` container from
                 local-infra/docker-compose.yml. Never against a shared server.

   Put the .bak files in   C:\workspace\local-infra\sql\backup
   The container sees that folder as   /backup

   DESIGN: databases keep their original names.

   Real environments name databases <env>_<group>_<db>:
     test4_power_supportcentre, test4_eo_supportcentre, prod_power_supportcentre...
   and the configuration addresses them through a prefix:
     Generic              = ...Initial Catalog=test4_power_{0}
     SupportCentreSchema  = test4_power_supportcentre.dbo
     DealerSchema         = test4_power_{0}.dbo

   Keeping the names means the local instance is the same shape as TEST4:
   switching group is a configuration change, and adding a group or a dealer is
   just another .bak dropped in this folder and a re-run of this script.
   Renaming everything to a single dev_uk_* namespace would make that impossible.

   Two things this handles that a plain RESTORE does not:

   1. Discovery. It reads whatever .bak files are in /backup, so you never edit
      a list. New group, new dealer - drop the file in and run again.

   2. Logical file names differ per database, so a hardcoded MOVE list breaks.
      This reads RESTORE FILELISTONLY per backup and builds MOVE from the actual
      contents.

   Safe to re-run: existing databases are skipped unless @Overwrite = 1.
   ===================================================================== */

SET NOCOUNT ON;

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------
DECLARE @BackupDir NVARCHAR(500) = N'/backup/';              -- path INSIDE the container
DECLARE @DataDir   NVARCHAR(500) = N'/var/opt/mssql/data/';  -- where the restored files land
DECLARE @WhatIf    BIT = 1;   -- 1 = print the RESTORE statements only, 0 = actually restore
DECLARE @Overwrite BIT = 0;   -- 1 = restore over a database that already exists

-- ---------------------------------------------------------------------
-- Refuse to run anywhere but the local container
-- ---------------------------------------------------------------------
IF @WhatIf = 0 AND SERVERPROPERTY('HostPlatform') <> N'Linux'
BEGIN
    RAISERROR (N'This is not the Linux container. Connect to localhost,1433 and try again.', 16, 1);
    RETURN;
END

-- ---------------------------------------------------------------------
-- Find the backups
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#found') IS NOT NULL DROP TABLE #found;
CREATE TABLE #found (fname NVARCHAR(500), depth INT, isfile INT);

INSERT INTO #found (fname, depth, isfile)
EXEC master.dbo.xp_dirtree @BackupDir, 1, 1;

IF OBJECT_ID('tempdb..#work') IS NOT NULL DROP TABLE #work;
CREATE TABLE #work
(
    fname     NVARCHAR(500) NOT NULL,
    target_db SYSNAME       NULL,
    note      NVARCHAR(200) NULL
);

-- Derive the database name from the file name. Our own backup script writes
-- <database>_yyyyMMdd_HHmmss.bak, so strip that suffix when it is there;
-- otherwise take the base name as-is, which covers files handed over by the DBA.
INSERT INTO #work (fname, target_db)
SELECT f.fname,
       CASE
           WHEN base LIKE N'%\_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\_[0-9][0-9][0-9][0-9][0-9][0-9]' ESCAPE N'\'
               THEN LEFT(base, LEN(base) - 16)
           ELSE base
       END
  FROM #found AS f
 CROSS APPLY (SELECT LEFT(f.fname, LEN(f.fname) - 4) AS base) AS b
 WHERE f.isfile = 1
   AND f.fname LIKE N'%.bak';

IF NOT EXISTS (SELECT 1 FROM #work)
BEGIN
    RAISERROR (N'No .bak files in /backup. Copy them into C:\workspace\local-infra\sql\backup first.', 16, 1);
    RETURN;
END

-- Keep only the newest file when several exist for the same database.
;WITH ranked AS (
    SELECT fname, target_db,
           ROW_NUMBER() OVER (PARTITION BY target_db ORDER BY fname DESC) AS rn
      FROM #work
)
UPDATE w
   SET note = N'superseded by a newer file'
  FROM #work w
  JOIN ranked r ON r.fname = w.fname
 WHERE r.rn > 1;

UPDATE #work
   SET note = N'already exists - set @Overwrite = 1 to replace'
 WHERE note IS NULL
   AND DB_ID(target_db) IS NOT NULL
   AND @Overwrite = 0;

SELECT fname AS backup_file,
       target_db AS will_restore_as,
       ISNULL(note, N'ready') AS status
  FROM #work
 ORDER BY CASE WHEN note IS NULL THEN 0 ELSE 1 END, target_db;

-- ---------------------------------------------------------------------
-- Restore loop
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#filelist') IS NOT NULL DROP TABLE #filelist;

CREATE TABLE #filelist
(
    LogicalName           NVARCHAR(128),
    PhysicalName          NVARCHAR(260),
    [Type]                CHAR(1),
    FileGroupName         NVARCHAR(128) NULL,
    Size                  NUMERIC(20,0),
    MaxSize               NUMERIC(20,0),
    FileID                BIGINT,
    CreateLSN             NUMERIC(25,0),
    DropLSN               NUMERIC(25,0) NULL,
    UniqueId              UNIQUEIDENTIFIER,
    ReadOnlyLSN           NUMERIC(25,0) NULL,
    ReadWriteLSN          NUMERIC(25,0) NULL,
    BackupSizeInBytes     BIGINT,
    SourceBlockSize       INT,
    FileGroupID           INT,
    LogGroupGUID          UNIQUEIDENTIFIER NULL,
    DifferentialBaseLSN   NUMERIC(25,0) NULL,
    DifferentialBaseGUID  UNIQUEIDENTIFIER NULL,
    IsReadOnly            BIT,
    IsPresent             BIT,
    TDEThumbprint         VARBINARY(32) NULL,
    SnapshotUrl           NVARCHAR(360) NULL
);

DECLARE @file   NVARCHAR(500),
        @target SYSNAME,
        @path   NVARCHAR(1000),
        @sql    NVARCHAR(MAX),
        @moves  NVARCHAR(MAX);

DECLARE map_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT fname, target_db FROM #work WHERE note IS NULL ORDER BY target_db;

OPEN map_cursor;
FETCH NEXT FROM map_cursor INTO @file, @target;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @path = @BackupDir + @file;

    BEGIN TRY
        DELETE FROM #filelist;

        SET @sql = N'RESTORE FILELISTONLY FROM DISK = @p;';
        INSERT INTO #filelist
        EXEC sp_executesql @sql, N'@p NVARCHAR(1000)', @p = @path;

        -- One MOVE per file, named after the target database so nothing
        -- collides with a database restored earlier.
        SET @moves = N'';
        SELECT @moves = @moves
             + N',
                 MOVE ' + QUOTENAME(LogicalName, '''')
             + N' TO ''' + @DataDir + @target + N'_' + CAST(FileID AS NVARCHAR(10))
             + CASE WHEN [Type] = 'L' THEN N'.ldf' ELSE N'.mdf' END + N''''
          FROM #filelist
         WHERE IsPresent = 1;

        SET @sql = N'RESTORE DATABASE ' + QUOTENAME(@target) + N'
                     FROM DISK = @p
                     WITH REPLACE, RECOVERY, STATS = 10' + @moves + N';';

        IF @WhatIf = 1
        BEGIN
            PRINT N'-- ' + @file + N'  ->  ' + @target;
            PRINT REPLACE(@sql, N'@p', N'''' + @path + N'''');
            PRINT N'';
        END
        ELSE
        BEGIN
            RAISERROR (N'Restoring %s -> %s', 10, 1, @file, @target) WITH NOWAIT;
            EXEC sp_executesql @sql, N'@p NVARCHAR(1000)', @p = @path;

            -- SIMPLE recovery: a dev box does not need a log chain, and this
            -- stops the log files growing without bound.
            SET @sql = N'ALTER DATABASE ' + QUOTENAME(@target) + N' SET RECOVERY SIMPLE;';
            EXEC sp_executesql @sql;

            -- The backup carries TEST4's users; re-point them at the local login.
            SET @sql = N'USE ' + QUOTENAME(@target) + N';
                         IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''EuroWebsite'')
                             ALTER USER [EuroWebsite] WITH LOGIN = [EuroWebsite];
                         ELSE
                             CREATE USER [EuroWebsite] FOR LOGIN [EuroWebsite];
                         IF NOT EXISTS (
                             SELECT 1 FROM sys.database_role_members rm
                               JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
                               JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
                              WHERE r.name = N''db_owner'' AND m.name = N''EuroWebsite'')
                             ALTER ROLE [db_owner] ADD MEMBER [EuroWebsite];';
            EXEC sp_executesql @sql;
        END
    END TRY
    BEGIN CATCH
        RAISERROR (N'FAILED %s -> %s', 10, 1, @file, @target) WITH NOWAIT;
        PRINT ERROR_MESSAGE();
    END CATCH

    FETCH NEXT FROM map_cursor INTO @file, @target;
END

CLOSE map_cursor;
DEALLOCATE map_cursor;

IF @WhatIf = 1
    RAISERROR (N'@WhatIf was 1: nothing was restored. Review the statements above, then set @WhatIf = 0.', 10, 1);

-- ---------------------------------------------------------------------
-- What is on the local instance now, grouped by environment prefix
-- ---------------------------------------------------------------------
SELECT d.name,
       d.state_desc,
       d.recovery_model_desc,
       CAST(SUM(mf.size) * 8 / 1024.0 AS DECIMAL(18,2)) AS size_mb
  FROM sys.databases d
  JOIN sys.master_files mf ON mf.database_id = d.database_id
 WHERE d.database_id > 4
 GROUP BY d.name, d.state_desc, d.recovery_model_desc
 ORDER BY d.name;

/* =====================================================================
   NEXT, AND DO NOT SKIP IT

     ../init/20-docker-overrides.sql

   The restored supportcentre still holds TEST4's configuration: RabbitMQ on
   10.2.34.12, MSSQL-TEST-QA, eo-web-cache, the real SMTP relay. Start a service
   before repointing it and it will talk to the test environment for real,
   including sending email.

   That script rewrites only the infrastructure endpoints and leaves the group
   prefixes (test4_power_{0} and so on) alone, which is what keeps this local
   copy a faithful mirror.
   ===================================================================== */
