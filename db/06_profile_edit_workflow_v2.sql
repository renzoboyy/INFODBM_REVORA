/* ============================================================================
   REVORA - SELF-SERVICE PROFILE EDIT -> RE-APPROVAL WORKFLOW v2
   (layered on top of 01_schema_v2.sql, 03_additional_objects_v2.sql,
    04_indexes_and_views_v2.sql, 05_security_v2.sql)

   Lifecycle implemented here:
     1. An Approved user submits an edit to certain contact/address/entity
        fields via sp_RequestProfileEdit. The proposed values are staged in
        ProfileEditRequests - Users/Entities/Branches are NOT touched yet.
     2. Their account's StatusID flips back to 1 (Pending), so they reappear
        in the admin queue (vw_PendingQueue / vw_PendingQueueClassified).
     3. While Pending, the account can still log in and read its own data
        (no SELECT permission changes anywhere), but sp_RequestProfileEdit
        refuses a second submission until the first is resolved - this is
        the "read but not write" gate.
     4. An admin resolves the request:
          - sp_ApproveProfileEdit applies the staged values and sets
            StatusID back to 2 (Approved).
          - sp_RejectProfileEdit discards the staged values (Users/
            Entities/Branches stay untouched) and sets StatusID back to 2
            (Approved) - a rejected edit never demotes a returning member
            to "Rejected"; that outcome is reserved for brand-new
            registrations via the existing sp_RejectRegistrant.

   Also fixes a latent bug in trg_AuditLog_UserStatusUpdate: its CASE
   expression had no branch for StatusID = 1, so any UPDATE that set a
   user's status back to Pending would violate AuditLog.AdminAction's
   NOT NULL constraint and roll back. That is exactly what step 2 above
   needs to do, so the trigger is fixed here first.

   TIN correction is merged into this same lifecycle. The standalone,
   instant, unreviewed dbo.sp_UpdateEntityTIN (previously defined in
   03_additional_objects_v2.sql, called directly from the admin dashboard)
   is retired here: Entities.TIN is now just another field an Approved
   account can propose a change to via sp_RequestProfileEdit, subject to
   the same admin approve/reject review as everything else - applied by
   sp_ApproveProfileEdit, which is why this comment calls that proc "the
   admin profile edit procedure".

   Run ONCE, after 01-05. Safe to re-run: every CREATE is preceded by an
   existence check / DROP, matching the style of the rest of the db/ folder.
   ============================================================================ */

USE [INFODBM_REVORA];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ============================================================================
   0. Retire sp_UpdateEntityTIN - superseded by sp_RequestProfileEdit /
   sp_ApproveProfileEdit / sp_RejectProfileEdit below. Dropped here (rather
   than relying on 03_additional_objects_v2.sql no longer creating it) so
   that databases already provisioned before this file existed also lose the
   standalone proc when this script is (re-)applied.
   ============================================================================ */
