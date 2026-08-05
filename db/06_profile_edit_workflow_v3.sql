/* ============================================================================
   REVORA - SELF-SERVICE PROFILE EDIT -> RE-APPROVAL WORKFLOW v3
   (layered on top of 01_schema_v3.sql, 03_additional_objects_v3.sql,
    04_indexes_and_views_v3.sql, 05_security_v3.sql)

   Ported from 06_profile_edit_workflow_v2.sql onto the v3 schema. Lifecycle
   is unchanged (see v2 header for the full walkthrough); the only functional
   difference is in sp_ApproveProfileEdit, which now RE-RESOLVES the address
   (personal and/or branch) against the geography hierarchy inline (find
   existing row or create it - the same logic sp_RegisterUser uses in
   03_additional_objects_v3.sql; there is no shared sp_ResolveAddress
   procedure) instead of UPDATE-ing Address/Branches columns in place. That's
   a deliberate
   consequence of the merge: Address rows are shareable now, so mutating one
   in place could silently change another user's address too. Applying an
   edit instead finds-or-creates the (possibly new) Address row for the
   updated Detailed/City/Province/PostalCode combination and repoints the
   Users.Address / Branch.AddressID foreign key at it - the old Address row
   is left alone (it may still be in use elsewhere).

   ProfileEditRequests itself is unchanged from v2: staged edits are stored
   as flat NewCity/NewProvince/NewPostalCode/NewBranchCity/etc. text columns,
   not FK'd into the geography hierarchy - they're just proposed values until
   sp_ApproveProfileEdit resolves them.

   Run ONCE, after 01-05 (v3). Safe to re-run: every CREATE is preceded by an
   existence check / DROP, matching the style of the rest of the db/ folder.
   ============================================================================ */

USE [INFODBM_REVORA];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ============================================================================
   0. Retire sp_UpdateEntityTIN - superseded by sp_RequestProfileEdit /
   sp_ApproveProfileEdit / sp_RejectProfileEdit below.
   ============================================================================ */
