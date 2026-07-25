import http from 'k6/http';
import { richTextContent, initialDerivedState } from './im-message-payload.js';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'conversation-visibility-smoke';
const profiles = {
  'conversation-visibility-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_conversation_visibility_errors: ['rate<0.001'],
      im_conversation_visibility_seed_latency: ['p(95)<1000', 'p(99)<2000'],
      im_conversation_visibility_clear_latency: ['p(95)<1000', 'p(99)<2500'],
      im_conversation_visibility_hidden_latency: ['p(95)<2000', 'p(99)<5000'],
      im_conversation_visibility_new_message_latency: ['p(95)<2000', 'p(99)<5000'],
      im_conversation_visibility_delete_latency: ['p(95)<1000', 'p(99)<2500'],
      im_conversation_visibility_removed_latency: ['p(95)<3000', 'p(99)<7000'],
      im_conversation_visibility_total_latency: ['p(95)<8000', 'p(99)<15000'],
    },
  },
  'conversation-visibility-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_conversation_visibility_errors: ['rate<0.001'],
      im_conversation_visibility_seed_latency: ['p(95)<1500', 'p(99)<3000'],
      im_conversation_visibility_clear_latency: ['p(95)<1500', 'p(99)<3000'],
      im_conversation_visibility_hidden_latency: ['p(95)<3000', 'p(99)<7000'],
      im_conversation_visibility_new_message_latency: ['p(95)<3000', 'p(99)<7000'],
      im_conversation_visibility_delete_latency: ['p(95)<1500', 'p(99)<3000'],
      im_conversation_visibility_removed_latency: ['p(95)<5000', 'p(99)<10000'],
      im_conversation_visibility_total_latency: ['p(95)<12000', 'p(99)<25000'],
    },
  },
  'conversation-visibility-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_conversation_visibility_errors: ['rate<0.005'],
      im_conversation_visibility_seed_latency: ['p(95)<3000', 'p(99)<7000'],
      im_conversation_visibility_clear_latency: ['p(95)<3000', 'p(99)<7000'],
      im_conversation_visibility_hidden_latency: ['p(95)<7000', 'p(99)<15000'],
      im_conversation_visibility_new_message_latency: ['p(95)<7000', 'p(99)<15000'],
      im_conversation_visibility_delete_latency: ['p(95)<3000', 'p(99)<7000'],
      im_conversation_visibility_removed_latency: ['p(95)<10000', 'p(99)<20000'],
      im_conversation_visibility_total_latency: ['p(95)<25000', 'p(99)<50000'],
    },
  },
};

export const options = profiles[profile] || profiles['conversation-visibility-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const commandBaseURL = (__ENV.IM_COMMAND_BASE_URL || baseURL).replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const fallbackMemberEmail = (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultMemberPassword = __ENV.IM_MEMBER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_CONVERSATION_VISIBILITY_TIMEOUT_MS || '12000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_CONVERSATION_VISIBILITY_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_CONVERSATION_VISIBILITY_SLEEP_MS || '250', 10);

export const visibilityErrors = new Rate('im_conversation_visibility_errors');
export const seedLatency = new Trend('im_conversation_visibility_seed_latency');
export const clearLatency = new Trend('im_conversation_visibility_clear_latency');
export const hiddenLatency = new Trend('im_conversation_visibility_hidden_latency');
export const newMessageLatency = new Trend('im_conversation_visibility_new_message_latency');
export const deleteLatency = new Trend('im_conversation_visibility_delete_latency');
export const removedLatency = new Trend('im_conversation_visibility_removed_latency');
export const totalLatency = new Trend('im_conversation_visibility_total_latency');

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

function accountsForVU() {
  if (csvAccounts.length >= 2) {
    const start = (((__VU - 1) * 2) % csvAccounts.length);
    return {
      owner: csvAccounts[start],
      member: csvAccounts[(start + 1) % csvAccounts.length],
    };
  }
  return {
    owner: { email: defaultOwnerEmail, password: defaultOwnerPassword },
    member: { email: fallbackMemberEmail, password: defaultMemberPassword },
  };
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
        deviceID: `k6-visibility-${__VU}-${account.email}`,
        deviceName: 'k6-visibility',
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'visibility login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createConversation(token, memberEmail) {
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title: `k6-visibility-${__VU}-${__ITER}-${Date.now()}`,
      memberEmails: [memberEmail],
    }),
    jsonHeaders(token)
  );
  check(res, { 'visibility create conversation ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    return null;
  }
  return res.json('id');
}

function sendInternalMessage(senderUserID, conversationID, clientMessageID) {
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
        content: richTextContent(`visibility ${clientMessageID}`),
        derivedState: initialDerivedState(),
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  seedLatency.add(Date.now() - startedAt);
  check(res, { 'visibility seed message accepted': (r) => r.status === 200 });
  return res.status === 200 ? res.json('message') : null;
}

