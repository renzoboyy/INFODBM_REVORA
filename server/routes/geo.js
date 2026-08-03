const express = require('express');
const router = express.Router();
const { sql, poolPromise } = require('../db');

// The 17 official PH regions - fixed, closed set, mirrored in dbo.Region by
// db/02_lookups_v3.sql. Served as a static list rather than a query so the
// dropdown is always complete even before any registrant has picked a
// given region.
const PH_REGIONS = [
  'NCR', 'CAR', 'Region I', 'Region II', 'Region III', 'Region IV-A', 'MIMAROPA',
  'Region V', 'Region VI', 'Region VII', 'Region VIII', 'Region IX', 'Region X',
  'Region XI', 'Region XII', 'Region XIII', 'BARMM'
];

router.get('/geo/regions', (req, res) => {
  res.json(PH_REGIONS);
});

// Province/City/Barangay are NOT exhaustively pre-seeded (unlike Region) -
// there's no reliable, complete PH-wide dataset baked into this app. These
// three endpoints only ever return what dbo.Province/CityMunicipality/
// Barangay already contain (i.e. whatever prior registrants have entered),
// filtered by the parent selection. The registration UI pairs each of these
// with an "Other (not listed)" free-text fallback for anything not yet seen.

router.get('/geo/provinces', async (req, res) => {
  const { region } = req.query;
  if (!region) return res.json([]);
  try {
    const pool = await poolPromise;
    const result = await pool.request()
      .input('Region', sql.NVarChar(50), region)
      .query(`
        SELECT DISTINCT p.ProvinceName
        FROM dbo.Province p
        JOIN dbo.Region r ON p.RegionID = r.RegionID
        WHERE r.RegionName = @Region
        ORDER BY p.ProvinceName
      `);
    res.json(result.recordset.map(r => r.ProvinceName));
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

router.get('/geo/cities', async (req, res) => {
  const { region, province } = req.query;
  if (!region || !province) return res.json([]);
  try {
    const pool = await poolPromise;
    const result = await pool.request()
      .input('Region', sql.NVarChar(50), region)
      .input('Province', sql.NVarChar(50), province)
      .query(`
        SELECT DISTINCT cm.CityName
        FROM dbo.CityMunicipality cm
        JOIN dbo.Province p ON cm.ProvinceID = p.ProvinceID
        JOIN dbo.Region r ON p.RegionID = r.RegionID
        WHERE r.RegionName = @Region AND p.ProvinceName = @Province
        ORDER BY cm.CityName
      `);
    res.json(result.recordset.map(r => r.CityName));
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

router.get('/geo/barangays', async (req, res) => {
  const { region, province, city } = req.query;
  if (!region || !province || !city) return res.json([]);
  try {
    const pool = await poolPromise;
    const result = await pool.request()
      .input('Region', sql.NVarChar(50), region)
      .input('Province', sql.NVarChar(50), province)
      .input('City', sql.NVarChar(50), city)
      .query(`
        SELECT DISTINCT bg.BarangayName, bg.PostalCode
        FROM dbo.Barangay bg
        JOIN dbo.CityMunicipality cm ON bg.CityID = cm.CityID
        JOIN dbo.Province p ON cm.ProvinceID = p.ProvinceID
        JOIN dbo.Region r ON p.RegionID = r.RegionID
        WHERE r.RegionName = @Region AND p.ProvinceName = @Province AND cm.CityName = @City
        ORDER BY bg.BarangayName
      `);
    res.json(result.recordset);
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

module.exports = router;
