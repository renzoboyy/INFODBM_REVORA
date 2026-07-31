/* =====================================================
   REVORA — register.js
   Multi-step registration wizard (7-step flow)
   ===================================================== */

'use strict';

const TOTAL_STEPS = 7;

// ── State ──────────────────────────────────────────
const state = {
  step: 1,
  role: null,           // { RoleID, RoleName }
  category: null,       // { CategoryID, CategoryName }
  accountType: 'Individual', // 'Individual' | 'Entity'
  credentials: {},      // username, email, password
  personalInfo: {},     // firstName, middleName, lastName, suffix, phoneNumber, birthDate
  govtType: null,
  govtNo: '',
  address: {},
  entity: {},
  lookups: null
};

// ── Lookups ────────────────────────────────────────
async function fetchLookups() {
  const res = await fetch('/api/lookups');
  state.lookups = await res.json();
}

// ── Progress helpers ───────────────────────────────
function setProgress(step) {
  const pct = ((step - 1) / (TOTAL_STEPS - 1)) * 100;
  document.getElementById('regProgressFill').style.width = pct + '%';

  const indicator = document.getElementById('regStepsIndicator');
  indicator.innerHTML = Array.from({ length: TOTAL_STEPS }, (_, i) => {
    const s = i + 1;
    let cls = 'step-dot';
    if (s < step) cls += ' done';
    else if (s === step) cls += ' active';
    return `<div class="${cls}"></div>`;
  }).join('');
}

function goToStep(n) {
  document.querySelectorAll('.reg-step').forEach(el => el.classList.add('hidden'));
  const next = document.getElementById(`step-${n}`);
  if (next) {
    next.classList.remove('hidden');
    state.step = n;
    setProgress(n);
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }
}

// ── Step 1: Role selection ─────────────────────────
const ROLE_DEFS = [
  {
    label: 'Generator',
    desc: 'You produce surplus or scrap materials and want to list them for exchange.'
  },
  {
    label: 'Upcycler',
    desc: 'You source recovered materials and transform them into new products.'
  }
];

function initStep1() {
  const container = document.getElementById('roleCards');
  const nextBtn = document.getElementById('role-next');

  container.innerHTML = ROLE_DEFS.map((r, i) => `
    <div class="role-card" data-idx="${i}" id="roleCard-${i}">
      <div class="role-card-title">${r.label}</div>
      <div class="role-card-desc">${r.desc}</div>
    </div>
  `).join('');

  container.querySelectorAll('.role-card').forEach(card => {
    card.addEventListener('click', () => {
      container.querySelectorAll('.role-card').forEach(c => c.classList.remove('selected'));
      card.classList.add('selected');
      const idx = parseInt(card.dataset.idx);
      const roleName = ROLE_DEFS[idx].label;
      state.role = state.lookups.roles.find(r => r.RoleName.toLowerCase() === roleName.toLowerCase())
        || { RoleID: idx === 0 ? 0 : 1, RoleName: roleName };
      nextBtn.disabled = false;
    });
  });

  nextBtn.addEventListener('click', () => {
    if (state.role) {
      buildStep2();
      goToStep(2);
    }
  });
}

// ── Step 2: Category / Type ────────────────────────
const CATEGORY_DISPLAY = {
  'Individual':          'Individual',
  'Sole Proprietorship': 'Sole Proprietor',
  'SME':                 'SME',
  'Corporation':         'Corporation'
};

function buildStep2() {
  const container = document.getElementById('typeCards');
  const nextBtn = document.getElementById('cat-next');
  container.innerHTML = '';
  nextBtn.disabled = true;
  state.category = null;

  state.lookups.categories.forEach(cat => {
    const label = CATEGORY_DISPLAY[cat.CategoryName] || cat.CategoryName;
    const card = document.createElement('div');
    card.className = 'type-card';
    card.dataset.id = cat.CategoryID;
    card.dataset.name = cat.CategoryName;
    card.innerHTML = `<span class="type-card-label">${label}</span>`;
    card.addEventListener('click', () => {
      container.querySelectorAll('.type-card').forEach(c => c.classList.remove('selected'));
      card.classList.add('selected');
      state.category = cat;
      state.accountType = (cat.CategoryName === 'Individual') ? 'Individual' : 'Entity';
      nextBtn.disabled = false;
    });
    container.appendChild(card);
  });
}

