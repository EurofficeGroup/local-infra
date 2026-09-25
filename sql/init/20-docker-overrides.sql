/* =====================================================================
   Repoint a restored support centre's configuration at the local containers.

   RUN ON: localhost,1433, with the support centre database as the context:

     docker exec -i mssql /opt/mssql-tools18/bin/sqlcmd \
       -S localhost -U sa -P '<MSSQL_SA_PASSWORD from .env.local>' -C \
       -d test4_power_supportcentre -i /init/20-docker-overrides.sql

   Run it once per group you restore - test4_power_supportcentre today,
   test4_eo_supportcentre when you add that group.

   WHAT IT DOES NOT TOUCH: the group prefix and catalog names. Values such as
     Generic             = ...Initial Catalog=test4_power_{0}
     SupportCentreSchema = test4_power_supportcentre.dbo
     DealerSchema        = test4_power_{0}.dbo
   keep their catalog names. That is what keeps the local instance a mirror of
   TEST4 rather than a one-off rename. Environment IS overridden below (to
   'local') - it turns out to feed dealer-routing-key computation for pub/sub,
   not just database names, so leaving it as 'test4' silently breaks event
   delivery between endpoints even though everything else works.

   Idempotent. Run it again after restoring a newer backup.
   ===================================================================== */

SET NOCOUNT ON;

-- Container hostnames, not localhost, and that is deliberate.
--
-- This configuration is read by two kinds of process: Noodles services inside
-- containers, which cannot reach 'localhost' (that is the container itself),
-- and Power sites on the Windows host, which cannot reach container names by
-- themselves. Run local-infra/hosts-setup.ps1 once and these names resolve to
-- 127.0.0.1 on the host too, so a single value works from both sides.
-- The published ports are identical either way.
DECLARE @SqlHost   NVARCHAR(100) = N'mssql,1433';
DECLARE @Rabbit    NVARCHAR(200) = N'host=rabbit;username=guest;password=guest';
DECLARE @Redis     NVARCHAR(200) = N'redis:6379,allowAdmin=true,abortConnect=false';
DECLARE @SmtpHost  NVARCHAR(100) = N'mailpit';
DECLARE @SmtpPort  NVARCHAR(10)  = N'1025';
-- Where the shared file locations point locally.
--
-- This is a CONTAINER path, because the services that use these values run in
-- Linux containers, and C:\... means nothing to them. Compose mounts the host
-- folder ./files at /files for every noodles service.
--
-- Power under IIS on this machine would need the Windows path instead, and one
-- row cannot be both. When that day comes, add a second row with cfg_Service
-- set to the Power service name - the configuration resolves the more specific
-- row first, which is what that column is for.
DECLARE @FileRoot  NVARCHAR(200) = N'/files/';
DECLARE @WhatIf    BIT = 0;   -- 1 = show the before/after, change nothing

-- ---------------------------------------------------------------------
-- Sanity: are we in a support centre database on the local container?
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.cfg_Configurations') IS NULL
BEGIN
    RAISERROR (N'No dbo.cfg_Configurations here. Connect with -d <env>_<group>_supportcentre.', 16, 1);
    RETURN;
END

IF @WhatIf = 0 AND SERVERPROPERTY('HostPlatform') <> N'Linux'
BEGIN
    RAISERROR (N'This is not the Linux container. Refusing to rewrite configuration.', 16, 1);
    RETURN;
END

PRINT N'Support centre: ' + DB_NAME();

-- ---------------------------------------------------------------------
-- 1. Connection strings: swap the server, keep the catalog
--
-- TEST4 values look like
--   Data Source=MSSQL-TEST-QA;Failover Partner=MSSQL-TEST-QA;Initial Catalog=test4_power_{0};User Id=EuroWebsite;...
-- and must become
--   Data Source=localhost,1433;Initial Catalog=test4_power_{0};User Id=EuroWebsite;...;TrustServerCertificate=True
--
-- Rebuilt token by token rather than by blind REPLACE, so an unexpected server
-- name cannot slip through and the catalog is never altered.
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#cs') IS NOT NULL DROP TABLE #cs;

-- COLLATE DATABASE_DEFAULT is not decoration: a temp table takes tempdb's
-- collation, these databases are Latin1_General_CI_AS, and comparing the two
-- fails outright with 'Cannot resolve the collation conflict'.
CREATE TABLE #cs
(
    cfg_Key   INT           NOT NULL PRIMARY KEY,
    cfg_Name  NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
    old_value NVARCHAR(MAX) NOT NULL,
    new_value NVARCHAR(MAX) NULL
);

