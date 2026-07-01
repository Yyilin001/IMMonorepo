import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'auth-token-rotation-smoke';
const profiles = {
  'auth-token-rotation-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_auth_token_rotation_errors: ['rate<0.001'],
      im_auth_token_rotation_total_latency: ['p(95)<3000', 'p(99)<6000'],
      im_auth_token_rotation_login_latency: ['p(95)<500', 'p(99)<1000'],
      im_auth_token_rotation_refresh_latency: ['p(95)<500', 'p(99)<1000'],
      im_auth_token_rotation_reuse_reject_latency: ['p(95)<500', 'p(99)<1000'],
      im_auth_token_rotation_me_latency: ['p(95)<500', 'p(99)<1000'],
    },
  },
  'auth-token-rotation-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_auth_token_rotation_errors: ['rate<0.001'],
      im_auth_token_rotation_total_latency: ['p(95)<5000', 'p(99)<10000'],
      im_auth_token_rotation_login_latency: ['p(95)<800', 'p(99)<2000'],
      im_auth_token_rotation_refresh_latency: ['p(95)<800', 'p(99)<2000'],
      im_auth_token_rotation_reuse_reject_latency: ['p(95)<800', 'p(99)<2000'],
      im_auth_token_rotation_me_latency: ['p(95)<800', 'p(99)<2000'],
    },
  },
  'auth-token-rotation-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.02'],
      im_auth_token_rotation_errors: ['rate<0.005'],
      im_auth_token_rotation_total_latency: ['p(95)<10000', 'p(99)<20000'],
      im_auth_token_rotation_login_latency: ['p(95)<1500', 'p(99)<4000'],
      im_auth_token_rotation_refresh_latency: ['p(95)<1500', 'p(99)<4000'],
      im_auth_token_rotation_reuse_reject_latency: ['p(95)<1500', 'p(99)<4000'],
      im_auth_token_rotation_me_latency: ['p(95)<1500', 'p(99)<4000'],
    },
  },
};

export const options = profiles[profile] || profiles['auth-token-rotation-smoke'];

http.setResponseCallback(http.expectedStatuses({ min: 200, max: 399 }, 401, 403));

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const sleepMillis = Number.parseInt(__ENV.IM_AUTH_TOKEN_ROTATION_SLEEP_MS || '0', 10);

export const rotationErrors = new Rate('im_auth_token_rotation_errors');
export const totalLatency = new Trend('im_auth_token_rotation_total_latency');
export const loginLatency = new Trend('im_auth_token_rotation_login_latency');
export const refreshLatency = new Trend('im_auth_token_rotation_refresh_latency');
export const reuseRejectLatency = new Trend('im_auth_token_rotation_reuse_reject_latency');
export const meLatency = new Trend('im_auth_token_rotation_me_latency');
export const logoutLatency = new Trend('im_auth_token_rotation_logout_latency');
export const rotationOK = new Counter('im_auth_token_rotation_ok_total');

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
  check(res, { 'auth-token-rotation login ok': (r) => r.status === 200 });
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
  check(res, { 'auth-token-rotation refresh ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function oldRefreshRejected(refreshToken) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/auth/refresh`,
    JSON.stringify({ refreshToken }),
    jsonHeaders()
  );
  reuseRejectLatency.add(Date.now() - startedAt);
  check(res, { 'auth-token-rotation old refresh rejected': (r) => r.status === 401 || r.status === 403 });
  return res.status === 401 || res.status === 403;
}

function currentAccessWorks(accessToken) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/me`, jsonHeaders(accessToken));
  meLatency.add(Date.now() - startedAt);
  check(res, { 'auth-token-rotation rotated access ok': (r) => r.status === 200 });
  return res.status === 200;
}

function logoutCurrent(accessToken) {
  const startedAt = Date.now();
  const res = http.del(`${baseURL}/api/auth/sessions/current`, null, jsonHeaders(accessToken));
  logoutLatency.add(Date.now() - startedAt);
  check(res, { 'auth-token-rotation cleanup logout accepted': (r) => r.status === 200 || r.status === 401 || r.status === 403 });
  return res.status === 200 || res.status === 401 || res.status === 403;
}

export default function () {
  const startedAt = Date.now();
  const account = accountForIteration();
  const deviceID = `k6-token-rotation-${__VU}-${__ITER}-${Date.now()}`;

  const auth = login(account, deviceID);
  if (!auth || !auth.accessToken || !auth.refreshToken) {
    rotationErrors.add(true);
    return;
  }

  const firstRefreshToken = auth.refreshToken;
  const firstRotated = refresh(firstRefreshToken);
  if (!firstRotated || !firstRotated.accessToken || !firstRotated.refreshToken) {
    rotationErrors.add(true);
    return;
  }

  if (!currentAccessWorks(firstRotated.accessToken)) {
    rotationErrors.add(true);
    return;
  }

  const secondRefreshToken = firstRotated.refreshToken;
  const secondRotated = refresh(secondRefreshToken);
  if (!secondRotated || !secondRotated.accessToken || !secondRotated.refreshToken) {
    rotationErrors.add(true);
    return;
  }

  if (!currentAccessWorks(secondRotated.accessToken)) {
    rotationErrors.add(true);
    return;
  }

  if (!oldRefreshRejected(firstRefreshToken)) {
    rotationErrors.add(true);
    return;
  }

  if (!oldRefreshRejected(secondRefreshToken)) {
    rotationErrors.add(true);
    return;
  }

  logoutCurrent(secondRotated.accessToken);

  totalLatency.add(Date.now() - startedAt);
  rotationOK.add(1);
  rotationErrors.add(false);

  if (sleepMillis > 0) {
    sleep(sleepMillis / 1000);
  }
}
