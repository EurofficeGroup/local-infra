/* =====================================================================
   Repoint code inside the restored databases at the local database names.

   RUN ON: localhost,1433 (the mssql container), any database context.
   setup-local.bat runs it right after 02-restore-local.sql; re-run any time
   with   ops-local.bat rename-refs

   WHY. The TEST4 backups are restored as dev_uk_* (02-restore-local.sql), but
   code deployed inside them names the TEST4 databases directly:
     synonyms   dev_uk_jst.dbo.itm_item -> [test4_power_productcatalogue].[dbo].[itm_item]
     views      dev_uk_supportcentre.dbo.dlr_Dealers  ... FROM test4_power_jst.dbo...
     procedures P_create_* in every database
   Left alone, every one of them fails with "Invalid object name" - and the
   views are what NHibernate reads, so Noodles and Power would break.

   WHAT IT DOES, in every database named <@TargetPrefix>_*:
     - synonyms: DROP + CREATE with <@SourcePrefix>_ replaced by <@TargetPrefix>_
     - views, procedures, functions, triggers: the definition with the same
       replacement, applied as CREATE OR ALTER (permissions are kept), under
       the module's own QUOTED_IDENTIFIER / ANSI_NULLS settings.
   An object that still cannot be compiled is left exactly as it was and
   listed. Typical cause: a support centre dealer view (UNION ALL over every
   dealer of the group) when one dealer's backup was not in sql/backup.

   The settings below come from .env (INFRA_BACKUP_PREFIX, INFRA_DB_PREFIX);
   setup-local.bat / ops-local.bat substitute them. Idempotent.
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @SourcePrefix NVARCHAR(100) = N'test4_power';  -- INFRA_BACKUP_PREFIX
DECLARE @TargetPrefix NVARCHAR(100) = N'dev_uk';       -- INFRA_DB_PREFIX

IF SERVERPROPERTY('HostPlatform') <> N'Linux'
BEGIN
    RAISERROR (N'This is not the Linux container. Refusing to rewrite database code.', 16, 1);
    RETURN;
END

IF @SourcePrefix = @TargetPrefix
BEGIN
    PRINT N'Source and target prefix are equal - nothing to rename.';
    RETURN;
END

DECLARE @src  NVARCHAR(101) = @SourcePrefix + N'_';
DECLARE @tgt  NVARCHAR(101) = @TargetPrefix + N'_';
DECLARE @like NVARCHAR(300) = N'%' + REPLACE(@SourcePrefix, N'_', N'[_]') + N'[_]%';

IF OBJECT_ID('tempdb..#obj') IS NOT NULL DROP TABLE #obj;
CREATE TABLE #obj
(
    id      INT IDENTITY PRIMARY KEY,
    db      SYSNAME,
    sch     SYSNAME,
    name    SYSNAME,
    kind    NVARCHAR(60),
    qi      BIT,
    an      BIT,
    body    NVARCHAR(MAX),          -- synonym base name or module definition
    status  NVARCHAR(20) NULL,
    error   NVARCHAR(2000) NULL
);

-- ---------------------------------------------------------------------
-- 1. Collect, from every <TargetPrefix>_* database
-- ---------------------------------------------------------------------
DECLARE @db SYSNAME, @collect NVARCHAR(MAX), @run NVARCHAR(MAX);

SET @collect = N'
    INSERT INTO #obj (db, sch, name, kind, qi, an, body)
    SELECT DB_NAME(), SCHEMA_NAME(s.schema_id), s.name, N''SYNONYM'', 1, 1, s.base_object_name
      FROM sys.synonyms s
     WHERE s.base_object_name LIKE @like;

    INSERT INTO #obj (db, sch, name, kind, qi, an, body)
    SELECT DB_NAME(), SCHEMA_NAME(o.schema_id), o.name, o.type_desc,
           m.uses_quoted_identifier, m.uses_ansi_nulls, m.definition
      FROM sys.sql_modules m
      JOIN sys.objects o ON o.object_id = m.object_id
     WHERE m.definition LIKE @like
       AND o.type IN (''V'', ''P'', ''FN'', ''IF'', ''TF'', ''TR'');';

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
     WHERE name LIKE REPLACE(@TargetPrefix, N'_', N'[_]') + N'[_]%'
       AND state_desc = N'ONLINE'
     ORDER BY name;
OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- <db>.sys.sp_executesql runs the batch with <db> as the current database.
    SET @run = QUOTENAME(@db) + N'.sys.sp_executesql';
    EXEC @run @collect, N'@like NVARCHAR(300)', @like = @like;
    FETCH NEXT FROM db_cursor INTO @db;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT db, kind, COUNT(*) AS objects_to_rewrite
  FROM #obj GROUP BY db, kind ORDER BY db, kind;

-- ---------------------------------------------------------------------
-- 2. Rewrite. Modules get up to three passes, because a view can fail only
--    because another view it reads has not been rewritten yet.
-- ---------------------------------------------------------------------
DECLARE @id INT, @sch SYSNAME, @name SYSNAME, @kind NVARCHAR(60), @qi BIT, @an BIT,
        @body NVARCHAR(MAX), @stmt NVARCHAR(MAX), @outer NVARCHAR(MAX),
        @pos INT, @next NVARCHAR(40), @found BIT, @pass INT = 1;

WHILE @pass <= 3
BEGIN
    DECLARE obj_cursor CURSOR LOCAL STATIC FOR
        SELECT id, db, sch, name, kind, qi, an, body
          FROM #obj
         WHERE status IS NULL OR status = N'failed'
         ORDER BY CASE kind WHEN N'SYNONYM' THEN 0 WHEN N'VIEW' THEN 1 ELSE 2 END, id;
    OPEN obj_cursor;
    FETCH NEXT FROM obj_cursor INTO @id, @db, @sch, @name, @kind, @qi, @an, @body;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @stmt = NULL;

        IF @kind = N'SYNONYM'
            SET @stmt = N'DROP SYNONYM ' + QUOTENAME(@sch) + N'.' + QUOTENAME(@name) + N';
                          CREATE SYNONYM ' + QUOTENAME(@sch) + N'.' + QUOTENAME(@name)
                      + N' FOR ' + REPLACE(@body, @src, @tgt) + N';';
        ELSE
        BEGIN
            -- Turn the first real "CREATE <PROC|VIEW|FUNCTION|TRIGGER>" into
            -- "CREATE OR ALTER", skipping words like "Created" in a header comment.
            SET @body = REPLACE(@body, @src, @tgt);

            SET @pos = CHARINDEX(N'CREATE', @body);
            SET @found = 0;
            WHILE @pos > 0 AND @found = 0
            BEGIN
                SET @next = LTRIM(REPLACE(REPLACE(REPLACE(SUBSTRING(@body, @pos + 6, 40),
                                  NCHAR(9), N' '), NCHAR(13), N' '), NCHAR(10), N' '));
                IF (@pos = 1 OR SUBSTRING(@body, @pos - 1, 1) IN (N' ', NCHAR(9), NCHAR(10), NCHAR(13)))
                   AND SUBSTRING(@body, @pos + 6, 1) IN (N' ', NCHAR(9), NCHAR(10), NCHAR(13))
                   AND (@next LIKE N'PROC%' OR @next LIKE N'VIEW%' OR @next LIKE N'FUNCTION%' OR @next LIKE N'TRIGGER%')
                BEGIN
                    IF @next NOT LIKE N'OR %'
                        SET @stmt = STUFF(@body, @pos, 6, N'CREATE OR ALTER');
                    SET @found = 1;
                END
                ELSE
                    SET @pos = CHARINDEX(N'CREATE', @body, @pos + 6);
            END
            IF @stmt IS NULL
                UPDATE #obj SET status = N'failed', error = N'No CREATE statement found in the definition.' WHERE id = @id;
        END

        IF @stmt IS NOT NULL
        BEGIN
            -- The SETs live in the outer dynamic batch, so they apply to the
            -- nested sp_executesql that compiles the object, and the CREATE
            -- stays the first statement of its own batch.
            SET @outer = N'SET QUOTED_IDENTIFIER ' + CASE @qi WHEN 1 THEN N'ON' ELSE N'OFF' END + N'; '
                       + N'SET ANSI_NULLS '        + CASE @an WHEN 1 THEN N'ON' ELSE N'OFF' END + N'; '
                       + N'EXEC ' + QUOTENAME(@db) + N'.sys.sp_executesql @s;';
            BEGIN TRY
                BEGIN TRANSACTION;
                EXEC sp_executesql @outer, N'@s NVARCHAR(MAX)', @s = @stmt;
                COMMIT;
                UPDATE #obj SET status = N'rewritten', error = NULL WHERE id = @id;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0 ROLLBACK;
                UPDATE #obj SET status = N'failed', error = LEFT(ERROR_MESSAGE(), 2000) WHERE id = @id;
            END CATCH
        END

        FETCH NEXT FROM obj_cursor INTO @id, @db, @sch, @name, @kind, @qi, @an, @body;
    END
    CLOSE obj_cursor;
    DEALLOCATE obj_cursor;

    IF NOT EXISTS (SELECT 1 FROM #obj WHERE status = N'failed') BREAK;
    SET @pass += 1;
END

-- ---------------------------------------------------------------------
-- 3. Report
-- ---------------------------------------------------------------------
SELECT db, kind, status, COUNT(*) AS objects
  FROM #obj GROUP BY db, kind, status ORDER BY db, kind, status;

IF EXISTS (SELECT 1 FROM #obj WHERE status = N'failed')
BEGIN
    SELECT db, kind, sch + N'.' + name AS object_name, error
      FROM #obj WHERE status = N'failed' ORDER BY db, kind, name;
    RAISERROR (N'WARNING: the objects above were left unchanged and still reference %s_* databases.', 10, 1, @SourcePrefix) WITH NOWAIT;
END
ELSE
    PRINT N'All references to ' + @src + N'* rewritten to ' + @tgt + N'*.';
GO
