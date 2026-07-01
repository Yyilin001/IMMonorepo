import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'governance-smoke';
const profiles = {
  'governance-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_governance_errors: ['rate<0.001'],
      im_governance_total_latency: ['p(95)<8000', 'p(99)<15000'],
      im_governance_create_latency: ['p(95)<1000', 'p(99)<2000'],
      im_governance_preferences_visible_latency: ['p(95)<2000', 'p(99)<5000'],
      im_governance_favorite_visible_latency: ['p(95)<2000', 'p(99)<5000'],
      im_governance_receipt_latency: ['p(95)<2000', 'p(99)<5000'],
      im_governance_recall_visible_latency: ['p(95)<3000', 'p(99)<7000'],
      im_governance_delete_visible_latency: ['p(95)<3000', 'p(99)<7000'],
    },
  },
  'governance-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_governance_errors: ['rate<0.001'],
      im_governance_total_latency: ['p(95)<10000', 'p(99)<20000'],
      im_governance_create_latency: ['p(95)<1500', 'p(99)<3000'],
      im_governance_preferences_visible_latency: ['p(95)<3000', 'p(99)<7000'],
      im_governance_favorite_visible_latency: ['p(95)<3000', 'p(99)<7000'],
      im_governance_receipt_latency: ['p(95)<3000', 'p(99)<7000'],
      im_governance_recall_visible_latency: ['p(95)<5000', 'p(99)<10000'],
      im_governance_delete_visible_latency: ['p(95)<5000', 'p(99)<10000'],
    },
  },
  'governance-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_governance_errors: ['rate<0.005'],
      im_governance_total_latency: ['p(95)<20000', 'p(99)<40000'],
      im_governance_create_latency: ['p(95)<3000', 'p(99)<7000'],
      im_governance_preferences_visible_latency: ['p(95)<7000', 'p(99)<15000'],
      im_governance_favorite_visible_latency: ['p(95)<7000', 'p(99)<15000'],
      im_governance_receipt_latency: ['p(95)<7000', 'p(99)<15000'],
      im_governance_recall_visible_latency: ['p(95)<10000', 'p(99)<20000'],
      im_governance_delete_visible_latency: ['p(95)<10000', 'p(99)<20000'],
    },
  },
};

