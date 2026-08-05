/* ============================================================================
   REVORA - SEED DATA v3 (matches 01_schema_v3.sql, merged Address/Branch)
   Same business content as 02_seed_v2.sql (10 Users, 6 Entities/Branches,
   10 GID rows) - adapted for the v3 geography hierarchy. Addresses are
   built through a session-local #ResolveAddress temp proc (defined below)
   instead of raw INSERTs into a flat Address/Branches table, so Region/
   Province/CityMunicipality/Barangay rows get created (or reused) exactly
   the way the app does it at runtime. There is no permanent dbo-schema
   sp_ResolveAddress object anymore (sp_RegisterUser and sp_ApproveProfileEdit
   inline this same find-or-create logic directly) - #ResolveAddress exists
   only for this script, to avoid duplicating it across 16 call sites, and is
   dropped automatically when the session ends.

   Run order: 01_schema_v3.sql -> 02_lookups_v3.sql (Roles/Categories/
   AccountStatus/Sectors - NOT re-inserted here) -> 03_additional_objects_v3.sql
   (defines sp_RegisterUser etc.) -> 04/05/06 (optional, no dependency either
   way) -> this script last. Despite the historical "02" seed slot in v2,
   this one is intentionally numbered 07 so nobody runs it before the schema
   it depends on exists.

   Users are still inserted one statement at a time (not a multi-row VALUES
   list): trg_AuditLog_UserInsert computes its LogID from a single scalar
   MAX(...) per *statement*, not per row, so a multi-row INSERT would assign
   every new user the same LogID and violate PK_AuditLog. Address-resolution
   variables are declared once at the top and stay in scope because nothing
   below uses GO until after the last Users INSERT.
   ============================================================================ */

USE [INFODBM_REVORA];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ============================================================================
   Preflight: fail fast with a readable message instead of dying partway
   through on an opaque FK violation (e.g. FK_Entities_Sectors, FK_Users_Roles)
   if the run order in the header above wasn't followed.
   ============================================================================ */
IF NOT EXISTS (SELECT 1 FROM dbo.Roles) OR NOT EXISTS (SELECT 1 FROM dbo.Categories)
   OR NOT EXISTS (SELECT 1 FROM dbo.AccountStatus) OR NOT EXISTS (SELECT 1 FROM dbo.Sectors)
BEGIN
    RAISERROR('07_seed_v3.sql requires Roles/Categories/AccountStatus/Sectors to already be populated. Run 02_lookups_v3.sql first, then re-run this script.', 16, 1);
    RETURN;
END
GO

/* ============================================================================
   #ResolveAddress - session-local temp proc, seed-script-only. Same
   find-or-create logic sp_RegisterUser/sp_ApproveProfileEdit inline for
   real registrations/edits; kept here as a temp proc purely so this script
   doesn't repeat it 16 times. Dropped automatically when the session ends.
   ============================================================================ */
IF OBJECT_ID('tempdb..#ResolveAddress') IS NOT NULL DROP PROCEDURE #ResolveAddress;
GO
CREATE PROCEDURE #ResolveAddress
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

INSERT INTO dbo.GID (GovtID, GovtType, GovtNo) VALUES
    ('G00001', 'PhilSys',        '9876543210123456'),
    ('G00002', 'UMID',           '432109876543'),
    ('G00003', 'Driver License', 'C21-43-098765'),
    ('G00004', 'Passport',       'P9988776'),
    ('G00005', 'PhilSys',        '8765432109876543'),
    ('G00006', 'PRC ID',         '7654321'),
    ('G00007', 'Driver License', 'D65-43-210987'),
    ('G00008', 'PhilSys',        '6543210987654321'),
    ('G00009', 'Passport',       'P1122334'),
    ('G00010', 'UMID',           '210987654321');
GO

