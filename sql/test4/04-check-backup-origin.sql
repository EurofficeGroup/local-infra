/* =====================================================================
   Where did these backups actually come from?

   WHERE TO RUN: against the local container, before 02-restore-local.sql.
     Get-Content .\sql\test4\04-check-backup-origin.sql |
       docker exec -i mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "<MSSQL_SA_PASSWORD from .env.local>" -C

   WHY: the file name is whatever the DBA typed, and the logical file names
   inside are inherited from however the database was first created - ours say
   'prod_power_supportcentre' and 'test_power_idl_new' for databases we asked to
   have taken from TEST4. Neither proves anything.

   The backup header does. It records the instance that produced the set and
   when, and those are written by the engine, not chosen by anyone.

   Read-only: HEADERONLY opens the file and reads its first blocks. It restores
   nothing and touches no database.

   WHAT TO LOOK FOR
     source_server  the TEST4 instance, not a production one
     source_db      the name the database had on that instance
     is_copy_only   1 means the backup chain of the source was left alone,
                    which is what the backup script asks for
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @BackupDir NVARCHAR(500) = N'/backup/';

-- ---------------------------------------------------------------------
-- Find the files
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#found') IS NOT NULL DROP TABLE #found;
CREATE TABLE #found (fname NVARCHAR(500), depth INT, isfile INT);

INSERT INTO #found (fname, depth, isfile)
EXEC master.dbo.xp_dirtree @BackupDir, 1, 1;

DELETE FROM #found WHERE isfile <> 1 OR fname NOT LIKE N'%.bak';

IF NOT EXISTS (SELECT 1 FROM #found)
BEGIN
    RAISERROR (N'No .bak files in /backup.', 16, 1);
    RETURN;
END

-- ---------------------------------------------------------------------
-- HEADERONLY has a fixed, wide result set and INSERT..EXEC demands an exact
-- match, so the whole shape has to be spelled out. These 56 columns are what
-- this engine returns, ending at EncryptorType - verified against the actual
-- output, not the documentation, which lists three more (LastValidRestoreTime,
-- TimeZone, CompressionAlgorithm) that later builds add. A mismatch here fails
-- as 'RESTORE HEADERONLY is terminating abnormally', which names the wrong
-- culprit; if that appears, run one HEADERONLY on its own and compare columns.
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#hdr') IS NOT NULL DROP TABLE #hdr;
CREATE TABLE #hdr
(
    BackupName              NVARCHAR(128),  BackupDescription       NVARCHAR(255),
    BackupType              SMALLINT,       ExpirationDate          DATETIME,
    Compressed              BIT,            Position                SMALLINT,
    DeviceType              TINYINT,        UserName                NVARCHAR(128),
    ServerName              NVARCHAR(128),  DatabaseName            NVARCHAR(128),
    DatabaseVersion         INT,            DatabaseCreationDate    DATETIME,
    BackupSize              NUMERIC(20,0),  FirstLSN                NUMERIC(25,0),
    LastLSN                 NUMERIC(25,0),  CheckpointLSN           NUMERIC(25,0),
    DatabaseBackupLSN       NUMERIC(25,0),  BackupStartDate         DATETIME,
    BackupFinishDate        DATETIME,       SortOrder               SMALLINT,
    CodePage                SMALLINT,       UnicodeLocaleId         INT,
    UnicodeComparisonStyle  INT,            CompatibilityLevel      TINYINT,
    SoftwareVendorId        INT,            SoftwareVersionMajor    INT,
    SoftwareVersionMinor    INT,            SoftwareVersionBuild    INT,
    MachineName             NVARCHAR(128),  Flags                   INT,
    BindingID               UNIQUEIDENTIFIER, RecoveryForkID        UNIQUEIDENTIFIER,
    Collation               NVARCHAR(128),  FamilyGUID              UNIQUEIDENTIFIER,
    HasBulkLoggedData       BIT,            IsSnapshot              BIT,
    IsReadOnly              BIT,            IsSingleUser            BIT,
    HasBackupChecksums      BIT,            IsDamaged               BIT,
    BeginsLogChain          BIT,            HasIncompleteMetaData   BIT,
    IsForceOffline          BIT,            IsCopyOnly              BIT,
    FirstRecoveryForkID     UNIQUEIDENTIFIER, ForkPointLSN          NUMERIC(25,0) NULL,
    RecoveryModel           NVARCHAR(60),   DifferentialBaseLSN     NUMERIC(25,0) NULL,
    DifferentialBaseGUID    UNIQUEIDENTIFIER NULL,
    BackupTypeDescription   NVARCHAR(60),   BackupSetGUID           UNIQUEIDENTIFIER NULL,
    CompressedBackupSize    BIGINT,         Containment             TINYINT,
    KeyAlgorithm            NVARCHAR(32),   EncryptorThumbprint     VARBINARY(20),
    EncryptorType           NVARCHAR(32)
);

IF OBJECT_ID('tempdb..#result') IS NOT NULL DROP TABLE #result;
CREATE TABLE #result
(
    backup_file   NVARCHAR(200),
    source_server NVARCHAR(128),
    source_db     NVARCHAR(128),
    taken_at      DATETIME,
    backup_type   NVARCHAR(60),
    is_copy_only  BIT,
    machine       NVARCHAR(128)
);

DECLARE @fname NVARCHAR(500), @sql NVARCHAR(1000);

DECLARE files CURSOR LOCAL FAST_FORWARD FOR
    SELECT fname FROM #found ORDER BY fname;

OPEN files;
FETCH NEXT FROM files INTO @fname;

WHILE @@FETCH_STATUS = 0
BEGIN
    TRUNCATE TABLE #hdr;

    -- REPLACE guards the quote, not injection: these names come from the
    -- filesystem, and one with an apostrophe would otherwise break the batch.
    SET @sql = N'RESTORE HEADERONLY FROM DISK = '''
             + REPLACE(@BackupDir + @fname, '''', '''''') + N'''';

    BEGIN TRY
        INSERT INTO #hdr EXEC (@sql);

        INSERT INTO #result
        SELECT @fname, ServerName, DatabaseName, BackupFinishDate,
               BackupTypeDescription, IsCopyOnly, MachineName
          FROM #hdr;
    END TRY
    BEGIN CATCH
        INSERT INTO #result (backup_file, source_server)
        VALUES (@fname, N'COULD NOT READ: ' + ERROR_MESSAGE());
    END CATCH

    FETCH NEXT FROM files INTO @fname;
END

CLOSE files;
DEALLOCATE files;

SELECT backup_file, source_server, source_db, taken_at,
       backup_type, is_copy_only, machine
  FROM #result
 ORDER BY backup_file;

PRINT '';
PRINT 'source_server should be the TEST4 instance. If any row names a production';
PRINT 'server, stop and go back to the DBA before restoring anything.';
GO
