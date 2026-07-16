import http from 'k6/http';
import { richTextContent, initialDerivedState } from './im-message-payload.js';
import { check, fail, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'user-journey-smoke';
const profiles = {
  'user-journey-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_user_journey_errors: ['rate<0.001'],
      im_user_journey_total_latency: ['p(95)<3500', 'p(99)<7000'],
      im_user_journey_read_latency: ['p(95)<1000', 'p(99)<2500'],
      im_user_journey_write_latency: ['p(95)<800', 'p(99)<2000'],
      im_user_journey_health_latency: ['p(95)<600', 'p(99)<1500'],
    },
  },
  'user-journey-baseline': {
    vus: 300,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_user_journey_errors: ['rate<0.002'],
      im_user_journey_total_latency: ['p(95)<5000', 'p(99)<10000'],
      im_user_journey_read_latency: ['p(95)<1500', 'p(99)<3500'],
      im_user_journey_write_latency: ['p(95)<1000', 'p(99)<2500'],
      im_user_journey_health_latency: ['p(95)<1000', 'p(99)<2500'],
    },
  },
  'user-journey-capacity': {
    vus: 1000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_user_journey_errors: ['rate<0.005'],
      im_user_journey_total_latency: ['p(95)<9000', 'p(99)<18000'],
      im_user_journey_read_latency: ['p(95)<3000', 'p(99)<7000'],
      im_user_journey_write_latency: ['p(95)<2000', 'p(99)<5000'],
      im_user_journey_health_latency: ['p(95)<2000', 'p(99)<5000'],
    },
  },
};

export const options = profiles[profile] || profiles['user-journey-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
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
const changesToken = __ENV.IM_USER_JOURNEY_AFTER_TOKEN || '1970-01-01T00:00:00.000Z:';
const domainEventCursor = Number.parseInt(__ENV.IM_USER_JOURNEY_DOMAIN_CURSOR || '0', 10);
const sleepMillis = Number.parseInt(__ENV.IM_USER_JOURNEY_SLEEP_MS || '300', 10);
const writeEvery = Math.max(0, Number.parseInt(__ENV.IM_USER_JOURNEY_WRITE_EVERY || '10', 10));
const timelineLimit = Number.parseInt(__ENV.IM_USER_JOURNEY_TIMELINE_LIMIT || '30', 10);

export const journeyErrors = new Rate('im_user_journey_errors');
export const totalLatency = new Trend('im_user_journey_total_latency');
export const readLatency = new Trend('im_user_journey_read_latency');
export const writeLatency = new Trend('im_user_journey_write_latency');
export const healthLatency = new Trend('im_user_journey_health_latency');
export const journeyOK = new Counter('im_user_journey_ok_total');

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
  const deviceID = `k6-user-journey-${__VU}`;
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
  check(res, { 'user journey login ok': (r) => r.status === 200 });
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

function postHealth(token) {
  const startedAt = Date.now();
  const seed = (__VU * 1000000) + __ITER;
  const res = http.post(
    `${baseURL}/api/im/client-health`,
    JSON.stringify({
      snapshot: {
        domainEventCursor: seed,
        deferredDomainEventCount: seed % 5,
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
      reason: 'user-journey',
      reportedAt: new Date().toISOString(),
    }),
    jsonHeaders(token)
  );
  healthLatency.add(Date.now() - startedAt);
  check(res, { 'user journey health ok': (r) => r.status === 204 });
  return res.status === 204;
}

function maybeSendMessage(auth, token) {
  if (!conversationID || !internalSecret || writeEvery <= 0 || (__ITER % writeEvery) !== 0) {
    return true;
  }
  const startedAt = Date.now();
  const clientMessageID = `k6-user-journey-${__VU}-${__ITER}-${Date.now()}`;
  const res = http.post(
    `${baseURL}/internal/im/messages/send`,
    JSON.stringify({
      senderUserID: auth.user.id,
      payload: {
        clientMessageID,
        messageID: null,
        conversationID,
        senderUserID: null,
        serverSequence: null,
        serverTimestamp: null,
        content: richTextContent(`journey ${clientMessageID}`),
        derivedState: initialDerivedState(),
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  writeLatency.add(Date.now() - startedAt);
  check(res, { 'user journey write ok': (r) => r.status === 200 });
  return res.status === 200;
}

export default function () {
  const startedAt = Date.now();
  const auth = login();
  const token = auth.accessToken;
  let ok = true;

  ok = timedGet(`${baseURL}/api/me`, token, 'me') && ok;
  ok = timedGet(`${baseURL}/api/im/conversations?limit=50`, token, 'conversation list') && ok;
  ok = timedGet(
    `${baseURL}/api/im/conversations/changes?afterToken=${encodeURIComponent(changesToken)}&limit=50`,
    token,
    'conversation changes'
  ) && ok;
  ok = timedGet(`${baseURL}/api/contacts`, token, 'contacts') && ok;
  ok = timedGet(`${baseURL}/api/contacts/changes?limit=50`, token, 'contact changes') && ok;
  ok = timedGet(`${baseURL}/api/im/domain-events?after=${domainEventCursor}&limit=50`, token, 'domain events') && ok;

  if (conversationID) {
    ok = timedGet(
      `${baseURL}/api/im/conversations/${conversationID}/timeline?limit=${timelineLimit}`,
      token,
      'timeline latest'
    ) && ok;
    ok = timedGet(
      `${baseURL}/api/im/conversations/${conversationID}/messages/since?afterSequence=0&limit=${timelineLimit}`,
      token,
      'messages since'
    ) && ok;
  }

  ok = maybeSendMessage(auth, token) && ok;
  ok = postHealth(token) && ok;

  journeyErrors.add(!ok);
  if (ok) {
    journeyOK.add(1);
  }
  totalLatency.add(Date.now() - startedAt);
  sleep(Math.max(0, sleepMillis) / 1000);
}
