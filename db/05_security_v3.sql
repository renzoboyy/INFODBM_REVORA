/* ============================================================================
   REVORA - DATABASE SECURITY LAYER v3
   Implements SQL Server security concepts from INFODBM Lab Activity 09,
   adapted to the actual REVORA system access model. Ported from
   05_security_v2.sql onto the v3 schema (Address+Branches merge, geography
   hierarchy). Logins/roles/masking are otherwise unchanged from v2.

   Three principals:
     revora_admin  -- DBA / superuser (db_owner + UNMASK)
     revora_staff  -- Admin-dashboard staff (read + approval SPs only)
     revora_api    -- Backend API connection (read/write, no DELETE/DDL)

   Run ONCE, on top of 01_schema_v3.sql + 03_additional_objects_v3.sql.
   Safe to re-run: each block checks for existence before creating.

   Login passwords are sqlcmd variables, so none are stored in the repo.
   Pass them on the command line (see README section 3):
     sqlcmd ... -i "db\05_security_v3.sql" -v AdminPassword="..." StaffPassword="..." ApiPassword="..."
   In SSMS, turn on Query > SQLCMD Mode and add :setvar lines first.
   ============================================================================ */

USE [master];
GO

/* ============================================================================
   PART 1 — SERVER-LEVEL LOGINS
   ============================================================================ */

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'revora_admin')
BEGIN
    CREATE LOGIN [revora_admin]
        WITH PASSWORD    = N'$(AdminPassword)',
             CHECK_POLICY = ON,
             CHECK_EXPIRATION = OFF;
    PRINT 'Login [revora_admin] created.';
END
ELSE
    PRINT 'Login [revora_admin] already exists — skipped.';
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'revora_staff')
BEGIN
    CREATE LOGIN [revora_staff]
        WITH PASSWORD    = N'$(StaffPassword)',
             CHECK_POLICY = ON,
             CHECK_EXPIRATION = OFF;
    PRINT 'Login [revora_staff] created.';
END
ELSE
    PRINT 'Login [revora_staff] already exists — skipped.';
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'revora_api')
BEGIN
    CREATE LOGIN [revora_api]
        WITH PASSWORD    = N'$(ApiPassword)',
             CHECK_POLICY = ON,
             CHECK_EXPIRATION = OFF;
    PRINT 'Login [revora_api] created.';
END
ELSE
    PRINT 'Login [revora_api] already exists — skipped.';
GO

/* ============================================================================
   PART 2 — DATABASE-LEVEL USERS
   ============================================================================ */

USE [INFODBM_REVORA];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'revora_admin_user')
BEGIN
    CREATE USER [revora_admin_user] FOR LOGIN [revora_admin];
    PRINT 'DB user [revora_admin_user] created.';
END
ELSE
    PRINT 'DB user [revora_admin_user] already exists — skipped.';
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'revora_staff_user')
BEGIN
    CREATE USER [revora_staff_user] FOR LOGIN [revora_staff];
    PRINT 'DB user [revora_staff_user] created.';
END
ELSE
    PRINT 'DB user [revora_staff_user] already exists — skipped.';
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'revora_api_user')
BEGIN
    CREATE USER [revora_api_user] FOR LOGIN [revora_api];
    PRINT 'DB user [revora_api_user] created.';
END
ELSE
    PRINT 'DB user [revora_api_user] already exists — skipped.';
GO

/* ============================================================================
   PART 3 — FIXED DATABASE ROLE ASSIGNMENTS
   ============================================================================ */

ALTER ROLE [db_owner]      ADD MEMBER [revora_admin_user];
GO
ALTER ROLE [db_datareader] ADD MEMBER [revora_staff_user];
GO
ALTER ROLE [db_datareader] ADD MEMBER [revora_api_user];
ALTER ROLE [db_datawriter] ADD MEMBER [revora_api_user];
GO

/* ============================================================================
   PART 4 — EXPLICIT DENY (belt-and-suspenders)
   Branches -> Branch (renamed/thinned table). Geography hierarchy tables
   (Region/Province/CityMunicipality/Barangay) added to the same DENY list -
   the address find-or-create logic inlined in sp_RegisterUser and
   sp_ApproveProfileEdit is the only thing that ever writes to them, and it
   never deletes rows, so the app logins have no legitimate reason to delete
   there either.
   ============================================================================ */

-- API: cannot delete any row in any user table
DENY DELETE ON OBJECT::[dbo].[Users]            TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[AuditLog]         TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Entities]         TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Branch]           TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Address]          TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Region]           TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Province]         TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[CityMunicipality] TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Barangay]         TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[GID]              TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Roles]            TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Categories]       TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[AccountStatus]    TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Sectors]          TO [revora_api_user];
GO