export const options = profiles[profile] || profiles['governance-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const defaultPeerEmail = __ENV.IM_MEMBER_EMAILS ? __ENV.IM_MEMBER_EMAILS.split(',')[0].trim() : 'alice@example.com';
const defaultPeerPassword = __ENV.IM_PEER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_GOVERNANCE_TIMEOUT_MS || '15000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_GOVERNANCE_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_GOVERNANCE_SLEEP_MS || '250', 10);

export const governanceErrors = new Rate('im_governance_errors');
export const totalLatency = new Trend('im_governance_total_latency');
export const createLatency = new Trend('im_governance_create_latency');
export const seedTimelineLatency = new Trend('im_governance_seed_timeline_latency');
export const preferencesCommandLatency = new Trend('im_governance_preferences_command_latency');
export const preferencesVisibleLatency = new Trend('im_governance_preferences_visible_latency');
export const reactionCommandLatency = new Trend('im_governance_reaction_command_latency');
export const editCommandLatency = new Trend('im_governance_edit_command_latency');
export const favoriteCommandLatency = new Trend('im_governance_favorite_command_latency');
export const favoriteVisibleLatency = new Trend('im_governance_favorite_visible_latency');
export const receiptLatency = new Trend('im_governance_receipt_latency');
export const recallCommandLatency = new Trend('im_governance_recall_command_latency');
export const recallVisibleLatency = new Trend('im_governance_recall_visible_latency');
export const deleteVisibleLatency = new Trend('im_governance_delete_visible_latency');

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
  check(res, { 'governance login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function ensureAuthState() {
  if (authState) {
    return authState;
  }
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for governance sync checks.');
  }
  const pair = accountPairForVU();
  const ownerAuth = login(pair.owner, `k6-governance-owner-${__VU}`);
  const peerAuth = login(pair.peer, `k6-governance-peer-${__VU}`);
  authState = {
    ownerEmail: pair.owner.email,
    peerEmail: pair.peer.email,
    ownerToken: ownerAuth.accessToken,
    peerToken: peerAuth.accessToken,
    ownerUserID: ownerAuth.user.id,
  };
  return authState;
}

function timedPost(url, body, params, metric, label, expectedStatus = 200) {
  const startedAt = Date.now();
  const res = http.post(url, JSON.stringify(body), params);
  metric.add(Date.now() - startedAt);
  check(res, { [`${label} ok`]: (r) => r.status === expectedStatus });
  if (res.status !== expectedStatus) {
    return null;
  }
  return res;
}

function createConversation(state) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title: `k6-governance-${__VU}-${__ITER}-${Date.now()}`,
      memberEmails: [state.peerEmail],
    }),
    jsonHeaders(state.ownerToken)
  );
  createLatency.add(Date.now() - startedAt);
  check(res, { 'governance create conversation ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json('id') : null;
}

function listSummary(token, conversationID) {
  const res = http.get(`${baseURL}/api/im/conversations?limit=100`, jsonHeaders(token));
  if (res.status !== 200) {
    return null;
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  return items.find((item) => item.id === conversationID) || null;
}

function findTimelineMessage(token, conversationID, messageID, afterSequence) {
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
    if (message && message.id === messageID) {
      return message;
    }
  }
  return null;
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
        content: {
          type: 'rich_text',
          body: { text: `governance ${clientMessageID}`, entities: [] },
        },
        derivedState: { recallState: 'active', edits: [], reactions: [], streamState: null },
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  check(res, { 'governance seed message accepted': (r) => r.status === 200 });
  return res.status === 200 ? res.json('message') : null;
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

function favoritesContain(token, conversationID, messageID, expectedPresent) {
  const res = http.get(
    `${baseURL}/api/im/favorites?conversationID=${conversationID}&limit=100`,
    jsonHeaders(token)
  );
  if (res.status !== 200) {
    return false;
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  const present = items.some((item) => item.id === messageID);
  return expectedPresent ? present : !present;
}

function markRead(token, conversationID, readSequence) {
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/read`,
    JSON.stringify({ readSequence }),
    jsonHeaders(token)
  );
  return res.status === 200 ? res.json() : null;
}

function receiptCaughtUp(token, conversationID, sequence) {
  const res = http.get(
    `${baseURL}/api/im/conversations/${conversationID}/receipts/summary`,
    jsonHeaders(token)
  );
  if (res.status !== 200) {
    return false;
  }
  return Number(res.json('readThroughSequence') || 0) >= Number(sequence || 0);
}

function isRecalled(message) {
  return message
    && message.derivedState
    && message.derivedState.recallState === 'recalled';
}

export default function () {
  const state = ensureAuthState();
  const startedAt = Date.now();
  const deadline = startedAt + pollTimeoutMillis;

  const conversationID = createConversation(state);
  if (!conversationID) {
    governanceErrors.add(true);
    return;
  }

  const clientMessageID = `k6-governance-${__VU}-${__ITER}-${Date.now()}`;
  const message = sendInternalMessage(state.ownerUserID, conversationID, clientMessageID);
  if (!message || !message.id || !message.serverSequence) {
    governanceErrors.add(true);
    return;
  }

  const timelineStartedAt = Date.now();
  const initialTimelineMessage = pollUntil(
    deadline,
    () => findTimelineMessage(state.ownerToken, conversationID, message.id, Number(message.serverSequence) - 1)
  );
  if (!initialTimelineMessage) {
    governanceErrors.add(true);
    return;
  }
  seedTimelineLatency.add(Date.now() - timelineStartedAt);

  const preferencesStartedAt = Date.now();
  const preferencesRes = http.patch(
    `${baseURL}/api/im/conversations/${conversationID}/preferences`,
    JSON.stringify({ isPinned: true, isMuted: true }),
    jsonHeaders(state.ownerToken)
  );
  preferencesCommandLatency.add(Date.now() - preferencesStartedAt);
  check(preferencesRes, { 'governance preferences ok': (r) => r.status === 200 });
  if (preferencesRes.status !== 200) {
    governanceErrors.add(true);
    return;
  }
  const preferencesVisibleStartedAt = Date.now();
  const preferencesVisible = pollUntil(deadline, () => {
    const summary = listSummary(state.ownerToken, conversationID);
    return summary && summary.isPinned === true && summary.isMuted === true;
  });
  if (!preferencesVisible) {
    governanceErrors.add(true);
    return;
  }
  preferencesVisibleLatency.add(Date.now() - preferencesVisibleStartedAt);

  if (!timedPost(
    `${baseURL}/api/im/conversations/${conversationID}/messages/${message.id}/reactions`,
    { emoji: '+1' },
    jsonHeaders(state.ownerToken),
    reactionCommandLatency,
    'governance reaction'
  )) {
    governanceErrors.add(true);
    return;
  }

  if (!timedPost(
    `${baseURL}/api/im/conversations/${conversationID}/messages/${message.id}/edit`,
    { body: { text: `edited ${clientMessageID}`, entities: [] } },
    jsonHeaders(state.ownerToken),
    editCommandLatency,
    'governance edit'
  )) {
    governanceErrors.add(true);
    return;
  }

  if (!timedPost(
    `${baseURL}/api/im/conversations/${conversationID}/messages/${message.id}/favorite`,
    {},
    jsonHeaders(state.ownerToken),
    favoriteCommandLatency,
    'governance favorite'
  )) {
    governanceErrors.add(true);
    return;
  }
  const favoriteVisibleStartedAt = Date.now();
  if (!pollUntil(deadline, () => favoritesContain(state.ownerToken, conversationID, message.id, true))) {
    governanceErrors.add(true);
    return;
  }
  favoriteVisibleLatency.add(Date.now() - favoriteVisibleStartedAt);

  const receiptStartedAt = Date.now();
  const readResponse = markRead(state.peerToken, conversationID, message.serverSequence);
  if (!readResponse) {
    governanceErrors.add(true);
    return;
  }
  if (!pollUntil(deadline, () => receiptCaughtUp(state.ownerToken, conversationID, message.serverSequence))) {
    governanceErrors.add(true);
    return;
  }
  receiptLatency.add(Date.now() - receiptStartedAt);

  const unfavoriteRes = http.del(
    `${baseURL}/api/im/conversations/${conversationID}/messages/${message.id}/favorite`,
    null,
    jsonHeaders(state.ownerToken)
  );
  check(unfavoriteRes, { 'governance unfavorite ok': (r) => r.status === 200 });
  if (unfavoriteRes.status !== 200) {
    governanceErrors.add(true);
    return;
  }
  if (!pollUntil(deadline, () => favoritesContain(state.ownerToken, conversationID, message.id, false))) {
    governanceErrors.add(true);
    return;
  }

  const recallStartedAt = Date.now();
  const recallRes = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/messages/${message.id}/recall`,
    '{}',
    jsonHeaders(state.ownerToken)
  );
  recallCommandLatency.add(Date.now() - recallStartedAt);
  check(recallRes, { 'governance recall ok': (r) => r.status === 200 });
  if (recallRes.status !== 200) {
    governanceErrors.add(true);
    return;
  }
  const recallVisibleStartedAt = Date.now();
  const recalled = pollUntil(
    deadline,
    () => isRecalled(findTimelineMessage(state.ownerToken, conversationID, message.id, Number(message.serverSequence) - 1))
  );
  if (!recalled) {
    governanceErrors.add(true);
    return;
  }
  recallVisibleLatency.add(Date.now() - recallVisibleStartedAt);

  const deleteRes = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/messages/delete`,
    JSON.stringify({ messageIDs: [message.id] }),
    jsonHeaders(state.ownerToken)
  );
  check(deleteRes, { 'governance delete message ok': (r) => r.status === 200 });
  if (deleteRes.status !== 200) {
    governanceErrors.add(true);
    return;
  }

  const deleteVisibleStartedAt = Date.now();
  const hidden = pollUntil(
    deadline,
    () => findTimelineMessage(state.ownerToken, conversationID, message.id, Number(message.serverSequence) - 1) === null
  );
  if (!hidden) {
    governanceErrors.add(true);
    return;
  }
  deleteVisibleLatency.add(Date.now() - deleteVisibleStartedAt);

  const clearRes = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/clear`,
    '{}',
    jsonHeaders(state.ownerToken)
  );
  check(clearRes, { 'governance clear conversation ok': (r) => r.status === 200 });
  const deleteConversationRes = http.del(
    `${baseURL}/api/im/conversations/${conversationID}`,
    null,
    jsonHeaders(state.ownerToken)
  );
  check(deleteConversationRes, { 'governance delete conversation ok': (r) => r.status === 200 });
  if (clearRes.status !== 200 || deleteConversationRes.status !== 200) {
    governanceErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  governanceErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
