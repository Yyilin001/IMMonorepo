import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'login-smoke';
const profiles = {
  'login-smoke': {
    vus: 1,
    duration: '20s',
    thresholds: {
      http_req_failed: ['rate<0.001'],
      im_auth_login_errors: ['rate<0.001'],
      im_auth_login_latency: ['p(95)<500', 'p(99)<1000'],
    },
  },
  'login-baseline': {
    vus: 200,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.001'],
      im_auth_login_errors: ['rate<0.001'],
      im_auth_login_latency: ['p(95)<500', 'p(99)<1500'],
    },
  },
  'login-capacity': {
    vus: 1000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_auth_login_errors: ['rate<0.005'],
      im_auth_login_latency: ['p(95)<1000', 'p(99)<3000'],
    },
  },
};

export const options = profiles[profile] || profiles['login-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const accountPrefix = __ENV.IM_ACCOUNT_PREFIX || 'load';
const accountDomain = __ENV.IM_ACCOUNT_DOMAIN || 'example.com';
const accountPassword = __ENV.IM_ACCOUNT_PASSWORD || defaultPassword;
const accountStartIndex = Number.parseInt(__ENV.IM_ACCOUNT_START_INDEX || '1', 10);
const accountCount = Number.parseInt(__ENV.IM_ACCOUNT_COUNT || '0', 10);
const sleepMillis = Number.parseInt(__ENV.IM_LOGIN_SLEEP_MS || '0', 10);

export const loginErrors = new Rate('im_auth_login_errors');
export const loginLatency = new Trend('im_auth_login_latency');
export const loginOK = new Counter('im_auth_login_ok_total');

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

function generatedAccount(index) {
  const value = accountStartIndex + index;
  const padded = String(value).padStart(5, '0');
  return {
    email: `${accountPrefix}-${padded}@${accountDomain}`,
    password: accountPassword,
  };
}

const csvAccounts = loadAccountsFromCSV(accountFile);

function accountForIteration() {
  if (csvAccounts.length > 0) {
    return csvAccounts[((__VU - 1) + __ITER) % csvAccounts.length];
  }
  if (accountCount > 0) {
    return generatedAccount(((__VU - 1) + __ITER) % accountCount);
  }
  return { email: defaultEmail, password: defaultPassword };
}

function jsonHeaders() {
  return { headers: { 'Content-Type': 'application/json' } };
}

export default function () {
  const account = accountForIteration();
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/auth/login`,
    JSON.stringify({
      email: account.email,
      password: account.password,
      device: {
        deviceID: `k6-login-${__VU}-${__ITER}`,
        deviceName: 'k6-login',
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );

  const ok = res.status === 200;
  loginLatency.add(Date.now() - startedAt);
  loginErrors.add(!ok);
  if (ok) {
    loginOK.add(1);
  }
  check(res, { 'login ok': (r) => r.status === 200 });

  if (sleepMillis > 0) {
    sleep(sleepMillis / 1000);
  }
}
