const express = require('express');
const router = express.Router();
const { poolPromise } = require('../db');

router.get('/lookups', async (req, res) => {
  try {
    const pool = await poolPromise;
    const [roles, categories, sectors, statuses] = await Promise.all([
      pool.request().query('SELECT RoleID, RoleName FROM dbo.Roles ORDER BY RoleName'),
      pool.request().query('SELECT CategoryID, CategoryName FROM dbo.Categories ORDER BY CategoryName'),
      pool.request().query('SELECT SectorID, SectorName FROM dbo.Sectors ORDER BY SectorName'),
      pool.request().query('SELECT StatusID, StatusName FROM dbo.AccountStatus ORDER BY StatusID')
    ]);
    res.json({
      roles: roles.recordset,
      categories: categories.recordset,
      sectors: sectors.recordset,
      statuses: statuses.recordset,
      govtTypes: ['PhilSys', 'Passport', 'Driver License', 'UMID', 'PRC ID']
    });
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

module.exports = router;
