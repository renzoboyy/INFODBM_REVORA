/* ============================================================================
   REVORA - ADDITIONAL OBJECTS v3 (layered on top of 01_schema_v3.sql)
   Adds:
     - sp_ResolveAddress                         (geography find-or-create helper)
     - ApproveUserAccount, sp_RejectRegistrant    (approval gatekeepers)
     - sp_RegisterUser                           (registration transaction)
     - fn_SLAStatus                              (On Track / Due Soon / Overdue)
     - vw_ApplicantDirectory, vw_ApplicantDetail  (admin search/review screens)
     - vw_PendingThenApproved (INTERSECT), vw_EntityBasedRegistrants (EXCEPT)

   App-compatibility note: the Node app's registration/profile-edit forms only
   collect DetailedAddress/City/Province/PostalCode (no Barangay or Region
   field exists in the UI yet - see registrant.html). sp_RegisterUser therefore
   takes @Region/@Barangay/@BranchRegion/@BranchBarangay as OPTIONAL parameters
   defaulting to 'Unspecified', so server/routes/registration.js needs no
   changes. Every barangay physically shares the postal code passed in, so
   City+PostalCode is still enough to disambiguate day-to-day; only the
   Region/Barangay *names* are placeholders until the UI grows real geography
   pickers, at which point only the client payload changes - the schema
   already has the correct shape.
   ============================================================================ */

USE [INFODBM_REVORA];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ============================================================================
   0. sp_ResolveAddress - find-or-create across the geography hierarchy and
   return an AddressID. Shared by sp_RegisterUser here and sp_ApproveProfileEdit
   in 06_profile_edit_workflow_v3.sql, so the hierarchy is only ever walked in
   one place.
   ============================================================================ */