IF OBJECT_ID('dbo.sp_UpdateEntityTIN', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_UpdateEntityTIN;
GO

/* ============================================================================
   1. ProfileEditRequests - staging table for one outstanding edit per user.
   Unchanged from v2.
   ============================================================================ */
IF OBJECT_ID('dbo.ProfileEditRequests', 'U') IS NOT NULL DROP TABLE dbo.ProfileEditRequests;
GO
CREATE TABLE [dbo].[ProfileEditRequests](
    [EditRequestID]          CHAR(6)       NOT NULL,
    [UserID]                 CHAR(6)       NOT NULL,
    [RequestStatus]          VARCHAR(10)   NOT NULL CONSTRAINT [DF_ProfileEditRequests_Status] DEFAULT ('Pending'),
    [SubmittedAt]            DATETIME      NOT NULL CONSTRAINT [DF_ProfileEditRequests_SubmittedAt] DEFAULT (GETDATE()),
    [ResolvedAt]             DATETIME      NULL,

    -- proposed personal fields
    [NewEmail]               NVARCHAR(50)  NULL,
    [NewPhoneNumber]         CHAR(11)      NULL,
    [NewDetailedHome]        NVARCHAR(250) NULL,
    [NewCity]                NVARCHAR(50)  NULL,
    [NewProvince]            NVARCHAR(50)  NULL,
    [NewPostalCode]          CHAR(4)       NULL,

    -- proposed entity fields (only relevant when the user has an EntityID)
    [NewEntityName]          NVARCHAR(50)  NULL,
    [NewTIN]                 NCHAR(11)     NULL,
    [NewSectorID]            CHAR(6)       NULL,
    [NewBranchDetailedAddr]  NVARCHAR(250) NULL,
    [NewBranchCity]          NVARCHAR(50)  NULL,
    [NewBranchPostalCode]    CHAR(4)       NULL,

    CONSTRAINT [PK_ProfileEditRequests] PRIMARY KEY CLUSTERED ([EditRequestID] ASC),
    CONSTRAINT [CK_ProfileEditRequests_Status] CHECK ([RequestStatus] IN ('Pending', 'Approved', 'Rejected')),
    CONSTRAINT [CK_ProfileEditRequests_PostalCode] CHECK ([NewPostalCode] IS NULL OR [NewPostalCode] LIKE '[0-9][0-9][0-9][0-9]'),
    CONSTRAINT [CK_ProfileEditRequests_BranchPostalCode] CHECK ([NewBranchPostalCode] IS NULL OR [NewBranchPostalCode] LIKE '[0-9][0-9][0-9][0-9]'),
    CONSTRAINT [CK_ProfileEditRequests_TINLength] CHECK ([NewTIN] IS NULL OR LEN(RTRIM([NewTIN])) = 11)
);
GO

ALTER TABLE [dbo].[ProfileEditRequests]
    ADD CONSTRAINT [FK_ProfileEditRequests_Users] FOREIGN KEY ([UserID])
    REFERENCES [dbo].[Users] ([UserID]);
GO

CREATE UNIQUE NONCLUSTERED INDEX [UIX_ProfileEditRequests_UserID_Pending]
    ON [dbo].[ProfileEditRequests] ([UserID] ASC)
    WHERE ([RequestStatus] = 'Pending');
GO

/* ============================================================================
   2. Bug fix: trg_AuditLog_UserStatusUpdate (unchanged from v2)
   ============================================================================ */
IF OBJECT_ID('dbo.trg_AuditLog_UserStatusUpdate', 'TR') IS NOT NULL DROP TRIGGER dbo.trg_AuditLog_UserStatusUpdate;
GO
CREATE TRIGGER [dbo].[trg_AuditLog_UserStatusUpdate]
ON [dbo].[Users]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF UPDATE(StatusID)
    BEGIN
        DECLARE @MaxLogNum INT;
        SELECT @MaxLogNum = ISNULL(MAX(CAST(SUBSTRING(LogID, 2, 8) AS INT)), 0)
        FROM AuditLog;

        INSERT INTO AuditLog (LogID, UserID, AdminAction, ActionTimestamp, Remarks)
        SELECT
            'L' + RIGHT('00000000' + CAST(@MaxLogNum + ROW_NUMBER() OVER (ORDER BY i.UserID) AS VARCHAR), 8),
            i.UserID,
            CASE i.StatusID
                WHEN 1 THEN 'Resubmitted'
                WHEN 2 THEN 'Approved'
                WHEN 3 THEN 'Rejected'
                WHEN 4 THEN 'Suspended'
                WHEN 5 THEN 'Deleted'
                WHEN 6 THEN 'Closed'
            END,
            GETDATE(),
            'Status changed from ' +
                (SELECT StatusName FROM AccountStatus WHERE StatusID = d.StatusID) +
                ' to ' +
                (SELECT StatusName FROM AccountStatus WHERE StatusID = i.StatusID)
        FROM inserted i
        JOIN deleted d ON i.UserID = d.UserID
        WHERE i.StatusID <> d.StatusID;
    END
END;
GO

/* ============================================================================
   3. sp_RequestProfileEdit - stage a proposed edit and re-queue for review.
   Unchanged from v2 (stages flat text only; no Address/Branch writes here).
   ============================================================================ */
IF OBJECT_ID('dbo.sp_RequestProfileEdit', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_RequestProfileEdit;
GO
CREATE PROCEDURE dbo.sp_RequestProfileEdit
    @TargetUserID           CHAR(6),
    @NewEmail               NVARCHAR(50)  = NULL,
    @NewPhoneNumber         CHAR(11)      = NULL,
    @NewDetailedHome        NVARCHAR(250) = NULL,
    @NewCity                NVARCHAR(50)  = NULL,
    @NewProvince            NVARCHAR(50)  = NULL,
    @NewPostalCode          CHAR(4)       = NULL,
    @NewEntityName          NVARCHAR(50)  = NULL,
    @NewTIN                 NCHAR(11)     = NULL,
    @NewSectorID            CHAR(6)       = NULL,
    @NewBranchDetailedAddr  NVARCHAR(250) = NULL,
    @NewBranchCity          NVARCHAR(50)  = NULL,
    @NewBranchPostalCode    CHAR(4)       = NULL,
    @NewRequestID           CHAR(6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION RequestProfileEdit;

        DECLARE @StatusID TINYINT = (SELECT StatusID FROM Users WHERE UserID = @TargetUserID);
        DECLARE @EntityID CHAR(6) = (SELECT EntityID FROM Users WHERE UserID = @TargetUserID);

        IF @StatusID IS NULL
            RAISERROR('User ''%s'' does not exist.', 16, 1, @TargetUserID);

        IF @StatusID <> 2
            RAISERROR('Only Approved accounts may submit an edit; account ''%s'' is not currently Approved.', 16, 1, @TargetUserID);

        IF EXISTS (SELECT 1 FROM ProfileEditRequests WHERE UserID = @TargetUserID AND RequestStatus = 'Pending')
            RAISERROR('An edit request for user ''%s'' is already pending review.', 16, 1, @TargetUserID);

        IF @EntityID IS NULL AND (
            @NewEntityName IS NOT NULL OR @NewTIN IS NOT NULL OR @NewSectorID IS NOT NULL OR
            @NewBranchDetailedAddr IS NOT NULL OR @NewBranchCity IS NOT NULL OR @NewBranchPostalCode IS NOT NULL
        )
            RAISERROR('User ''%s'' has no linked entity to edit.', 16, 1, @TargetUserID);

        SET @NewRequestID = 'R' + RIGHT('00000' + CAST(
            ISNULL((SELECT MAX(CAST(SUBSTRING(EditRequestID, 2, 5) AS INT)) FROM dbo.ProfileEditRequests), 0) + 1
        AS VARCHAR), 5);

        INSERT INTO dbo.ProfileEditRequests (
            EditRequestID, UserID, RequestStatus,
            NewEmail, NewPhoneNumber, NewDetailedHome, NewCity, NewProvince, NewPostalCode,
            NewEntityName, NewTIN, NewSectorID, NewBranchDetailedAddr, NewBranchCity, NewBranchPostalCode
        )
        VALUES (
            @NewRequestID, @TargetUserID, 'Pending',
            @NewEmail, @NewPhoneNumber, @NewDetailedHome, @NewCity, @NewProvince, @NewPostalCode,
            @NewEntityName, @NewTIN, @NewSectorID, @NewBranchDetailedAddr, @NewBranchCity, @NewBranchPostalCode
        );

        UPDATE Users SET StatusID = 1 WHERE UserID = @TargetUserID;

        COMMIT TRANSACTION RequestProfileEdit;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION RequestProfileEdit;
        THROW;
    END CATCH
END;
GO

/* ============================================================================
   4. sp_ApproveProfileEdit - "the admin profile edit procedure".
   CHANGED from v2: address changes are applied by RE-RESOLVING against the
   geography hierarchy inline and repointing the FK, not by UPDATE-ing
   Address/Branch columns in place (those columns no longer exist flat on
   either table, and mutating a shared Address row in place would affect
   every other record pointing at it).
   ============================================================================ */
IF OBJECT_ID('dbo.sp_ApproveProfileEdit', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_ApproveProfileEdit;
GO
CREATE PROCEDURE dbo.sp_ApproveProfileEdit
    @EditRequestID  CHAR(6),
    @ApprovalNotes  VARCHAR(250) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION ApproveProfileEdit;

        IF NOT EXISTS (SELECT 1 FROM ProfileEditRequests WHERE EditRequestID = @EditRequestID AND RequestStatus = 'Pending')
            RAISERROR('Cannot approve: edit request ''%s'' does not exist or is not Pending.', 16, 1, @EditRequestID);

        DECLARE @TargetUserID CHAR(6), @AddressID CHAR(6), @EntityID CHAR(6), @BranchID CHAR(6);
        SELECT
            @TargetUserID = per.UserID,
            @AddressID    = u.Address,
            @EntityID     = u.EntityID
        FROM ProfileEditRequests per
        JOIN Users u ON per.UserID = u.UserID
        WHERE per.EditRequestID = @EditRequestID;

        SET @BranchID = (SELECT BranchID FROM Entities WHERE EntityID = @EntityID);

        -- Email/PhoneNumber are Dynamic Data Masked (05_security_v3.sql). Read
        -- the proposed values from the (unmasked) staging table into
        -- variables and only write a column when its new value is actually
        -- provided - never read Users.Email/PhoneNumber back to "preserve" them.
        DECLARE @NewEmailVal NVARCHAR(50), @NewPhoneVal CHAR(11);
        DECLARE @NewDetailedHome NVARCHAR(250), @NewCity NVARCHAR(50), @NewProvince NVARCHAR(50), @NewPostalCode CHAR(4);
        DECLARE @NewEntityName NVARCHAR(50), @NewTIN NCHAR(11), @NewSectorID CHAR(6);
        DECLARE @NewBranchDetailedAddr NVARCHAR(250), @NewBranchCity NVARCHAR(50), @NewBranchPostalCode CHAR(4);

        SELECT
            @NewEmailVal = NewEmail, @NewPhoneVal = NewPhoneNumber,
            @NewDetailedHome = NewDetailedHome, @NewCity = NewCity, @NewProvince = NewProvince, @NewPostalCode = NewPostalCode,
            @NewEntityName = NewEntityName, @NewTIN = NewTIN, @NewSectorID = NewSectorID,
            @NewBranchDetailedAddr = NewBranchDetailedAddr, @NewBranchCity = NewBranchCity, @NewBranchPostalCode = NewBranchPostalCode
        FROM ProfileEditRequests WHERE EditRequestID = @EditRequestID;

        IF @NewEmailVal IS NOT NULL
            UPDATE Users SET Email = @NewEmailVal WHERE UserID = @TargetUserID;

        IF @NewPhoneVal IS NOT NULL
            UPDATE Users SET PhoneNumber = @NewPhoneVal WHERE UserID = @TargetUserID;

        /* ── Personal address: re-resolve only if any address field changed ── */
        IF @NewDetailedHome IS NOT NULL OR @NewCity IS NOT NULL OR @NewProvince IS NOT NULL OR @NewPostalCode IS NOT NULL
        BEGIN
            DECLARE @CurDetailed NVARCHAR(250), @CurBarangay NVARCHAR(50), @CurCity NVARCHAR(50), @CurProvince NVARCHAR(50), @CurRegion NVARCHAR(50), @CurPostal CHAR(4);
            SELECT
                @CurDetailed = a.DetailedAddress, @CurBarangay = bg.BarangayName,
                @CurCity = cm.CityName, @CurProvince = pv.ProvinceName, @CurRegion = rg.RegionName, @CurPostal = bg.PostalCode
            FROM Address a
            JOIN Barangay bg ON a.BarangayID = bg.BarangayID
            JOIN CityMunicipality cm ON bg.CityID = cm.CityID
            JOIN Province pv ON cm.ProvinceID = pv.ProvinceID
            JOIN Region rg ON pv.RegionID = rg.RegionID
            WHERE a.AddressID = @AddressID;

            -- EXEC's named-parameter syntax only accepts a literal, a
            -- variable, or DEFAULT as the value - not an arbitrary
            -- expression - so each COALESCE fallback is computed into a
            -- variable first.
            DECLARE @ResolvedProvince NVARCHAR(50) = COALESCE(@NewProvince, @CurProvince);
            DECLARE @ResolvedCity NVARCHAR(50) = COALESCE(@NewCity, @CurCity);
            DECLARE @ResolvedPostalCode CHAR(4) = COALESCE(@NewPostalCode, @CurPostal);
            DECLARE @ResolvedDetailedHome NVARCHAR(250) = COALESCE(@NewDetailedHome, @CurDetailed);

            /* ── Find-or-create across the geography hierarchy, inline
               (same logic as sp_RegisterUser; no shared stored proc). ── */
            DECLARE @NewHomeAddressID CHAR(6);
            DECLARE @HomeRegionID INT, @HomeProvinceID INT, @HomeCityID INT, @HomeBarangayID INT;

            SELECT @HomeRegionID = RegionID FROM dbo.Region WHERE RegionName = @CurRegion;
            IF @HomeRegionID IS NULL
            BEGIN
                INSERT INTO dbo.Region (RegionName) VALUES (@CurRegion);
                SET @HomeRegionID = SCOPE_IDENTITY();
            END

            SELECT @HomeProvinceID = ProvinceID FROM dbo.Province WHERE ProvinceName = @ResolvedProvince AND RegionID = @HomeRegionID;
            IF @HomeProvinceID IS NULL
            BEGIN
                INSERT INTO dbo.Province (RegionID, ProvinceName) VALUES (@HomeRegionID, @ResolvedProvince);
                SET @HomeProvinceID = SCOPE_IDENTITY();
            END

            SELECT @HomeCityID = CityID FROM dbo.CityMunicipality WHERE CityName = @ResolvedCity AND ProvinceID = @HomeProvinceID;
            IF @HomeCityID IS NULL
            BEGIN
                INSERT INTO dbo.CityMunicipality (ProvinceID, CityName) VALUES (@HomeProvinceID, @ResolvedCity);
                SET @HomeCityID = SCOPE_IDENTITY();
            END

            SELECT @HomeBarangayID = BarangayID FROM dbo.Barangay WHERE BarangayName = @CurBarangay AND CityID = @HomeCityID;
            IF @HomeBarangayID IS NULL
            BEGIN
                INSERT INTO dbo.Barangay (CityID, BarangayName, PostalCode) VALUES (@HomeCityID, @CurBarangay, @ResolvedPostalCode);
                SET @HomeBarangayID = SCOPE_IDENTITY();
            END
            ELSE IF (SELECT PostalCode FROM dbo.Barangay WHERE BarangayID = @HomeBarangayID) <> @ResolvedPostalCode
            BEGIN
                UPDATE dbo.Barangay SET PostalCode = @ResolvedPostalCode WHERE BarangayID = @HomeBarangayID;
            END

            SELECT @NewHomeAddressID = AddressID FROM dbo.Address WHERE DetailedAddress = @ResolvedDetailedHome AND BarangayID = @HomeBarangayID;
            IF @NewHomeAddressID IS NULL
            BEGIN
                SET @NewHomeAddressID = 'A' + RIGHT('00000' + CAST(
                    ISNULL((SELECT MAX(CAST(SUBSTRING(AddressID, 2, 5) AS INT)) FROM dbo.Address), 0) + 1
                AS VARCHAR), 5);
                INSERT INTO dbo.Address (AddressID, BarangayID, DetailedAddress)
                VALUES (@NewHomeAddressID, @HomeBarangayID, @ResolvedDetailedHome);
            END

            UPDATE Users SET Address = @NewHomeAddressID WHERE UserID = @TargetUserID;
        END

        IF @EntityID IS NOT NULL
        BEGIN
            UPDATE e
            SET
                e.EntityName = COALESCE(@NewEntityName, e.EntityName),
                e.TIN        = COALESCE(@NewTIN, e.TIN),
                e.SectorID   = COALESCE(@NewSectorID, e.SectorID)
            FROM Entities e
            WHERE e.EntityID = @EntityID;

            /* ── Branch address: re-resolve only if any branch address field changed ── */
            IF @BranchID IS NOT NULL AND (
                @NewBranchDetailedAddr IS NOT NULL OR @NewBranchCity IS NOT NULL OR @NewBranchPostalCode IS NOT NULL
            )
            BEGIN
                DECLARE @BranchAddressID CHAR(6) = (SELECT AddressID FROM Branch WHERE BranchID = @BranchID);
                DECLARE @CurBDetailed NVARCHAR(250), @CurBBarangay NVARCHAR(50), @CurBCity NVARCHAR(50), @CurBProvince NVARCHAR(50), @CurBRegion NVARCHAR(50), @CurBPostal CHAR(4);
                SELECT
                    @CurBDetailed = a.DetailedAddress, @CurBBarangay = bg.BarangayName,
                    @CurBCity = cm.CityName, @CurBProvince = pv.ProvinceName, @CurBRegion = rg.RegionName, @CurBPostal = bg.PostalCode
                FROM Address a
                JOIN Barangay bg ON a.BarangayID = bg.BarangayID
                JOIN CityMunicipality cm ON bg.CityID = cm.CityID
                JOIN Province pv ON cm.ProvinceID = pv.ProvinceID
                JOIN Region rg ON pv.RegionID = rg.RegionID
                WHERE a.AddressID = @BranchAddressID;

                DECLARE @ResolvedBranchCity NVARCHAR(50) = COALESCE(@NewBranchCity, @CurBCity);
                DECLARE @ResolvedBranchPostalCode CHAR(4) = COALESCE(@NewBranchPostalCode, @CurBPostal);
                DECLARE @ResolvedBranchDetailed NVARCHAR(250) = COALESCE(@NewBranchDetailedAddr, @CurBDetailed);

                /* ── Find-or-create across the geography hierarchy, inline
                   (same logic as sp_RegisterUser; no shared stored proc). ── */
                DECLARE @NewBranchAddressID CHAR(6);
                DECLARE @BrRegionID INT, @BrProvinceID INT, @BrCityID INT, @BrBarangayID INT;

                SELECT @BrRegionID = RegionID FROM dbo.Region WHERE RegionName = @CurBRegion;
                IF @BrRegionID IS NULL
                BEGIN
                    INSERT INTO dbo.Region (RegionName) VALUES (@CurBRegion);
                    SET @BrRegionID = SCOPE_IDENTITY();
                END

                SELECT @BrProvinceID = ProvinceID FROM dbo.Province WHERE ProvinceName = @CurBProvince AND RegionID = @BrRegionID;
                IF @BrProvinceID IS NULL
                BEGIN
                    INSERT INTO dbo.Province (RegionID, ProvinceName) VALUES (@BrRegionID, @CurBProvince);
                    SET @BrProvinceID = SCOPE_IDENTITY();
                END

                SELECT @BrCityID = CityID FROM dbo.CityMunicipality WHERE CityName = @ResolvedBranchCity AND ProvinceID = @BrProvinceID;
                IF @BrCityID IS NULL
                BEGIN
                    INSERT INTO dbo.CityMunicipality (ProvinceID, CityName) VALUES (@BrProvinceID, @ResolvedBranchCity);
                    SET @BrCityID = SCOPE_IDENTITY();
                END

                SELECT @BrBarangayID = BarangayID FROM dbo.Barangay WHERE BarangayName = @CurBBarangay AND CityID = @BrCityID;
                IF @BrBarangayID IS NULL
                BEGIN
                    INSERT INTO dbo.Barangay (CityID, BarangayName, PostalCode) VALUES (@BrCityID, @CurBBarangay, @ResolvedBranchPostalCode);
                    SET @BrBarangayID = SCOPE_IDENTITY();
                END
                ELSE IF (SELECT PostalCode FROM dbo.Barangay WHERE BarangayID = @BrBarangayID) <> @ResolvedBranchPostalCode
                BEGIN
                    UPDATE dbo.Barangay SET PostalCode = @ResolvedBranchPostalCode WHERE BarangayID = @BrBarangayID;
                END

                SELECT @NewBranchAddressID = AddressID FROM dbo.Address WHERE DetailedAddress = @ResolvedBranchDetailed AND BarangayID = @BrBarangayID;
                IF @NewBranchAddressID IS NULL
                BEGIN
                    SET @NewBranchAddressID = 'A' + RIGHT('00000' + CAST(
                        ISNULL((SELECT MAX(CAST(SUBSTRING(AddressID, 2, 5) AS INT)) FROM dbo.Address), 0) + 1
                    AS VARCHAR), 5);
                    INSERT INTO dbo.Address (AddressID, BarangayID, DetailedAddress)
                    VALUES (@NewBranchAddressID, @BrBarangayID, @ResolvedBranchDetailed);
                END

                UPDATE Branch SET AddressID = @NewBranchAddressID WHERE BranchID = @BranchID;
            END
        END

        UPDATE Users SET StatusID = 2, ApprovedAt = GETDATE() WHERE UserID = @TargetUserID;

        UPDATE ProfileEditRequests
        SET RequestStatus = 'Approved', ResolvedAt = GETDATE()
        WHERE EditRequestID = @EditRequestID;

        UPDATE AuditLog
        SET Remarks = @ApprovalNotes
        WHERE LogID = (
            SELECT TOP 1 LogID FROM AuditLog
            WHERE UserID = @TargetUserID AND AdminAction = 'Approved'
            ORDER BY ActionTimestamp DESC
        );

        COMMIT TRANSACTION ApproveProfileEdit;
        PRINT 'Done! Profile edit ' + @EditRequestID + ' approved and applied.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION ApproveProfileEdit;
        THROW;
    END CATCH
END;
GO

/* ============================================================================
   5. sp_RejectProfileEdit - discard staged values, revert to Approved.
   Unchanged from v2.
   ============================================================================ */
IF OBJECT_ID('dbo.sp_RejectProfileEdit', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_RejectProfileEdit;
GO
CREATE PROCEDURE dbo.sp_RejectProfileEdit
    @EditRequestID   CHAR(6),
    @RejectionNotes  VARCHAR(250) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION RejectProfileEdit;

        IF NOT EXISTS (SELECT 1 FROM ProfileEditRequests WHERE EditRequestID = @EditRequestID AND RequestStatus = 'Pending')
            RAISERROR('Cannot reject: edit request ''%s'' does not exist or is not Pending.', 16, 1, @EditRequestID);

        DECLARE @TargetUserID CHAR(6) = (SELECT UserID FROM ProfileEditRequests WHERE EditRequestID = @EditRequestID);

        UPDATE ProfileEditRequests
        SET RequestStatus = 'Rejected', ResolvedAt = GETDATE()
        WHERE EditRequestID = @EditRequestID;

        UPDATE Users SET StatusID = 2 WHERE UserID = @TargetUserID;

        IF @RejectionNotes IS NOT NULL
            UPDATE AuditLog
            SET Remarks = @RejectionNotes
            WHERE LogID = (
                SELECT TOP 1 LogID FROM AuditLog
                WHERE UserID = @TargetUserID AND AdminAction = 'Approved'
                ORDER BY ActionTimestamp DESC
            );

        COMMIT TRANSACTION RejectProfileEdit;
        PRINT 'Done! Profile edit ' + @EditRequestID + ' rejected; account reverted to Approved.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION RejectProfileEdit;
        THROW;
    END CATCH
END;
GO

/* ============================================================================
   6. vw_PendingProfileEdits - admin-facing old-vs-proposed diff, Pending only.
   CHANGED from v2: Current* columns for address fields are read through the
   geography hierarchy (same alias names as v2, so admin.js/app.js need no
   changes); CurrentBranchAddress etc. now come from Branch -> Address ->
   Barangay/City/Province instead of flat Branches columns.
   ============================================================================ */
IF OBJECT_ID('dbo.vw_PendingProfileEdits', 'V') IS NOT NULL DROP VIEW dbo.vw_PendingProfileEdits;
GO
CREATE VIEW dbo.vw_PendingProfileEdits AS
SELECT
    per.EditRequestID,
    per.UserID,
    per.SubmittedAt,
    u.Email        AS CurrentEmail,        per.NewEmail,
    u.PhoneNumber  AS CurrentPhoneNumber,  per.NewPhoneNumber,
    a.DetailedAddress AS CurrentDetailedHome, per.NewDetailedHome,
    hcm.CityName       AS CurrentCity,         per.NewCity,
    hpv.ProvinceName   AS CurrentProvince,     per.NewProvince,
    hbg.PostalCode     AS CurrentPostalCode,   per.NewPostalCode,
    e.EntityName   AS CurrentEntityName,   per.NewEntityName,
    e.TIN          AS CurrentTIN,          per.NewTIN,
    e.SectorID     AS CurrentSectorID,     per.NewSectorID,
    bad.DetailedAddress AS CurrentBranchAddress,    per.NewBranchDetailedAddr,
    bcm.CityName        AS CurrentBranchCity,       per.NewBranchCity,
    bbg.PostalCode      AS CurrentBranchPostalCode, per.NewBranchPostalCode
FROM dbo.ProfileEditRequests per
JOIN dbo.Users u ON per.UserID = u.UserID
JOIN dbo.Address a ON u.Address = a.AddressID
JOIN dbo.Barangay hbg ON a.BarangayID = hbg.BarangayID
JOIN dbo.CityMunicipality hcm ON hbg.CityID = hcm.CityID
JOIN dbo.Province hpv ON hcm.ProvinceID = hpv.ProvinceID
LEFT JOIN dbo.Entities e ON u.EntityID = e.EntityID
LEFT JOIN dbo.Branch br ON e.BranchID = br.BranchID
LEFT JOIN dbo.Address bad ON br.AddressID = bad.AddressID
LEFT JOIN dbo.Barangay bbg ON bad.BarangayID = bbg.BarangayID
LEFT JOIN dbo.CityMunicipality bcm ON bbg.CityID = bcm.CityID
WHERE per.RequestStatus = 'Pending';
GO

/* ============================================================================
   7. vw_PendingQueueClassified - unchanged from v2 (no Address/Branch here).
   ============================================================================ */
IF OBJECT_ID('dbo.vw_PendingQueueClassified', 'V') IS NOT NULL DROP VIEW dbo.vw_PendingQueueClassified;
GO
CREATE VIEW dbo.vw_PendingQueueClassified AS
SELECT
    u.UserID AS userID,
    u.FirstName,
    u.LastName,
    u.Email,
    u.CreatedAt,
    dbo.fn_SLAStatus(u.CreatedAt, u.StatusID) AS SLABucket,
    CASE WHEN EXISTS (
        SELECT 1 FROM dbo.ProfileEditRequests per
        WHERE per.UserID = u.UserID AND per.RequestStatus = 'Pending'
    ) THEN 'Profile Edit' ELSE 'New Registration' END AS QueueReason
FROM dbo.Users u
WHERE u.StatusID = 1;
GO

/* ============================================================================
   8. Security grants (additive - 05_security_v3.sql is left untouched).
   ============================================================================ */
GRANT EXECUTE ON OBJECT::[dbo].[sp_RequestProfileEdit] TO [revora_api_user];
GO
GRANT EXECUTE ON OBJECT::[dbo].[sp_ApproveProfileEdit] TO [revora_staff_user];
GRANT EXECUTE ON OBJECT::[dbo].[sp_RejectProfileEdit]  TO [revora_staff_user];
GO
GRANT SELECT ON OBJECT::[dbo].[vw_PendingProfileEdits]    TO [revora_staff_user];
GRANT SELECT ON OBJECT::[dbo].[vw_PendingQueueClassified] TO [revora_staff_user];
GRANT SELECT ON OBJECT::[dbo].[vw_PendingQueueClassified] TO [revora_api_user];
GO

PRINT '============================================================';
PRINT ' REVORA profile-edit workflow v3 applied successfully.';
PRINT ' sp_ApproveProfileEdit now re-resolves addresses inline against the';
PRINT ' geography hierarchy instead of updating shared Address/Branch rows in place.';
PRINT '============================================================';
GO
