function requireLogin() {
  const userId = localStorage.getItem('revora_userId');
  if (!userId) {
    window.location.href = 'login.html';
    return null;
  }
  return userId;
}

function logout() {
  localStorage.removeItem('revora_userId');
  window.location.href = 'login.html';
}

function fmtDate(value) {
  return value ? new Date(value).toLocaleDateString() : '-';
}

function fmtDateTime(value) {
  return value ? new Date(value).toLocaleString() : '-';
}

let currentProfile = null;

async function loadDashboard() {
  const userId = requireLogin();
  if (!userId) return;

  const res = await fetch(`/api/admin/users/${userId}`);
  if (!res.ok) {
    localStorage.removeItem('revora_userId');
    showMessage('Your session could not be verified. Please log in again.', 'error');
    setTimeout(() => { window.location.href = 'login.html'; }, 1500);
    return;
  }
  const a = await res.json();
  currentProfile = a;

  document.getElementById('loadingState').classList.add('hidden');
  document.getElementById('dashboardContent').classList.remove('hidden');

  const fullName = `${a.FirstName} ${a.MiddleName ? a.MiddleName + ' ' : ''}${a.LastName}${a.Suffix ? ' ' + a.Suffix : ''}`;
  document.getElementById('topbarName').textContent = fullName;
  document.getElementById('welcomeName').textContent = `Welcome, ${a.FirstName}`;

  const statGrid = document.getElementById('overviewStats');
  const tiles = [
    ['Account Status', a.StatusName],
    ['Role', a.RoleName],
    ['Category', a.CategoryName],
    ['Member Since', fmtDate(a.CreatedAt)]
  ];
  statGrid.innerHTML = tiles.map(([label, value]) => `
    <div class="stat-tile">
      <div class="stat-value">${value}</div>
      <div class="stat-label">${label}</div>
    </div>
  `).join('');

  document.getElementById('ov-status').innerHTML =
    `<span class="badge ${STATUS_BADGE[a.StatusName] || 'badge-gray'}">${a.StatusName}</span>`;
  document.getElementById('ov-role').textContent = a.RoleName;
  document.getElementById('ov-category').textContent = a.CategoryName;
  document.getElementById('ov-registered').textContent = fmtDateTime(a.CreatedAt);
  document.getElementById('ov-approved').textContent = fmtDateTime(a.ApprovedAt);

  const entityCard = document.getElementById('entityCard');
  if (a.EntityName) {
    const branchAddr = addr(a.BranchDetailedAddress, a.BranchBarangay, a.BranchCity, a.BranchProvince, a.BranchRegion, a.BranchPostalCode);
    entityCard.innerHTML = `
      <dl class="detail-grid">
        <dt>Entity Name</dt><dd>${a.EntityName}</dd>
        <dt>TIN</dt><dd>${(a.TIN || '').trim()}</dd>
        <dt>Sector</dt><dd>${a.SectorName || '-'}</dd>
        <dt>Branch ID</dt><dd>${a.BranchID || '-'}</dd>
        <dt>Branch Address</dt><dd>${branchAddr || '-'}</dd>
      </dl>
      <p class="muted" style="margin-top:14px;">Use the <strong>Edit Profile</strong> button on the Overview tab to request a correction to any of these details.</p>
    `;
  } else {
    entityCard.innerHTML = '<p class="muted placeholder-text">This account is registered as an Individual and has no linked entity.</p>';
  }

  const personalAddr = addr(a.DetailedHome, a.HomeBarangay, a.HomeCity, a.HomeProvince, a.HomeRegion, a.HomePostalCode);
  document.getElementById('ac-name').textContent = fullName;
  document.getElementById('ac-username').textContent = a.Username.trim();
  document.getElementById('ac-email').textContent = a.Email;
  document.getElementById('ac-phone').textContent = a.PhoneNumber;
  document.getElementById('ac-birthdate').textContent = fmtDate(a.BirthDate);
  document.getElementById('ac-govttype').textContent = a.GovtType;
  document.getElementById('ac-govtno').textContent = a.GovtNo;
  document.getElementById('ac-address').textContent = personalAddr || '-';

  await checkPendingEdit(userId);
}

async function checkPendingEdit(userId) {
  const banner = document.getElementById('pendingEditBanner');
  const editBtn = document.getElementById('openEditBtn');
  const res = await fetch(`/api/profile/edit-request/${userId}`);
  const req = await res.json();

  if (req) {
    editBtn.classList.add('hidden');
    banner.classList.remove('hidden');
    banner.innerHTML = `
      <h2 style="color:var(--yellow);">Edit Request Pending Review</h2>
      <p class="muted">You submitted a profile edit on ${fmtDateTime(req.SubmittedAt)}. It's awaiting admin approval &mdash; you can still browse your dashboard, but you can't submit another edit until this one is resolved.</p>
    `;
  } else {
    editBtn.classList.remove('hidden');
    banner.classList.add('hidden');
  }
}

