import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'auth-failure-recovery-smoke';
const profiles = {
  'auth-failure-recovery-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_auth_failure_recovery_errors: ['rate<0.001'],
      im_auth_failure_recovery_total_latency: ['p(95)<3000', 'p(99)<6000'],
      im_auth_failure_recovery_reject_latency: ['p(95)<500', 'p(99)<1000'],
      im_auth_failure_recovery_login_latency: ['p(95)<500', 'p(99)<1000'],
      im_auth_failure_recovery_refresh_reject_latency: ['p(95)<500', 'p(99)<1000'],
      im_auth_failure_recovery_access_reject_latency: ['p(95)<500', 'p(99)<1000'],
    },
  },
  'auth-failure-recovery-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_auth_failure_recovery_errors: ['rate<0.001'],
      im_auth_failure_recovery_total_latency: ['p(95)<5000', 'p(99)<10000'],
      im_auth_failure_recovery_reject_latency: ['p(95)<800', 'p(99)<2000'],
      im_auth_failure_recovery_login_latency: ['p(95)<800', 'p(99)<2000'],
      im_auth_failure_recovery_refresh_reject_latency: ['p(95)<800', 'p(99)<2000'],
      im_auth_failure_recovery_access_reject_latency: ['p(95)<800', 'p(99)<2000'],
    },
  },
  'auth-failure-recovery-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.02'],
      im_auth_failure_recovery_errors: ['rate<0.005'],
      im_auth_failure_recovery_total_latency: ['p(95)<10000', 'p(99)<20000'],
      im_auth_failure_recovery_reject_latency: ['p(95)<1500', 'p(99)<4000'],
      im_auth_failure_recovery_login_latency: ['p(95)<1500', 'p(99)<4000'],
      im_auth_failure_recovery_refresh_reject_latency: ['p(95)<1500', 'p(99)<4000'],
      im_auth_failure_recovery_access_reject_latency: ['p(95)<1500', 'p(99)<4000'],
    },
  },
};

export const options = profiles[profile] || profiles['auth-failure-recovery-smoke'];

http.setResponseCallback(http.expectedStatuses({ min: 200, max: 399 }, 400, 401, 403, 404));

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const wrongPassword = __ENV.IM_AUTH_FAILURE_WRONG_PASSWORD || `${defaultPassword}-wrong`;
const sleepMillis = Number.parseInt(__ENV.IM_AUTH_FAILURE_RECOVERY_SLEEP_MS || '250', 10);

export const recoveryErrors = new Rate('im_auth_failure_recovery_errors');
export const totalLatency = new Trend('im_auth_failure_recovery_total_latency');
export const rejectLatency = new Trend('im_auth_failure_recovery_reject_latency');
export const loginLatency = new Trend('im_auth_failure_recovery_login_latency');
export const refreshRejectLatency = new Trend('im_auth_failure_recovery_refresh_reject_latency');
export const accessRejectLatency = new Trend('im_auth_failure_recovery_access_reject_latency');
export const logoutLatency = new Trend('im_auth_failure_recovery_logout_latency');
export const recoveryOK = new Counter('im_auth_failure_recovery_ok_total');

function loadAccountsFromCSV(path) {
  if (!path) {
    return [];
  }
  return open(path)
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith('#'))
    .map((line) => {
      const comma = line.indexOf(',');
      if (comma < 0) {
        return null;
      }
      const email = line.slice(0, comma).trim();
      const password = line.slice(comma + 1).trim();
      return email && password ? { email, password } : null;
    })
    .filter((account) => account !== null);
}

const csvAccounts = loadAccountsFromCSV(accountFile);

function accountForIteration() {
  if (csvAccounts.length > 0) {
    return csvAccounts[((__VU - 1) + __ITER) % csvAccounts.length];
  }
  return { email: defaultEmail, password: defaultPassword };
}

function jsonHeaders(token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return { headers };
}

function loginAttempt(email, password, deviceID, metric) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/auth/login`,
    JSON.stringify({
      email,
      password,
      device: {
        deviceID,
        deviceName: deviceID,
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  metric.add(Date.now() - startedAt);
  return res;
}

function failedLoginRejected(account, suffix) {
  const res = loginAttempt(
    account.email,
    wrongPassword,
    `k6-auth-failure-wrong-${suffix}`,
    rejectLatency
  );
  check(res, { 'auth failure wrong password rejected': (r) => r.status === 400 || r.status === 401 || r.status === 403 });
  return res.status === 400 || res.status === 401 || res.status === 403;
}

function unknownAccountRejected(account, suffix) {
  const local = account.email.includes('@') ? account.email.split('@')[0] : account.email;
  const domain = account.email.includes('@') ? account.email.split('@').slice(1).join('@') : 'example.com';
  const unknownEmail = `${local}+missing-${suffix}@${domain}`;
  const res = loginAttempt(
    unknownEmail,
    account.password,
    `k6-auth-failure-missing-${suffix}`,
    rejectLatency
  );
  check(res, { 'auth failure unknown account rejected': (r) => r.status === 400 || r.status === 401 || r.status === 403 || r.status === 404 });
  return res.status === 400 || res.status === 401 || res.status === 403 || res.status === 404;
}

function successfulLogin(account, suffix) {
  const res = loginAttempt(
    account.email,
    account.password,
    `k6-auth-failure-recovery-${suffix}`,
    loginLatency
  );
  check(res, { 'auth failure recovery login ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function badRefreshRejected() {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/auth/refresh`,
    JSON.stringify({ refreshToken: `bad-refresh-${__VU}-${__ITER}-${Date.now()}` }),
    jsonHeaders()
  );
  refreshRejectLatency.add(Date.now() - startedAt);
  check(res, { 'auth failure bad refresh rejected': (r) => r.status === 400 || r.status === 401 || r.status === 403 });
  return res.status === 400 || res.status === 401 || res.status === 403;
}

function badAccessRejected() {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/me`, jsonHeaders(`bad-access-${__VU}-${__ITER}-${Date.now()}`));
  accessRejectLatency.add(Date.now() - startedAt);
  check(res, { 'auth failure bad access rejected': (r) => r.status === 401 || r.status === 403 });
  return res.status === 401 || res.status === 403;
}

function logoutCurrent(accessToken) {
  const startedAt = Date.now();
  const res = http.del(`${baseURL}/api/auth/sessions/current`, null, jsonHeaders(accessToken));
  logoutLatency.add(Date.now() - startedAt);
  check(res, { 'auth failure cleanup logout accepted': (r) => r.status === 200 || r.status === 401 || r.status === 403 });
  return res.status === 200 || res.status === 401 || res.status === 403;
}

export default function () {
  const startedAt = Date.now();
  const account = accountForIteration();
  const suffix = `${__VU}-${__ITER}-${Date.now()}`;

  if (!failedLoginRejected(account, suffix)) {
    recoveryErrors.add(true);
    return;
  }

  if (!unknownAccountRejected(account, suffix)) {
    recoveryErrors.add(true);
    return;
  }

  if (!badRefreshRejected()) {
    recoveryErrors.add(true);
    return;
  }

  if (!badAccessRejected()) {
    recoveryErrors.add(true);
    return;
  }

  const auth = successfulLogin(account, suffix);
  if (!auth || !auth.accessToken || !auth.refreshToken) {
    recoveryErrors.add(true);
    return;
  }

  logoutCurrent(auth.accessToken);

  totalLatency.add(Date.now() - startedAt);
  recoveryOK.add(1);
  recoveryErrors.add(false);

  if (sleepMillis > 0) {
    sleep(sleepMillis / 1000);
  }
}
