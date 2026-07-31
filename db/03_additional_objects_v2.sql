/* ============================================================================
   REVORA - ADDITIONAL OBJECTS v2 (layered on top of 01_schema_v2.sql)
   Adds:
     - ApproveUserAccount, sp_RejectRegistrant  (approval gatekeepers)
     - sp_RegisterUser                          (registration transaction)
     - sp_CloseBranch                           (Branch Closure workflow)
     - fn_SLAStatus                             (On Track / Due Soon / Overdue)
     - vw_ApplicantDirectory, vw_ApplicantDetail (admin search/review screens)
     - vw_PendingThenApproved (INTERSECT), vw_EntityBasedRegistrants (EXCEPT)
   ============================================================================ */

USE [INFODBM_REVORA];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ============================================================================
   1. ApproveUserAccount / sp_RejectRegistrant - approval gatekeepers.
   Neither touches AuditLog directly: trg_AuditLog_UserStatusUpdate already
   logs the status change; these just decide whether the UPDATE is allowed
   and let admins overwrite the trigger's generic remark with their own note.
   ============================================================================ */
IF OBJECT_ID('dbo.ApproveUserAccount', 'P') IS NOT NULL DROP PROCEDURE dbo.ApproveUserAccount;
GO
CREATE PROC [dbo].[ApproveUserAccount]
    @TargetUserID  CHAR(6),
    @ApprovalNotes VARCHAR(250)
AS
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;

            IF NOT EXISTS (SELECT 1 FROM Users WHERE UserID = @TargetUserID AND StatusID = 1)
                RAISERROR('Cannot approve: user ''%s'' is not Pending or does not exist.', 16, 1, @TargetUserID);

            UPDATE Users
            SET StatusID = 2, ApprovedAt = GETDATE()
            WHERE UserID = @TargetUserID;

            UPDATE AuditLog
            SET Remarks = @ApprovalNotes
            WHERE LogID = (
                SELECT TOP 1 LogID FROM AuditLog
                WHERE UserID = @TargetUserID AND AdminAction = 'Approved'
                ORDER BY ActionTimestamp DESC
            );

        COMMIT TRANSACTION;
        PRINT 'Done! User ' + @TargetUserID + ' approved successfully.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT 'Error! Everything was cancelled.';
        PRINT 'System Reason: ' + ERROR_MESSAGE();
    END CATCH
END;
GO

