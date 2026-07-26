const express = require('express');
const router = express.Router();
const { sql, poolPromise } = require('../db');

router.get('/search', async (req, res) => {
  const { q = '', status } = req.query;
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.input('q', sql.NVarChar, `%${q}%`);
    let where = '(FullName LIKE @q OR EntityName LIKE @q OR TIN LIKE @q OR Username LIKE @q)';
    if (status) {
      request.input('status', sql.TinyInt, status);
      where += ' AND StatusID = @status';
    }
    const result = await request.query(
      `SELECT * FROM dbo.vw_ApplicantDirectory WHERE ${where} ORDER BY CreatedAt DESC`
    );
    res.json(result.recordset);
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

module.exports = router;