/* ── Resolve personal addresses (A00001-equivalent, 10 reps) ── */
DECLARE @A1 CHAR(6), @A2 CHAR(6), @A3 CHAR(6), @A4 CHAR(6), @A5 CHAR(6),
        @A6 CHAR(6), @A7 CHAR(6), @A8 CHAR(6), @A9 CHAR(6), @A10 CHAR(6);

EXEC #ResolveAddress @RegionName='NCR',       @ProvinceName='Metro Manila',  @CityName='Taguig',      @BarangayName='Hagonoy',    @PostalCode='1630', @DetailedAddress='12 Weaver St.',                 @AddressID=@A1  OUTPUT;
EXEC #ResolveAddress @RegionName='NCR',       @ProvinceName='Metro Manila',  @CityName='Quezon City', @BarangayName='Silangan',   @PostalCode='1100', @DetailedAddress='45 Greenway Blvd.',              @AddressID=@A2  OUTPUT;
EXEC #ResolveAddress @RegionName='NCR',       @ProvinceName='Metro Manila',  @CityName='Caloocan',    @BarangayName='Bagumbong',  @PostalCode='1420', @DetailedAddress='27 Samson Rd.',                  @AddressID=@A3  OUTPUT;
EXEC #ResolveAddress @RegionName='Region VI', @ProvinceName='Iloilo',        @CityName='Iloilo City', @BarangayName='Mandurriao', @PostalCode='5000', @DetailedAddress='33 Fuentes St.',                 @AddressID=@A4  OUTPUT;
EXEC #ResolveAddress @RegionName='NCR',       @ProvinceName='Metro Manila',  @CityName='Quezon City', @BarangayName='Cubao',      @PostalCode='1109', @DetailedAddress='8 Uy Compound',                  @AddressID=@A5  OUTPUT;
EXEC #ResolveAddress @RegionName='NCR',       @ProvinceName='Metro Manila',  @CityName='Makati',      @BarangayName='Poblacion',  @PostalCode='1200', @DetailedAddress='19 Torres Ave.',                 @AddressID=@A6  OUTPUT;
EXEC #ResolveAddress @RegionName='NCR',       @ProvinceName='Metro Manila',  @CityName='San Juan',    @BarangayName='Greenhills', @PostalCode='1500', @DetailedAddress='5 Aquino Lane',                  @AddressID=@A7  OUTPUT;
EXEC #ResolveAddress @RegionName='Region III',@ProvinceName='Bulacan',       @CityName='Malolos',     @BarangayName='Sto. Rosario', @PostalCode='3000', @DetailedAddress='Purok 2',                      @AddressID=@A8  OUTPUT;
EXEC #ResolveAddress @RegionName='Region XI', @ProvinceName='Davao del Sur', @CityName='Davao City',  @BarangayName='Poblacion',  @PostalCode='8000', @DetailedAddress='77 Ong Residences',              @AddressID=@A9  OUTPUT;
EXEC #ResolveAddress @RegionName='Region III',@ProvinceName='Bulacan',       @CityName='Meycauayan',  @BarangayName='Calvario',   @PostalCode='3020', @DetailedAddress='3 Villanueva Compound',          @AddressID=@A10 OUTPUT;

/* ── Resolve branch addresses (B00001-equivalent, 6 entities) ──
   Same city/barangay as the matching rep's home address above (E00001's
   rep lives and works in Taguig, etc.) but a distinct DetailedAddress, so
   each resolves to its own Address row even though it shares a Barangay. */
DECLARE @BA1 CHAR(6), @BA2 CHAR(6), @BA3 CHAR(6), @BA4 CHAR(6), @BA5 CHAR(6), @BA6 CHAR(6);