INSERT INTO #cs (cfg_Key, cfg_Name, old_value)
SELECT cfg_Key, cfg_Name, cfg_Value
  FROM dbo.cfg_Configurations
 WHERE cfg_Value LIKE N'%Data Source=%'
    OR cfg_Value LIKE N'%data source=%';

UPDATE c
   SET new_value = x.rebuilt
  FROM #cs c
 CROSS APPLY (
        SELECT N'Data Source=' + @SqlHost + N';'
             + STRING_AGG(CAST(LTRIM(RTRIM(s.value)) AS NVARCHAR(MAX)), N';')
                   WITHIN GROUP (ORDER BY CAST(s.[key] AS INT))
             + N';Encrypt=False;TrustServerCertificate=True;' AS rebuilt
          -- Splitting through OPENJSON rather than STRING_SPLIT(.., .., 1):
          -- the ordinal argument of STRING_SPLIT needs compatibility level 160,
          -- and these databases are 150. Order is not optional here - the
          -- tokens are put back together below, and OPENJSON numbers them.
          -- STRING_ESCAPE guards the wrapping: a password containing a quote
          -- or a backslash would otherwise produce invalid JSON.
          FROM OPENJSON(N'["'
                        + REPLACE(STRING_ESCAPE(c.old_value, 'json'), N';', N'","')
                        + N'"]') AS s
         WHERE LTRIM(RTRIM(s.value)) <> N''
           -- endpoint and transport-security tokens are replaced, not kept
           AND LOWER(LTRIM(s.value)) NOT LIKE N'data source=%'
           AND LOWER(LTRIM(s.value)) NOT LIKE N'server=%'
           AND LOWER(LTRIM(s.value)) NOT LIKE N'failover partner=%'
           AND LOWER(LTRIM(s.value)) NOT LIKE N'encrypt=%'
           AND LOWER(LTRIM(s.value)) NOT LIKE N'trustservercertificate=%'
           -- Windows auth cannot work against a Linux container from the host
           AND LOWER(LTRIM(s.value)) NOT LIKE N'integrated security=%'
           AND LOWER(LTRIM(s.value)) NOT LIKE N'persist security info=%'
 ) AS x;

-- Anything that relied on Integrated Security now has no credentials - give it
-- the local login.
UPDATE #cs
   SET new_value = REPLACE(new_value, N';Encrypt=False;', N';User Id=EuroWebsite;Password=pensandpencils;Encrypt=False;')
 WHERE new_value NOT LIKE N'%User Id=%'
   AND new_value NOT LIKE N'%uid=%';

-- Credentials that are not credentials.
--
-- Some strings ship a placeholder instead of a password, for example
--   User Id=platform-test4-pow;Password=[secret:platform-test4-pow]
-- and the real value is injected from the secret store at deployment time.
-- There is no secret store here and no such login, so a string like this cannot
-- connect - and because it does have a User Id, the rule above leaves it alone.
--
-- Swap the whole pair for the local login. EuroWebsite is sysadmin on this
-- container (see 00-login-and-databases.sql), so it reaches every restored
-- group, which is exactly what the placeholder account was there to do.
UPDATE c
   SET new_value = x.rebuilt
  FROM #cs c
 CROSS APPLY (
        SELECT STRING_AGG(
                   CAST(CASE
                            WHEN LOWER(LTRIM(s.value)) LIKE N'user id=%' THEN N'User Id=EuroWebsite'
                            WHEN LOWER(LTRIM(s.value)) LIKE N'uid=%'     THEN N'User Id=EuroWebsite'
                            WHEN LOWER(LTRIM(s.value)) LIKE N'password=%' THEN N'Password=pensandpencils'
                            WHEN LOWER(LTRIM(s.value)) LIKE N'pwd=%'      THEN N'Password=pensandpencils'
                            ELSE LTRIM(RTRIM(s.value))
                        END AS NVARCHAR(MAX)), N';')
                   WITHIN GROUP (ORDER BY CAST(s.[key] AS INT)) + N';' AS rebuilt
          FROM OPENJSON(N'["'
                        + REPLACE(STRING_ESCAPE(c.new_value, 'json'), N';', N'","')
                        + N'"]') AS s
         WHERE LTRIM(RTRIM(s.value)) <> N''
 ) AS x
 WHERE c.new_value LIKE N'%[[]secret:%';

