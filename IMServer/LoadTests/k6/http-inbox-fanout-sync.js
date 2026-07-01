import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'inbox-fanout-smoke';
const profiles = {
  'inbox-fanout-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_inbox_fanout_errors: ['rate<0.001'],
      im_inbox_fanout_write_latency: ['p(95)<1000', 'p(99)<2500'],
      im_inbox_fanout_list_latency: ['p(95)<1000', 'p(99)<2500'],
      im_inbox_fanout_changes_latency: ['p(95)<1500', 'p(99)<3500'],
      im_inbox_fanout_since_latency: ['p(95)<1500', 'p(99)<3500'],
      im_inbox_fanout_total_latency: ['p(95)<5000', 'p(99)<10000'],
    },
  },
  'inbox-fanout-baseline': {
    vus: 200,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_inbox_fanout_errors: ['rate<0.002'],
      im_inbox_fanout_write_latency: ['p(95)<1500', 'p(99)<3500'],
      im_inbox_fanout_list_latency: ['p(95)<1500', 'p(99)<3500'],
      im_inbox_fanout_changes_latency: ['p(95)<2500', 'p(99)<6000'],
      im_inbox_fanout_since_latency: ['p(95)<2500', 'p(99)<6000'],
      im_inbox_fanout_total_latency: ['p(95)<8000', 'p(99)<16000'],
    },
  },
  'inbox-fanout-capacity': {
    vus: 1000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_inbox_fanout_errors: ['rate<0.005'],
      im_inbox_fanout_write_latency: ['p(95)<3000', 'p(99)<7000'],
      im_inbox_fanout_list_latency: ['p(95)<3000', 'p(99)<7000'],
      im_inbox_fanout_changes_latency: ['p(95)<5000', 'p(99)<12000'],
      im_inbox_fanout_since_latency: ['p(95)<5000', 'p(99)<12000'],
      im_inbox_fanout_total_latency: ['p(95)<15000', 'p(99)<30000'],
    },
  },
};

export const options = profiles[profile] || profiles['inbox-fanout-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const email = __ENV.IM_EMAIL || 'demo@example.com';
const password = __ENV.IM_PASSWORD || 'password1234';
const memberEmails = (__ENV.IM_MEMBER_EMAILS || 'alice@example.com')
  .split(',')
  .map((value) => value.trim())
  .filter((value) => value.length > 0);
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const conversationCount = Math.max(1, Number.parseInt(__ENV.IM_INBOX_CONVERSATION_COUNT || '20', 10));
const writesPerIteration = Math.max(1, Number.parseInt(__ENV.IM_INBOX_WRITES_PER_ITERATION || '3', 10));
const readSampleSize = Math.max(1, Number.parseInt(__ENV.IM_INBOX_READ_SAMPLE_SIZE || '5', 10));
const listLimit = Math.max(1, Number.parseInt(__ENV.IM_INBOX_LIST_LIMIT || '100', 10));
const sinceLimit = Math.max(1, Number.parseInt(__ENV.IM_INBOX_SINCE_LIMIT || '20', 10));
const changesToken = __ENV.IM_INBOX_CHANGES_AFTER_TOKEN || '1970-01-01T00:00:00.000Z:';
const sleepMillis = Number.parseInt(__ENV.IM_INBOX_SLEEP_MS || '250', 10);

export const inboxErrors = new Rate('im_inbox_fanout_errors');
export const writeLatency = new Trend('im_inbox_fanout_write_latency');
export const listLatency = new Trend('im_inbox_fanout_list_latency');
export const changesLatency = new Trend('im_inbox_fanout_changes_latency');
export const sinceLatency = new Trend('im_inbox_fanout_since_latency');
export const totalLatency = new Trend('im_inbox_fanout_total_latency');

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
  check(res, { 'inbox login ok': (r) => r.status === 200 });
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
      title: `k6-inbox-${Date.now()}-${index}`,
      memberEmails,
    }),
    jsonHeaders(token)
  );
  check(res, { 'inbox create conversation ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`create conversation failed: ${res.status} ${res.body}`);
  }
  return res.json('id');
}

function sendInternalMessage(senderUserID, conversationID, clientMessageID) {
  const startedAt = Date.now();
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
        content: { type: 'text', text: `inbox ${clientMessageID}` },
        derivedState: { reactions: [], editedAt: null, recalledAt: null },
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  writeLatency.add(Date.now() - startedAt);
  check(res, { 'inbox message accepted': (r) => r.status === 200 });
  return res.status === 200;
}

export function setup() {
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for inbox fanout sync.');
  }
  const auth = login('k6-inbox-setup');
  const existing = (__ENV.IM_CONVERSATION_IDS || '')
    .split(',')
    .map((value) => value.trim())
    .filter((value) => value.length > 0);
  const conversationIDs = existing.length > 0 ? existing : [];
  while (conversationIDs.length < conversationCount) {
    conversationIDs.push(createConversation(auth.accessToken, conversationIDs.length));
  }
  return {
    token: auth.accessToken,
    senderUserID: auth.user.id,
    conversationIDs,
  };
}

function timedGet(url, token, trend, label) {
  const startedAt = Date.now();
  const res = http.get(url, jsonHeaders(token));
  trend.add(Date.now() - startedAt);
  check(res, { [`${label} ok`]: (r) => r.status === 200 });
  return res;
}

function listContainsAnyUpdatedConversation(res, conversationIDs) {
  if (res.status !== 200) {
    return false;
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  const visibleIDs = new Set(items.map((item) => item.id));
  return conversationIDs.some((conversationID) => visibleIDs.has(conversationID));
}

function sinceContainsMessage(res, clientMessageID) {
  if (res.status !== 200) {
    return false;
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  return items.some((item) => item.message && item.message.clientMessageID === clientMessageID);
}

export default function (data) {
  const startedAt = Date.now();
  const conversationIDs = data.conversationIDs;
  const written = [];
  let failed = false;

  for (let index = 0; index < writesPerIteration; index += 1) {
    const conversationIndex = ((__VU - 1) + __ITER + index) % conversationIDs.length;
    const conversationID = conversationIDs[conversationIndex];
    const clientMessageID = `k6-inbox-${__VU}-${__ITER}-${index}-${Date.now()}`;
    if (sendInternalMessage(data.senderUserID, conversationID, clientMessageID)) {
      written.push({ conversationID, clientMessageID });
    } else {
      failed = true;
    }
  }

  const listRes = timedGet(`${baseURL}/api/im/conversations?limit=${listLimit}`, data.token, listLatency, 'inbox list');
  failed = !listContainsAnyUpdatedConversation(listRes, written.map((item) => item.conversationID)) || failed;

  const changesRes = timedGet(
    `${baseURL}/api/im/conversations/changes?afterToken=${encodeURIComponent(changesToken)}&limit=${listLimit}`,
    data.token,
    changesLatency,
    'inbox changes'
  );
  failed = changesRes.status !== 200 || failed;

  const reads = Math.min(readSampleSize, written.length);
  for (let index = 0; index < reads; index += 1) {
    const item = written[index];
    const sinceRes = timedGet(
      `${baseURL}/api/im/conversations/${item.conversationID}/messages/since?afterSequence=0&limit=${sinceLimit}`,
      data.token,
      sinceLatency,
      'inbox messages since'
    );
    failed = !sinceContainsMessage(sinceRes, item.clientMessageID) || failed;
  }

  totalLatency.add(Date.now() - startedAt);
  inboxErrors.add(failed);
  sleep(Math.max(0, sleepMillis) / 1000);
}
