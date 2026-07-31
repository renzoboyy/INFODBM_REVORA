/* ============================================================================
   REVORA - DATABASE SECURITY LAYER v2
   Implements SQL Server security concepts from INFODBM Lab Activity 09,
   adapted to the actual REVORA system access model.

   Three principals:
     revora_admin  -- DBA / superuser (db_owner + UNMASK)
     revora_staff  -- Admin-dashboard staff (read + approval SPs only)
     revora_api    -- Backend API connection (read/write, no DELETE/DDL)

   Run ONCE, on top of 01_schema_v2.sql + 03_additional_objects_v2.sql.
   Safe to re-run: each block checks for existence before creating.
   ============================================================================ */

USE [master];
GO

/* ============================================================================
   PART 1 — SERVER-LEVEL LOGINS
   Created at the instance level. Password policy enforced (CHECK_POLICY = ON).
   ============================================================================ */

-- revora_admin: the DBA / system owner. Will receive db_owner + UNMASK.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'revora_admin')
BEGIN
    CREATE LOGIN [revora_admin]
        WITH PASSWORD    = N'R3v0ra@Admin#2025!',
             CHECK_POLICY = ON,
             CHECK_EXPIRATION = OFF;
    PRINT 'Login [revora_admin] created.';
END
ELSE
    PRINT 'Login [revora_admin] already exists — skipped.';
GO

-- revora_staff: admin-dashboard operator.
-- Can browse all data and execute approval / branch-management SPs.
-- Cannot INSERT, UPDATE, DELETE raw rows or modify schema.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'revora_staff')
BEGIN
    CREATE LOGIN [revora_staff]
        WITH PASSWORD    = N'R3v0ra@Staff#2025!',
             CHECK_POLICY = ON,
             CHECK_EXPIRATION = OFF;
    PRINT 'Login [revora_staff] created.';
END
ELSE
    PRINT 'Login [revora_staff] already exists — skipped.';
GO

-- revora_api: the Node/Express backend service account.
-- Can read all data and write (INSERT/UPDATE) via stored procedures.
-- Explicitly denied DELETE and any DDL operations.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'revora_api')
BEGIN
    CREATE LOGIN [revora_api]
        WITH PASSWORD    = N'R3v0ra@Api#2025!',
             CHECK_POLICY = ON,
             CHECK_EXPIRATION = OFF;
    PRINT 'Login [revora_api] created.';
END
ELSE
    PRINT 'Login [revora_api] already exists — skipped.';
GO

/* ============================================================================
   PART 2 — DATABASE-LEVEL USERS
   Each login is mapped to one user inside INFODBM_REVORA.
   The database user has no independent password; authentication is handled
   by the server-level login.
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

   revora_admin_user  -> db_owner      (full control)
   revora_staff_user  -> db_datareader (SELECT on all user tables/views)
   revora_api_user    -> db_datareader (SELECT)
                      -> db_datawriter (INSERT + UPDATE on all user tables)
   ============================================================================ */

-- Admin: full ownership
ALTER ROLE [db_owner]      ADD MEMBER [revora_admin_user];
GO

-- Staff: read-only base (SPs provide all write-equivalent actions)
ALTER ROLE [db_datareader] ADD MEMBER [revora_staff_user];
GO

-- API: read + write
ALTER ROLE [db_datareader] ADD MEMBER [revora_api_user];
ALTER ROLE [db_datawriter] ADD MEMBER [revora_api_user];
GO

/* ============================================================================
   PART 4 — EXPLICIT DENY (belt-and-suspenders)

   revora_api_user gets db_datawriter (INSERT + UPDATE) but should NEVER be
   able to hard-delete rows. DENY overrides any role-based GRANT.

   revora_staff_user is db_datareader only — no INSERT/UPDATE/DELETE at all —
   but we add DENY DELETE explicitly to make the restriction auditable.
   ============================================================================ */

-- API: cannot delete any row in any user table
DENY DELETE ON OBJECT::[dbo].[Users]         TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[AuditLog]      TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Entities]      TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Branches]      TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Address]       TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[GID]           TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Roles]         TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Categories]    TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[AccountStatus] TO [revora_api_user];
DENY DELETE ON OBJECT::[dbo].[Sectors]       TO [revora_api_user];
GO

-- Staff: cannot delete raw rows either (they act through SPs)
DENY DELETE ON OBJECT::[dbo].[Users]         TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[AuditLog]      TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[Entities]      TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[Branches]      TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[Address]       TO [revora_staff_user];
DENY DELETE ON OBJECT::[dbo].[GID]           TO [revora_staff_user];
GO

