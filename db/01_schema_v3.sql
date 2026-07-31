/* ============================================================================
   REVORA - DATABASE SCHEMA v3
   Normalization refactor on top of v2:
     - Address and Branches merged into one ADDRESS table (was duplicated
       DetailedHome/DetailedAddress + City/PostalCode shape on both tables).
     - Geography decomposed into a 3NF/BCNF hierarchy:
         Region -> Province -> CityMunicipality -> Barangay (carries PostalCode)
     - Branch is now a thin record (BranchID + AddressID). BranchCode is
       REMOVED - BranchID is already the unique, system-generated identifier
       for a branch; BranchCode duplicated that role with a second,
       admin-supplied value and added nothing structurally.
   Dropped from v2 (carried over from the approved merge plan):
     - UK on Users.Address  (addresses are now shareable across records -
       two users at the same barangay no longer collide)
     - UK on Users.Password (password-uniqueness was an information leak:
       it let you infer two accounts share a password)
   Fixed relative to the merge sketch this was drafted from:
     - Entities.BranchID stays a FILTERED unique index (UIX_BranchID_NotNull),
       not a plain UNIQUE constraint. A plain UNIQUE constraint allows only
       ONE NULL total in SQL Server, and BranchID is nullable, so a plain
       constraint would break the moment a second entity ever went
       branchless.
   Retained from v2:
     - One representative per entity (filtered unique index on Users.EntityID)
     - GID uniqueness on (GovtType, GovtNo), all CHECK constraints, triggers,
       ApproveUserAccount's shape (recreated in 03_v3 against the new tables)
   WARNING: This script DROPS and RECREATES the database. All data is lost.
   ============================================================================ */

USE [master];
GO

IF DB_ID(N'INFODBM_REVORA') IS NOT NULL
BEGIN
    ALTER DATABASE [INFODBM_REVORA] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [INFODBM_REVORA];
END
GO

CREATE DATABASE [INFODBM_REVORA];
GO

USE [INFODBM_REVORA];
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ============================================================================
   1. GEOGRAPHY HIERARCHY  (Region -> Province -> CityMunicipality -> Barangay)
   Surrogate INT IDENTITY keys: these are internal lookup rows, resolved by
   name via find-or-create logic in sp_RegisterUser / sp_RequestProfileEdit
   (03_additional_objects_v3.sql / 06_profile_edit_workflow_v3.sql), never
   typed in directly by a caller the way UserID/EntityID codes are.
   ============================================================================ */

CREATE TABLE [dbo].[Region](
    [RegionID]   INT IDENTITY(1,1) NOT NULL,
    [RegionName] NVARCHAR(50)      NOT NULL,
    CONSTRAINT [PK_Region]      PRIMARY KEY CLUSTERED ([RegionID] ASC),
    CONSTRAINT [UK_Region_Name] UNIQUE ([RegionName])
);
GO

CREATE TABLE [dbo].[Province](
    [ProvinceID]   INT IDENTITY(1,1) NOT NULL,
    [RegionID]     INT               NOT NULL,
    [ProvinceName] NVARCHAR(50)      NOT NULL,
    CONSTRAINT [PK_Province] PRIMARY KEY CLUSTERED ([ProvinceID] ASC),
    CONSTRAINT [UK_Province] UNIQUE ([ProvinceName], [RegionID])
);
GO

CREATE TABLE [dbo].[CityMunicipality](
    [CityID]     INT IDENTITY(1,1) NOT NULL,
    [ProvinceID] INT               NOT NULL,
    [CityName]   NVARCHAR(50)      NOT NULL,
    CONSTRAINT [PK_CityMunicipality] PRIMARY KEY CLUSTERED ([CityID] ASC),
    CONSTRAINT [UK_City]             UNIQUE ([CityName], [ProvinceID])
);
GO

CREATE TABLE [dbo].[Barangay](
    [BarangayID]   INT IDENTITY(1,1) NOT NULL,
    [CityID]       INT               NOT NULL,
    [BarangayName] NVARCHAR(50)      NOT NULL,
    [PostalCode]   CHAR(4)           NOT NULL,
    CONSTRAINT [PK_Barangay]             PRIMARY KEY CLUSTERED ([BarangayID] ASC),
    CONSTRAINT [UK_Barangay]             UNIQUE ([BarangayName], [CityID]),
    CONSTRAINT [CK_Barangay_PostalCode]  CHECK ([PostalCode] LIKE '[0-9][0-9][0-9][0-9]')
);
GO

