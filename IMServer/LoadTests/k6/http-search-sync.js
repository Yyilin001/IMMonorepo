import http from 'k6/http';
import { richTextContent, initialDerivedState } from './im-message-payload.js';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'search-sync-smoke';
const profiles = {
  'search-sync-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_search_sync_errors: ['rate<0.001'],
      im_search_sync_accept_latency: ['p(95)<500', 'p(99)<1000'],
      im_search_sync_query_latency: ['p(95)<1000', 'p(99)<2000'],
      im_search_sync_visible_latency: ['p(95)<5000', 'p(99)<10000'],
    },
  },
  'search-sync-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_search_sync_errors: ['rate<0.001'],
      im_search_sync_accept_latency: ['p(95)<500', 'p(99)<1000'],
      im_search_sync_query_latency: ['p(95)<1000', 'p(99)<2500'],
      im_search_sync_visible_latency: ['p(95)<10000', 'p(99)<20000'],
    },
  },
  'search-sync-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_search_sync_errors: ['rate<0.005'],
      im_search_sync_accept_latency: ['p(95)<1000', 'p(99)<2500'],
      im_search_sync_query_latency: ['p(95)<2000', 'p(99)<5000'],
      im_search_sync_visible_latency: ['p(95)<20000', 'p(99)<60000'],
    },
  },
};

export const options = profiles[profile] || profiles['search-sync-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const commandBaseURL = (__ENV.IM_COMMAND_BASE_URL || baseURL).replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const memberEmails = (__ENV.IM_MEMBER_EMAILS || 'alice@example.com')
  .split(',')
  .map((value) => value.trim())
  .filter((value) => value.length > 0);
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_SEARCH_SYNC_TIMEOUT_MS || '30000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_SEARCH_SYNC_POLL_INTERVAL_MS || '500', 10);
const sleepMillis = Number.parseInt(__ENV.IM_SEARCH_SYNC_SLEEP_MS || '250', 10);

export const searchSyncErrors = new Rate('im_search_sync_errors');
export const acceptLatency = new Trend('im_search_sync_accept_latency');
export const queryLatency = new Trend('im_search_sync_query_latency');
export const visibleLatency = new Trend('im_search_sync_visible_latency');

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
let perVUState = null;

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

function login(account) {
  const res = http.post(
    `${baseURL}/api/auth/login`,
    JSON.stringify({
      email: account.email,
      password: account.password,
      device: {
        deviceID: `k6-search-${__VU}`,
        deviceName: 'k6-search',
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'search login ok': (r) => r.status === 200 });
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
      title: `k6-search-${__VU}-${Date.now()}`,
      memberEmails,
    }),
    jsonHeaders(token)
  );
  check(res, { 'search create conversation ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`create conversation failed: ${res.status} ${res.body}`);
  }
  return res.json('id');
}

function ensureState() {
  if (perVUState) {
    return perVUState;
  }
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for search sync checks.');
  }
  const auth = login(accountForVU());
  perVUState = {
    token: auth.accessToken,
    userID: auth.user.id,
    conversationID: createConversation(auth.accessToken),
  };
  return perVUState;
}

function sendInternalMessage(senderUserID, conversationID, clientMessageID, searchTerm) {
  const startedAt = Date.now();
  const res = http.post(
    `${commandBaseURL}/internal/im/messages/send`,
    JSON.stringify({
      senderUserID,
      payload: {
        clientMessageID,
        messageID: null,
        conversationID,
        senderUserID: null,
        serverSequence: null,
        serverTimestamp: null,
        content: richTextContent(`search-sync ${searchTerm}`),
        derivedState: initialDerivedState(),
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  acceptLatency.add(Date.now() - startedAt);
  check(res, { 'search seed message accepted': (r) => r.status === 200 });
  if (res.status !== 200) {
    return null;
  }
  return res.json('message');
}

function searchOnce(token, conversationID, query, serverSequence) {
  const startedAt = Date.now();
  const res = http.get(
    `${baseURL}/api/im/conversations/${conversationID}/search?q=${encodeURIComponent(query)}&limit=20`,
    jsonHeaders(token)
  );
  queryLatency.add(Date.now() - startedAt);
  if (res.status !== 200) {
    return false;
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  return items.some((item) => (
    Number(item.serverSequence || 0) === Number(serverSequence || 0)
    || String(item.snippet || '').includes(query)
    || JSON.stringify(item.content || {}).includes(query)
  ));
}

function pollUntil(deadline, action) {
  while (Date.now() < deadline) {
    const value = action();
    if (value) {
      return true;
    }
    sleep(Math.max(0.05, pollIntervalMillis / 1000));
  }
  return false;
}

export default function () {
  const state = ensureState();
  const startedAt = Date.now();
  const searchTerm = `term-${__VU}-${__ITER}-${Date.now()}`;
  const clientMessageID = `k6-search-${searchTerm}`;
  const message = sendInternalMessage(state.userID, state.conversationID, clientMessageID, searchTerm);
  if (!message || !message.serverSequence) {
    searchSyncErrors.add(true);
    return;
  }

  const visible = pollUntil(
    startedAt + pollTimeoutMillis,
    () => searchOnce(state.token, state.conversationID, searchTerm, message.serverSequence)
  );
  if (!visible) {
    searchSyncErrors.add(true);
    return;
  }

  visibleLatency.add(Date.now() - startedAt);
  searchSyncErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
