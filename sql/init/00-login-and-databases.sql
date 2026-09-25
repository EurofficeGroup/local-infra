-- ---------------------------------------------------------------------
-- Prerequisites for the local SQL Server container.
-- Run this FIRST, before restoring anything.
--
--   docker exec -i mssql /opt/mssql-tools18/bin/sqlcmd \
--     -S localhost -U sa -P "<MSSQL_SA_PASSWORD from .env.local>" -C \
--     -i /init/00-login-and-databases.sql
--
-- THE PASSWORDS HERE ARE NOT CHOSEN, THEY ARE DICTATED.
--
-- Every environment's configuration stores connection strings with these exact
-- credentials, and a restored support centre brings them along. If the local
-- logins do not match, nothing connects - so this is not the place to invent
-- something stronger.
--
--   EuroWebsite / pensandpencils    37 connection strings across the config
--                                   scripts, plus the Configuration API's own
--                                   appsettings.json
--   EuroService / 0*lEVEL*gIVES?    19 of them, notably NServiceBus/Persistence
--                                   (test4_power_nservicebus)
--
-- Deliberately does NOT create any <env>_<group>_* databases. Those arrive by
-- restore, under their original names. See sql/test4/README.md.
-- ---------------------------------------------------------------------

SET NOCOUNT ON;

-- CHECK_POLICY = OFF is required, not laziness: 'pensandpencils' is all
-- lowercase letters and fails SQL Server's complexity rule. The password is
-- fixed by the configuration, so the policy is what has to give.

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'EuroWebsite')
    CREATE LOGIN [EuroWebsite] WITH
        PASSWORD = N'pensandpencils',
        CHECK_POLICY = OFF,
        CHECK_EXPIRATION = OFF,
        DEFAULT_DATABASE = [master];
ELSE
    ALTER LOGIN [EuroWebsite] WITH PASSWORD = N'pensandpencils';
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'EuroService')
    CREATE LOGIN [EuroService] WITH
        PASSWORD = N'0*lEVEL*gIVES?',
        CHECK_POLICY = OFF,
        CHECK_EXPIRATION = OFF,
        DEFAULT_DATABASE = [master];
ELSE
    ALTER LOGIN [EuroService] WITH PASSWORD = N'0*lEVEL*gIVES?';
GO

-- Local dev container only: keeps permission fiddling out of the way, and lets
-- the same logins reach every group you later restore.
-- Do NOT copy this to any shared environment.
IF NOT EXISTS (SELECT 1 FROM sys.server_role_members rm
               JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
               JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
               WHERE r.name = N'sysadmin' AND m.name = N'EuroWebsite')
    ALTER SERVER ROLE [sysadmin] ADD MEMBER [EuroWebsite];
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_role_members rm
               JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
               JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
               WHERE r.name = N'sysadmin' AND m.name = N'EuroService')
    ALTER SERVER ROLE [sysadmin] ADD MEMBER [EuroService];
GO

-- The Noodles configuration database is referenced by every group's config
-- (Configuration -> "Initial Catalog=test4_noodles_configuration") but does not
-- exist on the TEST4 instance, so there is nothing to restore. An empty shell
-- lets services connect; the schema comes from the migrator in
-- C:\workspace\database if a service turns out to need it.
IF DB_ID('test4_noodles_configuration') IS NULL
    CREATE DATABASE [test4_noodles_configuration];
GO

SELECT name AS login_ready
  FROM sys.server_principals
 WHERE name IN (N'EuroWebsite', N'EuroService');
GO

PRINT 'Logins ready. Restore the group databases next.';
GO