/* ============================================================================
   2. ADDRESS  (merged table: street-level detail + link to Barangay).
   Shared by both dbo.Users.Address and dbo.Branch.AddressID.
   ============================================================================ */

CREATE TABLE [dbo].[Address](
    [AddressID]       CHAR(6)       NOT NULL,
    [BarangayID]      INT           NOT NULL,
    [DetailedAddress] NVARCHAR(250) NOT NULL,
    CONSTRAINT [PK_Address] PRIMARY KEY CLUSTERED ([AddressID] ASC),
    CONSTRAINT [UK_Address_DetailedAndBarangay] UNIQUE ([DetailedAddress], [BarangayID])
);
GO

/* ============================================================================
   3. BRANCH  (thin: identity + shared Address. BranchCode removed - BranchID
   already is the unique, system-issued branch identifier.)
   ============================================================================ */

CREATE TABLE [dbo].[Branch](
    [BranchID]  CHAR(6) NOT NULL,
    [AddressID] CHAR(6) NOT NULL,
    CONSTRAINT [PK_Branch] PRIMARY KEY CLUSTERED ([BranchID] ASC)
);
GO

/* ============================================================================
   4. LOOKUP / REFERENCE TABLES  (unchanged from v2)
   ============================================================================ */

CREATE TABLE [dbo].[Roles](
    [RoleID]   BIT         NOT NULL,
    [RoleName] VARCHAR(9)  NOT NULL,
    CONSTRAINT [PK_Roles]    PRIMARY KEY CLUSTERED ([RoleID] ASC),
    CONSTRAINT [UK_RoleName] UNIQUE ([RoleName])
);
GO

CREATE TABLE [dbo].[Categories](
    [CategoryID]   TINYINT     NOT NULL,
    [CategoryName] VARCHAR(15) NOT NULL,
    CONSTRAINT [PK_Categories]      PRIMARY KEY CLUSTERED ([CategoryID] ASC),
    CONSTRAINT [UK_Categories_Name] UNIQUE ([CategoryName])
);
GO

CREATE TABLE [dbo].[AccountStatus](
    [StatusID]   TINYINT     NOT NULL,
    [StatusName] VARCHAR(20) NOT NULL,
    CONSTRAINT [PK_AccountStatus]          PRIMARY KEY CLUSTERED ([StatusID] ASC),
    CONSTRAINT [UK_AccountStatus_Name]     UNIQUE ([StatusName]),
    CONSTRAINT [CK_AccountStatus_Approval] CHECK ([StatusID] >= 1 AND [StatusID] <= 6)
);
GO

CREATE TABLE [dbo].[Sectors](
    [SectorID]   CHAR(6)     NOT NULL,
    [SectorName] VARCHAR(50) NOT NULL,
    CONSTRAINT [PK_Sectors]    PRIMARY KEY CLUSTERED ([SectorID] ASC),
    CONSTRAINT [UK_SectorName] UNIQUE ([SectorName])
);
GO

CREATE TABLE [dbo].[GID](
    [GovtID]   CHAR(6)     NOT NULL,
    [GovtType] VARCHAR(15) NOT NULL,
    [GovtNo]   VARCHAR(20) NOT NULL,
    CONSTRAINT [PK_GID]           PRIMARY KEY CLUSTERED ([GovtID] ASC),
    CONSTRAINT [UK_GID_TypeAndNo] UNIQUE ([GovtType], [GovtNo]),
    CONSTRAINT [CK_GovernmentID_Validation] CHECK
    (
        ([GovtType] = 'PhilSys'        AND LEN([GovtNo]) = 16 AND NOT [GovtNo] LIKE '%[^0-9]%')
     OR ([GovtType] = 'Passport'       AND (LEN([GovtNo]) >= 6 AND LEN([GovtNo]) <= 12) AND NOT [GovtNo] LIKE '%[^A-Za-z0-9]%')
     OR ([GovtType] = 'Driver License' AND [GovtNo] LIKE '[A-Z][0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]')
     OR ([GovtType] = 'UMID'           AND LEN([GovtNo]) = 12 AND NOT [GovtNo] LIKE '%[^0-9]%')
     OR ([GovtType] = 'PRC ID'         AND LEN([GovtNo]) = 7  AND NOT [GovtNo] LIKE '%[^0-9]%')
    )
);
GO

/* ============================================================================
   5. ENTITIES  (one branch per entity, retained via a filtered unique index)
   ============================================================================ */