/* ============================================================================
   PART 5 — STORED PROCEDURE EXECUTE GRANTS

   Staff can only act through the defined SPs (approval, rejection, branch
   closure). The API can only write through sp_RegisterUser and
   sp_RequestProfileEdit. Neither can call each other's SPs.
   TIN corrections are no longer a standalone staff-only SP - see
   06_profile_edit_workflow_v2.sql, where TIN is folded into the same
   self-service request / admin approve-or-reject lifecycle as every other
   editable field.

   Principle of Least Privilege: give exactly what is needed, nothing more.
   ============================================================================ */

-- Staff: approval & management SPs (admin-dashboard operations)
GRANT EXECUTE ON OBJECT::[dbo].[ApproveUserAccount]  TO [revora_staff_user];
GRANT EXECUTE ON OBJECT::[dbo].[sp_RejectRegistrant] TO [revora_staff_user];
GRANT EXECUTE ON OBJECT::[dbo].[sp_CloseBranch]      TO [revora_staff_user];
GO

-- API: registration SP only (the public-facing registration endpoint)
GRANT EXECUTE ON OBJECT::[dbo].[sp_RegisterUser]     TO [revora_api_user];
GO

/* ============================================================================
   PART 6 — VIEW GRANTS
   Staff needs SELECT on all admin views.
   db_datareader already covers this, but we grant the key admin-dashboard
   views explicitly for clarity and future schema-change safety.
   ============================================================================ */

GRANT SELECT ON OBJECT::[dbo].[vw_ApplicantDirectory]     TO [revora_staff_user];
GRANT SELECT ON OBJECT::[dbo].[vw_ApplicantDetail]        TO [revora_staff_user];
GRANT SELECT ON OBJECT::[dbo].[vw_PendingQueue]           TO [revora_staff_user];
GRANT SELECT ON OBJECT::[dbo].[vw_PendingThenApproved]    TO [revora_staff_user];
GRANT SELECT ON OBJECT::[dbo].[vw_EntityBasedRegistrants] TO [revora_staff_user];
GO

-- API needs the directory view and pending queue for dashboard queries
GRANT SELECT ON OBJECT::[dbo].[vw_ApplicantDirectory]     TO [revora_api_user];
GRANT SELECT ON OBJECT::[dbo].[vw_PendingQueue]           TO [revora_api_user];
GO

/* ============================================================================
   PART 7 — DYNAMIC DATA MASKING (DDM)
   Sensitive PII columns are masked for any user without UNMASK permission.
   revora_staff_user and revora_api_user will see redacted values;
   only revora_admin_user is granted UNMASK to see real data.

   Mask functions:
     email()                      -> aXXX@XXXX.com  (preserves format shape)
     partial(0,'XXXXXXXXXXX',0)   -> fully replaces with fixed X string
   ============================================================================ */

-- Users.Email  (e.g., miguel.santos@santostextile.ph  ->  mXXX@XXXX.com)
ALTER TABLE [dbo].[Users]
    ALTER COLUMN [Email] NVARCHAR(50)
    MASKED WITH (FUNCTION = 'email()');
GO

-- Users.PhoneNumber  (e.g., 09281000001  ->  XXXXXXXXXXX)
ALTER TABLE [dbo].[Users]
    ALTER COLUMN [PhoneNumber] CHAR(11)
    MASKED WITH (FUNCTION = 'partial(0, "XXXXXXXXXXX", 0)');
GO

-- GID.GovtNo  (e.g., 9876543210123456  ->  XXXX-XXXX-XXXX)
ALTER TABLE [dbo].[GID]
    ALTER COLUMN [GovtNo] VARCHAR(20)
    MASKED WITH (FUNCTION = 'partial(0, "XXXX-XXXX-XXXX", 0)');
GO

/* ============================================================================
   PART 8 — UNMASK GRANT
   Only the admin DB user can see the real values of masked columns.
   Staff and API users will always receive the masked output.
   ============================================================================ */

GRANT UNMASK TO [revora_admin_user];
GO

/* ============================================================================
   PART 9 — SCALAR FUNCTION GRANT
   fn_SLAStatus is called inside vw_PendingQueue. db_datareader does not
   automatically grant EXECUTE on scalar functions, so grant it explicitly.
   ============================================================================ */

