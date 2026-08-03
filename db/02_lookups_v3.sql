/* ============================================================================
   REVORA - REQUIRED LOOKUP DATA v3
   Unlike 02_seed_v2.sql (sample business records - Address/Branches/Users/
   Entities/GID - safe to skip entirely), this script populates static
   REFERENCE data the app cannot function without: Roles, Categories,
   AccountStatus, Sectors, and now Region. GET /api/lookups and
   GET /api/geo/regions read these directly, and sp_RegisterUser's Users
   insert has FK constraints against RoleID/CategoryID/StatusID, so
   registration fails outright with these tables empty.

   Run this after 01_schema_v3.sql (and before/after 03-06, order doesn't
   matter - it has no dependency on any of them). Safe to re-run.
   ============================================================================ */

USE [INFODBM_REVORA];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.Roles)
INSERT INTO dbo.Roles (RoleID, RoleName) VALUES
    (0, 'Generator'),
    (1, 'Upcycler');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.Categories)
INSERT INTO dbo.Categories (CategoryID, CategoryName) VALUES
    (1, 'Individual'),
    (2, 'Sole Prop'),
    (3, 'Small Business'),
    (4, 'Corporation');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.AccountStatus)
INSERT INTO dbo.AccountStatus (StatusID, StatusName) VALUES
    (1, 'Pending'),
    (2, 'Approved'),
    (3, 'Rejected'),
    (4, 'Suspended'),
    (5, 'Deleted'),
    (6, 'Closed');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.Sectors)
INSERT INTO dbo.Sectors (SectorID, SectorName) VALUES
    ('S00001', 'Textiles & Fashion'),
    ('S00002', 'Printing & Packaging'),
    ('S00003', 'Food & Beverage'),
    ('S00004', 'Manufacturing'),
    ('S00005', 'Construction & Real Estate'),
    ('S00006', 'Retail & E-commerce'),
    ('S00007', 'Healthcare & Wellness'),
    ('S00008', 'Agriculture & Forestry'),
    ('S00009', 'Information Technology'),
    ('S00010', 'Hospitality & Tourism');
GO

/* ============================================================================
   REGION - the 17 official PH regions, seeded up front so the registration
   UI can present Region as a closed dropdown (GET /api/geo/regions) instead
   of free text. Guarded per-row (not per-table) since NCR/Region III/
   Region VI/Region XI may already exist from prior registrations/seed data;
   naming matches that existing convention (short form, not the long
   descriptive name) so this never forks an existing row.
   ============================================================================ */
DECLARE @Regions TABLE (RegionName NVARCHAR(50));
INSERT INTO @Regions VALUES
    ('NCR'), ('CAR'), ('Region I'), ('Region II'), ('Region III'), ('Region IV-A'),
    ('MIMAROPA'), ('Region V'), ('Region VI'), ('Region VII'), ('Region VIII'),
    ('Region IX'), ('Region X'), ('Region XI'), ('Region XII'), ('Region XIII'), ('BARMM');

INSERT INTO dbo.Region (RegionName)
SELECT r.RegionName FROM @Regions r
WHERE NOT EXISTS (SELECT 1 FROM dbo.Region WHERE RegionName = r.RegionName);
GO

PRINT '============================================================';
PRINT ' REVORA required lookup data (v3) loaded successfully.';
PRINT '============================================================';
GO
