const express = require('express');
const router = express.Router();
const { sql, poolPromise } = require('../db');

router.post('/register', async (req, res) => {
  const b = req.body;
  try {
    const pool = await poolPromise;
    const request = pool.request();

    request.input('AccountType', sql.VarChar(10), b.accountType);
    request.input('DetailedHome', sql.NVarChar(250), b.detailedHome);
    request.input('City', sql.NVarChar(50), b.city);
    request.input('Province', sql.NVarChar(50), b.province);
    request.input('PostalCode', sql.Char(4), b.postalCode);
    request.input('GovtType', sql.VarChar(15), b.govtType);
    request.input('GovtNo', sql.VarChar(20), b.govtNo);

    if (b.accountType === 'Entity') {
      request.input('BranchDetailedAddr', sql.NVarChar(250), b.branchDetailedAddress);
      request.input('BranchCity', sql.NVarChar(50), b.branchCity);
      request.input('BranchPostalCode', sql.Char(4), b.branchPostalCode);
      request.input('EntityName', sql.NVarChar(50), b.entityName);
      request.input('TIN', sql.NChar(11), b.tin);
      request.input('SectorID', sql.Char(6), b.sectorId);
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
    // ROLLBACK already happened inside SQL Server - no partial rows exist
    res.status(400).json({ success: false, message: err.message });
  }
});

module.exports = router;