CREATE TABLE [dbo].[Entities](
    [EntityID]   CHAR(6)      NOT NULL,
    [EntityName] NVARCHAR(50) NOT NULL,
    [TIN]        NCHAR(11)    NOT NULL,
    [SectorID]   CHAR(6)      NOT NULL,
    [BranchID]   CHAR(6)      NULL,
    CONSTRAINT [PK_Entities]   PRIMARY KEY CLUSTERED ([EntityID] ASC),
    CONSTRAINT [UK_TIN]        UNIQUE ([TIN]),
    CONSTRAINT [CK_TIN_Length] CHECK (LEN(RTRIM([TIN])) = 11)
);
GO

/* One branch per entity: unique BranchID among non-NULL values only.
   (See header note: a plain UNIQUE constraint here would break after the
   second branch closure, since SQL Server allows only one NULL under a
   plain UNIQUE constraint.) */
CREATE UNIQUE NONCLUSTERED INDEX [UIX_BranchID_NotNull]
    ON [dbo].[Entities] ([BranchID] ASC)
    WHERE ([BranchID] IS NOT NULL);
GO

/* ============================================================================
   6. USERS  (unchanged column list; Address FK now points at the merged
   Address table. UK_Password and UK_Address dropped per the merge plan.)
   ============================================================================ */

CREATE TABLE [dbo].[Users](
    [UserID]      CHAR(6)        NOT NULL,
    [Username]    NCHAR(10)      NOT NULL,
    [Password]    VARBINARY(32)  NOT NULL,
    [FirstName]   NVARCHAR(50)   NOT NULL,
    [MiddleName]  NVARCHAR(50)   NULL,
    [LastName]    NVARCHAR(50)   NOT NULL,
    [Suffix]      NVARCHAR(50)   NULL,
    [Email]       NVARCHAR(50)   NOT NULL,
    [PhoneNumber] CHAR(11)       NOT NULL,
    [BirthDate]   DATE           NOT NULL,
    [Address]     CHAR(6)        NOT NULL,
    [RoleID]      BIT            NOT NULL,
    [GovtID]      CHAR(6)        NOT NULL,
    [StatusID]    TINYINT        NOT NULL,
    [EntityID]    CHAR(6)        NULL,
    [CategoryID]  TINYINT        NOT NULL,
    [ApprovedAt]  DATETIME       NULL,
    [CreatedAt]   DATETIME       NOT NULL CONSTRAINT [DF_Users_CreatedAt] DEFAULT (GETDATE()),
    CONSTRAINT [PK_Users]             PRIMARY KEY CLUSTERED ([UserID] ASC),
    CONSTRAINT [UK_Users_Username]    UNIQUE ([Username]),
    CONSTRAINT [UK_Users_Email]       UNIQUE ([Email]),
    CONSTRAINT [UK_Users_PhoneNumber] UNIQUE ([PhoneNumber]),
    CONSTRAINT [UK_GovtID]            UNIQUE ([GovtID]),
    CONSTRAINT [CK_Email_Format]       CHECK ([Email] LIKE '%_@_%._%'),
    CONSTRAINT [CK_PhoneNumber_Format] CHECK ([PhoneNumber] LIKE '09[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'),
    CONSTRAINT [CK_BirthDate_Valid]    CHECK ([BirthDate] >= '1900-01-01' AND [BirthDate] < GETDATE())
);
GO

/* One representative per entity: unique EntityID among non-NULL values only */
CREATE UNIQUE NONCLUSTERED INDEX [UIX_EntityID_NotNull]
    ON [dbo].[Users] ([EntityID] ASC)
    WHERE ([EntityID] IS NOT NULL);
GO

/* ============================================================================
   7. AUDITLOG  (unchanged from v2)
   ============================================================================ */

CREATE TABLE [dbo].[AuditLog](
    [LogID]           CHAR(9)      NOT NULL,
    [UserID]          CHAR(6)      NOT NULL,
    [AdminAction]     VARCHAR(50)  NOT NULL,
    [ActionTimestamp] DATETIME     NOT NULL,
    [Remarks]         VARCHAR(250) NULL,
    CONSTRAINT [PK_AuditLog] PRIMARY KEY CLUSTERED ([LogID] ASC)
);
GO

/* ============================================================================
   8. FOREIGN KEYS
   ============================================================================ */

ALTER TABLE [dbo].[Province]
    ADD CONSTRAINT [FK_Province_Region] FOREIGN KEY ([RegionID])
    REFERENCES [dbo].[Region] ([RegionID]);
GO
ALTER TABLE [dbo].[CityMunicipality]
    ADD CONSTRAINT [FK_City_Province] FOREIGN KEY ([ProvinceID])
    REFERENCES [dbo].[Province] ([ProvinceID]);
