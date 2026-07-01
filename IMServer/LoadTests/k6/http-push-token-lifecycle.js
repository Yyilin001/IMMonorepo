import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'push-token-smoke';
const profiles = {
  'push-token-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_push_token_errors: ['rate<0.001'],
      im_push_token_total_latency: ['p(95)<2500', 'p(99)<5000'],
      im_push_token_register_latency: ['p(95)<500', 'p(99)<1000'],
      im_push_token_upsert_latency: ['p(95)<500', 'p(99)<1000'],
      im_push_token_delete_latency: ['p(95)<500', 'p(99)<1000'],
      im_push_token_idempotent_delete_latency: ['p(95)<500', 'p(99)<1000'],
    },
  },
  'push-token-baseline': {
    vus: 200,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_push_token_errors: ['rate<0.001'],
      im_push_token_total_latency: ['p(95)<4000', 'p(99)<8000'],
      im_push_token_register_latency: ['p(95)<800', 'p(99)<2000'],
      im_push_token_upsert_latency: ['p(95)<800', 'p(99)<2000'],
      im_push_token_delete_latency: ['p(95)<800', 'p(99)<2000'],
      im_push_token_idempotent_delete_latency: ['p(95)<800', 'p(99)<2000'],
    },
  },
  'push-token-capacity': {
    vus: 1000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_push_token_errors: ['rate<0.005'],
      im_push_token_total_latency: ['p(95)<8000', 'p(99)<15000'],
      im_push_token_register_latency: ['p(95)<1500', 'p(99)<4000'],
      im_push_token_upsert_latency: ['p(95)<1500', 'p(99)<4000'],
      im_push_token_delete_latency: ['p(95)<1500', 'p(99)<4000'],
      im_push_token_idempotent_delete_latency: ['p(95)<1500', 'p(99)<4000'],
    },
  },
};

export const options = profiles[profile] || profiles['push-token-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const sleepMillis = Number.parseInt(__ENV.IM_PUSH_TOKEN_SLEEP_MS || '0', 10);

export const pushTokenErrors = new Rate('im_push_token_errors');
export const totalLatency = new Trend('im_push_token_total_latency');
export const registerLatency = new Trend('im_push_token_register_latency');
export const upsertLatency = new Trend('im_push_token_upsert_latency');
export const deleteLatency = new Trend('im_push_token_delete_latency');
export const idempotentDeleteLatency = new Trend('im_push_token_idempotent_delete_latency');
export const lifecycleOK = new Counter('im_push_token_lifecycle_ok_total');

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
let authState = null;

function accountForVU() {
  if (csvAccounts.length > 0) {
    return csvAccounts[(__VU - 1) % csvAccounts.length];
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

function login() {
  if (authState) {
    return authState;
  }
  const account = accountForVU();
  const deviceID = `k6-push-token-${__VU}`;
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
  check(res, { 'push-token login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  authState = res.json();
  return authState;
}

function registerPushToken(accessToken, token, metric, label) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/push/device-tokens`,
    JSON.stringify({ platform: 'ios', token }),
    jsonHeaders(accessToken)
  );
  metric.add(Date.now() - startedAt);
  check(res, { [`${label} ok`]: (r) => r.status === 200 });
  if (res.status !== 200) {
    return null;
  }
  return res.json();
}

function deletePushToken(accessToken, tokenID, metric, label) {
  const startedAt = Date.now();
  const res = http.del(`${baseURL}/api/push/device-tokens/${tokenID}`, null, jsonHeaders(accessToken));
  metric.add(Date.now() - startedAt);
  check(res, { [`${label} ok`]: (r) => r.status === 200 });
  return res.status === 200;
}

export default function () {
  const startedAt = Date.now();
  const auth = login();
  const token = `apns-k6-${__VU}-${__ITER}`;

  const created = registerPushToken(auth.accessToken, token, registerLatency, 'push-token register');
  if (!created || !created.id || created.platform !== 'ios' || created.token !== token || created.isActive !== true) {
    pushTokenErrors.add(true);
    return;
  }

  const upserted = registerPushToken(auth.accessToken, token, upsertLatency, 'push-token upsert');
  if (!upserted || upserted.id !== created.id || upserted.isActive !== true) {
    pushTokenErrors.add(true);
    return;
  }

  if (!deletePushToken(auth.accessToken, created.id, deleteLatency, 'push-token delete')) {
    pushTokenErrors.add(true);
    return;
  }

  if (!deletePushToken(auth.accessToken, created.id, idempotentDeleteLatency, 'push-token idempotent delete')) {
    pushTokenErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  lifecycleOK.add(1);
  pushTokenErrors.add(false);

  if (sleepMillis > 0) {
    sleep(sleepMillis / 1000);
  }
}
