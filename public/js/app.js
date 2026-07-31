function showMessage(text, type) {
  const el = document.getElementById('message');
  if (!el) return;
  el.innerHTML = `<div class="msg msg-${type === 'success' ? 'success' : 'error'}">${text}</div>`;
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function debounce(fn, delay) {
  let timer;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), delay);
  };
}

const SLA_BADGE = { 'On Track': 'badge-green', 'Due Soon': 'badge-yellow', 'Overdue': 'badge-red', 'N/A': 'badge-gray' };
const STATUS_BADGE = {
  Pending: 'badge-yellow', Approved: 'badge-green', Rejected: 'badge-red',
  Suspended: 'badge-gray', Deleted: 'badge-red', Closed: 'badge-gray'
};

let currentTabStatus = '1';
let selectedApplicantId = null;

async function loadAnalytics() {
  const grid = document.getElementById('statGrid');
  const secondaryGrid = document.getElementById('statGridSecondary');
  if (!grid) return;
  const a = await (await fetch('/api/admin/analytics')).json();

  const primaryTiles = [
    ['Pending Applications', a.pendingApplications],
    ['Oldest Application', a.oldestPending ? new Date(a.oldestPending).toLocaleString() : '-'],
    ['Newest Application', a.newestPending ? new Date(a.newestPending).toLocaleString() : '-'],
    ['Average Approval Time', a.avgDaysToApprove != null ? `${a.avgDaysToApprove} Days` : '-']
  ];
  grid.innerHTML = primaryTiles.map(([label, value]) => `
    <div class="stat-tile">
      <div class="stat-value">${value}</div>
      <div class="stat-label">${label}</div>
    </div>
  `).join('');

  const secondaryTiles = [
    ['Pending -> Approved (INTERSECT)', a.pendingThenApprovedCount],
    ['Entity-Based Registrants (EXCEPT)', a.entityBasedCount]
  ];
  secondaryGrid.innerHTML = secondaryTiles.map(([label, value]) => `
    <div class="stat-tile stat-tile-compact">
      <div class="stat-value">${value}</div>
      <div class="stat-label">${label}</div>
    </div>
  `).join('');

  document.getElementById('countPending').textContent = a.pendingApplications;
  document.getElementById('countApproved').textContent = a.approvedCount;
  document.getElementById('countRejected').textContent = a.rejectedCount;
}

function initials(fullName) {
  return fullName.split(' ').filter(Boolean).slice(0, 2).map(w => w[0].toUpperCase()).join('');
}

async function loadApplicantList(status) {
  const list = document.getElementById('applicantList');
  if (!list) return;

  let rows;
  if (status === '1') {
    rows = await (await fetch('/api/admin/queue')).json();
  } else {
    const res = await fetch(`/api/search?q=&status=${status}`);
    rows = await res.json();
  }

  list.innerHTML = rows.map(r => `
    <div class="applicant-row" data-id="${r.UserID}">
      <div class="applicant-avatar">${initials(r.FullName)}</div>
      <div class="applicant-info">
        <div class="applicant-name">${r.FullName}</div>
        <div class="applicant-email">${r.Email}</div>
      </div>
      <div style="margin-left:auto;display:flex;gap:6px;flex-shrink:0;">
        ${r.QueueReason === 'Profile Edit' ? `<span class="badge badge-gray">Edit</span>` : ''}
        ${r.SLAFlag && r.SLAFlag !== 'N/A' ? `<span class="badge ${SLA_BADGE[r.SLAFlag] || 'badge-gray'}">${r.SLAFlag}</span>` : ''}
      </div>
    </div>
  `).join('') || '<p class="muted" style="padding:14px;">No registrations in this status.</p>';

  list.querySelectorAll('.applicant-row').forEach(row => {
    row.addEventListener('click', () => selectApplicant(row.dataset.id));
  });

  if (selectedApplicantId && rows.some(r => r.UserID === selectedApplicantId)) {
    const row = list.querySelector(`.applicant-row[data-id="${selectedApplicantId}"]`);
    if (row) row.classList.add('selected');
  } else {
    selectedApplicantId = null;
    document.getElementById('reviewDetailPane').innerHTML =
      '<p class="muted placeholder-text">Select registration to view applicant details.</p>';
  }
}

