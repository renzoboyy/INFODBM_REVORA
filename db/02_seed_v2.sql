/* ============================================================================
   REVORA - SEED DATA v2 (matches 01_schema_v2.sql)
   All users are first INSERTed as Pending (so trg_AuditLog_UserInsert logs
   "Pending" for every one of them), then most are promoted to Approved via
   UPDATE (so trg_AuditLog_UserStatusUpdate logs "Approved" for those) -
   this gives every approved user a genuine Pending -> Approved audit trail,
   which the INTERSECT demo query in Section F relies on.
   ============================================================================ */

USE [INFODBM_REVORA];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

INSERT INTO dbo.Roles (RoleID, RoleName) VALUES
    (0, 'Generator'),
    (1, 'Upcycler');
GO

INSERT INTO dbo.Categories (CategoryID, CategoryName) VALUES
    (1, 'Individual'),
    (2, 'Sole Prop'),
    (3, 'Small Business'),
    (4, 'Corporation');
GO

INSERT INTO dbo.AccountStatus (StatusID, StatusName) VALUES
    (1, 'Pending'),
    (2, 'Approved'),
    (3, 'Rejected'),
    (4, 'Suspended'),
    (5, 'Deleted'),
    (6, 'Closed');
GO

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

INSERT INTO dbo.Address (AddressID, DetailedHome, City, Province, PostalCode) VALUES
    ('A00001', '12 Weaver St., Taguig',             'Taguig',       'Metro Manila',  '1630'),
    ('A00002', '45 Greenway Blvd., Quezon City',     'Quezon City',  'Metro Manila',  '1100'),
    ('A00003', '27 Samson Rd., Bagumbong, Caloocan', 'Caloocan',     'Metro Manila',  '1420'),
    ('A00004', '33 Fuentes St., Mandurriao',         'Iloilo City',  'Iloilo',        '5000'),
    ('A00005', '8 Uy Compound, Cubao',                'Quezon City',  'Metro Manila',  '1109'),
    ('A00006', '19 Torres Ave., Makati',              'Makati',       'Metro Manila',  '1200'),
    ('A00007', '5 Aquino Lane, San Juan',             'San Juan',     'Metro Manila',  '1500'),
    ('A00008', 'Purok 2, Malolos',                     'Malolos',      'Bulacan',       '3000'),
    ('A00009', '77 Ong Residences, Davao',             'Davao City',   'Davao del Sur', '8000'),
    ('A00010', '3 Villanueva Compound, Meycauayan',    'Meycauayan',   'Bulacan',       '3020');
GO

INSERT INTO dbo.Branches (BranchID, BranchCode, DetailedAddress, City, PostalCode) VALUES
    ('B00001', '00001', 'Unit 4, Textile Row, Taguig',                'Taguig',      '1630'),
    ('B00002', '00002', '88 Recyclers Ave., Quezon City',             'Quezon City', '1100'),
    ('B00003', '00003', 'Main Plant, Mandurriao Industrial Zone',     'Iloilo City', '5000'),
    ('B00004', '00004', 'Agri Hub Bldg., Malolos',                    'Malolos',     '3000'),
    ('B00005', '00005', 'IT Park Tower, Davao City',                  'Davao City',  '8000'),
    ('B00006', '00006', 'Packaging Complex, Meycauayan',              'Meycauayan',  '3020');
GO

INSERT INTO dbo.Entities (EntityID, EntityName, TIN, SectorID, BranchID) VALUES
    ('E00001', 'Santos Textile Works',     '101-202-303', 'S00001', 'B00001'),
    ('E00002', 'Reyes Upcycled Goods',     '202-303-404', 'S00006', 'B00002'),
    ('E00003', 'Delgado Manufacturing',    '303-404-505', 'S00004', 'B00003'),
    ('E00004', 'Cruz Agri Ventures',       '404-505-606', 'S00008', 'B00004'),
    ('E00005', 'Lim Tech Solutions',       '505-606-707', 'S00009', 'B00005'),
    ('E00006', 'Villanueva Packaging Co.', '606-707-808', 'S00002', 'B00006');
GO

