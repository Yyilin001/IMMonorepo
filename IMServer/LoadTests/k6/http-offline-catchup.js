import http from 'k6/http';
import { richTextContent, initialDerivedState } from './im-message-payload.js';
import { check, fail, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'offline-catchup-smoke';
const profiles = {
  'offline-catchup-smoke': {
    vus: 5,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_offline_catchup_errors: ['rate<0.001'],
      im_offline_catchup_total_latency: ['p(95)<5000', 'p(99)<10000'],
      im_offline_catchup_write_latency: ['p(95)<1000', 'p(99)<2500'],
      im_offline_catchup_read_latency: ['p(95)<2000', 'p(99)<5000'],
    },
  },
  'offline-catchup-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_offline_catchup_errors: ['rate<0.002'],
      im_offline_catchup_total_latency: ['p(95)<7000', 'p(99)<15000'],
      im_offline_catchup_write_latency: ['p(95)<1500', 'p(99)<3500'],
      im_offline_catchup_read_latency: ['p(95)<3000', 'p(99)<7000'],
    },
  },
  'offline-catchup-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_offline_catchup_errors: ['rate<0.005'],
      im_offline_catchup_total_latency: ['p(95)<12000', 'p(99)<25000'],
      im_offline_catchup_write_latency: ['p(95)<3000', 'p(99)<7000'],
      im_offline_catchup_read_latency: ['p(95)<5000', 'p(99)<12000'],
    },
  },
};

export const options = profiles[profile] || profiles['offline-catchup-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const commandBaseURL = (__ENV.IM_COMMAND_BASE_URL || baseURL).replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const accountPrefix = __ENV.IM_ACCOUNT_PREFIX || 'load';
const accountDomain = __ENV.IM_ACCOUNT_DOMAIN || 'example.com';
const accountPassword = __ENV.IM_ACCOUNT_PASSWORD || defaultPassword;
const accountStartIndex = Number.parseInt(__ENV.IM_ACCOUNT_START_INDEX || '1', 10);
const accountCount = Number.parseInt(__ENV.IM_ACCOUNT_COUNT || '0', 10);
const conversationID = __ENV.IM_CONVERSATION_ID || '';
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const messagesPerCatchup = Math.max(1, Number.parseInt(__ENV.IM_OFFLINE_CATCHUP_MESSAGES || '3', 10));
const timelineLimit = Number.parseInt(__ENV.IM_OFFLINE_CATCHUP_TIMELINE_LIMIT || '50', 10);
const changesTokenOverride = __ENV.IM_OFFLINE_CATCHUP_AFTER_TOKEN || '';
const domainEventCursor = Number.parseInt(__ENV.IM_OFFLINE_CATCHUP_DOMAIN_CURSOR || '0', 10);
const sleepMillis = Number.parseInt(__ENV.IM_OFFLINE_CATCHUP_SLEEP_MS || '500', 10);

export const catchupErrors = new Rate('im_offline_catchup_errors');
export const totalLatency = new Trend('im_offline_catchup_total_latency');
export const writeLatency = new Trend('im_offline_catchup_write_latency');
export const readLatency = new Trend('im_offline_catchup_read_latency');
export const catchupOK = new Counter('im_offline_catchup_ok_total');

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
let perVUState = null;

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

function login(account, deviceID) {
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
  check(res, { 'offline catchup login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function ensureState() {
  if (perVUState) {
    return perVUState;
  }
  if (!conversationID) {
    fail('IM_CONVERSATION_ID is required for offline catch-up tests.');
  }
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for offline catch-up tests.');
  }
  const account = accountForVU();
  const auth = login(account, `k6-offline-catchup-${__VU}`);
  perVUState = {
    token: auth.accessToken,
    senderUserID: auth.user.id,
  };
  return perVUState;
}

function sendOfflineMessages(state) {
  let ok = true;
  for (let index = 0; index < messagesPerCatchup; index += 1) {
    const startedAt = Date.now();
    const clientMessageID = `k6-offline-${__VU}-${__ITER}-${index}-${Date.now()}`;
    const res = http.post(
      `${commandBaseURL}/internal/im/messages/send`,
      JSON.stringify({
        senderUserID: state.senderUserID,
        payload: {
          clientMessageID,
          messageID: null,
          conversationID,
          senderUserID: null,
          serverSequence: null,
          serverTimestamp: null,
          content: richTextContent(`offline catchup ${clientMessageID}`),
          derivedState: initialDerivedState(),
        },
      }),
      { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
    );
    writeLatency.add(Date.now() - startedAt);
    check(res, { 'offline message write ok': (r) => r.status === 200 });
    ok = (res.status === 200) && ok;
  }
  return ok;
}

function timedGet(url, token, label) {
  const startedAt = Date.now();
  const res = http.get(url, jsonHeaders(token));
  readLatency.add(Date.now() - startedAt);
  check(res, { [`${label} ok`]: (r) => r.status === 200 });
  return res.status === 200;
}

function fetchConversationList(state) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/im/conversations?limit=100`, jsonHeaders(state.token));
  readLatency.add(Date.now() - startedAt);
  check(res, { 'conversation list baseline ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    return null;
  }

  const body = res.json();
  return typeof body.snapshotToken === 'string' && body.snapshotToken.length > 0
    ? body.snapshotToken
    : null;
}

function catchUp(state, baselineSnapshotToken) {
  let ok = true;
  const afterToken = changesTokenOverride || baselineSnapshotToken;
  if (!afterToken) {
    return false;
  }
  ok = timedGet(
    `${baseURL}/api/im/conversations/changes?afterToken=${encodeURIComponent(afterToken)}&limit=100`,
    state.token,
    'conversation changes'
  ) && ok;
  ok = timedGet(
    `${baseURL}/api/im/conversations/${conversationID}/timeline?limit=${timelineLimit}`,
    state.token,
    'timeline latest'
  ) && ok;
  ok = timedGet(
    `${baseURL}/api/im/conversations/${conversationID}/timeline/since?afterSequence=0&limit=${timelineLimit}`,
    state.token,
    'messages since'
  ) && ok;
  ok = timedGet(
    `${baseURL}/api/im/domain-events?after=${domainEventCursor}&limit=100`,
    state.token,
    'domain events'
  ) && ok;
  return ok;
}

export default function () {
  const startedAt = Date.now();
  const state = ensureState();
  const baselineSnapshotToken = fetchConversationList(state);
  let ok = baselineSnapshotToken !== null;
  ok = sendOfflineMessages(state) && ok;
  ok = catchUp(state, baselineSnapshotToken) && ok;
  catchupErrors.add(!ok);
  if (ok) {
    catchupOK.add(1);
  }
  totalLatency.add(Date.now() - startedAt);
  sleep(Math.max(0, sleepMillis) / 1000);
}
