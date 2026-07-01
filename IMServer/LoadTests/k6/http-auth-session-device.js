import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'auth-session-smoke';
const profiles = {
  'auth-session-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_auth_session_errors: ['rate<0.001'],
      im_auth_session_total_latency: ['p(95)<2500', 'p(99)<5000'],
      im_auth_session_login_latency: ['p(95)<500', 'p(99)<1000'],
      im_auth_session_refresh_latency: ['p(95)<500', 'p(99)<1000'],
      im_auth_session_list_latency: ['p(95)<500', 'p(99)<1000'],
      im_auth_session_push_register_latency: ['p(95)<500', 'p(99)<1000'],
      im_auth_session_logout_latency: ['p(95)<500', 'p(99)<1000'],
    },
  },
  'auth-session-baseline': {
    vus: 200,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_auth_session_errors: ['rate<0.001'],
      im_auth_session_total_latency: ['p(95)<4000', 'p(99)<8000'],
      im_auth_session_login_latency: ['p(95)<800', 'p(99)<2000'],
      im_auth_session_refresh_latency: ['p(95)<800', 'p(99)<2000'],
      im_auth_session_list_latency: ['p(95)<800', 'p(99)<2000'],
      im_auth_session_push_register_latency: ['p(95)<800', 'p(99)<2000'],
      im_auth_session_logout_latency: ['p(95)<800', 'p(99)<2000'],
    },
  },
  'auth-session-capacity': {
    vus: 1000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_auth_session_errors: ['rate<0.005'],
      im_auth_session_total_latency: ['p(95)<8000', 'p(99)<15000'],
      im_auth_session_login_latency: ['p(95)<1500', 'p(99)<4000'],
      im_auth_session_refresh_latency: ['p(95)<1500', 'p(99)<4000'],
      im_auth_session_list_latency: ['p(95)<1500', 'p(99)<4000'],
      im_auth_session_push_register_latency: ['p(95)<1500', 'p(99)<4000'],
      im_auth_session_logout_latency: ['p(95)<1500', 'p(99)<4000'],
    },
  },
};

export const options = profiles[profile] || profiles['auth-session-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const sleepMillis = Number.parseInt(__ENV.IM_AUTH_SESSION_SLEEP_MS || '0', 10);

export const authSessionErrors = new Rate('im_auth_session_errors');
export const totalLatency = new Trend('im_auth_session_total_latency');
export const loginLatency = new Trend('im_auth_session_login_latency');
export const refreshLatency = new Trend('im_auth_session_refresh_latency');
export const listLatency = new Trend('im_auth_session_list_latency');
export const pushRegisterLatency = new Trend('im_auth_session_push_register_latency');
export const pushDeleteLatency = new Trend('im_auth_session_push_delete_latency');
export const logoutLatency = new Trend('im_auth_session_logout_latency');
export const lifecycleOK = new Counter('im_auth_session_lifecycle_ok_total');

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

function login(account, deviceID) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/auth/login`,
    JSON.stringify({
      email: account.email,
      password: account.password,
      device: {
        deviceID,
        deviceName: deviceID,
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  loginLatency.add(Date.now() - startedAt);
  check(res, { 'auth-session login ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function refresh(refreshToken) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/auth/refresh`,
    JSON.stringify({ refreshToken }),
    jsonHeaders()
  );
  refreshLatency.add(Date.now() - startedAt);
  check(res, { 'auth-session refresh ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function listSessions(accessToken, expectedDeviceID) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/auth/sessions`, jsonHeaders(accessToken));
  listLatency.add(Date.now() - startedAt);
  check(res, { 'auth-session list ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    return false;
  }
  const sessions = res.json();
  return Array.isArray(sessions)
    && sessions.some((item) => item.deviceID === expectedDeviceID && item.isCurrent === true);
}

function registerPushToken(accessToken, token) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/push/device-tokens`,
    JSON.stringify({ platform: 'ios', token }),
    jsonHeaders(accessToken)
  );
  pushRegisterLatency.add(Date.now() - startedAt);
  check(res, { 'auth-session push register ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json('id') : null;
}

function deletePushToken(accessToken, tokenID) {
  const startedAt = Date.now();
  const res = http.del(`${baseURL}/api/push/device-tokens/${tokenID}`, null, jsonHeaders(accessToken));
  pushDeleteLatency.add(Date.now() - startedAt);
  check(res, { 'auth-session push delete ok': (r) => r.status === 200 });
  return res.status === 200;
}

function logoutCurrent(accessToken) {
  const startedAt = Date.now();
  const res = http.del(`${baseURL}/api/auth/sessions/current`, null, jsonHeaders(accessToken));
  logoutLatency.add(Date.now() - startedAt);
  check(res, { 'auth-session logout current ok': (r) => r.status === 200 });
  return res.status === 200;
}

export default function () {
  const startedAt = Date.now();
  const account = accountForIteration();
  const deviceID = `k6-auth-session-${__VU}-${__ITER}-${Date.now()}`;
  const auth = login(account, deviceID);
  if (!auth || !auth.accessToken || !auth.refreshToken) {
    authSessionErrors.add(true);
    return;
  }

  const refreshed = refresh(auth.refreshToken);
  if (!refreshed || !refreshed.accessToken) {
    authSessionErrors.add(true);
    return;
  }

  if (!listSessions(refreshed.accessToken, deviceID)) {
    authSessionErrors.add(true);
    return;
  }

  const pushToken = `apns-${__VU}-${__ITER}-${Date.now()}`;
  const tokenID = registerPushToken(refreshed.accessToken, pushToken);
  if (!tokenID) {
    authSessionErrors.add(true);
    return;
  }

  if (!deletePushToken(refreshed.accessToken, tokenID)) {
    authSessionErrors.add(true);
    return;
  }

  if (!logoutCurrent(refreshed.accessToken)) {
    authSessionErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  lifecycleOK.add(1);
  authSessionErrors.add(false);

  if (sleepMillis > 0) {
    sleep(sleepMillis / 1000);
  }
}