-- Staff: cannot delete raw rows either (they act through SPs)
DENY DELETE ON OBJECT::[dbo].[Users]            TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[AuditLog]         TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[Entities]         TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[Branch]           TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[Address]          TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[Region]           TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[Province]         TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[CityMunicipality] TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[Barangay]         TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[GID]              TO [revora_staff_user];
GO

/* ============================================================================
   PART 5 — STORED PROCEDURE EXECUTE GRANTS
   The address find-or-create logic lives inline inside sp_RegisterUser /
   sp_ApproveProfileEdit (no separate shared stored procedure), so no
   additional EXECUTE grant is needed for it beyond the grants on those
   procs themselves.
   ============================================================================ */

GRANT EXECUTE ON OBJECT::[dbo].[ApproveUserAccount]  TO [revora_staff_user];
GRANT EXECUTE ON OBJECT::[dbo].[sp_RejectRegistrant] TO [revora_staff_user];
GO

GRANT EXECUTE ON OBJECT::[dbo].[sp_RegisterUser]     TO [revora_api_user];
GO

/* ============================================================================
   PART 6 — VIEW GRANTS  (same view names as v2)
   ============================================================================ */

GRANT SELECT ON OBJECT::[dbo].[vw_ApplicantDirectory]     TO [revora_staff_user];
GRANT SELECT ON OBJECT::[dbo].[vw_ApplicantDetail]        TO [revora_staff_user];
GRANT SELECT ON OBJECT::[dbo].[vw_PendingThenApproved]    TO [revora_staff_user];
GRANT SELECT ON OBJECT::[dbo].[vw_EntityBasedRegistrants] TO [revora_staff_user];
GO

GRANT SELECT ON OBJECT::[dbo].[vw_ApplicantDirectory]     TO [revora_api_user];
GO

/* ============================================================================
   PART 7 — DYNAMIC DATA MASKING (DDM)  (unchanged - same columns/types)
   ============================================================================ */

ALTER TABLE [dbo].[Users]
    ALTER COLUMN [Email] NVARCHAR(50)
    MASKED WITH (FUNCTION = 'email()');
GO

ALTER TABLE [dbo].[Users]
    ALTER COLUMN [PhoneNumber] CHAR(11)
    MASKED WITH (FUNCTION = 'partial(0, "XXXXXXXXXXX", 0)');
GO

ALTER TABLE [dbo].[GID]
    ALTER COLUMN [GovtNo] VARCHAR(20)
    MASKED WITH (FUNCTION = 'partial(0, "XXXX-XXXX-XXXX", 0)');
GO

/* ============================================================================
   PART 8 — UNMASK GRANT
   ============================================================================ */

GRANT UNMASK TO [revora_admin_user];
GO

/* ============================================================================
   PART 9 — SCALAR FUNCTION GRANT
   ============================================================================ */

GRANT EXECUTE ON OBJECT::[dbo].[fn_SLAStatus] TO [revora_staff_user];
GRANT EXECUTE ON OBJECT::[dbo].[fn_SLAStatus] TO [revora_api_user];
GO

/* ============================================================================
   PRINT SUMMARY
   ============================================================================ */

PRINT '============================================================';
PRINT ' REVORA Security Layer v3 applied successfully.';
PRINT '';
PRINT ' Server logins created:';
PRINT '   revora_admin  (password: AdminPassword variable)';
PRINT '   revora_staff  (password: StaffPassword variable)';
PRINT '   revora_api    (password: ApiPassword variable)';
PRINT '';
PRINT ' Database users created (in INFODBM_REVORA):';
PRINT '   revora_admin_user  -> db_owner + UNMASK';
PRINT '   revora_staff_user  -> db_datareader';
PRINT '                         EXECUTE: ApproveUserAccount,';
PRINT '                                  sp_RejectRegistrant';
PRINT '                         DENY DELETE on all tables incl. geography hierarchy';
PRINT '   revora_api_user    -> db_datareader + db_datawriter';
PRINT '                         EXECUTE: sp_RegisterUser';
PRINT '                         DENY DELETE on all tables incl. geography hierarchy';
PRINT '';
PRINT ' Dynamic Data Masking applied to:';
PRINT '   dbo.Users.Email        -> email() mask';
PRINT '   dbo.Users.PhoneNumber  -> partial mask (XXXXXXXXXXX)';
PRINT '   dbo.GID.GovtNo         -> partial mask (XXXX-XXXX-XXXX)';
PRINT '============================================================';
GO
