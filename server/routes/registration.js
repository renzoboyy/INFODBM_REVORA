const express = require('express');
const router = express.Router();
const { sql, poolPromise } = require('../db');

// Translates raw SQL Server constraint-violation text (CHECK/UNIQUE
// violations bubbling up from sp_RegisterUser) into a message a registrant
// can actually act on. Matched by constraint name since that's the one
// stable substring SQL Server always includes in the error text, regardless
// of which column/table the message otherwise mentions.
const CONSTRAINT_MESSAGES = [
  [/CK_GovernmentID_Validation/i, 'The government ID number does not match the required format for the selected ID type.'],
  [/CK_TIN_Length/i,               'TIN must be exactly 11 characters.'],
  [/CK_Email_Format/i,             'Please enter a valid email address.'],
  [/CK_PhoneNumber_Format/i,       'Phone number must be in the format 09XXXXXXXXX.'],
  [/CK_BirthDate_Valid/i,          'Please enter a valid date of birth.'],
  [/CK_Address_PostalCode|CK_Barangay_PostalCode/i, 'Postal code must be exactly 4 digits.'],
  [/UK_Users_Username/i,           'That username is already taken. Please choose another.'],
  [/UK_Users_Email/i,              'An account with that email address already exists.'],
  [/UK_Users_PhoneNumber/i,        'An account with that phone number already exists.'],
  [/UK_GID_TypeAndNo|UK_GovtID/i,  'This government ID is already registered to another account.'],
  [/UK_TIN/i,                      'An entity with that TIN is already registered.'],
  [/UK_Address/i,                  'That address is already on file under different details. Please double-check your entries.']
];

function friendlyRegistrationError(err) {
  const raw = err && err.message ? err.message : '';
  for (const [pattern, friendly] of CONSTRAINT_MESSAGES) {
    if (pattern.test(raw)) return friendly;
  }
  if (/UNIQUE KEY constraint|Violation of PRIMARY KEY/i.test(raw)) {
    return 'Some of the information you entered is already associated with another account.';
  }
  if (/CHECK constraint/i.test(raw)) {
    return 'One of the fields you entered is not in a valid format. Please review your entries and try again.';
  }
  return 'We could not complete your registration due to a server error. Please try again, and contact support if the problem continues.';
}

// Fixed-length driver-bound columns (NCHAR/CHAR) throw an opaque low-level
// TDS protocol error - not a catchable SQL constraint message - when handed
// a value longer than the column, so those lengths must be rejected here,
// before ever reaching request.input(). Everything else here just
// duplicates the client-side checks in public/js/register.js as a
// server-side backstop (never trust the client).
function validateRegistrationInput(b) {
  if (!b.username || b.username.length > 10) return 'Username must be 10 characters or fewer.';
  if (!b.password || b.password.length > 32) return 'Password must be 32 characters or fewer.';
  if (!b.email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(b.email)) return 'Please enter a valid email address.';
  if (!b.phoneNumber || !/^09[0-9]{9}$/.test(b.phoneNumber)) return 'Phone number must be in the format 09XXXXXXXXX.';
  if (!b.postalCode || !/^[0-9]{4}$/.test(b.postalCode)) return 'Postal code must be exactly 4 digits.';
  if (!b.govtNo || b.govtNo.length > 20) return 'Government ID number is too long.';
  // Region/Province/City/Barangay are all required in the registration UI's
  // geography picker (GET /api/geo/*) - this is a server-side backstop
  // matching that, not a new business rule.
  if (!b.region) return 'Please select a region.';
  if (!b.province) return 'Please select or enter a province.';
  if (!b.city) return 'Please select or enter a city/municipality.';
  if (!b.barangay) return 'Please select or enter a barangay.';
  if (b.accountType === 'Entity') {
    if (!b.tin || !/^[0-9]{11}$/.test(b.tin)) return 'TIN must be exactly 11 digits.';
    if (!b.branchPostalCode || !/^[0-9]{4}$/.test(b.branchPostalCode)) return 'Branch postal code must be exactly 4 digits.';
    if (!b.branchRegion) return 'Please select a branch region.';
    if (!b.branchProvince) return 'Please select or enter a branch province.';
    if (!b.branchCity) return 'Please select or enter a branch city/municipality.';
    if (!b.branchBarangay) return 'Please select or enter a branch barangay.';
  }
  return null;
}

