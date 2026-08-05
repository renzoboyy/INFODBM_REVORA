/* ============================================================================
   REVORA - PERFORMANCE INDEXES & QUEUE VIEW v3 (layered on top of
   01_schema_v3.sql / 03_additional_objects_v3.sql)

   Unchanged from v4 in substance - none of these touch Address/Branch, so
   the Address+Branches merge has no effect here. Carried forward as v3 only
   to keep the numbered run order consistent with the rest of the db/ folder.

   Adds:
     - IX_Users_StatusID_CreatedAt    (Users queue/analytics lookups by status)
     - IX_AuditLog_UserID_Timestamp   (approval/rejection audit trail lookups)

   vw_PendingQueue (formerly defined here) was removed - superseded by
   vw_PendingQueueClassified and never queried by server/.
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
   3. vw_PendingQueue - REMOVED. Superseded by vw_PendingQueueClassified
   (06_profile_edit_workflow_v3.sql), which adds the QueueReason column
   needed to distinguish new registrations from profile-edit re-queues.
   Nothing in server/ ever queried this view, so it was dropped outright
   rather than kept alongside its replacement.
   ============================================================================ */
IF OBJECT_ID('dbo.vw_PendingQueue', 'V') IS NOT NULL DROP VIEW dbo.vw_PendingQueue;
GO

PRINT '============================================================';
PRINT ' REVORA indexes (v3) created successfully.';
PRINT '============================================================';
GO