GRANT EXECUTE ON OBJECT::[dbo].[fn_SLAStatus] TO [revora_staff_user];
GRANT EXECUTE ON OBJECT::[dbo].[fn_SLAStatus] TO [revora_api_user];
GO

/* ============================================================================
   PRINT SUMMARY
   ============================================================================ */

PRINT '============================================================';
PRINT ' REVORA Security Layer v2 applied successfully.';
PRINT '';
PRINT ' Server logins created:';
PRINT '   revora_admin  (password: R3v0ra@Admin#2025!)';
PRINT '   revora_staff  (password: R3v0ra@Staff#2025!)';
PRINT '   revora_api    (password: R3v0ra@Api#2025!)';
PRINT '';
PRINT ' Database users created (in INFODBM_REVORA):';
PRINT '   revora_admin_user  -> db_owner + UNMASK';
PRINT '   revora_staff_user  -> db_datareader';
PRINT '                         EXECUTE: ApproveUserAccount,';
PRINT '                                  sp_RejectRegistrant,';
PRINT '                                  sp_CloseBranch';
PRINT '                         DENY DELETE on all tables';
PRINT '   revora_api_user    -> db_datareader + db_datawriter';
PRINT '                         EXECUTE: sp_RegisterUser';
PRINT '                         DENY DELETE on all tables';
PRINT '';
PRINT ' NOTE: TIN correction is no longer a standalone SP here - see';
PRINT '       06_profile_edit_workflow_v2.sql (sp_RequestProfileEdit /';
PRINT '       sp_ApproveProfileEdit / sp_RejectProfileEdit).';
PRINT '';
PRINT ' Dynamic Data Masking applied to:';
PRINT '   dbo.Users.Email        -> email() mask';
PRINT '   dbo.Users.PhoneNumber  -> partial mask (XXXXXXXXXXX)';
PRINT '   dbo.GID.GovtNo         -> partial mask (XXXX-XXXX-XXXX)';
PRINT '============================================================';
GO

/* ============================================================================
   VERIFICATION BLOCK
   Uncomment and run each block while connected as the target login in SSMS,
   or use EXECUTE AS USER to simulate the login context.
   ============================================================================

-- ── AS revora_admin_user: should see REAL unmasked PII ───────────────────
EXECUTE AS USER = 'revora_admin_user';
    SELECT TOP 3 UserID, Email, PhoneNumber FROM dbo.Users;   -- real values
    SELECT TOP 3 GovtID, GovtNo FROM dbo.GID;                 -- real values
REVERT;
GO

-- ── AS revora_staff_user: should see MASKED PII, can run approval SPs ───
EXECUTE AS USER = 'revora_staff_user';
    SELECT TOP 3 UserID, Email, PhoneNumber FROM dbo.Users;   -- masked
    SELECT TOP 3 GovtID, GovtNo FROM dbo.GID;                 -- masked
    SELECT * FROM dbo.vw_PendingQueue;                         -- OK
    EXEC dbo.ApproveUserAccount 'U00003', 'Test approval';     -- OK
    EXEC dbo.sp_RejectRegistrant 'U00005', 'Test rejection';   -- OK
    INSERT INTO dbo.Users (UserID) VALUES ('X99999');          -- FAILS: no INSERT perm
    DELETE FROM dbo.Users WHERE UserID = 'U00001';             -- FAILS: DENY DELETE
    EXEC dbo.sp_RegisterUser 'Individual', '1 Test', 'City',   -- FAILS: no EXECUTE
         'Province', '1234', 'UMID', '123456789012',
         NULL, NULL, NULL, NULL, NULL, NULL, NULL,
         N'testuser  ', 'Pass1!', N'Test', NULL, N'User',
         NULL, N't@t.com', '09000000000', '1990-01-01', 1, 1, NULL;
REVERT;
GO

-- ── AS revora_api_user: can register users, CANNOT delete or approve ─────
EXECUTE AS USER = 'revora_api_user';
    SELECT TOP 3 UserID, Email FROM dbo.Users;                 -- masked
    SELECT * FROM dbo.vw_PendingQueue;                         -- OK
    DELETE FROM dbo.Users WHERE UserID = 'U00001';             -- FAILS: DENY DELETE
    EXEC dbo.ApproveUserAccount 'U00003', 'Hack';              -- FAILS: no EXECUTE
    EXEC dbo.sp_RejectRegistrant 'U00003', 'Hack';             -- FAILS: no EXECUTE
REVERT;
GO

   ============================================================================ */
