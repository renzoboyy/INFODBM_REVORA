/* ============================================================================
   REVORA - PERFORMANCE INDEXES & QUEUE VIEW v2 (layered on top of
   01_schema_v2.sql / 03_additional_objects_v2.sql)

   Adds:
     - IX_Users_StatusID_CreatedAt    (Users queue/analytics lookups by status)
     - IX_AuditLog_UserID_Timestamp   (approval/rejection audit trail lookups)
     - vw_PendingQueue                (covering-index view for the admin queue)
   ============================================================================ */

USE [INFODBM_REVORA];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ============================================================================
   1. IX_Users_StatusID_CreatedAt
   Serves: admin queue (WHERE StatusID = 1 ORDER BY CreatedAt), analytics
   COUNT/MIN/MAX(CreatedAt) WHERE StatusID = 1. INCLUDE covers the columns
   vw_PendingQueue projects, so a StatusID lookup never needs a key lookup
   back into the clustered index.
   ============================================================================ */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Users_StatusID_CreatedAt' AND object_id = OBJECT_ID('dbo.Users'))
    DROP INDEX [IX_Users_StatusID_CreatedAt] ON [dbo].[Users];
GO
CREATE NONCLUSTERED INDEX [IX_Users_StatusID_CreatedAt]
    ON [dbo].[Users] ([StatusID] ASC, [CreatedAt] ASC)
    INCLUDE ([FirstName], [LastName], [Email]);
GO

/* ============================================================================
   2. IX_AuditLog_UserID_Timestamp
   Serves: ApproveUserAccount / sp_RejectRegistrant's
   "TOP 1 ... WHERE UserID = @TargetUserID ORDER BY ActionTimestamp DESC"
   lookups used to attach admin notes to the log row just written by the
   AuditLog triggers.
   ============================================================================ */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AuditLog_UserID_Timestamp' AND object_id = OBJECT_ID('dbo.AuditLog'))
    DROP INDEX [IX_AuditLog_UserID_Timestamp] ON [dbo].[AuditLog];
GO
CREATE NONCLUSTERED INDEX [IX_AuditLog_UserID_Timestamp]
    ON [dbo].[AuditLog] ([UserID] ASC, [ActionTimestamp] ASC)
    INCLUDE ([AdminAction], [Remarks]);
GO

/* ============================================================================
   3. vw_PendingQueue - lightweight admin queue projection.
   Column list is a 1:1 match with IX_Users_StatusID_CreatedAt's key +
   INCLUDE columns, so this view is satisfied entirely by an index seek on
   IX_Users_StatusID_CreatedAt with no key lookup and no joins out to Roles/
   Categories/AccountStatus/GID/Entities/Sectors (unlike vw_ApplicantDirectory).
   ============================================================================ */
IF OBJECT_ID('dbo.vw_PendingQueue', 'V') IS NOT NULL DROP VIEW dbo.vw_PendingQueue;
GO
CREATE VIEW dbo.vw_PendingQueue AS
SELECT
    UserID AS userID,
    FirstName,
    LastName,
    Email,
    CreatedAt,
    dbo.fn_SLAStatus(CreatedAt, StatusID) AS SLABucket
FROM dbo.Users
WHERE StatusID = 1;
GO

PRINT '============================================================';
PRINT ' REVORA indexes & vw_PendingQueue created successfully.';
PRINT '============================================================';
GO
