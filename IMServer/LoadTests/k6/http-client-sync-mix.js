import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'client-sync-mix-smoke';
const profiles = {
  'client-sync-mix-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_client_sync_mix_errors: ['rate<0.001'],
      im_client_sync_mix_total_latency: ['p(95)<3000', 'p(99)<6000'],
      im_client_sync_mix_read_latency: ['p(95)<800', 'p(99)<1500'],
      im_client_sync_mix_health_latency: ['p(95)<500', 'p(99)<1000'],
    },
  },
  'client-sync-mix-baseline': {
    vus: 300,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_client_sync_mix_errors: ['rate<0.001'],
      im_client_sync_mix_total_latency: ['p(95)<4000', 'p(99)<8000'],
      im_client_sync_mix_read_latency: ['p(95)<1000', 'p(99)<2500'],
      im_client_sync_mix_health_latency: ['p(95)<800', 'p(99)<2000'],
    },
  },
  'client-sync-mix-capacity': {
    vus: 1000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_client_sync_mix_errors: ['rate<0.005'],
      im_client_sync_mix_total_latency: ['p(95)<7000', 'p(99)<15000'],
      im_client_sync_mix_read_latency: ['p(95)<2000', 'p(99)<5000'],
      im_client_sync_mix_health_latency: ['p(95)<1500', 'p(99)<4000'],
    },
  },
};

export const options = profiles[profile] || profiles['client-sync-mix-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const accountPrefix = __ENV.IM_ACCOUNT_PREFIX || 'load';
const accountDomain = __ENV.IM_ACCOUNT_DOMAIN || 'example.com';
const accountPassword = __ENV.IM_ACCOUNT_PASSWORD || defaultPassword;
const accountStartIndex = Number.parseInt(__ENV.IM_ACCOUNT_START_INDEX || '1', 10);
const accountCount = Number.parseInt(__ENV.IM_ACCOUNT_COUNT || '0', 10);
const sleepMillis = Number.parseInt(__ENV.IM_CLIENT_SYNC_MIX_SLEEP_MS || '250', 10);
const conversationID = __ENV.IM_CONVERSATION_ID || '';
const changesToken = __ENV.IM_CLIENT_SYNC_MIX_AFTER_TOKEN || '1970-01-01T00:00:00.000Z:';
const domainEventCursor = Number.parseInt(__ENV.IM_CLIENT_SYNC_MIX_DOMAIN_CURSOR || '0', 10);

export const clientSyncMixErrors = new Rate('im_client_sync_mix_errors');
export const totalLatency = new Trend('im_client_sync_mix_total_latency');
export const readLatency = new Trend('im_client_sync_mix_read_latency');
export const healthLatency = new Trend('im_client_sync_mix_health_latency');
export const requestOK = new Counter('im_client_sync_mix_ok_total');

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
let perVUAuth = null;

function accountForVU() {
  if (csvAccounts.length > 0) {
    return csvAccounts[(__VU - 1) % csvAccounts.length];
  }
  if (accountCount > 0) {
    return generatedAccount((__VU - 1) % accountCount);
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
  if (perVUAuth) {
    return perVUAuth;
  }
  const account = accountForVU();
  const deviceID = `k6-client-sync-mix-${__VU}`;
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
  check(res, { 'client sync mix login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  perVUAuth = res.json();
  return perVUAuth;
}

function timedGet(url, token, label) {
  const startedAt = Date.now();
  const res = http.get(url, jsonHeaders(token));
  readLatency.add(Date.now() - startedAt);
  check(res, { [`${label} ok`]: (r) => r.status === 200 });
  return res.status === 200;
}

function postClientHealth(token) {
  const startedAt = Date.now();
  const seed = (__VU * 100000) + __ITER;
  const res = http.post(
    `${baseURL}/api/im/client-health`,
    JSON.stringify({
      snapshot: {
        domainEventCursor: seed,
        deferredDomainEventCount: seed % 3,
        fullRefreshConversationCount: 0,
        domainEventMetrics: {
          invalidDomainEventMetadata: 0,
          missingRequiredNotice: 0,
          deferredStored: seed % 2,
          deferredEncodeFailed: 0,
          deferredNotDeferrable: 0,
          deferredReplayApplied: seed % 2,
          deferredExpired: 0,
          deferredFullRefreshRequested: 0,
          cacheDroppedCanonicalMessages: 0,
          cacheDroppedTimelineNotices: 0,
          invalidCanonicalMessageDTOs: 0,
          invalidProjectionDTOs: 0,
          sequenceDecodeOverflow: 0,
          realtimeMissingDeliveryRow: 0,
          catchUpCursorGap: 0,
          catchUpStoppedBeforeCursorAdvance: 0,
          invalidDeferredPayload: 0,
        },
        timelineCatchUpDiagnostics: null,
        timelineCatchUpConfiguration: null,
      },
      reason: 'foreground-sync',
      reportedAt: new Date().toISOString(),
    }),
    jsonHeaders(token)
  );
  healthLatency.add(Date.now() - startedAt);
  check(res, { 'client sync mix health ok': (r) => r.status === 204 });
  return res.status === 204;
}

export default function () {
  const startedAt = Date.now();
  const auth = login();
  const token = auth.accessToken;
  let ok = true;

  ok = timedGet(`${baseURL}/api/me`, token, 'me') && ok;
  ok = timedGet(`${baseURL}/api/contacts`, token, 'contacts') && ok;
  ok = timedGet(`${baseURL}/api/contacts/changes?limit=100`, token, 'contact changes') && ok;
  ok = timedGet(`${baseURL}/api/im/conversations?limit=100`, token, 'conversation list') && ok;
  ok = timedGet(
    `${baseURL}/api/im/conversations/changes?afterToken=${encodeURIComponent(changesToken)}&limit=100`,
    token,
    'conversation changes'
  ) && ok;
  ok = timedGet(
    `${baseURL}/api/im/domain-events?after=${domainEventCursor}&limit=100`,
    token,
    'domain events'
  ) && ok;

  if (conversationID) {
    ok = timedGet(
      `${baseURL}/api/im/conversations/${conversationID}/timeline?limit=50`,
      token,
      'timeline latest'
    ) && ok;
    ok = timedGet(
      `${baseURL}/api/im/conversations/${conversationID}/timeline/since?afterSequence=0&limit=50`,
      token,
      'timeline since'
    ) && ok;
  }

  ok = postClientHealth(token) && ok;
  clientSyncMixErrors.add(!ok);
  if (ok) {
    requestOK.add(1);
  }
  totalLatency.add(Date.now() - startedAt);
  sleep(Math.max(0, sleepMillis) / 1000);
}
