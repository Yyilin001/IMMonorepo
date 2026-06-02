import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'local-convergence-smoke';
const profiles = {
  'local-convergence-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_message_convergence_errors: ['rate<0.001'],
      im_message_accept_latency: ['p(95)<500', 'p(99)<1000'],
      im_message_timeline_latency: ['p(95)<1500', 'p(99)<3000'],
      im_message_summary_latency: ['p(95)<3000', 'p(99)<5000'],
    },
  },
  'staging-convergence-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_message_convergence_errors: ['rate<0.001'],
      im_message_accept_latency: ['p(95)<300', 'p(99)<800'],
      im_message_timeline_latency: ['p(95)<2000', 'p(99)<5000'],
      im_message_summary_latency: ['p(95)<5000', 'p(99)<10000'],
    },
  },
};

export const options = profiles[profile] || profiles['local-convergence-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const email = __ENV.IM_EMAIL || 'demo@example.com';
const password = __ENV.IM_PASSWORD || 'password1234';
const memberEmails = (__ENV.IM_MEMBER_EMAILS || 'alice@example.com')
  .split(',')
  .map((value) => value.trim())
  .filter((value) => value.length > 0);
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_CONVERGENCE_TIMEOUT_MS || '10000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_CONVERGENCE_POLL_INTERVAL_MS || '250', 10);

export const convergenceErrors = new Rate('im_message_convergence_errors');
export const acceptLatency = new Trend('im_message_accept_latency');
export const timelineLatency = new Trend('im_message_timeline_latency');
export const summaryLatency = new Trend('im_message_summary_latency');

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
      deviceID: 'k6-message-convergence',
      deviceName: 'k6-message-convergence',
      platform: 'load-test',
    }),
    jsonHeaders()
  );
  check(res, { 'login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed: ${res.status} ${res.body}`);
  }
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
      title: `k6-message-convergence-${Date.now()}`,
      memberEmails,
    }),
    jsonHeaders(token)
  );
  check(res, { 'create convergence conversation ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`create conversation failed: ${res.status} ${res.body}`);
  }
  return res.json('id');
}

export function setup() {
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for message convergence checks.');
  }

  const auth = login();
  return {
    token: auth.accessToken,
    senderUserID: auth.user.id,
    conversationID: createConversation(auth.accessToken),
  };
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
        content: { type: 'text', text: `convergence ${clientMessageID}` },
        derivedState: { reactions: [], editedAt: null, recalledAt: null },
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );

  acceptLatency.add(Date.now() - startedAt);
  check(res, { 'message accepted': (r) => r.status === 200 });
  return res.status === 200;
}

function latestSummarySequence(token, conversationID) {
  const res = http.get(`${baseURL}/api/im/conversations?limit=100`, jsonHeaders(token));
  if (res.status !== 200) {
    return 0;
  }

  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  const summary = items.find((item) => item.id === conversationID);
  return Number(summary && summary.lastMessage ? summary.lastMessage.serverSequence || 0 : 0);
}

function findTimelineMessage(token, conversationID, clientMessageID, afterSequence) {
  const res = http.get(
    `${baseURL}/api/im/conversations/${conversationID}/messages/since?afterSequence=${afterSequence}&limit=100`,
    jsonHeaders(token)
  );
  if (res.status !== 200) {
    return null;
  }

  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  for (const item of items) {
    const message = item.message;
    if (message && message.clientMessageID === clientMessageID) {
      return message;
    }
  }
  return null;
}

function summaryHasMessage(token, conversationID, serverSequence) {
  const res = http.get(`${baseURL}/api/im/conversations?limit=100`, jsonHeaders(token));
  if (res.status !== 200) {
    return false;
  }

  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  return items.some((item) => (
    item.id === conversationID
    && item.lastMessage
    && Number(item.lastMessage.serverSequence || 0) >= Number(serverSequence || 0)
  ));
}

function pollUntil(deadline, action) {
  while (Date.now() < deadline) {
    const value = action();
    if (value) {
      return value;
    }
    sleep(Math.max(0.05, pollIntervalMillis / 1000));
  }
  return null;
}

export default function (data) {
  const clientMessageID = `k6-convergence-${__VU}-${__ITER}-${Date.now()}`;
  const startedAt = Date.now();
  const previousSequence = latestSummarySequence(data.token, data.conversationID);

  if (!sendInternalMessage(data.senderUserID, data.conversationID, clientMessageID)) {
    convergenceErrors.add(true);
    return;
  }

  const deadline = startedAt + pollTimeoutMillis;
  const message = pollUntil(
    deadline,
    () => findTimelineMessage(data.token, data.conversationID, clientMessageID, previousSequence)
  );
  if (!message) {
    convergenceErrors.add(true);
    return;
  }
  timelineLatency.add(Date.now() - startedAt);

  const summaryVisible = pollUntil(
    deadline,
    () => summaryHasMessage(data.token, data.conversationID, message.serverSequence)
  );
  if (!summaryVisible) {
    convergenceErrors.add(true);
    return;
  }
  summaryLatency.add(Date.now() - startedAt);
  convergenceErrors.add(false);
}
