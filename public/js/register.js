/* =====================================================
   REVORA — register.js
   Multi-step registration wizard (7-step flow)
   ===================================================== */

'use strict';

const TOTAL_STEPS = 7;

let personalGeo = null;
let branchGeo = null;

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

// ── Address fields (Region dropdown + manual Province/City/Barangay) ──
// Region is a closed dropdown (GET /api/geo/regions - Luzon regions only).
// Province/City/Barangay/PostalCode are always typed in manually - there's
// no picker, no "Other" fallback, nothing to cascade. One instance is
// created for the personal address fields and a second, separate instance
// for the branch address fields - they never share state.

async function fetchJSON(url) {
  try {
    const res = await fetch(url);
    return res.ok ? await res.json() : [];
  } catch {
    return [];
  }
}

function initAddressFields(ids) {
  const regionSel   = document.getElementById(ids.region);
  const provinceEl  = document.getElementById(ids.province);
  const cityEl      = document.getElementById(ids.city);
  const barangayEl  = document.getElementById(ids.barangay);
  const postalInput = document.getElementById(ids.postal);

  (async () => {
    const regions = await fetchJSON('/api/geo/regions');
    regionSel.innerHTML = `<option value="">Select Region</option>` +
      regions.map(r => `<option value="${r}">${r}</option>`).join('');
  })();

  function getValues() {
    return {
      region: regionSel.value || '',
      province: provinceEl.value.trim(),
      city: cityEl.value.trim(),
      barangay: barangayEl.value.trim(),
      postalCode: postalInput.value.trim()
    };
  }

  function validate(label) {
    const v = getValues();
    if (!v.region) return `Please select a ${label}region.`;
    if (!v.province) return `Please enter a ${label}province.`;
    if (!v.city) return `Please enter a ${label}city/municipality.`;
    if (!v.barangay) return `Please enter a ${label}barangay.`;
    if (!/^[0-9]{4}$/.test(v.postalCode)) return `${label ? 'Branch postal' : 'Postal'} code must be exactly 4 digits.`;
    return null;
  }

  return { getValues, validate };
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
    if (password.length > 32) {
      showRegMsg('Password must be 32 characters or fewer.', 'error'); return;
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
    // Mirrors CK_BirthDate_Valid in db/01_schema_v3.sql
    const bd = new Date(birthDate + 'T00:00:00');
    const minDate = new Date('1900-01-01T00:00:00');
    if (isNaN(bd.getTime()) || bd < minDate || bd >= new Date()) {
      showRegMsg('Please enter a valid date of birth (between 1900-01-01 and today).', 'error'); return;
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
// Mirrors CK_GovernmentID_Validation in db/01_schema_v3.sql exactly, so a
// value that passes here is guaranteed to pass the database CHECK too.
const GOVT_HINTS = {
  'PhilSys':        'Format: 16 digits (numbers only).',
  'Passport':       'Format: 6-12 letters/digits, e.g. P1234567.',
  'Driver License': 'Format: A00-00-000000 (1 letter + digits).',
  'UMID':           'Format: 12 digits (numbers only).',
  'PRC ID':         'Format: 7 digits (numbers only).'
};
const GOVT_VALIDATORS = {
  'PhilSys':        { pattern: /^[0-9]{16}$/,                    maxlength: 16, uppercase: false, error: 'PhilSys ID must be exactly 16 digits.' },
  'Passport':       { pattern: /^[A-Za-z0-9]{6,12}$/,             maxlength: 12, uppercase: false, error: 'Passport number must be 6-12 letters/digits.' },
  'Driver License': { pattern: /^[A-Z][0-9]{2}-[0-9]{2}-[0-9]{6}$/, maxlength: 13, uppercase: true,  error: 'Driver License must be in format A00-00-000000.' },
  'UMID':           { pattern: /^[0-9]{12}$/,                    maxlength: 12, uppercase: false, error: 'UMID must be exactly 12 digits.' },
  'PRC ID':         { pattern: /^[0-9]{7}$/,                     maxlength: 7,  uppercase: false, error: 'PRC ID must be exactly 7 digits.' }
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
      const v = GOVT_VALIDATORS[state.govtType];
      noInput.maxLength = v ? v.maxlength : 20;
      noInput.value = state.govtNo || '';
      noInput.focus();
      checkGovtReady();
    });
  });

  noInput.addEventListener('input', () => {
    const v = GOVT_VALIDATORS[state.govtType];
    state.govtNo = (v && v.uppercase ? noInput.value.toUpperCase() : noInput.value).trim();
    if (v && v.uppercase) noInput.value = state.govtNo;
    checkGovtReady();
  });

  function checkGovtReady() {
    nextBtn.disabled = !(state.govtType && state.govtNo.length > 0);
  }

  nextBtn.addEventListener('click', () => {
    if (!state.govtType || !state.govtNo) {
      showRegMsg('Please select an ID type and enter your ID number.', 'error'); return;
    }
    const v = GOVT_VALIDATORS[state.govtType];
    if (v && !v.pattern.test(state.govtNo)) {
      showRegMsg(v.error, 'error'); return;
    }
    clearRegMsg();
    goToStep(6);
  });
}