IF OBJECT_ID('dbo.sp_ResolveAddress', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_ResolveAddress;
GO
CREATE PROCEDURE dbo.sp_ResolveAddress
    @RegionName      NVARCHAR(50),
    @ProvinceName    NVARCHAR(50),
    @CityName        NVARCHAR(50),
    @BarangayName    NVARCHAR(50),
    @PostalCode      CHAR(4),
    @DetailedAddress NVARCHAR(250),
    @AddressID       CHAR(6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RegionID INT, @ProvinceID INT, @CityID INT, @BarangayID INT;

    SELECT @RegionID = RegionID FROM dbo.Region WHERE RegionName = @RegionName;
    IF @RegionID IS NULL
    BEGIN
        INSERT INTO dbo.Region (RegionName) VALUES (@RegionName);
        SET @RegionID = SCOPE_IDENTITY();
    END

    SELECT @ProvinceID = ProvinceID FROM dbo.Province WHERE ProvinceName = @ProvinceName AND RegionID = @RegionID;
    IF @ProvinceID IS NULL
    BEGIN
        INSERT INTO dbo.Province (RegionID, ProvinceName) VALUES (@RegionID, @ProvinceName);
        SET @ProvinceID = SCOPE_IDENTITY();
    END

    SELECT @CityID = CityID FROM dbo.CityMunicipality WHERE CityName = @CityName AND ProvinceID = @ProvinceID;
    IF @CityID IS NULL
    BEGIN
        INSERT INTO dbo.CityMunicipality (ProvinceID, CityName) VALUES (@ProvinceID, @CityName);
        SET @CityID = SCOPE_IDENTITY();
    END

    SELECT @BarangayID = BarangayID FROM dbo.Barangay WHERE BarangayName = @BarangayName AND CityID = @CityID;
    IF @BarangayID IS NULL
    BEGIN
        INSERT INTO dbo.Barangay (CityID, BarangayName, PostalCode) VALUES (@CityID, @BarangayName, @PostalCode);
        SET @BarangayID = SCOPE_IDENTITY();
    END
    ELSE IF (SELECT PostalCode FROM dbo.Barangay WHERE BarangayID = @BarangayID) <> @PostalCode
    BEGIN
        UPDATE dbo.Barangay SET PostalCode = @PostalCode WHERE BarangayID = @BarangayID;
    END

    SELECT @AddressID = AddressID FROM dbo.Address WHERE DetailedAddress = @DetailedAddress AND BarangayID = @BarangayID;
    IF @AddressID IS NULL
    BEGIN
        SET @AddressID = 'A' + RIGHT('00000' + CAST(
            ISNULL((SELECT MAX(CAST(SUBSTRING(AddressID, 2, 5) AS INT)) FROM dbo.Address), 0) + 1
        AS VARCHAR), 5);
        INSERT INTO dbo.Address (AddressID, BarangayID, DetailedAddress)
        VALUES (@AddressID, @BarangayID, @DetailedAddress);
    END
END;
GO

/* ============================================================================
   1. ApproveUserAccount / sp_RejectRegistrant - approval gatekeepers.
   Unchanged from v2 (no Address/Branch involvement).
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
   2. sp_RegisterUser - full registration transaction (merged Address/Branch).
   Address -> GID -> [Branch(Address) -> Entities] -> Users, all-or-nothing.
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
    @BranchDetailedAddr   NVARCHAR(250)  = NULL,
    @BranchCity           NVARCHAR(50)   = NULL,
    @BranchProvince       NVARCHAR(50)   = NULL,
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
    @NewUserID             CHAR(6) OUTPUT,
    -- geography hierarchy: not yet collected by the UI (registrant.html has
    -- no Barangay/Region field), so these default to placeholders. Pass real
    -- values once the front-end grows the corresponding inputs.
    @Region               NVARCHAR(50)   = 'Unspecified',
    @Barangay             NVARCHAR(50)   = 'Unspecified',
    @BranchRegion         NVARCHAR(50)   = 'Unspecified',
    @BranchBarangay       NVARCHAR(50)   = 'Unspecified'
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION RegisterUser;

        DECLARE @AddressID       CHAR(6);
        DECLARE @BranchAddressID CHAR(6);
        DECLARE @GovtID          CHAR(6);
        DECLARE @BranchID        CHAR(6);
        DECLARE @EntityID        CHAR(6);

        /* ── Address (personal) ── */
        EXEC dbo.sp_ResolveAddress
            @RegionName = @Region, @ProvinceName = @Province, @CityName = @City,
            @BarangayName = @Barangay, @PostalCode = @PostalCode, @DetailedAddress = @DetailedHome,
            @AddressID = @AddressID OUTPUT;

        /* ── Government ID ── */
        SET @GovtID = 'G' + RIGHT('00000' + CAST(
            ISNULL((SELECT MAX(CAST(SUBSTRING(GovtID, 2, 5) AS INT)) FROM dbo.GID), 0) + 1
        AS VARCHAR), 5);
        INSERT INTO dbo.GID (GovtID, GovtType, GovtNo)
        VALUES (@GovtID, @GovtType, @GovtNo);

        IF @AccountType = 'Entity'
        BEGIN
            /* ── Address (branch) ──
               EXEC's named-parameter syntax only accepts a literal, a
               variable, or DEFAULT as the value - not an arbitrary
               expression - so the ISNULL fallback has to be computed into
               a variable first. */
            DECLARE @ResolvedBranchProvince NVARCHAR(50) = ISNULL(@BranchProvince, @Province);

            EXEC dbo.sp_ResolveAddress
                @RegionName = @BranchRegion, @ProvinceName = @ResolvedBranchProvince,
                @CityName = @BranchCity, @BarangayName = @BranchBarangay, @PostalCode = @BranchPostalCode,
                @DetailedAddress = @BranchDetailedAddr, @AddressID = @BranchAddressID OUTPUT;

            /* ── Branch ── */
            SET @BranchID = 'B' + RIGHT('00000' + CAST(
                ISNULL((SELECT MAX(CAST(SUBSTRING(BranchID, 2, 5) AS INT)) FROM dbo.Branch), 0) + 1
            AS VARCHAR), 5);
            INSERT INTO dbo.Branch (BranchID, AddressID)
            VALUES (@BranchID, @BranchAddressID);

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
   3. fn_SLAStatus - SLA / processing-time flag (unchanged from v2)
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
   4. vw_ApplicantDirectory - flattened search/browse view.
   Unchanged column list from v2 (never selected Address/Branch address
   fields directly - just Entities.BranchID as an identifier).
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
   5. vw_ApplicantDetail - full applicant profile for admin review (F.14).
   Reads City/Province/PostalCode through the new geography hierarchy instead
   of flat columns. Column aliases (HomeCity, HomeProvince, HomePostalCode,
   BranchDetailedAddress, BranchCity, BranchPostalCode) are kept identical to
   v2 so the existing app code needs no changes; BranchCode is dropped (the
   app layer must stop reading it - see server/routes/admin.js, public/js/
   app.js, public/js/dashboard.js).
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
    a.DetailedAddress AS DetailedHome,
    hbg.BarangayName  AS HomeBarangay,
    hcm.CityName       AS HomeCity,
    hpv.ProvinceName   AS HomeProvince,
    hrg.RegionName     AS HomeRegion,
    hbg.PostalCode     AS HomePostalCode,
    e.EntityName, e.TIN,
    sec.SectorName,
    br.BranchID,
    bad.DetailedAddress AS BranchDetailedAddress,
    bbg.BarangayName    AS BranchBarangay,
    bcm.CityName        AS BranchCity,
    bpv.ProvinceName    AS BranchProvince,
    brg.RegionName      AS BranchRegion,
    bbg.PostalCode      AS BranchPostalCode
FROM dbo.Users u
JOIN dbo.Roles              r   ON u.RoleID     = r.RoleID
JOIN dbo.Categories         c   ON u.CategoryID = c.CategoryID
JOIN dbo.AccountStatus      s   ON u.StatusID   = s.StatusID
JOIN dbo.GID                g   ON u.GovtID     = g.GovtID
JOIN dbo.Address            a   ON u.Address    = a.AddressID
JOIN dbo.Barangay           hbg ON a.BarangayID = hbg.BarangayID
JOIN dbo.CityMunicipality   hcm ON hbg.CityID    = hcm.CityID
JOIN dbo.Province           hpv ON hcm.ProvinceID = hpv.ProvinceID
JOIN dbo.Region             hrg ON hpv.RegionID  = hrg.RegionID
LEFT JOIN dbo.Entities      e   ON u.EntityID   = e.EntityID
LEFT JOIN dbo.Sectors       sec ON e.SectorID   = sec.SectorID
LEFT JOIN dbo.Branch        br  ON e.BranchID   = br.BranchID
LEFT JOIN dbo.Address       bad ON br.AddressID = bad.AddressID
LEFT JOIN dbo.Barangay      bbg ON bad.BarangayID = bbg.BarangayID
LEFT JOIN dbo.CityMunicipality bcm ON bbg.CityID = bcm.CityID
LEFT JOIN dbo.Province      bpv ON bcm.ProvinceID = bpv.ProvinceID
LEFT JOIN dbo.Region        brg ON bpv.RegionID  = brg.RegionID;
GO

/* ============================================================================
   6. Set-based demo views (Section F, queries 1-2) - unchanged from v2.
   ============================================================================ */
IF OBJECT_ID('dbo.vw_PendingThenApproved', 'V') IS NOT NULL DROP VIEW dbo.vw_PendingThenApproved;
GO
CREATE VIEW dbo.vw_PendingThenApproved AS
    SELECT UserID FROM AuditLog WHERE AdminAction = 'Pending'
    INTERSECT
    SELECT UserID FROM AuditLog WHERE AdminAction = 'Approved';
GO

IF OBJECT_ID('dbo.vw_EntityBasedRegistrants', 'V') IS NOT NULL DROP VIEW dbo.vw_EntityBasedRegistrants;
GO
CREATE VIEW dbo.vw_EntityBasedRegistrants AS
    SELECT UserID FROM Users
    EXCEPT
    SELECT UserID FROM Users WHERE EntityID IS NULL;
GO

PRINT '============================================================';
PRINT ' Additional REVORA objects v3 created successfully.';
PRINT '============================================================';
GO
