// Some browsers restore the previous tab's scroll offset on a plain
// refresh (not just back/forward navigation), which reads as "every reload
// nudges the page down a bit" since the async data loads below change the
// page's height between visits. Force a clean top-of-page start instead.
if ('scrollRestoration' in history) {
  history.scrollRestoration = 'manual';
}
window.scrollTo(0, 0);

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
  Suspended: 'badge-gray', Deleted: 'badge-red', Closed: 'badge-gray',
  Resubmitted: 'badge-yellow'
};

let currentTabStatus = '1';
let selectedApplicantId = null;
// True right after an approve/reject, while the pane is showing the
// confirmation message instead of the plain "select a registration"
// placeholder. loadApplicantList()'s empty-state branch checks this so its
// refresh doesn't wipe the confirmation out from under it; selecting a new
// applicant clears it back to normal.
let paneShowingDecision = false;

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
  playFadeUp(list);

  list.querySelectorAll('.applicant-row').forEach(row => {
    row.addEventListener('click', () => selectApplicant(row.dataset.id));
  });

  if (selectedApplicantId && rows.some(r => r.UserID === selectedApplicantId)) {
    const row = list.querySelector(`.applicant-row[data-id="${selectedApplicantId}"]`);
    if (row) row.classList.add('selected');
  } else {
    selectedApplicantId = null;
    if (!paneShowingDecision) {
      document.getElementById('reviewDetailPane').innerHTML =
        '<p class="muted placeholder-text">Select registration to view applicant details.</p>';
    }
  }
}

// Squeezes the detail pane down to a sliver and back out (an "eye blink" /
// closing-sandwich motion), swapping its content for a name-based
// confirmation at the midpoint - when it reopens, it's already showing the
// result rather than jump-cutting straight to the empty placeholder.
function blinkDecisionResult(pane, fullName, action) {
  // The confirmation card is much shorter than the applicant detail view it
  // replaces, so the page's scrollable height drops the instant the content
  // swaps below. If the admin was scrolled down, the browser clamps the
  // scroll position back into bounds immediately - a hard, unsmoothed jump.
  // Ease there ourselves first so the swap (at 300ms) lands after we've
  // already arrived, in sync with the blink instead of fighting it.
  window.scrollTo({ top: 0, behavior: 'smooth' });

  pane.classList.remove('blink');
  void pane.offsetWidth;
  pane.classList.add('blink');
  // Strip the class once the animation finishes - a CSS animation applied
  // via a class that's left in place replays from scratch the next time the
  // element goes display:none -> block (e.g. switching tabs away and back),
  // since display:none drops all in-flight/completed animation state.
  pane.addEventListener('animationend', () => pane.classList.remove('blink'), { once: true });
  setTimeout(() => {
    const approved = action === 'approve';
    pane.innerHTML = `
      <div class="decision-confirm">
        <div class="decision-confirm-icon ${approved ? 'decision-confirm-icon-approve' : 'decision-confirm-icon-reject'}">
          ${approved ? '&#10003;' : '&#10005;'}
        </div>
        <p><strong>${fullName}</strong> has been ${approved ? 'approved' : 'rejected'}.</p>
      </div>
      <p class="decision-followup-text">Select registration to view applicant details.</p>
    `;
    paneShowingDecision = true;
  }, 300);
}

async function handleDecision(userId, action) {
  const notesInput = document.getElementById('reviewNotes');
  const notes = notesInput ? notesInput.value.trim() : '';
  const pane = document.getElementById('reviewDetailPane');
  const nameEl = pane.querySelector('h2');
  const fullName = nameEl ? nameEl.textContent.trim() : `User ${userId}`;

  const res = await fetch(`/api/admin/users/${userId}/${action}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ notes: notes || undefined })
  });
  const data = await res.json();
  if (data.success) {
    selectedApplicantId = null;
    blinkDecisionResult(pane, fullName, action);
    // Delay the list/search/analytics refresh so it doesn't stomp the
    // confirmation message the instant it appears - loadApplicantList()
    // resets reviewDetailPane back to the "select a registration"
    // placeholder whenever nothing is selected.
    setTimeout(() => {
      loadApplicantList(currentTabStatus);
      runSearch();
      loadAnalytics();
    }, 1300);
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
  paneShowingDecision = false;
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

async function loadAuditLog() {
  const body = document.getElementById('auditLogBody');
  if (!body) return;
  const rows = await (await fetch('/api/admin/auditlog')).json();

  body.innerHTML = rows.map(r => `
    <tr>
      <td>${r.LogID}</td>
      <td>${r.FullName ? r.FullName + ' (' + r.UserID + ')' : r.UserID}</td>
      <td><span class="badge ${STATUS_BADGE[r.AdminAction] || 'badge-gray'}">${r.AdminAction}</span></td>
      <td>${new Date(r.ActionTimestamp).toLocaleString()}</td>
      <td>${r.Remarks || '-'}</td>
    </tr>
  `).join('') || '<tr><td colspan="5" class="muted">No audit log entries yet.</td></tr>';
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

// Replays the fade-up/slide-up transition on an element every time it's
// called, not just once - removing 'visible' then forcing a reflow before
// re-adding it is what makes the CSS transition fire again on repeat tab
// clicks (simply re-adding an already-present class is a no-op).
function playFadeUp(el) {
  el.classList.remove('visible');
  void el.offsetWidth;
  el.classList.add('visible');
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
      const panel = document.getElementById(`panel-${item.dataset.panel}`);
      panel.classList.remove('hidden');
      playFadeUp(panel);
      if (item.dataset.panel === 'auditlog') loadAuditLog();
    });
  });
  // animate the panel that's active on first load too
  const initialPanel = document.querySelector('.admin-panel:not(.hidden)');
  if (initialPanel) playFadeUp(initialPanel);
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
      paneShowingDecision = false;
      loadApplicantList(currentTabStatus);
    });
  });
}

function initAdminPage() {
  const searchBox = document.getElementById('searchBox');
  if (!searchBox) return;
  searchBox.addEventListener('input', debounce(runSearch, 300));
  document.getElementById('statusFilter').addEventListener('change', runSearch);

  initAdminNav();
  initQueueTabs();

  loadAnalytics();
  loadApplicantList(currentTabStatus);
  runSearch();
  loadEditRequests();
}

document.addEventListener('DOMContentLoaded', () => {
  window.scrollTo(0, 0);
  initAdminPage();
});