EXEC #ResolveAddress @RegionName='NCR',       @ProvinceName='Metro Manila',  @CityName='Taguig',      @BarangayName='Hagonoy',    @PostalCode='1630', @DetailedAddress='Unit 4, Textile Row',            @AddressID=@BA1 OUTPUT;
EXEC #ResolveAddress @RegionName='NCR',       @ProvinceName='Metro Manila',  @CityName='Quezon City', @BarangayName='Silangan',   @PostalCode='1100', @DetailedAddress='88 Recyclers Ave.',              @AddressID=@BA2 OUTPUT;
EXEC #ResolveAddress @RegionName='Region VI', @ProvinceName='Iloilo',        @CityName='Iloilo City', @BarangayName='Mandurriao', @PostalCode='5000', @DetailedAddress='Main Plant, Mandurriao Industrial Zone', @AddressID=@BA3 OUTPUT;
EXEC #ResolveAddress @RegionName='Region III',@ProvinceName='Bulacan',       @CityName='Malolos',     @BarangayName='Sto. Rosario', @PostalCode='3000', @DetailedAddress='Agri Hub Bldg.',               @AddressID=@BA4 OUTPUT;
EXEC #ResolveAddress @RegionName='Region XI', @ProvinceName='Davao del Sur', @CityName='Davao City',  @BarangayName='Poblacion',  @PostalCode='8000', @DetailedAddress='IT Park Tower',                  @AddressID=@BA5 OUTPUT;
EXEC #ResolveAddress @RegionName='Region III',@ProvinceName='Bulacan',       @CityName='Meycauayan',  @BarangayName='Calvario',   @PostalCode='3020', @DetailedAddress='Packaging Complex',              @AddressID=@BA6 OUTPUT;

INSERT INTO dbo.Branch (BranchID, AddressID) VALUES
    ('B00001', @BA1),
    ('B00002', @BA2),
    ('B00003', @BA3),
    ('B00004', @BA4),
    ('B00005', @BA5),
    ('B00006', @BA6);

INSERT INTO dbo.Entities (EntityID, EntityName, TIN, SectorID, BranchID) VALUES
    ('E00001', 'Santos Textile Works',     '101-202-303', 'S00001', 'B00001'),
    ('E00002', 'Reyes Upcycled Goods',     '202-303-404', 'S00006', 'B00002'),
    ('E00003', 'Delgado Manufacturing',    '303-404-505', 'S00004', 'B00003'),
    ('E00004', 'Cruz Agri Ventures',       '404-505-606', 'S00008', 'B00004'),
    ('E00005', 'Lim Tech Solutions',       '505-606-707', 'S00009', 'B00005'),
    ('E00006', 'Villanueva Packaging Co.', '606-707-808', 'S00002', 'B00006');

INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00001', N'miguels   ', CONVERT(VARBINARY(100), 'Passw0rd!01'), N'Miguel', NULL, N'Santos', NULL, N'miguel.santos@santostextile.ph', '09281000001', '1980-02-14', @A1, 0, 'G00001', 1, 'E00001', 4, NULL);
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00002', N'biancar   ', CONVERT(VARBINARY(100), 'Passw0rd!02'), N'Bianca', N'Lopez', N'Reyes', NULL, N'bianca.reyes@recycledgoods.ph', '09281000002', '1990-06-21', @A2, 0, 'G00002', 1, 'E00002', 3, NULL);
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00003', N'diegor    ', CONVERT(VARBINARY(100), 'Passw0rd!03'), N'Diego', N'Villar', N'Ramos', NULL, N'diego.ramos@gmail.com', '09281000003', '1999-11-05', @A3, 1, 'G00003', 1, NULL, 1, NULL);
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00004', N'patriciac ', CONVERT(VARBINARY(100), 'Passw0rd!04'), N'Patricia', N'Manalo', N'Cruz', NULL, N'patricia.cruz@cruzagri.ph', '09281000004', '1985-03-30', @A4, 0, 'G00004', 1, 'E00004', 2, NULL);
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00005', N'antoniod  ', CONVERT(VARBINARY(100), 'Passw0rd!05'), N'Antonio', N'Fuentes', N'Delgado', NULL, N'antonio.delgado@delgadomfg.ph', '09281000005', '1987-09-30', @A5, 0, 'G00005', 1, 'E00003', 4, NULL);
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00006', N'samanthay ', CONVERT(VARBINARY(100), 'Passw0rd!06'), N'Samantha', N'Uy', N'Yu', NULL, N'samantha.yu@gmail.com', '09281000006', '1996-07-12', @A6, 1, 'G00006', 1, NULL, 1, NULL);
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00007', N'rafaelt   ', CONVERT(VARBINARY(100), 'Passw0rd!07'), N'Rafael', NULL, N'Torres', NULL, N'rafael.torres@gmail.com', '09281000007', '1993-01-18', @A7, 1, 'G00007', 1, NULL, 1, NULL);
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00008', N'josefinaa ', CONVERT(VARBINARY(100), 'Passw0rd!08'), N'Josefina', NULL, N'Aquino', NULL, N'josefina.aquino@gmail.com', '09281000008', '1991-04-09', @A8, 1, 'G00008', 1, NULL, 1, NULL);
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00009', N'carmelav  ', CONVERT(VARBINARY(100), 'Passw0rd!09'), N'Carmela', N'Bautista', N'Villanueva', NULL, N'carmela.villanueva@villanuevapkg.ph', '09281000009', '1988-08-08', @A10, 0, 'G00009', 1, 'E00006', 3, NULL);
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00010', N'gabriell  ', CONVERT(VARBINARY(100), 'Passw0rd!10'), N'Gabriel', N'Ong', N'Lim', NULL, N'gabriel.lim@limtech.ph', '09281000010', '1994-12-25', @A9, 0, 'G00010', 1, 'E00005', 4, NULL);
GO

