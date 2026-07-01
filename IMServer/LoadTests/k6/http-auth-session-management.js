import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'auth-session-management-smoke';
const profiles = {
  'auth-session-management-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_auth_session_management_errors: ['rate<0.001'],
      im_auth_session_management_total_latency: ['p(95)<3000', 'p(99)<6000'],
      im_auth_session_management_login_latency: ['p(95)<500', 'p(99)<1000'],
      im_auth_session_management_list_latency: ['p(95)<500', 'p(99)<1000'],
      im_auth_session_management_logout_one_latency: ['p(95)<500', 'p(99)<1000'],
      im_auth_session_management_logout_all_latency: ['p(95)<800', 'p(99)<1500'],
      im_auth_session_management_revoked_refresh_latency: ['p(95)<500', 'p(99)<1000'],
    },
  },
  'auth-session-management-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_auth_session_management_errors: ['rate<0.001'],
      im_auth_session_management_total_latency: ['p(95)<5000', 'p(99)<10000'],
      im_auth_session_management_login_latency: ['p(95)<800', 'p(99)<2000'],
      im_auth_session_management_list_latency: ['p(95)<800', 'p(99)<2000'],
      im_auth_session_management_logout_one_latency: ['p(95)<800', 'p(99)<2000'],
      im_auth_session_management_logout_all_latency: ['p(95)<1000', 'p(99)<2500'],
      im_auth_session_management_revoked_refresh_latency: ['p(95)<800', 'p(99)<2000'],
    },
  },
  'auth-session-management-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.02'],
      im_auth_session_management_errors: ['rate<0.005'],
      im_auth_session_management_total_latency: ['p(95)<10000', 'p(99)<20000'],
      im_auth_session_management_login_latency: ['p(95)<1500', 'p(99)<4000'],
      im_auth_session_management_list_latency: ['p(95)<1500', 'p(99)<4000'],
      im_auth_session_management_logout_one_latency: ['p(95)<1500', 'p(99)<4000'],
      im_auth_session_management_logout_all_latency: ['p(95)<2500', 'p(99)<5000'],
      im_auth_session_management_revoked_refresh_latency: ['p(95)<1500', 'p(99)<4000'],
    },
  },
};

export const options = profiles[profile] || profiles['auth-session-management-smoke'];

http.setResponseCallback(http.expectedStatuses({ min: 200, max: 399 }, 401, 403));

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const sleepMillis = Number.parseInt(__ENV.IM_AUTH_SESSION_MANAGEMENT_SLEEP_MS || '0', 10);

export const managementErrors = new Rate('im_auth_session_management_errors');
export const totalLatency = new Trend('im_auth_session_management_total_latency');
export const loginLatency = new Trend('im_auth_session_management_login_latency');
export const listLatency = new Trend('im_auth_session_management_list_latency');
export const logoutOneLatency = new Trend('im_auth_session_management_logout_one_latency');
export const logoutAllLatency = new Trend('im_auth_session_management_logout_all_latency');
export const revokedRefreshLatency = new Trend('im_auth_session_management_revoked_refresh_latency');
export const managementOK = new Counter('im_auth_session_management_ok_total');

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
  check(res, { 'auth-session-management login ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function listSessions(accessToken) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/auth/sessions`, jsonHeaders(accessToken));
  listLatency.add(Date.now() - startedAt);
  check(res, { 'auth-session-management list ok': (r) => r.status === 200 });
  return res.status === 200 && Array.isArray(res.json()) ? res.json() : null;
}

function findSessionID(sessions, deviceID) {
  const session = sessions.find((item) => item.deviceID === deviceID);
  return session && session.id ? session.id : null;
}

function logoutSession(accessToken, sessionID) {
  const startedAt = Date.now();
  const res = http.del(`${baseURL}/api/auth/sessions/${sessionID}`, null, jsonHeaders(accessToken));
  logoutOneLatency.add(Date.now() - startedAt);
  check(res, { 'auth-session-management logout one ok': (r) => r.status === 200 });
  return res.status === 200;
}

function logoutAll(accessToken) {
  const startedAt = Date.now();
  const res = http.del(`${baseURL}/api/auth/sessions/all`, null, jsonHeaders(accessToken));
  logoutAllLatency.add(Date.now() - startedAt);
  check(res, { 'auth-session-management logout all ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json('revokedSessions') : null;
}

function revokedRefreshFails(refreshToken) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/auth/refresh`,
    JSON.stringify({ refreshToken }),
    jsonHeaders()
  );
  revokedRefreshLatency.add(Date.now() - startedAt);
  check(res, { 'auth-session-management revoked refresh rejected': (r) => r.status === 401 || r.status === 403 });
  return res.status === 401 || res.status === 403;
}

export default function () {
  const startedAt = Date.now();
  const account = accountForIteration();
  const suffix = `${__VU}-${__ITER}-${Date.now()}`;
  const controllerDeviceID = `k6-session-controller-${suffix}`;
  const targetDeviceID = `k6-session-target-${suffix}`;

  const controllerAuth = login(account, controllerDeviceID);
  const targetAuth = login(account, targetDeviceID);
  if (!controllerAuth || !targetAuth || !controllerAuth.accessToken || !targetAuth.refreshToken) {
    managementErrors.add(true);
    return;
  }

  const sessions = listSessions(controllerAuth.accessToken);
  const targetSessionID = sessions ? findSessionID(sessions, targetDeviceID) : null;
  if (!targetSessionID) {
    managementErrors.add(true);
    return;
  }

  if (!logoutSession(controllerAuth.accessToken, targetSessionID)) {
    managementErrors.add(true);
    return;
  }

  if (!revokedRefreshFails(targetAuth.refreshToken)) {
    managementErrors.add(true);
    return;
  }

  const revokedSessions = logoutAll(controllerAuth.accessToken);
  if (revokedSessions === null || Number(revokedSessions) < 1) {
    managementErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  managementOK.add(1);
  managementErrors.add(false);

  if (sleepMillis > 0) {
    sleep(sleepMillis / 1000);
  }
}
