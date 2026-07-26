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

function fillSelect(select, items, valueKey, labelKey, placeholder) {
  select.innerHTML = `<option value="">${placeholder}</option>` +
    items.map(i => `<option value="${i[valueKey]}">${i[labelKey]}</option>`).join('');
}

const GOVT_HINTS = {
  'PhilSys': '16 digits, numbers only.',
  'Passport': '6-12 alphanumeric characters.',
  'Driver License': 'Format: A00-00-000000',
  'UMID': '12 digits, numbers only.',
  'PRC ID': '7 digits, numbers only.'
};

async function initRegistrantPage() {
  const form = document.getElementById('registerForm');
  if (!form) return;

  const lookups = await (await fetch('/api/lookups')).json();
  fillSelect(document.getElementById('categoryId'), lookups.categories, 'CategoryID', 'CategoryName', 'Select Category');
  fillSelect(document.getElementById('roleId'), lookups.roles, 'RoleID', 'RoleName', 'Select Role');
  fillSelect(document.getElementById('sectorId'), lookups.sectors, 'SectorID', 'SectorName', 'Select Sector');

  const govtSel = document.getElementById('govtType');
  govtSel.innerHTML = '<option value="">Select ID Type</option>' +
    lookups.govtTypes.map(t => `<option value="${t}">${t}</option>`).join('');
  govtSel.addEventListener('change', () => {
    document.getElementById('govtHint').textContent = GOVT_HINTS[govtSel.value] || '';
  });

  document.querySelectorAll('input[name="accountType"]').forEach(radio => {
    radio.addEventListener('change', e => {
      const entitySection = document.getElementById('entitySection');
      const showEntity = e.target.value === 'Entity';
      entitySection.classList.toggle('hidden', !showEntity);
      document.getElementById('entityName').required = showEntity;
      document.getElementById('tin').required = showEntity;
      document.getElementById('branchCode').required = showEntity;
      document.getElementById('branchDetailedAddress').required = showEntity;
      document.getElementById('branchCity').required = showEntity;
      document.getElementById('branchPostalCode').required = showEntity;
    });
  });

  form.addEventListener('submit', async e => {
    e.preventDefault();
    const fd = new FormData(form);
    const payload = Object.fromEntries(fd.entries());
    payload.roleId = payload.roleId === '1' ? true : payload.roleId === '0' ? false : payload.roleId;

    const res = await fetch('/api/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    if (data.success) {
      showMessage(`${data.message} Reference ID: ${data.userId}`, 'success');
      form.reset();
      document.getElementById('entitySection').classList.add('hidden');
    } else {
      showMessage(data.message, 'error');
    }
  });
}

const SLA_BADGE = { 'On Track': 'badge-green', 'Due Soon': 'badge-yellow', 'Overdue': 'badge-red', 'N/A': 'badge-gray' };
const STATUS_BADGE = {
  Pending: 'badge-yellow', Approved: 'badge-green', Rejected: 'badge-red',
  Suspended: 'badge-gray', Deleted: 'badge-red', Closed: 'badge-gray'
};

async function loadAnalytics() {
  const grid = document.getElementById('statGrid');
  if (!grid) return;
  const a = await (await fetch('/api/admin/analytics')).json();
  const tiles = [
    ['Pending Applications', a.pendingApplications],
    ['Oldest Pending', a.oldestPending ? new Date(a.oldestPending).toLocaleDateString() : '-'],
    ['Newest Pending', a.newestPending ? new Date(a.newestPending).toLocaleDateString() : '-'],
    ['Avg. Days to Approve', a.avgDaysToApprove ?? '-'],
    ['Pending -> Approved (INTERSECT)', a.pendingThenApprovedCount],
    ['Entity-Based Registrants (EXCEPT)', a.entityBasedCount]
  ];
  grid.innerHTML = tiles.map(([label, value]) => `
    <div class="stat-tile">
      <div class="stat-value">${value}</div>
      <div class="stat-label">${label}</div>
    </div>
  `).join('');
}

