function initLoginPage() {
  const togglePw = document.getElementById('togglePw');
  const pwInput = document.getElementById('fi-password');
  if (togglePw) {
    togglePw.addEventListener('click', () => {
      pwInput.type = pwInput.type === 'password' ? 'text' : 'password';
    });
  }

  const loginBtn = document.getElementById('loginBtn');
  const usernameInput = document.getElementById('fi-username');

  async function submitLogin() {
    const username = usernameInput.value.trim();
    const password = pwInput.value;
    if (!username || !password) {
      showMessage('Please enter both your username and password.', 'error');
      return;
    }

    loginBtn.disabled = true;
    loginBtn.textContent = 'Logging in…';

    try {
      const res = await fetch('/api/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password })
      });
      const data = await res.json();

      if (data.success) {
        localStorage.setItem('revora_userId', data.userId);
        window.location.href = 'dashboard.html';
        return;
      }
      showMessage(data.message || 'Login failed.', 'error');
    } catch (err) {
      showMessage('Could not reach the server. Please try again.', 'error');
    } finally {
      loginBtn.disabled = false;
      loginBtn.textContent = 'Log In';
    }
  }

  loginBtn.addEventListener('click', submitLogin);
  pwInput.addEventListener('keydown', e => { if (e.key === 'Enter') submitLogin(); });
  usernameInput.addEventListener('keydown', e => { if (e.key === 'Enter') submitLogin(); });
}

document.addEventListener('DOMContentLoaded', initLoginPage);