function initStep2() {
  document.getElementById('cat-next').addEventListener('click', () => {
    if (state.category) goToStep(3);
  });
}

// ── Step 3: Account Credentials ────────────────────
function initStep3() {
  const nextBtn = document.getElementById('creds-next');
  const pwInput = document.getElementById('fi-password');
  const cpwInput = document.getElementById('fi-confirm-pw');
  const pwHint = document.getElementById('pwMatchHint');

  document.getElementById('togglePw').addEventListener('click', () => {
    pwInput.type = pwInput.type === 'password' ? 'text' : 'password';
  });
  document.getElementById('toggleConfirmPw').addEventListener('click', () => {
    cpwInput.type = cpwInput.type === 'password' ? 'text' : 'password';
  });

  function checkPwMatch() {
    if (!cpwInput.value) { pwHint.textContent = ''; pwHint.className = 'field-hint'; return; }
    if (pwInput.value === cpwInput.value) {
      pwHint.textContent = '✓ Passwords match';
      pwHint.className = 'field-hint hint-ok';
    } else {
      pwHint.textContent = '✗ Passwords do not match';
      pwHint.className = 'field-hint hint-error';
    }
  }

  cpwInput.addEventListener('input', checkPwMatch);
  pwInput.addEventListener('input', checkPwMatch);

  nextBtn.addEventListener('click', () => {
    const username = document.getElementById('fi-username').value.trim();
    const email = document.getElementById('fi-email').value.trim();
    const password = pwInput.value;
    const confirmPw = cpwInput.value;

    if (!username || !email || !password || !confirmPw) {
      showRegMsg('Please fill in all required fields.', 'error'); return;
    }
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      showRegMsg('Please enter a valid email address.', 'error'); return;
    }
    if (password !== confirmPw) {
      showRegMsg('Passwords do not match.', 'error'); return;
    }
    if (password.length < 6) {
      showRegMsg('Password must be at least 6 characters.', 'error'); return;
    }

    state.credentials = { username, email, password };
    clearRegMsg();
    goToStep(4);
  });
}

// ── Step 4: Personal Information ──────────────────
function initStep4() {
  document.getElementById('personal-next').addEventListener('click', () => {
    const firstName = document.getElementById('fi-firstName').value.trim();
    const lastName = document.getElementById('fi-lastName').value.trim();
    const phone = document.getElementById('fi-phone').value.trim();
    const birthDate = document.getElementById('fi-birthdate').value;

    if (!firstName || !lastName || !phone || !birthDate) {
      showRegMsg('Please fill in all required fields.', 'error'); return;
    }
    if (!/^09[0-9]{9}$/.test(phone)) {
      showRegMsg('Phone number must be in the format 09XXXXXXXXX (11 digits).', 'error'); return;
    }

    state.personalInfo = {
      firstName,
      middleName: document.getElementById('fi-middleName').value.trim() || null,
      lastName,
      suffix: document.getElementById('fi-suffix').value.trim() || null,
      phoneNumber: phone,
      birthDate
    };

    clearRegMsg();
    goToStep(5);
  });
}

// ── Step 5: Government ID ──────────────────────────
const GOVT_HINTS = {
  'PhilSys':        'Format: 16 digits (numbers only).',
  'Passport':       'Format: 1 letter + 7 digits, e.g. P1234567.',
  'Driver License': 'Format: A00-00-000000 (letter + digits).',
  'UMID':           'Format: 12 digits (numbers only).',
  'PRC ID':         'Format: 7 digits (numbers only).'
};

