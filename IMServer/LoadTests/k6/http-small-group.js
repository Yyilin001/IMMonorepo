import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'local-smoke';
const profiles = {
  'local-smoke': {
    vus: 100,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.001'],
      http_req_duration: ['p(95)<500', 'p(99)<1000'],
    },
  },
  'staging-baseline': {
    vus: 10000,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.001'],
      http_req_duration: ['p(95)<300', 'p(99)<800'],
    },
  },
  'capacity-target': {
    vus: 50000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.001'],
      http_req_duration: ['p(95)<150', 'p(99)<300'],
    },
  },
};

export const options = profiles[profile] || profiles['local-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const email = __ENV.IM_EMAIL || 'demo@example.com';
const password = __ENV.IM_PASSWORD || 'password1234';
const memberEmails = (__ENV.IM_MEMBER_EMAILS || 'alice@example.com')
  .split(',')
  .map((value) => value.trim())
  .filter((value) => value.length > 0);
const internalSecret = __ENV.IM_INTERNAL_SECRET || '';

export const smallGroupErrors = new Rate('im_small_group_errors');
export const changesLatency = new Trend('im_changes_latency');

function jsonHeaders(token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return { headers };
}

function login() {
  const res = http.post(
    `${baseURL}/api/auth/login`,
    JSON.stringify({
      email,
      password,
      device: {
        deviceID: `k6-${__VU}`,
        deviceName: 'k6',
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'login ok': (r) => r.status === 200 });
  smallGroupErrors.add(res.status !== 200);
  return res.json();
}

function createConversation(token) {
  if (__ENV.IM_CONVERSATION_ID) {
    return __ENV.IM_CONVERSATION_ID;
  }
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title: `k6-small-group-${__VU}`,
      memberEmails,
    }),
    jsonHeaders(token)
  );
  check(res, { 'create conversation ok': (r) => r.status === 200 });
  smallGroupErrors.add(res.status !== 200);
  return res.json('id');
}

function sendInternalMessage(userID, conversationID) {
  if (!internalSecret) {
    return;
  }
  const res = http.post(
    `${baseURL}/internal/im/messages/send`,
    JSON.stringify({
      senderUserID: userID,
      payload: {
        clientMessageID: `k6-${__VU}-${__ITER}`,
        messageID: null,
        conversationID,
        senderUserID: null,
        serverSequence: null,
        serverTimestamp: null,
        content: { type: 'text', text: `hello ${__VU}/${__ITER}` },
        derivedState: { reactions: [], editedAt: null, recalledAt: null },
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  check(res, { 'internal send accepted': (r) => r.status === 200 });
  smallGroupErrors.add(res.status !== 200);
}

export default function () {
  const auth = login();
  const token = auth.accessToken;
  const userID = auth.user.id;
  const conversationID = createConversation(token);

  sendInternalMessage(userID, conversationID);

  const listRes = http.get(`${baseURL}/api/im/conversations?limit=30`, jsonHeaders(token));
  check(listRes, { 'list conversations ok': (r) => r.status === 200 });
  smallGroupErrors.add(listRes.status !== 200);

  const changesStarted = Date.now();
  const changesRes = http.get(
    `${baseURL}/api/im/conversations/changes?afterToken=1970-01-01T00:00:00.000Z:`,
    jsonHeaders(token)
  );
  changesLatency.add(Date.now() - changesStarted);
  check(changesRes, { 'changes ok': (r) => r.status === 200 || r.status === 400 });

  const sinceRes = http.get(
    `${baseURL}/api/im/conversations/${conversationID}/messages/since?afterSequence=0&limit=50`,
    jsonHeaders(token)
  );
  check(sinceRes, { 'messages since ok': (r) => r.status === 200 });
  smallGroupErrors.add(sinceRes.status !== 200);

  sleep(profile === 'local-smoke' ? 1 : 0.1);
}
