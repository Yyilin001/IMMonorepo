import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'cold-start-smoke';
const profiles = {
  'cold-start-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_cold_start_errors: ['rate<0.001'],
      im_cold_start_list_latency: ['p(95)<1000', 'p(99)<2000'],
      im_cold_start_changes_latency: ['p(95)<1000', 'p(99)<2000'],
      im_cold_start_messages_since_latency: ['p(95)<1500', 'p(99)<3000'],
      im_cold_start_total_latency: ['p(95)<3000', 'p(99)<5000'],
    },
  },
  'cold-start-baseline': {
    vus: 200,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_cold_start_errors: ['rate<0.001'],
      im_cold_start_list_latency: ['p(95)<700', 'p(99)<1500'],
      im_cold_start_changes_latency: ['p(95)<700', 'p(99)<1500'],
      im_cold_start_messages_since_latency: ['p(95)<1200', 'p(99)<2500'],
      im_cold_start_total_latency: ['p(95)<2500', 'p(99)<5000'],
    },
  },
  'cold-start-capacity': {
    vus: 1000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_cold_start_errors: ['rate<0.005'],
      im_cold_start_list_latency: ['p(95)<1000', 'p(99)<2500'],
      im_cold_start_changes_latency: ['p(95)<1000', 'p(99)<2500'],
      im_cold_start_messages_since_latency: ['p(95)<2000', 'p(99)<5000'],
      im_cold_start_total_latency: ['p(95)<5000', 'p(99)<10000'],
    },
  },
};

export const options = profiles[profile] || profiles['cold-start-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const email = __ENV.IM_EMAIL || 'demo@example.com';
const password = __ENV.IM_PASSWORD || 'password1234';
const memberEmails = (__ENV.IM_MEMBER_EMAILS || 'alice@example.com')
  .split(',')
  .map((value) => value.trim())
  .filter((value) => value.length > 0);
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const conversationCount = Number.parseInt(__ENV.IM_COLD_START_CONVERSATION_COUNT || '3', 10);
const messagesPerConversation = Number.parseInt(__ENV.IM_COLD_START_MESSAGES_PER_CONVERSATION || '5', 10);
const sinceLimit = Number.parseInt(__ENV.IM_COLD_START_SINCE_LIMIT || '50', 10);
const sleepMillis = Number.parseInt(__ENV.IM_COLD_START_SLEEP_MS || '250', 10);

export const coldStartErrors = new Rate('im_cold_start_errors');
export const listLatency = new Trend('im_cold_start_list_latency');
export const changesLatency = new Trend('im_cold_start_changes_latency');
export const messagesSinceLatency = new Trend('im_cold_start_messages_since_latency');
export const totalLatency = new Trend('im_cold_start_total_latency');

function jsonHeaders(token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return { headers };
}

function login(deviceID) {
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
  check(res, { 'login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createConversation(token, index) {
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title: `k6-cold-start-${Date.now()}-${index}`,
      memberEmails,
    }),
    jsonHeaders(token)
  );
  check(res, { 'create cold-start conversation ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`create conversation failed: ${res.status} ${res.body}`);
  }
  return res.json('id');
}

function sendInternalMessage(senderUserID, conversationID, clientMessageID) {
  const res = http.post(
    `${baseURL}/internal/im/messages/send`,
    JSON.stringify({
      senderUserID,
      payload: {
        clientMessageID,
        messageID: null,
        conversationID,
        senderUserID: null,
        serverSequence: null,
        serverTimestamp: null,
        content: { type: 'text', text: `cold-start ${clientMessageID}` },
        derivedState: { reactions: [], editedAt: null, recalledAt: null },
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  check(res, { 'seed message accepted': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`seed message failed: ${res.status} ${res.body}`);
  }
}

export function setup() {
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for cold-start sync setup.');
  }

  const auth = login('k6-cold-start-setup');
  const existing = (__ENV.IM_CONVERSATION_IDS || '')
    .split(',')
    .map((value) => value.trim())
    .filter((value) => value.length > 0);
  const conversationIDs = existing.length > 0 ? existing : [];
  while (conversationIDs.length < Math.max(1, conversationCount)) {
    conversationIDs.push(createConversation(auth.accessToken, conversationIDs.length));
  }

  for (const conversationID of conversationIDs) {
    for (let messageIndex = 0; messageIndex < Math.max(1, messagesPerConversation); messageIndex += 1) {
      sendInternalMessage(
        auth.user.id,
        conversationID,
        `k6-cold-start-seed-${conversationID}-${messageIndex}-${Date.now()}`
      );
    }
  }

  return {
    token: auth.accessToken,
    conversationIDs,
  };
}

function timedGet(url, token, trend, checkName) {
  const startedAt = Date.now();
  const res = http.get(url, jsonHeaders(token));
  trend.add(Date.now() - startedAt);
  check(res, { [checkName]: (r) => r.status === 200 });
  return res;
}

export default function (data) {
  const startedAt = Date.now();
  let failed = false;

  const listRes = timedGet(`${baseURL}/api/im/conversations?limit=100`, data.token, listLatency, 'cold list ok');
  failed = failed || listRes.status !== 200;

  const changesRes = timedGet(
    `${baseURL}/api/im/conversations/changes?afterToken=1970-01-01T00:00:00.000Z:&limit=100`,
    data.token,
    changesLatency,
    'cold changes ok'
  );
  failed = failed || changesRes.status !== 200;

  for (const conversationID of data.conversationIDs) {
    const sinceRes = timedGet(
      `${baseURL}/api/im/conversations/${conversationID}/messages/since?afterSequence=0&limit=${sinceLimit}`,
      data.token,
      messagesSinceLatency,
      'cold messages since ok'
    );
    if (sinceRes.status !== 200) {
      failed = true;
      continue;
    }
    const body = sinceRes.json();
    const items = Array.isArray(body.items) ? body.items : [];
    if (items.length === 0) {
      failed = true;
    }
  }

  totalLatency.add(Date.now() - startedAt);
  coldStartErrors.add(failed);
  sleep(Math.max(0, sleepMillis) / 1000);
}