function messageVisible(token, conversationID, clientMessageID, afterSequence = 0) {
  const res = http.get(
    `${baseURL}/api/im/conversations/${conversationID}/timeline/since?afterSequence=${afterSequence}&limit=100`,
    jsonHeaders(token)
  );
  if (res.status !== 200) {
    return false;
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  return items.some((item) => item.message && item.message.clientMessageID === clientMessageID);
}

function listSummary(token, conversationID) {
  const res = http.get(`${baseURL}/api/im/conversations?limit=100`, jsonHeaders(token));
  if (res.status !== 200) {
    return { contains: false, snapshotToken: null };
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  return {
    contains: items.some((item) => item.id === conversationID),
    snapshotToken: body.snapshotToken || null,
  };
}

function changesContainRemoved(token, conversationID, baselineToken) {
  if (!baselineToken) {
    return false;
  }
  const res = http.get(
    `${baseURL}/api/im/conversations/changes?afterToken=${encodeURIComponent(baselineToken)}&limit=100`,
    jsonHeaders(token)
  );
  if (res.status !== 200) {
    return false;
  }
  const body = res.json();
  const removed = Array.isArray(body.removedConversationIDs) ? body.removedConversationIDs : [];
  return removed.includes(conversationID);
}

function postClear(token, conversationID) {
  const startedAt = Date.now();
  const res = http.post(`${baseURL}/api/im/conversations/${conversationID}/clear`, '{}', jsonHeaders(token));
  clearLatency.add(Date.now() - startedAt);
  check(res, { 'visibility clear conversation ok': (r) => r.status === 200 });
  return res.status === 200;
}

function deleteConversation(token, conversationID) {
  const startedAt = Date.now();
  const res = http.del(`${baseURL}/api/im/conversations/${conversationID}`, null, jsonHeaders(token));
  deleteLatency.add(Date.now() - startedAt);
  check(res, { 'visibility delete conversation ok': (r) => r.status === 200 });
  return res.status === 200;
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

export default function () {
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for conversation visibility checks.');
  }

  const startedAt = Date.now();
  const accounts = accountsForVU();
  const ownerAuth = login(accounts.owner);
  const conversationID = createConversation(ownerAuth.accessToken, accounts.member.email);
  if (!conversationID) {
    visibilityErrors.add(true);
    return;
  }

  const deadline = startedAt + pollTimeoutMillis;
  const oldClientMessageID = `k6-visibility-old-${__VU}-${__ITER}-${Date.now()}`;
  const oldMessage = sendInternalMessage(ownerAuth.user.id, conversationID, oldClientMessageID);
  if (!oldMessage || !oldMessage.serverSequence) {
    visibilityErrors.add(true);
    return;
  }
  if (!pollUntil(deadline, () => messageVisible(ownerAuth.accessToken, conversationID, oldClientMessageID, 0))) {
    visibilityErrors.add(true);
    return;
  }

  if (!postClear(ownerAuth.accessToken, conversationID)) {
    visibilityErrors.add(true);
    return;
  }

  const hiddenStartedAt = Date.now();
  const oldHidden = pollUntil(deadline, () => !messageVisible(ownerAuth.accessToken, conversationID, oldClientMessageID, 0));
  if (!oldHidden) {
    visibilityErrors.add(true);
    return;
  }
  hiddenLatency.add(Date.now() - hiddenStartedAt);

  const newStartedAt = Date.now();
  const newClientMessageID = `k6-visibility-new-${__VU}-${__ITER}-${Date.now()}`;
  const newMessage = sendInternalMessage(ownerAuth.user.id, conversationID, newClientMessageID);
  if (!newMessage || !newMessage.serverSequence) {
    visibilityErrors.add(true);
    return;
  }
  if (!pollUntil(deadline, () => messageVisible(ownerAuth.accessToken, conversationID, newClientMessageID, oldMessage.serverSequence))) {
    visibilityErrors.add(true);
    return;
  }
  newMessageLatency.add(Date.now() - newStartedAt);

  const deleteBaseline = listSummary(ownerAuth.accessToken, conversationID);
  if (!deleteBaseline.contains) {
    visibilityErrors.add(true);
    return;
  }
  if (!deleteConversation(ownerAuth.accessToken, conversationID)) {
    visibilityErrors.add(true);
    return;
  }

  const removedStartedAt = Date.now();
  const removed = pollUntil(deadline, () => {
    const summary = listSummary(ownerAuth.accessToken, conversationID);
    return !summary.contains
      && changesContainRemoved(ownerAuth.accessToken, conversationID, deleteBaseline.snapshotToken);
  });
  if (!removed) {
    visibilityErrors.add(true);
    return;
  }
  removedLatency.add(Date.now() - removedStartedAt);

  totalLatency.add(Date.now() - startedAt);
  visibilityErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