IF OBJECT_ID('dbo.sp_UpdateEntityTIN', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_UpdateEntityTIN;
GO

/* ============================================================================
   1. ProfileEditRequests - staging table for one outstanding edit per user.
   NULL in any New* column means "no change requested for that column".
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

-- Only one outstanding (Pending) edit request per user at a time.
CREATE UNIQUE NONCLUSTERED INDEX [UIX_ProfileEditRequests_UserID_Pending]
    ON [dbo].[ProfileEditRequests] ([UserID] ASC)
    WHERE ([RequestStatus] = 'Pending');
GO

/* ============================================================================
   2. Bug fix: trg_AuditLog_UserStatusUpdate
   Adds the missing StatusID = 1 branch ("Resubmitted") so that transitioning
   a user back to Pending (step 2 of this workflow) does not violate
   AuditLog.AdminAction's NOT NULL constraint.
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
   Enforces: caller must be Approved (StatusID = 2), and must not already
   have a Pending edit request outstanding. This is the "no write while
   Pending" gate - read access is untouched everywhere else.
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
   4. sp_ApproveProfileEdit - "the admin profile edit procedure": applies
   staged values (including a proposed TIN correction) and re-approves the
   account. Only columns with a proposed (non-NULL) value are overwritten;
   everything else keeps its current value via COALESCE.
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

        -- Email/PhoneNumber are Dynamic Data Masked (05_security_v2.sql). A
        -- principal without UNMASK (e.g. revora_staff_user) reads the MASKED
        -- placeholder for these columns even inside an UPDATE...FROM, so a
        -- COALESCE(new, current) pattern would silently overwrite untouched
        -- data with the mask text. Read the proposed values from the
        -- (unmasked) staging table into variables and only write a column
        -- when its new value is actually provided - never read Users.Email/
        -- PhoneNumber back to "preserve" them.
        DECLARE @NewEmailVal NVARCHAR(50), @NewPhoneVal CHAR(11);
        SELECT @NewEmailVal = NewEmail, @NewPhoneVal = NewPhoneNumber
        FROM ProfileEditRequests WHERE EditRequestID = @EditRequestID;

        IF @NewEmailVal IS NOT NULL
            UPDATE Users SET Email = @NewEmailVal WHERE UserID = @TargetUserID;

        IF @NewPhoneVal IS NOT NULL
            UPDATE Users SET PhoneNumber = @NewPhoneVal WHERE UserID = @TargetUserID;

        UPDATE a
        SET
            a.DetailedHome = COALESCE(per.NewDetailedHome, a.DetailedHome),
            a.City         = COALESCE(per.NewCity, a.City),
            a.Province     = COALESCE(per.NewProvince, a.Province),
            a.PostalCode   = COALESCE(per.NewPostalCode, a.PostalCode)
        FROM Address a
        JOIN ProfileEditRequests per ON per.EditRequestID = @EditRequestID
        WHERE a.AddressID = @AddressID;

        IF @EntityID IS NOT NULL
        BEGIN
            UPDATE e
            SET
                e.EntityName = COALESCE(per.NewEntityName, e.EntityName),
                e.TIN        = COALESCE(per.NewTIN, e.TIN),
                e.SectorID   = COALESCE(per.NewSectorID, e.SectorID)
            FROM Entities e
            JOIN ProfileEditRequests per ON per.EditRequestID = @EditRequestID
            WHERE e.EntityID = @EntityID;

            IF @BranchID IS NOT NULL
            BEGIN
                UPDATE br
                SET
                    br.DetailedAddress = COALESCE(per.NewBranchDetailedAddr, br.DetailedAddress),
                    br.City            = COALESCE(per.NewBranchCity, br.City),
                    br.PostalCode      = COALESCE(per.NewBranchPostalCode, br.PostalCode)
                FROM Branches br
                JOIN ProfileEditRequests per ON per.EditRequestID = @EditRequestID
                WHERE br.BranchID = @BranchID;
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
   Users/Entities/Branches are never written to here, so the previously
   approved data is guaranteed untouched.
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
    a.DetailedHome AS CurrentDetailedHome, per.NewDetailedHome,
    a.City         AS CurrentCity,         per.NewCity,
    a.Province     AS CurrentProvince,     per.NewProvince,
    a.PostalCode   AS CurrentPostalCode,   per.NewPostalCode,
    e.EntityName   AS CurrentEntityName,   per.NewEntityName,
    e.TIN          AS CurrentTIN,          per.NewTIN,
    e.SectorID     AS CurrentSectorID,     per.NewSectorID,
    br.DetailedAddress AS CurrentBranchAddress,    per.NewBranchDetailedAddr,
    br.City            AS CurrentBranchCity,       per.NewBranchCity,
    br.PostalCode      AS CurrentBranchPostalCode, per.NewBranchPostalCode
FROM dbo.ProfileEditRequests per
JOIN dbo.Users u ON per.UserID = u.UserID
JOIN dbo.Address a ON u.Address = a.AddressID
LEFT JOIN dbo.Entities e ON u.EntityID = e.EntityID
LEFT JOIN dbo.Branches br ON e.BranchID = br.BranchID
WHERE per.RequestStatus = 'Pending';
GO

/* ============================================================================
   7. vw_PendingQueueClassified - vw_PendingQueue + a QueueReason column, so
   an admin UI can tell "new registration" apart from "resubmitted edit" and
   route Approve/Reject to the right pair of stored procedures.
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
   8. Security grants (additive - 05_security_v2.sql is left untouched).
   revora_api_user gets the self-service submit proc only.
   revora_staff_user gets the two admin resolution procs + both new views.
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
PRINT ' REVORA profile-edit workflow v2 applied successfully.';
PRINT '';
PRINT ' New table: ProfileEditRequests';
PRINT ' Fixed trigger: trg_AuditLog_UserStatusUpdate (added StatusID=1 case)';
PRINT ' New procs: sp_RequestProfileEdit, sp_ApproveProfileEdit, sp_RejectProfileEdit';
PRINT ' New views: vw_PendingProfileEdits, vw_PendingQueueClassified';
PRINT ' Retired: sp_UpdateEntityTIN (TIN correction now flows through';
PRINT '          sp_RequestProfileEdit -> sp_ApproveProfileEdit like every';
PRINT '          other editable field)';
PRINT '============================================================';
GO