function initStep5() {
  const grid = document.getElementById('idTypeGrid');
  const noField = document.getElementById('govtNoField');
  const noInput = document.getElementById('fi-govtNo');
  const hint = document.getElementById('govtHint');
  const nextBtn = document.getElementById('govtid-next');

  const types = (state.lookups && state.lookups.govtTypes) || ['PhilSys', 'Passport', 'Driver License', 'UMID', 'PRC ID'];
  grid.innerHTML = types.map(t => `
    <div class="id-type-pill" data-type="${t}">${t}</div>
  `).join('');

  grid.querySelectorAll('.id-type-pill').forEach(pill => {
    pill.addEventListener('click', () => {
      grid.querySelectorAll('.id-type-pill').forEach(p => p.classList.remove('selected'));
      pill.classList.add('selected');
      state.govtType = pill.dataset.type;
      noField.style.display = '';
      hint.textContent = GOVT_HINTS[state.govtType] || '';
      noInput.value = state.govtNo || '';
      noInput.focus();
      checkGovtReady();
    });
  });

  noInput.addEventListener('input', () => {
    state.govtNo = noInput.value.trim();
    checkGovtReady();
  });

  function checkGovtReady() {
    nextBtn.disabled = !(state.govtType && state.govtNo.length > 0);
  }

  nextBtn.addEventListener('click', () => {
    if (!state.govtType || !state.govtNo) {
      showRegMsg('Please select an ID type and enter your ID number.', 'error'); return;
    }
    clearRegMsg();
    goToStep(6);
  });
}

// ── Step 6: Home Address ───────────────────────────
function initStep6() {
  document.getElementById('address-next').addEventListener('click', () => {
    const home = document.getElementById('fi-home').value.trim();
    const city = document.getElementById('fi-city').value.trim();
    const postal = document.getElementById('fi-postal').value.trim();

    if (!home || !city || !postal) {
      showRegMsg('Please fill in all required address fields.', 'error'); return;
    }
    if (!/^[0-9]{4}$/.test(postal)) {
      showRegMsg('Postal code must be exactly 4 digits.', 'error'); return;
    }

    state.address = {
      detailedHome: home,
      city,
      province: document.getElementById('fi-province').value.trim() || null,
      postalCode: postal
    };

    clearRegMsg();
    buildStep7();
    goToStep(7);
  });
}

// ── Step 7: Entity Info or Review ─────────────────
function buildStep7() {
  const entityBlock = document.getElementById('entityBlock');
  const reviewBlock = document.getElementById('reviewBlock');
  const step7Title = document.getElementById('step7Title');
  const step7Sub = document.getElementById('step7Sub');
  const step7Nav = document.getElementById('step7Nav');
  const submitNav = document.getElementById('submitNav');

  submitNav.classList.add('hidden');
  reviewBlock.classList.add('hidden');
  step7Nav.classList.remove('hidden');

  if (state.accountType === 'Entity') {
    entityBlock.classList.remove('hidden');
    step7Title.innerHTML = 'Entity &amp; Branch Information';
    step7Sub.textContent = 'Since you are registering as a business entity, please provide your TIN, entity name, sector, and branch details.';

    const sectorSel = document.getElementById('fi-sector');
    sectorSel.innerHTML = '<option value="">Select Sector</option>' +
      state.lookups.sectors.map(s => `<option value="${s.SectorID}">${s.SectorName}</option>`).join('');

    document.getElementById('entity-next').innerHTML = 'Review &amp; Submit &rarr;';
    document.getElementById('entity-next').onclick = validateAndShowReview;
  } else {
    entityBlock.classList.add('hidden');
    step7Title.innerHTML = 'Review &amp; Submit';
    step7Sub.textContent = 'Please review your registration details before submitting.';
    document.getElementById('entity-next').innerHTML = 'Review &amp; Submit &rarr;';
    document.getElementById('entity-next').onclick = validateAndShowReview;
  }
}