// ── Step 6: Home Address ───────────────────────────
function initStep6() {
  personalGeo = initAddressFields({
    region: 'fi-region', province: 'fi-province', city: 'fi-city',
    barangay: 'fi-barangay', postal: 'fi-postal'
  });

  document.getElementById('address-next').addEventListener('click', () => {
    const home = document.getElementById('fi-home').value.trim();
    if (!home) {
      showRegMsg('Please fill in all required address fields.', 'error'); return;
    }
    const geoErr = personalGeo.validate('');
    if (geoErr) {
      showRegMsg(geoErr, 'error'); return;
    }

    const v = personalGeo.getValues();
    state.address = {
      detailedHome: home,
      barangay: v.barangay,
      city: v.city,
      province: v.province,
      region: v.region,
      postalCode: v.postalCode
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

    if (!branchGeo) {
      branchGeo = initAddressFields({
        region: 'fi-branchRegion', province: 'fi-branchProvince', city: 'fi-branchCity',
        barangay: 'fi-branchBarangay', postal: 'fi-branchPostal'
      });
    }

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

    if (!entityName || !tin || !sectorId || !branchAddr) {
      showRegMsg('Please fill in all required entity and branch fields.', 'error'); return;
    }
    if (!/^[0-9]{11}$/.test(tin)) {
      showRegMsg('TIN must be exactly 11 digits (no letters or dashes).', 'error'); return;
    }
    const geoErr = branchGeo.validate('branch ');
    if (geoErr) {
      showRegMsg(geoErr, 'error'); return;
    }

    const v = branchGeo.getValues();
    state.entity = {
      entityName, tin, sectorId,
      branchDetailedAddress: branchAddr,
      branchBarangay: v.barangay, branchCity: v.city, branchProvince: v.province,
      branchRegion: v.region, branchPostalCode: v.postalCode
    };
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
        <dl class="review-item"><dt>Branch Address</dt><dd>${state.entity.branchDetailedAddress}, ${state.entity.branchBarangay}, ${state.entity.branchCity}, ${state.entity.branchProvince} ${state.entity.branchPostalCode}${state.entity.branchRegion ? ' (' + state.entity.branchRegion + ')' : ''}</dd></dl>
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
        <dl class="review-item"><dt>Address</dt><dd>${state.address.detailedHome}, ${state.address.barangay}</dd></dl>
        <dl class="review-item"><dt>City / Province</dt><dd>${state.address.city}${state.address.province ? ', ' + state.address.province : ''} ${state.address.postalCode}${state.address.region ? ' (' + state.address.region + ')' : ''}</dd></dl>
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