router.post('/register', async (req, res) => {
  const b = req.body;
  const validationError = validateRegistrationInput(b);
  if (validationError) {
    return res.status(400).json({ success: false, message: validationError });
  }
  try {
    const pool = await poolPromise;
    const request = pool.request();

    request.input('AccountType', sql.VarChar(10), b.accountType);
    request.input('DetailedHome', sql.NVarChar(250), b.detailedHome);
    request.input('City', sql.NVarChar(50), b.city);
    request.input('PostalCode', sql.Char(4), b.postalCode);
    request.input('GovtType', sql.VarChar(15), b.govtType);
    request.input('GovtNo', sql.VarChar(20), b.govtNo);

    // @Province/@Barangay/@Region all default to 'Unspecified' in
    // sp_RegisterUser - only bind them when a real value was submitted, so
    // an omitted/blank field falls through to that default instead of being
    // written as NULL. This matters because Province.ProvinceName and
    // Region.RegionName are both NOT NULL in the schema; binding an empty
    // Province as SQL NULL here would throw a raw constraint violation
    // inside sp_ResolveAddress instead of failing gracefully.
    if (b.province) request.input('Province', sql.NVarChar(50), b.province);
    if (b.barangay) request.input('Barangay', sql.NVarChar(50), b.barangay);
    if (b.region) request.input('Region', sql.NVarChar(50), b.region);

    if (b.accountType === 'Entity') {
      request.input('BranchDetailedAddr', sql.NVarChar(250), b.branchDetailedAddress);
      request.input('BranchCity', sql.NVarChar(50), b.branchCity);
      request.input('BranchProvince', sql.NVarChar(50), b.branchProvince);
      request.input('BranchPostalCode', sql.Char(4), b.branchPostalCode);
      request.input('EntityName', sql.NVarChar(50), b.entityName);
      request.input('TIN', sql.NChar(11), b.tin);
      request.input('SectorID', sql.Char(6), b.sectorId);
      if (b.branchBarangay) request.input('BranchBarangay', sql.NVarChar(50), b.branchBarangay);
      if (b.branchRegion) request.input('BranchRegion', sql.NVarChar(50), b.branchRegion);
    }

    request.input('Username', sql.NChar(10), b.username);
    request.input('PlainPassword', sql.VarChar(100), b.password);
    request.input('FirstName', sql.NVarChar(50), b.firstName);
    request.input('MiddleName', sql.NVarChar(50), b.middleName || null);
    request.input('LastName', sql.NVarChar(50), b.lastName);
    request.input('Suffix', sql.NVarChar(50), b.suffix || null);
    request.input('Email', sql.NVarChar(50), b.email);
    request.input('PhoneNumber', sql.Char(11), b.phoneNumber);
    request.input('BirthDate', sql.Date, b.birthDate);
    request.input('RoleID', sql.Bit, b.roleId);
    request.input('CategoryID', sql.TinyInt, b.categoryId);
    request.output('NewUserID', sql.Char(6));

    const result = await request.execute('dbo.sp_RegisterUser');
    res.json({
      success: true,
      userId: result.output.NewUserID,
      message: 'Registration submitted - pending review.'
    });
  } catch (err) {
    // ROLLBACK already happened inside SQL Server - no partial rows exist.
    // Log the raw driver/SQL error for debugging, but never send it to the
    // client as-is - translate it into something a registrant can act on.
    console.error('Registration failed:', err.message);
    res.status(400).json({ success: false, message: friendlyRegistrationError(err) });
  }
});

module.exports = router;