function validateAndShowReview() {
  if (state.accountType === 'Entity') {
    const entityName = document.getElementById('fi-entityName').value.trim();
    const tin = document.getElementById('fi-tin').value.trim();
    const sectorId = document.getElementById('fi-sector').value;
    const branchAddr = document.getElementById('fi-branchAddr').value.trim();
    const branchCity = document.getElementById('fi-branchCity').value.trim();
    const branchPostal = document.getElementById('fi-branchPostal').value.trim();

    if (!entityName || !tin || !sectorId || !branchAddr || !branchCity || !branchPostal) {
      showRegMsg('Please fill in all required entity and branch fields.', 'error'); return;
    }
    if (tin.length !== 11) {
      showRegMsg('TIN must be exactly 11 characters (no dashes).', 'error'); return;
    }
    if (!/^[0-9]{4}$/.test(branchPostal)) {
      showRegMsg('Branch Postal Code must be exactly 4 digits.', 'error'); return;
    }

    state.entity = { entityName, tin, sectorId, branchDetailedAddress: branchAddr, branchCity, branchPostalCode: branchPostal };
  }

  clearRegMsg();
  showReview();
}

function showReview() {
  document.getElementById('entityBlock').classList.add('hidden');
  document.getElementById('reviewBlock').classList.remove('hidden');
  document.getElementById('step7Nav').classList.add('hidden');
  document.getElementById('submitNav').classList.remove('hidden');

  const sector = state.accountType === 'Entity'
    ? (state.lookups.sectors.find(s => s.SectorID === state.entity.sectorId) || {}).SectorName || state.entity.sectorId
    : null;

  const entityHtml = state.accountType === 'Entity' ? `
    <div class="review-section">
      <div class="review-section-title">Entity &amp; Branch</div>
      <div class="review-grid">
        <dl class="review-item"><dt>Entity Name</dt><dd>${state.entity.entityName}</dd></dl>
        <dl class="review-item"><dt>TIN</dt><dd>${state.entity.tin}</dd></dl>
        <dl class="review-item"><dt>Sector</dt><dd>${sector || '-'}</dd></dl>
        <dl class="review-item"><dt>Branch Address</dt><dd>${state.entity.branchDetailedAddress}, ${state.entity.branchCity} ${state.entity.branchPostalCode}</dd></dl>
      </div>
    </div>
  ` : '';

  document.getElementById('reviewSummary').innerHTML = `
    <div class="review-section">
      <div class="review-section-title">Role &amp; Category</div>
      <div class="review-grid">
        <dl class="review-item"><dt>Role</dt><dd>${state.role ? state.role.RoleName : '-'}</dd></dl>
        <dl class="review-item"><dt>Category</dt><dd>${state.category ? state.category.CategoryName : '-'}</dd></dl>
      </div>
    </div>
    <div class="review-section">
      <div class="review-section-title">Account Credentials</div>
      <div class="review-grid">
        <dl class="review-item"><dt>Username</dt><dd>${state.credentials.username}</dd></dl>
        <dl class="review-item"><dt>Email</dt><dd>${state.credentials.email}</dd></dl>
      </div>
    </div>
    <div class="review-section">
      <div class="review-section-title">Personal Information</div>
      <div class="review-grid">
        <dl class="review-item"><dt>Full Name</dt><dd>${state.personalInfo.firstName}${state.personalInfo.middleName ? ' ' + state.personalInfo.middleName : ''} ${state.personalInfo.lastName}${state.personalInfo.suffix ? ' ' + state.personalInfo.suffix : ''}</dd></dl>
        <dl class="review-item"><dt>Date of Birth</dt><dd>${state.personalInfo.birthDate}</dd></dl>
        <dl class="review-item"><dt>Phone</dt><dd>${state.personalInfo.phoneNumber}</dd></dl>
      </div>
    </div>
    <div class="review-section">
      <div class="review-section-title">Government ID</div>
      <div class="review-grid">
        <dl class="review-item"><dt>ID Type</dt><dd>${state.govtType}</dd></dl>
        <dl class="review-item"><dt>ID Number</dt><dd>${state.govtNo}</dd></dl>
      </div>
    </div>
    <div class="review-section">
      <div class="review-section-title">Home Address</div>
      <div class="review-grid">
        <dl class="review-item"><dt>Address</dt><dd>${state.address.detailedHome}</dd></dl>
        <dl class="review-item"><dt>City / Province</dt><dd>${state.address.city}${state.address.province ? ', ' + state.address.province : ''} ${state.address.postalCode}</dd></dl>
      </div>
    </div>
    ${entityHtml}
  `;
}