SELECT cfg_Name, old_value, new_value FROM #cs ORDER BY cfg_Name;

-- ---------------------------------------------------------------------
-- 2. Flat endpoint values
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#flat') IS NOT NULL DROP TABLE #flat;
CREATE TABLE #flat (name NVARCHAR(200) COLLATE DATABASE_DEFAULT PRIMARY KEY, value NVARCHAR(MAX));

INSERT INTO #flat (name, value) VALUES
    -- THE TRANSPORT SWITCH.
    --
    -- The estate runs NServiceBus over Azure Service Bus, and the endpoint
    -- authenticates with DefaultAzureCredential - managed identity, Azure CLI,
    -- Visual Studio. A container has none of those, so every endpoint dies at
    -- startup in QueueCreator, including the Configuration API's own.
    --
    -- EurofficeGroup.NServiceBus.Core ships both transports, and this key picks
    -- between them; false sends it to RabbitMQ, which reads 'Rabbit' below.
    --
    -- The key is stored once globally and again per service (33 rows here), and
    -- the per-service row wins. The UPDATE that applies #flat joins on cfg_Name
    -- alone, so all of them are covered - do not narrow that join.
    (N'UseAzureServiceBus',      N'false'),

    -- The estate never sets this: production queues/exchanges are created once
    -- by a deployment step, not by the endpoint itself. Locally there is no such
    -- step, so without this the NSB RabbitMQ transport never creates its own
    -- queue/exchange (Noodles.Configuration.Setup.Multitenancy.Core.cs reads it
    -- as `EnableInstallers`, default false) and every Noodles service crashes on
    -- startup with "NOT_FOUND - no queue/exchange ..." in a restart loop.
    (N'EnableInstallers',        N'true'),

    -- The comment above this table used to say Environment was untouched on
    -- purpose - true for the endpoint's OWN address (Multitenancy.Common.cs
    -- reads that from the per-service appsettings.local.json file, which
    -- already says "local"). But PerMessageDealerContext.cs reads Environment
    -- through IConfiguration, which is fed by the bootstrapped config-api
    -- client and therefore sees THIS table, not the local file. Left at the
    -- restored backup's 'test4', that class computes the dealer-routing
    -- key as 'test4-pow' while every endpoint's own queue/exchange binds
    -- under 'local_<machine>-pow' - two different keys on a topic exchange
    -- never match, so events (e.g. CustomerLoginEmailChangedEvent) publish
    -- successfully but are never routed to any subscriber.
    (N'Environment',             N'local'),

    (N'Rabbit',                  @Rabbit),
    (N'Cache',                   @Redis),
    (N'Redis.ConnectionString',  @Redis),

    -- EMAIL. This is the most dangerous part of a restored configuration.
    -- TEST4 power points at a real provider:
    --     Default.Service          = SmtpRemoteEmailService
    --     RemoteService.Host       = smtp.mandrillapp.com
    --     RemoteService.Port       = 587,  Secure = True
    --     RemoteService.Username   = technology@euroffice.co.uk
    --     RemoteService.Password   = [secret:test4-pow-remoteservice-password]
    --     RemoteService.MandrillApiKey = NULL
    -- The password turned out to be a placeholder, resolved from the secret store
    -- at deployment time, and the API key is empty - so a restored copy cannot in
    -- fact authenticate. That is luck, not a safeguard: the host is real, the port
    -- is real, and the recipients in the restored data are real customers.
    -- Redirect it at Mailpit, which accepts anything and forwards nothing.
    (N'Default.Service',         N'SmtpRemoteEmailService'),
    (N'RemoteService.Host',      @SmtpHost),
    (N'RemoteService.Port',      @SmtpPort),
    (N'RemoteService.Secure',    N'False'),
    (N'RemoteService.Username',  N''),
    (N'RemoteService.Password',  N''),
    (N'RemoteService.MandrillApiKey', N''),

    -- Noodles gateway/uploader hosts
    (N'NoodlesActionsServer',    N'noodles-actions'),
    (N'NoodlesGatewayServer_0',  N'localhost'),
    (N'NoodlesUploadersServer_0',N'noodles-uploaders');