IF OBJECT_ID('dbo.sp_RejectRegistrant', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_RejectRegistrant;
GO
CREATE PROCEDURE dbo.sp_RejectRegistrant
    @TargetUserID   CHAR(6),
    @RejectionNotes VARCHAR(250) = NULL
AS
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;

            IF NOT EXISTS (SELECT 1 FROM Users WHERE UserID = @TargetUserID AND StatusID = 1)
                RAISERROR('Cannot reject: user ''%s'' is not Pending or does not exist.', 16, 1, @TargetUserID);

            UPDATE Users SET StatusID = 3 WHERE UserID = @TargetUserID;

            IF @RejectionNotes IS NOT NULL
                UPDATE AuditLog
                SET Remarks = @RejectionNotes
                WHERE LogID = (
                    SELECT TOP 1 LogID FROM AuditLog
                    WHERE UserID = @TargetUserID AND AdminAction = 'Rejected'
                    ORDER BY ActionTimestamp DESC
                );

        COMMIT TRANSACTION;
        PRINT 'Done! User ' + @TargetUserID + ' rejected.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT 'Error! Everything was cancelled.';
        PRINT 'System Reason: ' + ERROR_MESSAGE();
        THROW;
    END CATCH
END;
GO

/* ============================================================================
   2. sp_RegisterUser - full registration transaction (flat Address/Branches).
   Address -> GID -> [Branches -> Entities] -> Users, all-or-nothing.
   ============================================================================ */
IF OBJECT_ID('dbo.sp_RegisterUser', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_RegisterUser;
GO
CREATE PROCEDURE dbo.sp_RegisterUser
    @AccountType        VARCHAR(10),      -- 'Individual' or 'Entity'
    -- personal address
    @DetailedHome        NVARCHAR(250),
    @City                NVARCHAR(50),
    @Province             NVARCHAR(50),
    @PostalCode           CHAR(4),
    -- government ID
    @GovtType             VARCHAR(15),
    @GovtNo               VARCHAR(20),
    -- entity-only (NULL/ignored when @AccountType = 'Individual')
    @BranchCode           CHAR(5)        = NULL,
    @BranchDetailedAddr   NVARCHAR(250)  = NULL,
    @BranchCity           NVARCHAR(50)   = NULL,
    @BranchPostalCode     CHAR(4)        = NULL,
    @EntityName           NVARCHAR(50)   = NULL,
    @TIN                  NCHAR(11)      = NULL,
    @SectorID              CHAR(6)        = NULL,
    -- user
    @Username             NCHAR(10),
    @PlainPassword        VARCHAR(100),
    @FirstName             NVARCHAR(50),
    @MiddleName            NVARCHAR(50)   = NULL,
    @LastName              NVARCHAR(50),
    @Suffix                NVARCHAR(50)   = NULL,
    @Email                 NVARCHAR(50),
    @PhoneNumber           CHAR(11),
    @BirthDate             DATE,
    @RoleID                BIT,
    @CategoryID            TINYINT,
    @NewUserID             CHAR(6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION RegisterUser;

        DECLARE @AddressID CHAR(6);
        DECLARE @GovtID    CHAR(6);
        DECLARE @BranchID  CHAR(6);
        DECLARE @EntityID  CHAR(6);

        /* ── Address ── */
        SET @AddressID = 'A' + RIGHT('00000' + CAST(
            ISNULL((SELECT MAX(CAST(SUBSTRING(AddressID, 2, 5) AS INT)) FROM dbo.Address), 0) + 1
        AS VARCHAR), 5);
        INSERT INTO dbo.Address (AddressID, DetailedHome, City, Province, PostalCode)
        VALUES (@AddressID, @DetailedHome, @City, @Province, @PostalCode);

        /* ── Government ID ── */
        SET @GovtID = 'G' + RIGHT('00000' + CAST(
            ISNULL((SELECT MAX(CAST(SUBSTRING(GovtID, 2, 5) AS INT)) FROM dbo.GID), 0) + 1
        AS VARCHAR), 5);
        INSERT INTO dbo.GID (GovtID, GovtType, GovtNo)
        VALUES (@GovtID, @GovtType, @GovtNo);

        IF @AccountType = 'Entity'
        BEGIN
            /* ── Branch ── */
            SET @BranchID = 'B' + RIGHT('00000' + CAST(
                ISNULL((SELECT MAX(CAST(SUBSTRING(BranchID, 2, 5) AS INT)) FROM dbo.Branches), 0) + 1
            AS VARCHAR), 5);
            INSERT INTO dbo.Branches (BranchID, BranchCode, DetailedAddress, City, PostalCode)
            VALUES (@BranchID, @BranchCode, @BranchDetailedAddr, @BranchCity, @BranchPostalCode);

            /* ── Entity ── */
            SET @EntityID = 'E' + RIGHT('00000' + CAST(
                ISNULL((SELECT MAX(CAST(SUBSTRING(EntityID, 2, 5) AS INT)) FROM dbo.Entities), 0) + 1
            AS VARCHAR), 5);
            INSERT INTO dbo.Entities (EntityID, EntityName, TIN, SectorID, BranchID)
            VALUES (@EntityID, @EntityName, @TIN, @SectorID, @BranchID);
        END

        /* ── User ── */
        SET @NewUserID = 'U' + RIGHT('00000' + CAST(
            ISNULL((SELECT MAX(CAST(SUBSTRING(UserID, 2, 5) AS INT)) FROM dbo.Users), 0) + 1
        AS VARCHAR), 5);

        INSERT INTO dbo.Users (
            UserID, Username, Password, FirstName, MiddleName, LastName, Suffix,
            Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID,
            EntityID, CategoryID, ApprovedAt
        )
        VALUES (
            @NewUserID, @Username, CONVERT(VARBINARY(100), @PlainPassword), @FirstName, @MiddleName, @LastName, @Suffix,
            @Email, @PhoneNumber, @BirthDate, @AddressID, @RoleID, @GovtID, 1,
            CASE WHEN @AccountType = 'Entity' THEN @EntityID ELSE NULL END,
            @CategoryID, NULL
        );

        COMMIT TRANSACTION RegisterUser;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION RegisterUser;
        THROW;
    END CATCH
END;

GO

/* ============================================================================
   3. sp_CloseBranch - Branch Closure workflow (Section F, queries 17-20).
   (17) confirm branch exists -> (18) close the affected user's account ->
   (19) unlink the entity from the branch -> (20) delete the branch record.
   ============================================================================ */
IF OBJECT_ID('dbo.sp_CloseBranch', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_CloseBranch;
GO
CREATE PROCEDURE dbo.sp_CloseBranch
    @BranchID CHAR(6)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION CloseBranch;

        -- (17) confirm the branch exists
        IF NOT EXISTS (SELECT 1 FROM Branches WHERE BranchID = @BranchID)
            RAISERROR('Cannot close: branch ''%s'' does not exist.', 16, 1, @BranchID);

        DECLARE @EntityID CHAR(6) = (SELECT EntityID FROM Entities WHERE BranchID = @BranchID);

        -- (18) close the account(s) of the representative(s) tied to this entity
        UPDATE Users
        SET StatusID = 6
        WHERE EntityID = @EntityID AND StatusID NOT IN (5, 6);

        -- (19) unplug the entity from the branch before deleting it
        UPDATE Entities SET BranchID = NULL WHERE BranchID = @BranchID;

        -- (20) remove the branch record now that nothing references it
        DELETE FROM Branches WHERE BranchID = @BranchID;

        COMMIT TRANSACTION CloseBranch;
        PRINT 'Done! Branch ' + @BranchID + ' closed successfully.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION CloseBranch;
        THROW;
    END CATCH
END;
GO

/* ============================================================================
   4. fn_SLAStatus - SLA / processing-time flag
   ============================================================================ */
IF OBJECT_ID('dbo.fn_SLAStatus', 'FN') IS NOT NULL DROP FUNCTION dbo.fn_SLAStatus;
GO
CREATE FUNCTION dbo.fn_SLAStatus (@CreatedAt DATETIME, @StatusID TINYINT)
RETURNS VARCHAR(20)
AS
BEGIN
    DECLARE @Result VARCHAR(20);
    DECLARE @HoursElapsed INT = DATEDIFF(HOUR, @CreatedAt, GETDATE());

    IF @StatusID <> 1                    SET @Result = 'N/A';
    ELSE IF @HoursElapsed <= 72          SET @Result = 'On Track';
    ELSE IF @HoursElapsed <= 120         SET @Result = 'Due Soon';
    ELSE                                 SET @Result = 'Overdue';

    RETURN @Result;
END;
GO

/* ============================================================================
   5. vw_ApplicantDirectory - flattened search/browse view (flat address)
   ============================================================================ */
IF OBJECT_ID('dbo.vw_ApplicantDirectory', 'V') IS NOT NULL DROP VIEW dbo.vw_ApplicantDirectory;
GO
CREATE VIEW dbo.vw_ApplicantDirectory AS
SELECT
    u.UserID,
    u.Username,
    u.FirstName + ' ' + ISNULL(u.MiddleName + ' ', '') + u.LastName + ISNULL(' ' + u.Suffix, '') AS FullName,
    u.Email,
    u.PhoneNumber,
    r.RoleName,
    c.CategoryName,
    s.StatusID,
    s.StatusName,
    e.EntityName,
    e.TIN,
    e.BranchID,
    sec.SectorName,
    g.GovtType,
    g.GovtNo,
    u.CreatedAt,
    u.ApprovedAt
FROM dbo.Users u
JOIN dbo.Roles          r   ON u.RoleID     = r.RoleID
JOIN dbo.Categories     c   ON u.CategoryID = c.CategoryID
JOIN dbo.AccountStatus  s   ON u.StatusID   = s.StatusID
JOIN dbo.GID            g   ON u.GovtID     = g.GovtID
LEFT JOIN dbo.Entities  e   ON u.EntityID   = e.EntityID
LEFT JOIN dbo.Sectors   sec ON e.SectorID   = sec.SectorID;
GO

/* ============================================================================
   6. vw_ApplicantDetail - full applicant profile for admin review (F.14)
   ============================================================================ */
IF OBJECT_ID('dbo.vw_ApplicantDetail', 'V') IS NOT NULL DROP VIEW dbo.vw_ApplicantDetail;
GO
CREATE VIEW dbo.vw_ApplicantDetail AS
SELECT
    u.UserID,
    u.Username,
    u.FirstName, u.MiddleName, u.LastName, u.Suffix,
    u.Email, u.PhoneNumber, u.BirthDate, u.CreatedAt, u.ApprovedAt,
    r.RoleName,
    c.CategoryName,
    s.StatusID, s.StatusName,
    g.GovtType, g.GovtNo,
    a.DetailedHome, a.City AS HomeCity, a.Province AS HomeProvince, a.PostalCode AS HomePostalCode,
    e.EntityName, e.TIN,
    sec.SectorName,
    br.BranchID, br.BranchCode, br.DetailedAddress AS BranchDetailedAddress,
    br.City AS BranchCity, br.PostalCode AS BranchPostalCode
FROM dbo.Users u
JOIN dbo.Roles          r   ON u.RoleID     = r.RoleID
JOIN dbo.Categories     c   ON u.CategoryID = c.CategoryID
JOIN dbo.AccountStatus  s   ON u.StatusID   = s.StatusID
JOIN dbo.GID            g   ON u.GovtID     = g.GovtID
JOIN dbo.Address        a   ON u.Address    = a.AddressID
LEFT JOIN dbo.Entities  e   ON u.EntityID   = e.EntityID
LEFT JOIN dbo.Sectors   sec ON e.SectorID   = sec.SectorID
LEFT JOIN dbo.Branches  br  ON e.BranchID   = br.BranchID;
GO

/* ============================================================================
   7. Set-based demo views (Section F, queries 1-2)
   ============================================================================ */
IF OBJECT_ID('dbo.vw_PendingThenApproved', 'V') IS NOT NULL DROP VIEW dbo.vw_PendingThenApproved;
GO
-- (1) Users who have BOTH a "Pending" and an "Approved" audit log entry -
-- i.e. accounts whose registration lifecycle has progressed through the
-- approval pipeline (not still-pending, not rejected-only).
CREATE VIEW dbo.vw_PendingThenApproved AS
    SELECT UserID FROM AuditLog WHERE AdminAction = 'Pending'
    INTERSECT
    SELECT UserID FROM AuditLog WHERE AdminAction = 'Approved';
GO

IF OBJECT_ID('dbo.vw_EntityBasedRegistrants', 'V') IS NOT NULL DROP VIEW dbo.vw_EntityBasedRegistrants;
GO
-- (2) Users who hold an existing EntityID - entity-based registrants,
-- isolated from individuals by subtracting the NULL-EntityID pool.
CREATE VIEW dbo.vw_EntityBasedRegistrants AS
    SELECT UserID FROM Users
    EXCEPT
    SELECT UserID FROM Users WHERE EntityID IS NULL;
GO

PRINT '============================================================';
PRINT ' Additional REVORA objects v2 created successfully.';
PRINT '============================================================';
GO
