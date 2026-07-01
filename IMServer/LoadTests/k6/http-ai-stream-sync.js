import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'ai-stream-smoke';
const profiles = {
  'ai-stream-smoke': {
    vus: 5,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_ai_stream_errors: ['rate<0.001'],
      im_ai_stream_create_latency: ['p(95)<1000', 'p(99)<2500'],
      im_ai_stream_start_latency: ['p(95)<1500', 'p(99)<3000'],
      im_ai_stream_complete_visible_latency: ['p(95)<5000', 'p(99)<10000'],
      im_ai_stream_cancel_latency: ['p(95)<2000', 'p(99)<5000'],
      im_ai_stream_total_latency: ['p(95)<8000', 'p(99)<15000'],
    },
  },
  'ai-stream-baseline': {
    vus: 50,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_ai_stream_errors: ['rate<0.001'],
      im_ai_stream_create_latency: ['p(95)<1500', 'p(99)<3000'],
      im_ai_stream_start_latency: ['p(95)<2500', 'p(99)<5000'],
      im_ai_stream_complete_visible_latency: ['p(95)<8000', 'p(99)<15000'],
      im_ai_stream_cancel_latency: ['p(95)<3000', 'p(99)<7000'],
      im_ai_stream_total_latency: ['p(95)<15000', 'p(99)<30000'],
    },
  },
  'ai-stream-capacity': {
    vus: 200,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_ai_stream_errors: ['rate<0.005'],
      im_ai_stream_create_latency: ['p(95)<3000', 'p(99)<7000'],
      im_ai_stream_start_latency: ['p(95)<5000', 'p(99)<10000'],
      im_ai_stream_complete_visible_latency: ['p(95)<15000', 'p(99)<30000'],
      im_ai_stream_cancel_latency: ['p(95)<7000', 'p(99)<15000'],
      im_ai_stream_total_latency: ['p(95)<30000', 'p(99)<60000'],
    },
  },
};

export const options = profiles[profile] || profiles['ai-stream-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const defaultPeerEmail = __ENV.IM_MEMBER_EMAILS ? __ENV.IM_MEMBER_EMAILS.split(',')[0].trim() : 'alice@example.com';
const defaultPeerPassword = __ENV.IM_PEER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_AI_STREAM_TIMEOUT_MS || '15000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_AI_STREAM_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_AI_STREAM_SLEEP_MS || '250', 10);

export const aiStreamErrors = new Rate('im_ai_stream_errors');
export const createLatency = new Trend('im_ai_stream_create_latency');
export const startLatency = new Trend('im_ai_stream_start_latency');
export const completeVisibleLatency = new Trend('im_ai_stream_complete_visible_latency');
export const snapshotLatency = new Trend('im_ai_stream_snapshot_latency');
export const cancelLatency = new Trend('im_ai_stream_cancel_latency');
export const totalLatency = new Trend('im_ai_stream_total_latency');

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

function accountPairForVU() {
  if (csvAccounts.length >= 2) {
    const ownerIndex = (((__VU - 1) * 2) % csvAccounts.length);
    return {
      owner: csvAccounts[ownerIndex],
      peer: csvAccounts[(ownerIndex + 1) % csvAccounts.length],
    };
  }
  return {
    owner: { email: defaultOwnerEmail, password: defaultOwnerPassword },
    peer: { email: defaultPeerEmail, password: defaultPeerPassword },
  };
}

function jsonHeaders(token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return { headers };
}

function login(account, role) {
  const res = http.post(
    `${baseURL}/api/auth/login`,
    JSON.stringify({
      email: account.email,
      password: account.password,
      device: {
        deviceID: `k6-ai-stream-${role}-${__VU}`,
        deviceName: `k6-ai-stream-${role}`,
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'ai stream login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function ensureAuthState() {
  if (authState) {
    return authState;
  }
  const pair = accountPairForVU();
  const ownerAuth = login(pair.owner, 'owner');
  login(pair.peer, 'peer');
  authState = {
    ownerEmail: pair.owner.email,
    peerEmail: pair.peer.email,
    ownerToken: ownerAuth.accessToken,
  };
  return authState;
}

function createConversation(state) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title: `k6-ai-stream-${__VU}-${__ITER}-${Date.now()}`,
      memberEmails: [state.peerEmail],
    }),
    jsonHeaders(state.ownerToken)
  );
  createLatency.add(Date.now() - startedAt);
  check(res, { 'ai stream create conversation ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json('id') : null;
}

function startStream(token, conversationID, prompt) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/ai/messages`,
    JSON.stringify({ prompt }),
    jsonHeaders(token)
  );
  startLatency.add(Date.now() - startedAt);
  check(res, { 'ai stream start ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function streamState(response) {
  if (!response || !response.stream) {
    return null;
  }
  return response.stream.state || null;
}

function streamMessageID(response) {
  return response && response.message ? response.message.id : null;
}

function snapshot(token, conversationID, messageID) {
  const startedAt = Date.now();
  const res = http.get(
    `${baseURL}/api/im/conversations/${conversationID}/messages/${messageID}/stream`,
    jsonHeaders(token)
  );
  snapshotLatency.add(Date.now() - startedAt);
  return res.status === 200 ? res.json() : null;
}

function waitForCompleted(token, conversationID, messageID) {
  const startedAt = Date.now();
  const deadline = startedAt + pollTimeoutMillis;
  while (Date.now() <= deadline) {
    const response = snapshot(token, conversationID, messageID);
    const state = streamState(response);
    if (state === 'completed') {
      completeVisibleLatency.add(Date.now() - startedAt);
      return true;
    }
    if (state === 'failed' || state === 'cancelled') {
      completeVisibleLatency.add(Date.now() - startedAt);
      return false;
    }
    sleep(Math.max(1, pollIntervalMillis) / 1000);
  }
  completeVisibleLatency.add(Date.now() - startedAt);
  return false;
}

function cancelStream(token, conversationID, messageID) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/messages/${messageID}/stream/cancel`,
    null,
    { headers: { Authorization: `Bearer ${token}` } }
  );
  cancelLatency.add(Date.now() - startedAt);
  check(res, { 'ai stream cancel ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    return false;
  }
  const response = res.json();
  const state = streamState(response);
  return state === 'cancelled' || state === 'completed';
}

export default function () {
  const state = ensureAuthState();
  const startedAt = Date.now();
  const conversationID = createConversation(state);
  if (!conversationID) {
    aiStreamErrors.add(true);
    return;
  }

  const completeStream = startStream(
    state.ownerToken,
    conversationID,
    `summarize load-test iteration ${__VU}-${__ITER}`
  );
  const completeMessageID = streamMessageID(completeStream);
  if (!completeMessageID || !waitForCompleted(state.ownerToken, conversationID, completeMessageID)) {
    aiStreamErrors.add(true);
    return;
  }

  const cancellableStream = startStream(
    state.ownerToken,
    conversationID,
    `cancel load-test iteration ${__VU}-${__ITER}`
  );
  const cancellableMessageID = streamMessageID(cancellableStream);
  if (!cancellableMessageID || !cancelStream(state.ownerToken, conversationID, cancellableMessageID)) {
    aiStreamErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  aiStreamErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
