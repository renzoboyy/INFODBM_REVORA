/* ============================================================================
   REVORA - PERFORMANCE INDEXES & QUEUE VIEW v3 (layered on top of
   01_schema_v3.sql / 03_additional_objects_v3.sql)

   Unchanged from v4 in substance - none of these touch Address/Branch, so
   the Address+Branches merge has no effect here. Carried forward as v3 only
   to keep the numbered run order consistent with the rest of the db/ folder.

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
PRINT ' REVORA indexes & vw_PendingQueue (v3) created successfully.';
PRINT '============================================================';
GO