-- Backdate CreatedAt so the admin queue/SLA/avg-approval-time demos have
-- realistic spread (oldest submissions first).
UPDATE dbo.Users SET CreatedAt = DATEADD(DAY, -12, GETDATE()) WHERE UserID = 'U00001';
UPDATE dbo.Users SET CreatedAt = DATEADD(DAY, -11, GETDATE()) WHERE UserID = 'U00002';
UPDATE dbo.Users SET CreatedAt = DATEADD(DAY,  -9, GETDATE()) WHERE UserID = 'U00004';
UPDATE dbo.Users SET CreatedAt = DATEADD(DAY,  -7, GETDATE()) WHERE UserID = 'U00006';
UPDATE dbo.Users SET CreatedAt = DATEADD(DAY,  -6, GETDATE()) WHERE UserID = 'U00007';
UPDATE dbo.Users SET CreatedAt = DATEADD(DAY,  -5, GETDATE()) WHERE UserID = 'U00008';
UPDATE dbo.Users SET CreatedAt = DATEADD(DAY,  -4, GETDATE()) WHERE UserID = 'U00009';
UPDATE dbo.Users SET CreatedAt = DATEADD(DAY,  -2, GETDATE()) WHERE UserID = 'U00003';
UPDATE dbo.Users SET CreatedAt = DATEADD(HOUR, -30, GETDATE()) WHERE UserID = 'U00005';
UPDATE dbo.Users SET CreatedAt = DATEADD(HOUR, -50, GETDATE()) WHERE UserID = 'U00010';
GO

-- Promote seven of the ten to Approved (fires trg_AuditLog_UserStatusUpdate,
-- logging the genuine Pending -> Approved transition). U00003, U00005, and
-- U00010 are left Pending for the admin review demo.
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY, -10, GETDATE()) WHERE UserID = 'U00001';
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY,  -9, GETDATE()) WHERE UserID = 'U00002';
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY,  -7, GETDATE()) WHERE UserID = 'U00004';
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY,  -5, GETDATE()) WHERE UserID = 'U00006';
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY,  -4, GETDATE()) WHERE UserID = 'U00007';
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY,  -3, GETDATE()) WHERE UserID = 'U00008';
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY,  -2, GETDATE()) WHERE UserID = 'U00009';
GO

PRINT '============================================================';
PRINT ' Seed data v3 loaded: 10 Users (3 Pending, 7 Approved), 6 Entities/Branches.';
PRINT '============================================================';
GO
