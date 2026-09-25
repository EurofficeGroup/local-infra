/* =====================================================================
   FULL COPY_ONLY backups of the TEST4 databases.

   WHERE TO RUN: on the TEST4 SQL Server (vm-tstdb-uks-02.datacentre.euroffice.com),
                 in an SSMS query window connected to that instance.

   READ-ONLY WITH RESPECT TO THE DATA. This script never creates, alters or
   drops anything in any user database. The only things it writes are:
     - the .bak files on the server's disk
     - backup history rows in msdb (SQL Server adds those itself)

   COPY_ONLY is not optional here. A plain FULL backup resets the differential
   base and takes ownership of the log chain, which would silently break
   whatever scheduled backup job TEST4 already has. COPY_ONLY takes the same
   full copy without touching that chain.

   Set @BackupRoot, then run. Nothing else needs editing.
   ===================================================================== */

SET NOCOUNT ON;

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------

-- WHERE THE .bak FILES GO.
--
-- This is a folder on vm-tstdb-uks-02, NOT on your machine. SSMS runs on your
-- laptop, but BACKUP DATABASE runs on the server: the SQL Server service writes
-- the file to the server's own disk. Creating the folder locally does nothing.
--
-- Leave @BackupRoot as NULL and the script uses the instance's configured
-- default backup folder, which already exists and which the service account can
-- already write to. That is the path of least resistance - nobody has to create
-- anything, and you need no file access to the server at all.
--
-- Set it to an explicit path only if you have a reason to, e.g. N'D:\Backups\'.
DECLARE @BackupRoot   NVARCHAR(500) = NULL;

-- Optional subfolder under @BackupRoot, to keep these files together.
-- Needs @CreateFolder = 1 on the first run, which requires sysadmin
-- (xp_create_subdir). Set to NULL to write straight into @BackupRoot.
DECLARE @SubFolder    NVARCHAR(200) = NULL;
DECLARE @CreateFolder BIT = 0;

-- WHICH DATABASES.
--
-- 'test4[_]%' is all 14 of them: ~254 GB of data, ~85 GB compressed. Too much
-- for a laptop and a slow thing to copy over the network.
--
-- For a local Power/Noodles box you want the 'power' set: local_sc.sql seeds
-- DealerGroup = 'pow' and Group = 'POW', and every Noodles appsettings.json says
-- "DealerGroup": "pow". That set is ~15 GB of data, ~5 GB compressed:
--   test4_power_supportcentre, test4_power_productcatalogue,
--   test4_power_nservicebus, test4_power_idl, test4_power_jst
DECLARE @Pattern      NVARCHAR(128) = N'test4[_]power[_]%';

DECLARE @UseCompression BIT = 1;   -- set to 0 on Express (see notes at the bottom)
DECLARE @Verify         BIT = 1;   -- RESTORE VERIFYONLY after each backup
DECLARE @WhatIf         BIT = 1;   -- 1 = only print the commands, 0 = actually back up

-- ---------------------------------------------------------------------
-- Resolve the backup folder on the server
-- ---------------------------------------------------------------------
IF @BackupRoot IS NULL
BEGIN
    EXEC master.dbo.xp_instance_regread
         N'HKEY_LOCAL_MACHINE',
         N'Software\Microsoft\MSSQLServer\MSSQLServer',
         N'BackupDirectory',
         @BackupRoot OUTPUT;

    IF @BackupRoot IS NULL
    BEGIN
        RAISERROR (N'Could not read the default backup directory. Set @BackupRoot explicitly to a path on the SERVER.', 16, 1);
        RETURN;
    END
END