GO
ALTER TABLE [dbo].[Barangay]
    ADD CONSTRAINT [FK_Barangay_City] FOREIGN KEY ([CityID])
    REFERENCES [dbo].[CityMunicipality] ([CityID]);
GO
ALTER TABLE [dbo].[Address]
    ADD CONSTRAINT [FK_Address_Barangay] FOREIGN KEY ([BarangayID])
    REFERENCES [dbo].[Barangay] ([BarangayID]);
GO
ALTER TABLE [dbo].[Branch]
    ADD CONSTRAINT [FK_Branch_Address] FOREIGN KEY ([AddressID])
    REFERENCES [dbo].[Address] ([AddressID]);
GO
ALTER TABLE [dbo].[Entities]
    ADD CONSTRAINT [FK_Entities_Sectors] FOREIGN KEY ([SectorID])
    REFERENCES [dbo].[Sectors] ([SectorID]);
GO
ALTER TABLE [dbo].[Entities]
    ADD CONSTRAINT [FK_Entities_Branch] FOREIGN KEY ([BranchID])
    REFERENCES [dbo].[Branch] ([BranchID]);
GO
ALTER TABLE [dbo].[Users]
    ADD CONSTRAINT [FK_Users_Address] FOREIGN KEY ([Address])
    REFERENCES [dbo].[Address] ([AddressID]);
GO
ALTER TABLE [dbo].[Users]
    ADD CONSTRAINT [FK_Users_Roles] FOREIGN KEY ([RoleID])
    REFERENCES [dbo].[Roles] ([RoleID]);
GO
ALTER TABLE [dbo].[Users]
    ADD CONSTRAINT [FK_Users_GID] FOREIGN KEY ([GovtID])
    REFERENCES [dbo].[GID] ([GovtID]);
GO
ALTER TABLE [dbo].[Users]
    ADD CONSTRAINT [FK_Users_AccountStatus] FOREIGN KEY ([StatusID])
    REFERENCES [dbo].[AccountStatus] ([StatusID]);
GO
ALTER TABLE [dbo].[Users]
    ADD CONSTRAINT [FK_Users_Entities] FOREIGN KEY ([EntityID])
    REFERENCES [dbo].[Entities] ([EntityID]);
GO
ALTER TABLE [dbo].[Users]
    ADD CONSTRAINT [FK_Users_Categories] FOREIGN KEY ([CategoryID])
    REFERENCES [dbo].[Categories] ([CategoryID]);
GO
ALTER TABLE [dbo].[AuditLog]
    ADD CONSTRAINT [FK_AuditLog_Users] FOREIGN KEY ([UserID])
    REFERENCES [dbo].[Users] ([UserID]);
GO

/* ============================================================================
   9. TRIGGERS  (unchanged from v2 - none of these touch Address/Branch)
   ============================================================================ */

CREATE TRIGGER [dbo].[trg_HashPassword]
ON [dbo].[Users]
INSTEAD OF INSERT
AS
BEGIN
    INSERT INTO dbo.Users(
        UserID, Username, Password, FirstName, MiddleName, LastName, Suffix,
        Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID,
        EntityID, CategoryID, ApprovedAt
    )
    SELECT
        UserID, Username, HASHBYTES('SHA2_256', Password), FirstName, MiddleName,
        LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID,
        StatusID, EntityID, CategoryID, ApprovedAt
    FROM inserted;
END
GO

CREATE TRIGGER [dbo].[trg_AuditLog_UserInsert]
ON [dbo].[Users]
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO AuditLog (LogID, UserID, AdminAction, ActionTimestamp, Remarks)
    SELECT
        'L' + RIGHT('00000000' + CAST(
            ISNULL((SELECT MAX(CAST(SUBSTRING(LogID, 2, 8) AS INT)) FROM AuditLog), 0) + 1
        AS VARCHAR), 8),
        i.UserID,
        'Pending',
        GETDATE(),
        'New registration submitted. Account awaiting admin review.'
    FROM inserted i
    WHERE i.StatusID = 1;
END;
GO

-- NOTE: fixed for StatusID = 1 ("Resubmitted") in 06_profile_edit_workflow_v3.sql.
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

PRINT '============================================================';
PRINT ' INFODBM_REVORA schema v3 created successfully.';
PRINT ' Address+Branches merged; geography hierarchy added; BranchCode removed.';
PRINT ' Run 03_additional_objects_v3.sql next.';
PRINT '============================================================';
GO