// ── Submission ─────────────────────────────────────
async function submitRegistration() {
  const btn = document.getElementById('submitBtn');
  btn.disabled = true;
  btn.textContent = 'Submitting…';

  const payload = {
    accountType: state.accountType,
    roleId: state.role ? state.role.RoleID : null,
    categoryId: state.category ? state.category.CategoryID : null,
    govtType: state.govtType,
    govtNo: state.govtNo,
    ...state.credentials,
    ...state.personalInfo,
    ...state.address
  };

  if (state.accountType === 'Entity') {
    Object.assign(payload, state.entity);
  }

  try {
    const res = await fetch('/api/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    if (data.success) {
      document.querySelectorAll('.reg-step').forEach(el => el.classList.add('hidden'));
      document.getElementById('step-success').classList.remove('hidden');
      document.getElementById('successRef').innerHTML =
        `Your Reference ID: <strong style="color:#4fd88a;font-size:1.1rem;">${data.userId}</strong>`;
      document.getElementById('regProgressFill').style.width = '100%';
    } else {
      showRegMsg(data.message, 'error');
      btn.disabled = false;
      btn.textContent = 'Submit Registration';
    }
  } catch (err) {
    showRegMsg('Network error — please try again.', 'error');
    btn.disabled = false;
    btn.textContent = 'Submit Registration';
  }
}

// ── Message helpers ────────────────────────────────
function showRegMsg(text, type) {
  const el = document.getElementById('message');
  if (!el) return;
  el.innerHTML = `<div class="msg msg-${type === 'success' ? 'success' : 'error'}">${text}</div>`;
  el.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function clearRegMsg() {
  const el = document.getElementById('message');
  if (el) el.innerHTML = '';
}

// ── Back buttons ───────────────────────────────────
function initBackButtons() {
  document.querySelectorAll('[data-back]').forEach(btn => {
    btn.addEventListener('click', () => {
      clearRegMsg();
      goToStep(parseInt(btn.dataset.back));
    });
  });
}

// ── Edit button ────────────────────────────────────
function initEditButton() {
  const editBtn = document.getElementById('editBtn');
  if (!editBtn) return;
  editBtn.addEventListener('click', () => {
    document.getElementById('reviewBlock').classList.add('hidden');
    document.getElementById('submitNav').classList.add('hidden');
    document.getElementById('step7Nav').classList.remove('hidden');

    if (state.accountType === 'Entity') {
      document.getElementById('entityBlock').classList.remove('hidden');
    } else {
      goToStep(6);
    }
  });
}

// ── Submit button ──────────────────────────────────
function initSubmitButton() {
  const btn = document.getElementById('submitBtn');
  if (btn) btn.addEventListener('click', submitRegistration);
}

// ── BOOT ───────────────────────────────────────────
(async function boot() {
  await fetchLookups();
  setProgress(1);
  initStep1();
  initStep2();
  initStep3();
  initStep4();
  initStep5();
  initStep6();
  initBackButtons();
  initEditButton();
  initSubmitButton();
  goToStep(1);
})();
