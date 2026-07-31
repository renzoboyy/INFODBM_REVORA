const express = require('express');
const router = express.Router();
const { sql, poolPromise } = require('../db');

router.get('/admin/queue', async (req, res) => {
  try {
    const pool = await poolPromise;
    const result = await pool.request().query(`
      SELECT userID AS UserID, FirstName + ' ' + LastName AS FullName, Email, CreatedAt,
             SLABucket AS SLAFlag, QueueReason
      FROM dbo.vw_PendingQueueClassified
      ORDER BY CreatedAt ASC
    `);
    res.json(result.recordset);
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

// Profile-edit resolution workflow (dbo.ProfileEditRequests)
router.get('/admin/edit-requests', async (req, res) => {
  try {
    const pool = await poolPromise;
    const result = await pool.request().query(
      'SELECT * FROM dbo.vw_PendingProfileEdits ORDER BY SubmittedAt ASC'
    );
    res.json(result.recordset);
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

router.post('/admin/edit-requests/:id/approve', async (req, res) => {
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.input('EditRequestID', sql.Char(6), req.params.id);
    request.input('ApprovalNotes', sql.VarChar(250), req.body.notes || 'Approved via admin dashboard.');
    await request.execute('dbo.sp_ApproveProfileEdit');
    res.json({ success: true });
  } catch (err) {
    res.status(400).json({ success: false, message: err.message });
  }
});

router.post('/admin/edit-requests/:id/reject', async (req, res) => {
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.input('EditRequestID', sql.Char(6), req.params.id);
    request.input('RejectionNotes', sql.VarChar(250), req.body.notes || null);
    await request.execute('dbo.sp_RejectProfileEdit');
    res.json({ success: true });
  } catch (err) {
    res.status(400).json({ success: false, message: err.message });
  }
});

// Section F queries (9)-(13): queue count, oldest/newest pending, avg approval time
router.get('/admin/analytics', async (req, res) => {
  try {
    const pool = await poolPromise;
    const [count, statusCounts, minMax, avgTime, pendingThenApproved, entityBased] = await Promise.all([
      pool.request().query('SELECT COUNT(*) AS PendingApplications FROM Users WHERE StatusID = 1'),
      pool.request().query(`
        SELECT
          SUM(CASE WHEN StatusID = 2 THEN 1 ELSE 0 END) AS ApprovedCount,
          SUM(CASE WHEN StatusID = 3 THEN 1 ELSE 0 END) AS RejectedCount
        FROM Users
      `),
      pool.request().query('SELECT MIN(CreatedAt) AS OldestPending, MAX(CreatedAt) AS NewestPending FROM Users WHERE StatusID = 1'),
      pool.request().query(`
        SELECT CAST(AVG(DATEDIFF(HOUR, CreatedAt, ApprovedAt) * 1.00 / 24) AS DECIMAL(3,2)) AS AvgDaysToApprove
        FROM Users WHERE ApprovedAt IS NOT NULL
      `),
      pool.request().query('SELECT COUNT(*) AS Cnt FROM vw_PendingThenApproved'),
      pool.request().query('SELECT COUNT(*) AS Cnt FROM vw_EntityBasedRegistrants')
    ]);
    res.json({
      pendingApplications: count.recordset[0].PendingApplications,
      approvedCount: statusCounts.recordset[0].ApprovedCount,
      rejectedCount: statusCounts.recordset[0].RejectedCount,
      oldestPending: minMax.recordset[0].OldestPending,
      newestPending: minMax.recordset[0].NewestPending,
      avgDaysToApprove: avgTime.recordset[0].AvgDaysToApprove,
      pendingThenApprovedCount: pendingThenApproved.recordset[0].Cnt,
      entityBasedCount: entityBased.recordset[0].Cnt
    });
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

router.get('/admin/users/:id', async (req, res) => {
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.input('UserID', sql.Char(6), req.params.id);
    const result = await request.query('SELECT * FROM dbo.vw_ApplicantDetail WHERE UserID = @UserID');
    if (!result.recordset.length) {
      return res.status(404).json({ message: 'Applicant not found.' });
    }
    res.json(result.recordset[0]);
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

router.post('/admin/users/:id/approve', async (req, res) => {
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.input('TargetUserID', sql.Char(6), req.params.id);
    request.input('ApprovalNotes', sql.VarChar(250), req.body.notes || 'Approved via admin dashboard.');
    await request.execute('dbo.ApproveUserAccount');

    // ApproveUserAccount PRINTs its own errors instead of raising them to the
    // caller, so a no-op (e.g. user wasn't Pending) looks like success unless
    // we confirm the status actually changed.
    const check = pool.request();
    check.input('TargetUserID', sql.Char(6), req.params.id);
    const result = await check.query('SELECT StatusID FROM dbo.Users WHERE UserID = @TargetUserID');
    if (result.recordset[0]?.StatusID !== 2) {
      return res.status(400).json({ success: false, message: 'User was not Pending or does not exist.' });
    }
    res.json({ success: true });
  } catch (err) {
    res.status(400).json({ success: false, message: err.message });
  }
});

router.post('/admin/users/:id/reject', async (req, res) => {
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.input('TargetUserID', sql.Char(6), req.params.id);
    request.input('RejectionNotes', sql.VarChar(250), req.body.notes || null);
    await request.execute('dbo.sp_RejectRegistrant');
    res.json({ success: true });
  } catch (err) {
    res.status(400).json({ success: false, message: err.message });
  }
});

router.get('/admin/branches/:id', async (req, res) => {
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.input('BranchID', sql.Char(6), req.params.id);
    const result = await request.query(`
      SELECT br.BranchID, br.BranchCode, br.DetailedAddress, br.City, br.PostalCode,
             e.EntityID, e.EntityName, e.TIN
      FROM dbo.Branches br
      LEFT JOIN dbo.Entities e ON e.BranchID = br.BranchID
      WHERE br.BranchID = @BranchID
    `);
    if (!result.recordset.length) {
      return res.status(404).json({ message: 'Branch not found.' });
    }
    res.json(result.recordset[0]);
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

router.post('/admin/branches/:id/close', async (req, res) => {
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.input('BranchID', sql.Char(6), req.params.id);
    await request.execute('dbo.sp_CloseBranch');
    res.json({ success: true });
  } catch (err) {
    res.status(400).json({ success: false, message: err.message });
  }
});

module.exports = router;