async function populateSectorSelect(currentSectorName) {
  const select = document.getElementById('ei-sector');
  const res = await fetch('/api/lookups');
  const data = await res.json();
  select.innerHTML = (data.sectors || []).map(s =>
    `<option value="${s.SectorID}" ${s.SectorName === currentSectorName ? 'selected' : ''}>${s.SectorName}</option>`
  ).join('');
}

async function openEditModal() {
  const a = currentProfile;
  if (!a) return;

  document.getElementById('ei-email').value = a.Email || '';
  document.getElementById('ei-phone').value = a.PhoneNumber || '';
  document.getElementById('ei-home').value = a.DetailedHome || '';
  document.getElementById('ei-city').value = a.HomeCity || '';
  document.getElementById('ei-province').value = a.HomeProvince || '';
  document.getElementById('ei-postal').value = a.HomePostalCode || '';

  const entityBlock = document.getElementById('entityEditBlock');
  if (a.EntityName) {
    entityBlock.classList.remove('hidden');
    document.getElementById('ei-entityname').value = a.EntityName || '';
    document.getElementById('ei-tin').value = (a.TIN || '').trim();
    document.getElementById('ei-branchaddr').value = a.BranchDetailedAddress || '';
    document.getElementById('ei-branchcity').value = a.BranchCity || '';
    document.getElementById('ei-branchpostal').value = a.BranchPostalCode || '';
    await populateSectorSelect(a.SectorName);
  } else {
    entityBlock.classList.add('hidden');
  }

  document.getElementById('editModalMessage').innerHTML = '';
  document.getElementById('editModalOverlay').classList.remove('hidden');
}

function closeEditModal() {
  document.getElementById('editModalOverlay').classList.add('hidden');
}

function valOrNull(id) {
  const v = document.getElementById(id).value.trim();
  return v === '' ? null : v;
}

async function submitEditRequest() {
  const a = currentProfile;
  const userId = localStorage.getItem('revora_userId');
  const body = { userId };
  let hasChange = false;

  const diffCheck = (fieldId, currentVal, key) => {
    const newVal = valOrNull(fieldId);
    const curNormalized = (currentVal || '').toString().trim();
    if (newVal !== null && newVal !== curNormalized) {
      body[key] = newVal;
      hasChange = true;
    }
  };

  diffCheck('ei-email', a.Email, 'newEmail');
  diffCheck('ei-phone', a.PhoneNumber, 'newPhoneNumber');
  diffCheck('ei-home', a.DetailedHome, 'newDetailedHome');
  diffCheck('ei-city', a.HomeCity, 'newCity');
  diffCheck('ei-province', a.HomeProvince, 'newProvince');
  diffCheck('ei-postal', a.HomePostalCode, 'newPostalCode');

  if (a.EntityName) {
    diffCheck('ei-entityname', a.EntityName, 'newEntityName');
    diffCheck('ei-tin', a.TIN, 'newTIN');
    diffCheck('ei-branchaddr', a.BranchDetailedAddress, 'newBranchDetailedAddress');
    diffCheck('ei-branchcity', a.BranchCity, 'newBranchCity');
    diffCheck('ei-branchpostal', a.BranchPostalCode, 'newBranchPostalCode');

    const sectorSelect = document.getElementById('ei-sector');
    const selectedOption = sectorSelect.options[sectorSelect.selectedIndex];
    if (selectedOption && selectedOption.textContent.trim() !== (a.SectorName || '').trim()) {
      body.newSectorId = sectorSelect.value;
      hasChange = true;
    }
  }

  if (!hasChange) {
    document.getElementById('editModalMessage').innerHTML =
      '<div class="msg msg-error">No changes detected &mdash; update at least one field before submitting.</div>';
    return;
  }

  const submitBtn = document.getElementById('editSubmitBtn');
  submitBtn.disabled = true;
  submitBtn.textContent = 'Submitting…';

  try {
    const res = await fetch('/api/profile/edit-request', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });
    const data = await res.json();

    if (data.success) {
      closeEditModal();
      showMessage('Your edit request has been submitted for admin review. Your account status is now Pending.', 'success');
      loadDashboard();
    } else {
      document.getElementById('editModalMessage').innerHTML =
        `<div class="msg msg-error">${data.message || 'Failed to submit edit request.'}</div>`;
    }
  } catch (err) {
    document.getElementById('editModalMessage').innerHTML =
      '<div class="msg msg-error">Could not reach the server. Please try again.</div>';
  } finally {
    submitBtn.disabled = false;
    submitBtn.textContent = 'Submit for Review';
  }
}

document.addEventListener('DOMContentLoaded', () => {
  initAdminNav();
  document.getElementById('logoutBtn').addEventListener('click', logout);
  document.getElementById('openEditBtn').addEventListener('click', openEditModal);
  document.getElementById('editModalCloseBtn').addEventListener('click', closeEditModal);
  document.getElementById('editCancelBtn').addEventListener('click', closeEditModal);
  document.getElementById('editSubmitBtn').addEventListener('click', submitEditRequest);
  loadDashboard();
});