IF RIGHT(@BackupRoot, 1) NOT IN (N'\', N'/')
    SET @BackupRoot = @BackupRoot + N'\';

IF @SubFolder IS NOT NULL AND LEN(@SubFolder) > 0
BEGIN
    SET @BackupRoot = @BackupRoot + @SubFolder + N'\';

    IF @CreateFolder = 1
        EXEC master.dbo.xp_create_subdir @BackupRoot;   -- needs sysadmin
END

PRINT N'Backup folder on the server: ' + @BackupRoot;

-- ---------------------------------------------------------------------
-- Free space on the server's volumes, so you do not fill a shared disk
-- ---------------------------------------------------------------------
SELECT DISTINCT
       vs.volume_mount_point,
       vs.logical_volume_name,
       CAST(vs.total_bytes     / 1073741824.0 AS DECIMAL(18,2)) AS total_gb,
       CAST(vs.available_bytes / 1073741824.0 AS DECIMAL(18,2)) AS free_gb
  FROM sys.master_files AS mf
 CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
 ORDER BY vs.volume_mount_point;

-- ---------------------------------------------------------------------
-- Pre-flight: what will be backed up and how much disk it needs
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#targets') IS NOT NULL DROP TABLE #targets;

CREATE TABLE #targets
(
    database_name SYSNAME       PRIMARY KEY,
    data_mb       DECIMAL(18,2) NULL
);

INSERT INTO #targets (database_name, data_mb)
SELECT d.name,
       (SELECT SUM(CAST(mf.size AS DECIMAL(18,2))) * 8 / 1024
          FROM sys.master_files mf
         WHERE mf.database_id = d.database_id
           AND mf.type_desc = 'ROWS')
  FROM sys.databases d
 WHERE d.name LIKE @Pattern ESCAPE '\'
   AND d.database_id > 4                 -- skip master/tempdb/model/msdb
   AND d.state = 0                       -- ONLINE only
   AND d.source_database_id IS NULL      -- not a snapshot
   AND d.is_read_only = 0;

SELECT database_name,
       data_mb                                   AS data_size_mb,
       CAST(data_mb / 3.0 AS DECIMAL(18,2))      AS rough_compressed_mb
  FROM #targets
 ORDER BY database_name;

SELECT COUNT(*)                                  AS databases_to_back_up,
       CAST(SUM(data_mb) AS DECIMAL(18,2))       AS total_data_mb,
       CAST(SUM(data_mb) / 3.0 AS DECIMAL(18,2)) AS rough_total_compressed_mb
  FROM #targets;

IF NOT EXISTS (SELECT 1 FROM #targets)
BEGIN
    RAISERROR (N'No databases matched the pattern. Check @Pattern and the instance you are connected to.', 16, 1);
    RETURN;
END

-- ---------------------------------------------------------------------
-- Backup loop. One failure must not stop the rest.
-- ---------------------------------------------------------------------
DECLARE @Stamp NVARCHAR(20) = FORMAT(SYSDATETIME(), 'yyyyMMdd_HHmmss');

IF OBJECT_ID('tempdb..#results') IS NOT NULL DROP TABLE #results;

CREATE TABLE #results
(
    database_name SYSNAME,
    backup_file   NVARCHAR(1000) NULL,
    status        NVARCHAR(20),
    error_number  INT            NULL,
    error_message NVARCHAR(4000) NULL,
    started_at    DATETIME2      NULL,
    finished_at   DATETIME2      NULL
);

DECLARE @db      SYSNAME,
        @path    NVARCHAR(1000),
        @sql     NVARCHAR(MAX),
        @started DATETIME2;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT database_name FROM #targets ORDER BY database_name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @path    = @BackupRoot + @db + N'_' + @Stamp + N'.bak';
    SET @started = SYSDATETIME();

    -- The database name cannot be a parameter in BACKUP DATABASE, so it goes
    -- through QUOTENAME. The file path is passed as a real parameter.
    SET @sql = N'BACKUP DATABASE ' + QUOTENAME(@db) + N'
                 TO DISK = @p
                 WITH COPY_ONLY, INIT, CHECKSUM, STATS = 10'
             + CASE WHEN @UseCompression = 1 THEN N', COMPRESSION' ELSE N'' END
             + N';';

    BEGIN TRY
        IF @WhatIf = 1
        BEGIN
            PRINT N'-- ' + @db;
            PRINT REPLACE(@sql, N'@p', N'''' + @path + N'''');

            INSERT INTO #results (database_name, backup_file, status, started_at, finished_at)
            VALUES (@db, @path, N'WHATIF', @started, SYSDATETIME());
        END
        ELSE
        BEGIN
            EXEC sp_executesql @sql, N'@p NVARCHAR(1000)', @p = @path;

            IF @Verify = 1
            BEGIN
                SET @sql = N'RESTORE VERIFYONLY FROM DISK = @p WITH CHECKSUM;';
                EXEC sp_executesql @sql, N'@p NVARCHAR(1000)', @p = @path;
            END

            INSERT INTO #results (database_name, backup_file, status, started_at, finished_at)
            VALUES (@db, @path, N'OK', @started, SYSDATETIME());
        END
    END TRY
    BEGIN CATCH
        INSERT INTO #results (database_name, backup_file, status, error_number, error_message, started_at, finished_at)
        VALUES (@db, @path, N'FAILED', ERROR_NUMBER(), ERROR_MESSAGE(), @started, SYSDATETIME());

        RAISERROR (N'Backup failed for %s: %s', 10, 1, @db, N'') WITH NOWAIT;
        PRINT ERROR_MESSAGE();
    END CATCH

    FETCH NEXT FROM db_cursor INTO @db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

-- ---------------------------------------------------------------------
-- Run summary
-- ---------------------------------------------------------------------
SELECT database_name,
       status,
       backup_file,
       DATEDIFF(SECOND, started_at, finished_at) AS seconds,
       error_number,
       error_message
  FROM #results
 ORDER BY CASE status WHEN N'FAILED' THEN 0 ELSE 1 END, database_name;

IF EXISTS (SELECT 1 FROM #results WHERE status = N'FAILED')
    RAISERROR (N'One or more backups failed - see the summary above.', 10, 1);

IF @WhatIf = 1
    RAISERROR (N'@WhatIf was 1: nothing was backed up. Review the printed commands, then set @WhatIf = 0 and run again.', 10, 1);

-- ---------------------------------------------------------------------
-- Independent verification against msdb: what actually landed on disk
-- ---------------------------------------------------------------------
SELECT bs.database_name,
       bs.backup_start_date,
       bs.backup_finish_date,
       DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date) AS seconds,
       bs.type                                                       AS backup_type,   -- D = full
       bs.is_copy_only,
       CAST(bs.backup_size     / 1048576.0 AS DECIMAL(18,2))         AS backup_size_mb,
       CAST(bs.compressed_backup_size / 1048576.0 AS DECIMAL(18,2))  AS compressed_mb,
       bmf.physical_device_name
  FROM msdb.dbo.backupset AS bs
  JOIN msdb.dbo.backupmediafamily AS bmf
    ON bmf.media_set_id = bs.media_set_id
 WHERE bs.database_name LIKE N'test4[_]%'
   AND bs.type = 'D'
   AND bs.backup_start_date >= DATEADD(HOUR, -6, SYSDATETIME())
 ORDER BY bs.backup_start_date DESC;

/* =====================================================================
   NOTES

   1. @BackupRoot is a path on the SQL Server machine, not on your laptop.
      SSMS running on your machine does not make it local. The folder must
      exist on the server and the SQL Server *service account* must be able
      to write to it - your own Windows permissions are irrelevant.

      Remote server, getting the files to your machine:
        a) back up to a local server path (fastest, what this script assumes),
           then copy over the admin share:
             robocopy \\vm-tstdb-uks-02.datacentre.euroffice.com\D$\Backups\test4_local C:\workspace\local-infra\sql\backup *.bak
        b) or back up straight to a UNC path the service account can reach:
             @BackupRoot = N'\\some-fileserver\share\test4_local\'
           A backup to a UNC path fails with "Operating system error 5"
           unless the service account itself has write access there.
        Do not enable xp_cmdshell to copy files - that is a server-level
        configuration change on a shared test box.

   2. Express edition: backup compression is not supported. Set
      @UseCompression = 0. Expect the .bak files to be roughly three times
      larger. Everything else in the script works unchanged.

   3. Permissions on the source instance:
        - db_backupoperator in each database being backed up, or sysadmin
        - VIEW ANY DEFINITION / VIEW SERVER STATE to read sys.databases and
          sys.master_files for every database (otherwise the pre-flight list
          silently comes back short - sys.databases only shows databases you
          have access to)
        - SELECT on msdb.dbo.backupset / backupmediafamily for the final check
      And, separately from your login: write access to the target folder for
      the SQL Server service account.

   4. @WhatIf starts at 1 on purpose, so the first run only prints the
      commands and the size estimate. Check the free disk space on the target
      drive against the estimate before setting it to 0.
   ===================================================================== */