async function handleDecision(userId, action) {
  const notesInput = document.getElementById('reviewNotes');
  const notes = notesInput ? notesInput.value.trim() : '';
  const res = await fetch(`/api/admin/users/${userId}/${action}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ notes: notes || undefined })
  });
  const data = await res.json();
  if (data.success) {
    showMessage(`User ${userId} ${action}d.`, 'success');
    selectedApplicantId = null;
    loadApplicantList(currentTabStatus);
    runSearch();
    loadAnalytics();
  } else {
    showMessage(data.message, 'error');
  }
}

function addr(detailed, barangay, city, province, region, postal) {
  if (!detailed) return null;
  const barangayPart = barangay && barangay !== 'Unspecified' ? ', ' + barangay : '';
  const regionPart = region && region !== 'Unspecified' ? ' (' + region + ')' : '';
  return `${detailed}${barangayPart}, ${city}${province ? ', ' + province : ''} ${postal || ''}${regionPart}`.trim();
}

async function selectApplicant(userId) {
  selectedApplicantId = userId;
  document.querySelectorAll('.applicant-row').forEach(row => {
    row.classList.toggle('selected', row.dataset.id === userId);
  });

  const pane = document.getElementById('reviewDetailPane');
  const res = await fetch(`/api/admin/users/${userId}`);
  if (!res.ok) {
    showMessage('Could not load applicant details.', 'error');
    return;
  }
  const a = await res.json();

  const personalAddr = addr(a.DetailedHome, a.HomeBarangay, a.HomeCity, a.HomeProvince, a.HomeRegion, a.HomePostalCode);
  const branchAddr = addr(a.BranchDetailedAddress, a.BranchBarangay, a.BranchCity, a.BranchProvince, a.BranchRegion, a.BranchPostalCode);

  let entityRows = '';
  if (a.EntityName) {
    entityRows = `
      <div class="section-label">Entity Information</div>
      <dt>Entity Name</dt><dd>${a.EntityName}</dd>
      <dt>TIN</dt><dd>${(a.TIN || '').trim()}</dd>
      <dt>Sector</dt><dd>${a.SectorName}</dd>
      <dt>Branch ID</dt><dd>${a.BranchID || '-'}</dd>
      <dt>Branch Address</dt><dd>${branchAddr || '-'}</dd>
    `;
  }

  const actionsHtml = a.StatusID === 1 ? `
    <div class="modal-footer">
      <textarea id="reviewNotes" rows="2" placeholder="Optional notes (shown in the audit log)..."></textarea>
      <div class="actions" style="margin-top:10px;">
        <button type="button" class="btn-approve" id="reviewApprove">Approve</button>
        <button type="button" class="btn-reject" id="reviewReject">Reject</button>
      </div>
    </div>
  ` : '';

  pane.innerHTML = `
    <h2>${a.FirstName} ${a.MiddleName ? a.MiddleName + ' ' : ''}${a.LastName}${a.Suffix ? ' ' + a.Suffix : ''}</h2>
    <dl class="detail-grid">
      <div class="section-label">Account</div>
      <dt>User ID</dt><dd>${a.UserID}</dd>
      <dt>Username</dt><dd>${a.Username.trim()}</dd>
      <dt>Status</dt><dd><span class="badge ${STATUS_BADGE[a.StatusName] || 'badge-gray'}">${a.StatusName}</span></dd>
      <dt>Role / Category</dt><dd>${a.RoleName} - ${a.CategoryName}</dd>
      <dt>Submitted</dt><dd>${new Date(a.CreatedAt).toLocaleString()}</dd>

      <div class="section-label">Contact</div>
      <dt>Email</dt><dd>${a.Email}</dd>
      <dt>Phone</dt><dd>${a.PhoneNumber}</dd>
      <dt>Birth Date</dt><dd>${new Date(a.BirthDate).toLocaleDateString()}</dd>

      <div class="section-label">Government ID</div>
      <dt>Type</dt><dd>${a.GovtType}</dd>
      <dt>Number</dt><dd>${a.GovtNo}</dd>

      <div class="section-label">Home Address</div>
      <dt>Address</dt><dd>${personalAddr || '-'}</dd>

      ${entityRows}
    </dl>
    ${actionsHtml}
  `;

  if (a.StatusID === 1) {
    document.getElementById('reviewApprove').onclick = () => handleDecision(a.UserID, 'approve');
    document.getElementById('reviewReject').onclick = () => handleDecision(a.UserID, 'reject');
  }
}

async function runSearch() {
  const body = document.getElementById('resultsBody');
  if (!body) return;
  const q = document.getElementById('searchBox').value;
  const status = document.getElementById('statusFilter').value;
  const res = await fetch(`/api/search?q=${encodeURIComponent(q)}&status=${status}`);
  const rows = await res.json();
  body.innerHTML = rows.map(r => `
    <tr>
      <td>${r.UserID}</td>
      <td>${r.FullName}</td>
      <td>${r.Email}</td>
      <td>${r.CategoryName}</td>
      <td><span class="badge ${STATUS_BADGE[r.StatusName] || 'badge-gray'}">${r.StatusName}</span></td>
      <td>${r.EntityName || '-'}</td>
    </tr>
  `).join('') || '<tr><td colspan="6" class="muted">No results.</td></tr>';
}

async function lookupBranch() {
  const id = document.getElementById('branchIdInput').value.trim();
  const resultEl = document.getElementById('branchLookupResult');
  if (!id) return;
  const res = await fetch(`/api/admin/branches/${id}`);
  if (!res.ok) {
    resultEl.innerHTML = '<p class="msg msg-error">Branch not found.</p>';
    return;
  }
  const b = await res.json();
  resultEl.innerHTML = `
    <dl class="detail-grid">
      <dt>Branch ID</dt><dd>${b.BranchID}</dd>
      <dt>Address</dt><dd>${b.DetailedAddress}, ${b.City} ${b.PostalCode}</dd>
      <dt>Linked Entity</dt><dd>${b.EntityName || '(none)'}</dd>
    </dl>
    <button type="button" class="btn-reject" id="branchCloseBtn">Confirm Close Branch</button>
  `;
  document.getElementById('branchCloseBtn').addEventListener('click', () => closeBranch(id));
}

let sectorMap = null;
async function ensureSectorMap() {
  if (sectorMap) return sectorMap;
  const res = await fetch('/api/lookups');
  const data = await res.json();
  sectorMap = {};
  (data.sectors || []).forEach(s => { sectorMap[s.SectorID] = s.SectorName; });
  return sectorMap;
}

const EDIT_DIFF_FIELDS = [
  { cur: 'CurrentEmail', new: 'NewEmail', label: 'Email' },
  { cur: 'CurrentPhoneNumber', new: 'NewPhoneNumber', label: 'Phone Number' },
  { cur: 'CurrentDetailedHome', new: 'NewDetailedHome', label: 'Home Address' },
  { cur: 'CurrentCity', new: 'NewCity', label: 'City' },
  { cur: 'CurrentProvince', new: 'NewProvince', label: 'Province' },
  { cur: 'CurrentPostalCode', new: 'NewPostalCode', label: 'Postal Code' },
  { cur: 'CurrentEntityName', new: 'NewEntityName', label: 'Entity Name' },
  { cur: 'CurrentTIN', new: 'NewTIN', label: 'TIN' },
  { cur: 'CurrentSectorID', new: 'NewSectorID', label: 'Sector', resolve: v => (sectorMap && sectorMap[v]) || v },
  { cur: 'CurrentBranchAddress', new: 'NewBranchDetailedAddr', label: 'Branch Address' },
  { cur: 'CurrentBranchCity', new: 'NewBranchCity', label: 'Branch City' },
  { cur: 'CurrentBranchPostalCode', new: 'NewBranchPostalCode', label: 'Branch Postal Code' }
];

function renderEditRequestCard(r) {
  const rows = EDIT_DIFF_FIELDS
    .filter(f => r[f.new] !== null && r[f.new] !== undefined)
    .map(f => {
      const curVal = f.resolve ? f.resolve(r[f.cur]) : (r[f.cur] || '-');
      const newVal = f.resolve ? f.resolve(r[f.new]) : r[f.new];
      return `<tr><td>${f.label}</td><td>${curVal}</td><td><strong>${newVal}</strong></td></tr>`;
    }).join('');

  return `
    <div class="card">
      <h2>Request ${r.EditRequestID} &mdash; ${r.UserID}</h2>
      <p class="muted">Submitted ${new Date(r.SubmittedAt).toLocaleString()}</p>
      <table>
        <thead><tr><th>Field</th><th>Current</th><th>Proposed</th></tr></thead>
        <tbody>${rows || '<tr><td colspan="3" class="muted">No fields changed.</td></tr>'}</tbody>
      </table>
      <textarea class="edit-req-notes" rows="2" placeholder="Optional notes (shown in the audit log)..."></textarea>
      <div class="actions" style="margin-top:10px;">
        <button type="button" class="btn-approve" data-action="approve" data-id="${r.EditRequestID}">Approve</button>
        <button type="button" class="btn-reject" data-action="reject" data-id="${r.EditRequestID}">Reject</button>
      </div>
    </div>
  `;
}

async function loadEditRequests() {
  const container = document.getElementById('editRequestsList');
  if (!container) return;

  await ensureSectorMap();
  const res = await fetch('/api/admin/edit-requests');
  const rows = await res.json();

  container.innerHTML = rows.map(renderEditRequestCard).join('') ||
    '<div class="card"><p class="muted placeholder-text">No profile edit requests awaiting review.</p></div>';

  const countEl = document.getElementById('editReqCount');
  if (countEl) countEl.textContent = rows.length;

  container.querySelectorAll('[data-action]').forEach(btn => {
    btn.addEventListener('click', () => resolveEditRequest(btn.dataset.id, btn.dataset.action, btn));
  });
}

async function resolveEditRequest(id, action, btn) {
  const card = btn.closest('.card');
  const notes = card.querySelector('.edit-req-notes').value.trim();
  card.querySelectorAll('button').forEach(b => b.disabled = true);

  const res = await fetch(`/api/admin/edit-requests/${id}/${action}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ notes: notes || undefined })
  });
  const data = await res.json();

  if (data.success) {
    showMessage(`Edit request ${id} ${action}d.`, 'success');
    loadEditRequests();
    loadApplicantList(currentTabStatus);
    runSearch();
    loadAnalytics();
  } else {
    showMessage(data.message, 'error');
    card.querySelectorAll('button').forEach(b => b.disabled = false);
  }
}