async function loadQueue() {
  const body = document.getElementById('queueBody');
  if (!body) return;
  const rows = await (await fetch('/api/admin/queue')).json();
  body.innerHTML = rows.map(r => `
    <tr>
      <td>${r.UserID}</td>
      <td>${r.FullName}</td>
      <td>${r.EntityName || '-'}</td>
      <td>${new Date(r.CreatedAt).toLocaleString()}</td>
      <td><span class="badge ${SLA_BADGE[r.SLAFlag] || 'badge-gray'}">${r.SLAFlag}</span></td>
      <td class="actions">
        <button class="btn-primary" data-action="review" data-id="${r.UserID}">Review</button>
      </td>
    </tr>
  `).join('') || '<tr><td colspan="6" class="muted">No pending registrations.</td></tr>';

  body.querySelectorAll('button[data-action="review"]').forEach(btn => {
    btn.addEventListener('click', () => openReview(btn.dataset.id));
  });
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
    closeReview();
    loadQueue();
    runSearch();
    loadAnalytics();
  } else {
    showMessage(data.message, 'error');
  }
}

function addr(detailed, city, province, postal) {
  if (!detailed) return null;
  return `${detailed}, ${city}${province ? ', ' + province : ''} ${postal || ''}`.trim();
}

async function openReview(userId) {
  const overlay = document.getElementById('reviewOverlay');
  const body = document.getElementById('reviewBody');
  const res = await fetch(`/api/admin/users/${userId}`);
  if (!res.ok) {
    showMessage('Could not load applicant details.', 'error');
    return;
  }
  const a = await res.json();

  document.getElementById('reviewTitle').textContent =
    `${a.FirstName} ${a.MiddleName ? a.MiddleName + ' ' : ''}${a.LastName}${a.Suffix ? ' ' + a.Suffix : ''}`;
  document.getElementById('reviewNotes').value = '';

  const personalAddr = addr(a.DetailedHome, a.HomeCity, a.HomeProvince, a.HomePostalCode);
  const branchAddr = addr(a.BranchDetailedAddress, a.BranchCity, null, a.BranchPostalCode);

  let entityRows = '';
  if (a.EntityName) {
    entityRows = `
      <div class="section-label">Entity Information</div>
      <dt>Entity Name</dt><dd>${a.EntityName}</dd>
      <dt>TIN</dt><dd>${a.TIN}</dd>
      <dt>Sector</dt><dd>${a.SectorName}</dd>
      <dt>Branch ID / Code</dt><dd>${a.BranchID || '-'} / ${a.BranchCode || '-'}</dd>
      <dt>Branch Address</dt><dd>${branchAddr || '-'}</dd>
    `;
  }

  body.innerHTML = `
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
  `;

  document.getElementById('reviewApprove').onclick = () => handleDecision(a.UserID, 'approve');
  document.getElementById('reviewReject').onclick = () => handleDecision(a.UserID, 'reject');

  overlay.classList.remove('hidden');
}

function closeReview() {
  document.getElementById('reviewOverlay').classList.add('hidden');
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
      <dt>Branch Code</dt><dd>${b.BranchCode}</dd>
      <dt>Address</dt><dd>${b.DetailedAddress}, ${b.City} ${b.PostalCode}</dd>
      <dt>Linked Entity</dt><dd>${b.EntityName || '(none)'}</dd>
    </dl>
    <button type="button" class="btn-reject" id="branchCloseBtn">Confirm Close Branch</button>
  `;
  document.getElementById('branchCloseBtn').addEventListener('click', () => closeBranch(id));
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

function initAdminPage() {
  const searchBox = document.getElementById('searchBox');
  if (!searchBox) return;
  searchBox.addEventListener('input', debounce(runSearch, 300));
  document.getElementById('statusFilter').addEventListener('change', runSearch);

  document.getElementById('reviewClose').addEventListener('click', closeReview);
  document.getElementById('reviewOverlay').addEventListener('click', e => {
    if (e.target.id === 'reviewOverlay') closeReview();
  });

  document.getElementById('branchLookupBtn').addEventListener('click', lookupBranch);

  loadAnalytics();
  loadQueue();
  runSearch();
}

document.addEventListener('DOMContentLoaded', () => {
  initRegistrantPage();
  initAdminPage();
});