-- Users are inserted one statement at a time (not a multi-row VALUES list):
-- trg_AuditLog_UserInsert computes its LogID as a single scalar
-- (SELECT COUNT(*)+1 FROM AuditLog) per *statement*, not per row, so a
-- multi-row INSERT would assign every new user the same LogID and violate
-- PK_AuditLog.
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00001', N'miguels   ', CONVERT(VARBINARY(100), 'Passw0rd!01'), N'Miguel', NULL, N'Santos', NULL, N'miguel.santos@santostextile.ph', '09281000001', '1980-02-14', 'A00001', 0, 'G00001', 1, 'E00001', 4, NULL);
GO
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00002', N'biancar   ', CONVERT(VARBINARY(100), 'Passw0rd!02'), N'Bianca', N'Lopez', N'Reyes', NULL, N'bianca.reyes@recycledgoods.ph', '09281000002', '1990-06-21', 'A00002', 0, 'G00002', 1, 'E00002', 3, NULL);
GO
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00003', N'diegor    ', CONVERT(VARBINARY(100), 'Passw0rd!03'), N'Diego', N'Villar', N'Ramos', NULL, N'diego.ramos@gmail.com', '09281000003', '1999-11-05', 'A00003', 1, 'G00003', 1, NULL, 1, NULL);
GO
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00004', N'patriciac ', CONVERT(VARBINARY(100), 'Passw0rd!04'), N'Patricia', N'Manalo', N'Cruz', NULL, N'patricia.cruz@cruzagri.ph', '09281000004', '1985-03-30', 'A00004', 0, 'G00004', 1, 'E00004', 2, NULL);
GO
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00005', N'antoniod  ', CONVERT(VARBINARY(100), 'Passw0rd!05'), N'Antonio', N'Fuentes', N'Delgado', NULL, N'antonio.delgado@delgadomfg.ph', '09281000005', '1987-09-30', 'A00005', 0, 'G00005', 1, 'E00003', 4, NULL);
GO
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00006', N'samanthay ', CONVERT(VARBINARY(100), 'Passw0rd!06'), N'Samantha', N'Uy', N'Yu', NULL, N'samantha.yu@gmail.com', '09281000006', '1996-07-12', 'A00006', 1, 'G00006', 1, NULL, 1, NULL);
GO
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00007', N'rafaelt   ', CONVERT(VARBINARY(100), 'Passw0rd!07'), N'Rafael', NULL, N'Torres', NULL, N'rafael.torres@gmail.com', '09281000007', '1993-01-18', 'A00007', 1, 'G00007', 1, NULL, 1, NULL);
GO
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00008', N'josefinaa ', CONVERT(VARBINARY(100), 'Passw0rd!08'), N'Josefina', NULL, N'Aquino', NULL, N'josefina.aquino@gmail.com', '09281000008', '1991-04-09', 'A00008', 1, 'G00008', 1, NULL, 1, NULL);
GO
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00009', N'carmelav  ', CONVERT(VARBINARY(100), 'Passw0rd!09'), N'Carmela', N'Bautista', N'Villanueva', NULL, N'carmela.villanueva@villanuevapkg.ph', '09281000009', '1988-08-08', 'A00010', 0, 'G00009', 1, 'E00006', 3, NULL);
GO
INSERT INTO dbo.Users (UserID, Username, Password, FirstName, MiddleName, LastName, Suffix, Email, PhoneNumber, BirthDate, Address, RoleID, GovtID, StatusID, EntityID, CategoryID, ApprovedAt)
VALUES ('U00010', N'gabriell  ', CONVERT(VARBINARY(100), 'Passw0rd!10'), N'Gabriel', N'Ong', N'Lim', NULL, N'gabriel.lim@limtech.ph', '09281000010', '1994-12-25', 'A00009', 0, 'G00010', 1, 'E00005', 4, NULL);
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
UPDATE dbo.Users SET CreatedAt = DATEADD(DAY,   -2, GETDATE()) WHERE UserID = 'U00003';
UPDATE dbo.Users SET CreatedAt = DATEADD(HOUR, -30, GETDATE()) WHERE UserID = 'U00005';
UPDATE dbo.Users SET CreatedAt = DATEADD(HOUR, -50, GETDATE()) WHERE UserID = 'U00010';
GO

-- Promote seven of the ten to Approved (fires trg_AuditLog_UserStatusUpdate,
-- logging the genuine Pending -> Approved transition). U00003, U00005, and
-- U00010 are left Pending for the admin review / branch closure demo.
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY, -10, GETDATE()) WHERE UserID = 'U00001';
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY,  -9, GETDATE()) WHERE UserID = 'U00002';
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY,  -7, GETDATE()) WHERE UserID = 'U00004';
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY,  -5, GETDATE()) WHERE UserID = 'U00006';
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY,  -4, GETDATE()) WHERE UserID = 'U00007';
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY,  -3, GETDATE()) WHERE UserID = 'U00008';
UPDATE dbo.Users SET StatusID = 2, ApprovedAt = DATEADD(DAY,  -2, GETDATE()) WHERE UserID = 'U00009';
GO

PRINT '============================================================';
PRINT ' Seed data v2 loaded: 10 Users (3 Pending, 7 Approved).';
PRINT '============================================================';
GO