async function closeBranch(id) {
  const res = await fetch(`/api/admin/branches/${id}/close`, { method: 'POST' });
  const data = await res.json();
  if (data.success) {
    showMessage(`Branch ${id} closed: linked user(s) set to Closed, entity unlinked, branch record deleted.`, 'success');
    document.getElementById('branchLookupResult').innerHTML = '';
    document.getElementById('branchIdInput').value = '';
    loadQueue();
    runSearch();
    loadAnalytics();
  } else {
    showMessage(data.message, 'error');
  }
}

function initAdminNav() {
  const navItems = document.querySelectorAll('.nav-item');
  if (!navItems.length) return;
  navItems.forEach(item => {
    item.addEventListener('click', e => {
      e.preventDefault();
      navItems.forEach(i => i.classList.remove('active'));
      item.classList.add('active');
      document.querySelectorAll('.admin-panel').forEach(panel => panel.classList.add('hidden'));
      document.getElementById(`panel-${item.dataset.panel}`).classList.remove('hidden');
    });
  });
}

function initQueueTabs() {
  const tabs = document.querySelectorAll('.tab-pill');
  if (!tabs.length) return;
  tabs.forEach(tab => {
    tab.addEventListener('click', () => {
      tabs.forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      currentTabStatus = tab.dataset.status;
      selectedApplicantId = null;
      loadApplicantList(currentTabStatus);
    });
  });
}

function initAdminPage() {
  const searchBox = document.getElementById('searchBox');
  if (!searchBox) return;
  searchBox.addEventListener('input', debounce(runSearch, 300));
  document.getElementById('statusFilter').addEventListener('change', runSearch);

  document.getElementById('branchLookupBtn').addEventListener('click', lookupBranch);

  initAdminNav();
  initQueueTabs();

  loadAnalytics();
  loadApplicantList(currentTabStatus);
  runSearch();
  loadEditRequests();
}

document.addEventListener('DOMContentLoaded', () => {
  initAdminPage();
});
