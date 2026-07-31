const express = require('express');
const router = express.Router();
const { sql, poolPromise } = require('../db');

router.post('/login', async (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) {
    return res.status(400).json({ success: false, message: 'Username and password are required.' });
  }
  if (username.length > 10) {
    return res.status(401).json({ success: false, message: 'Invalid username or password.' });
  }
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.input('Username', sql.NChar(10), username);
    request.input('Password', sql.VarChar(100), password);
    const result = await request.query(`
      SELECT UserID, StatusID
      FROM dbo.Users
      WHERE Username = @Username AND Password = HASHBYTES('SHA2_256', @Password)
    `);

    if (!result.recordset.length) {
      return res.status(401).json({ success: false, message: 'Invalid username or password.' });
    }

    const { UserID, StatusID } = result.recordset[0];
    if (StatusID !== 2) {
      const statusResult = await pool.request()
        .input('StatusID', sql.TinyInt, StatusID)
        .query('SELECT StatusName FROM dbo.AccountStatus WHERE StatusID = @StatusID');
      const statusName = statusResult.recordset[0]?.StatusName || 'Unknown';
      return res.status(403).json({
        success: false,
        message: `Your account status is "${statusName}" and cannot log in yet. Approved accounts only.`,
        statusName
      });
    }

    res.json({ success: true, userId: UserID });
  } catch (err) {
    res.status(500).json({ success: false, message: err.message });
  }
});

module.exports = router;