-- Keys deliberately NOT touched:
--   FilterEmails         - switching it on activates EmailFilterForTestEnvironments,
--                          which needs an allow-list file (C:\AllowedEmailList.txt by
--                          default). Mailpit is already a hard boundary; a half-configured
--                          filter is a new failure mode, not extra safety.
--   ElasticSearchConnectionString - left pointing at elastic-test-lb.euroffice.co.uk.
--                          An earlier version of this comment claimed no such key existed
--                          and that search here is only Endeca. It does exist.
--                          Not repointed on purpose: the 'search' profile is not part of
--                          a plain 'compose up', so aiming this at the elastic container
--                          would break anyone who does not start that profile.
--                          To use the local one:
--                             UPDATE dbo.cfg_Configurations
--                                SET cfg_Value = N'http://elastic:9200'
--                              WHERE cfg_Name = N'ElasticSearchConnectionString';
--                          then  docker compose --profile search up -d
--   Ssrs.ServerUrl       - a TEST4 configuration pointing at the live reporting server.
--                          Nothing local reads it yet; if a service ever renders a
--                          report, it will reach that server.
--   AzureStorage.*       - no such key either. The only Azure Storage package referenced
--                          by Power or Noodles is Azure.Storage.Files.Shares.

SELECT f.name,
       (SELECT TOP 1 cfg_Value FROM dbo.cfg_Configurations c
         WHERE c.cfg_Name = f.name AND c.cfg_Dealer IS NULL AND c.cfg_Service IS NULL) AS old_value,
       f.value AS new_value
  FROM #flat f
 ORDER BY f.name;

-- ---------------------------------------------------------------------
-- 3. UNC file locations that do not exist locally
-- ---------------------------------------------------------------------
SELECT cfg_Name, cfg_Value AS old_value,
       @FileRoot + RIGHT(cfg_Value, CHARINDEX(N'\', REVERSE(cfg_Value) + N'\') - 1) AS new_value
  FROM dbo.cfg_Configurations
 WHERE cfg_Value LIKE N'\\%';

-- ---------------------------------------------------------------------
-- Apply
-- ---------------------------------------------------------------------
IF @WhatIf = 1
BEGIN
    RAISERROR (N'@WhatIf was 1: nothing changed. Review the three result sets above, then set @WhatIf = 0.', 10, 1);
    RETURN;
END

BEGIN TRANSACTION;

UPDATE c
   SET c.cfg_Value = x.new_value
  FROM dbo.cfg_Configurations c
  JOIN #cs x ON x.cfg_Key = c.cfg_Key
 WHERE x.new_value IS NOT NULL;

PRINT N'Connection strings repointed: ' + CAST(@@ROWCOUNT AS NVARCHAR(10));

UPDATE c
   SET c.cfg_Value = f.value
  FROM dbo.cfg_Configurations c
  JOIN #flat f ON f.name = c.cfg_Name;

PRINT N'Endpoint values updated: ' + CAST(@@ROWCOUNT AS NVARCHAR(10));

INSERT INTO dbo.cfg_Configurations (cfg_Dealer, cfg_Service, cfg_Name, cfg_Value)
SELECT NULL, NULL, f.name, f.value
  FROM #flat f
 WHERE NOT EXISTS (SELECT 1 FROM dbo.cfg_Configurations c WHERE c.cfg_Name = f.name);

PRINT N'Endpoint values added: ' + CAST(@@ROWCOUNT AS NVARCHAR(10));

UPDATE dbo.cfg_Configurations
   SET cfg_Value = @FileRoot + RIGHT(cfg_Value, CHARINDEX(N'\', REVERSE(cfg_Value) + N'\') - 1)
 WHERE cfg_Value LIKE N'\\%';

PRINT N'UNC paths redirected: ' + CAST(@@ROWCOUNT AS NVARCHAR(10));

COMMIT;

-- ---------------------------------------------------------------------
-- Verify: nothing should point outside this machine any more
-- ---------------------------------------------------------------------
SELECT cfg_Name, cfg_Value
  FROM dbo.cfg_Configurations
 WHERE cfg_Value LIKE N'%datacentre.euroffice.com%'
    OR cfg_Value LIKE N'%euroffice.co.uk%'
    OR cfg_Value LIKE N'%MSSQL-TEST-QA%'
    OR cfg_Value LIKE N'%mandrill%'
    OR cfg_Value LIKE N'%10.2.34.%'
    OR cfg_Value LIKE N'\\%'
 ORDER BY cfg_Name;

PRINT N'Rows above still reference something outside this machine - review them.';
PRINT N'Some are harmless (public URLs, CDN, payment gateways); a broker, database or mail host is not.';
GO
