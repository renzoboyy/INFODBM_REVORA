const express = require('express');
const router = express.Router();
const { sql, poolPromise } = require('../db');

// Self-service: submit a proposed edit. Re-queues the account to Pending
// (dbo.sp_RequestProfileEdit) and blocks a second submission until the
// first is resolved by an admin.
router.post('/profile/edit-request', async (req, res) => {
  const b = req.body;
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.input('TargetUserID', sql.Char(6), b.userId);
    request.input('NewEmail', sql.NVarChar(50), b.newEmail || null);
    request.input('NewPhoneNumber', sql.Char(11), b.newPhoneNumber || null);
    request.input('NewDetailedHome', sql.NVarChar(250), b.newDetailedHome || null);
    request.input('NewCity', sql.NVarChar(50), b.newCity || null);
    request.input('NewProvince', sql.NVarChar(50), b.newProvince || null);
    request.input('NewPostalCode', sql.Char(4), b.newPostalCode || null);
    request.input('NewEntityName', sql.NVarChar(50), b.newEntityName || null);
    request.input('NewTIN', sql.NChar(11), b.newTIN || null);
    request.input('NewSectorID', sql.Char(6), b.newSectorId || null);
    request.input('NewBranchDetailedAddr', sql.NVarChar(250), b.newBranchDetailedAddress || null);
    request.input('NewBranchCity', sql.NVarChar(50), b.newBranchCity || null);
    request.input('NewBranchPostalCode', sql.Char(4), b.newBranchPostalCode || null);
    request.output('NewRequestID', sql.Char(6));

    const result = await request.execute('dbo.sp_RequestProfileEdit');
    res.json({ success: true, requestId: result.output.NewRequestID });
  } catch (err) {
    res.status(400).json({ success: false, message: err.message });
  }
});

// Self-service: check whether the caller already has an edit request
// awaiting review, and if so, what it proposed (old-vs-new diff).
router.get('/profile/edit-request/:userId', async (req, res) => {
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.input('UserID', sql.Char(6), req.params.userId);
    const result = await request.query(
      'SELECT * FROM dbo.vw_PendingProfileEdits WHERE UserID = @UserID'
    );
    res.json(result.recordset[0] || null);
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

module.exports = router;
