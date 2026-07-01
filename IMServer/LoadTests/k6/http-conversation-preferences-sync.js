import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'conversation-preferences-smoke';
const profiles = {
  'conversation-preferences-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_conversation_preferences_errors: ['rate<0.001'],
      im_conversation_preferences_create_latency: ['p(95)<1000', 'p(99)<2000'],
      im_conversation_preferences_patch_latency: ['p(95)<500', 'p(99)<1000'],
      im_conversation_preferences_list_latency: ['p(95)<1500', 'p(99)<3000'],
      im_conversation_preferences_changes_latency: ['p(95)<2000', 'p(99)<5000'],
      im_conversation_preferences_total_latency: ['p(95)<6000', 'p(99)<12000'],
    },
  },
  'conversation-preferences-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_conversation_preferences_errors: ['rate<0.001'],
      im_conversation_preferences_create_latency: ['p(95)<1500', 'p(99)<3000'],
      im_conversation_preferences_patch_latency: ['p(95)<800', 'p(99)<2000'],
      im_conversation_preferences_list_latency: ['p(95)<2500', 'p(99)<5000'],
      im_conversation_preferences_changes_latency: ['p(95)<3000', 'p(99)<7000'],
      im_conversation_preferences_total_latency: ['p(95)<10000', 'p(99)<20000'],
    },
  },
  'conversation-preferences-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_conversation_preferences_errors: ['rate<0.005'],
      im_conversation_preferences_create_latency: ['p(95)<3000', 'p(99)<7000'],
      im_conversation_preferences_patch_latency: ['p(95)<1500', 'p(99)<4000'],
      im_conversation_preferences_list_latency: ['p(95)<5000', 'p(99)<10000'],
      im_conversation_preferences_changes_latency: ['p(95)<7000', 'p(99)<15000'],
      im_conversation_preferences_total_latency: ['p(95)<20000', 'p(99)<40000'],
    },
  },
};

export const options = profiles[profile] || profiles['conversation-preferences-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const fallbackMemberEmail = (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultMemberPassword = __ENV.IM_MEMBER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_CONVERSATION_PREFERENCES_TIMEOUT_MS || '10000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_CONVERSATION_PREFERENCES_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_CONVERSATION_PREFERENCES_SLEEP_MS || '250', 10);

export const preferenceErrors = new Rate('im_conversation_preferences_errors');
export const createLatency = new Trend('im_conversation_preferences_create_latency');
export const patchLatency = new Trend('im_conversation_preferences_patch_latency');
export const listLatency = new Trend('im_conversation_preferences_list_latency');
export const changesLatency = new Trend('im_conversation_preferences_changes_latency');
export const totalLatency = new Trend('im_conversation_preferences_total_latency');

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
        deviceID: `k6-conversation-preferences-${__VU}-${account.email}`,
        deviceName: 'k6-conversation-preferences',
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'conversation preferences login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createConversation(token, memberEmail, title) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title,
      memberEmails: [memberEmail],
    }),
    jsonHeaders(token)
  );
  createLatency.add(Date.now() - startedAt);
  check(res, { 'conversation preferences create ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function ensureState() {
  if (perVUState) {
    return perVUState;
  }
  const accounts = accountsForVU();
  const ownerAuth = login(accounts.owner);
  const stamp = `${__VU}-${Date.now()}`;
  const older = createConversation(ownerAuth.accessToken, accounts.member.email, `k6-pref-old-${stamp}`);
  const newer = createConversation(ownerAuth.accessToken, accounts.member.email, `k6-pref-new-${stamp}`);
  if (!older || !newer) {
    fail('failed to create conversation preferences seed conversations');
  }
  perVUState = {
    token: ownerAuth.accessToken,
    olderID: older.id,
    newerID: newer.id,
  };
  return perVUState;
}

function listPage(token) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/im/conversations?limit=100`, jsonHeaders(token));
  listLatency.add(Date.now() - startedAt);
  if (res.status !== 200) {
    return { items: [], snapshotToken: null };
  }
  const body = res.json();
  return {
    items: Array.isArray(body.items) ? body.items : [],
    snapshotToken: body.snapshotToken || null,
  };
}

function patchPreferences(token, conversationID, isPinned, isMuted) {
  const startedAt = Date.now();
  const res = http.patch(
    `${baseURL}/api/im/conversations/${conversationID}/preferences`,
    JSON.stringify({ isPinned, isMuted }),
    jsonHeaders(token)
  );
  patchLatency.add(Date.now() - startedAt);
  check(res, { 'conversation preferences patch ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function changesContainPreferences(token, conversationID, baselineToken, isPinned, isMuted) {
  if (!baselineToken) {
    return false;
  }
  const startedAt = Date.now();
  const res = http.get(
    `${baseURL}/api/im/conversations/changes?afterToken=${encodeURIComponent(baselineToken)}&limit=100`,
    jsonHeaders(token)
  );
  changesLatency.add(Date.now() - startedAt);
  if (res.status !== 200) {
    return false;
  }
  const body = res.json();
  const upserts = Array.isArray(body.upserts) ? body.upserts : [];
  return upserts.some((item) => (
    item.id === conversationID
    && item.isPinned === isPinned
    && item.isMuted === isMuted
  ));
}

function pinnedAtTop(token, olderID, newerID) {
  const page = listPage(token);
  const olderIndex = page.items.findIndex((item) => item.id === olderID);
  const newerIndex = page.items.findIndex((item) => item.id === newerID);
  const older = page.items[olderIndex];
  return olderIndex >= 0
    && newerIndex >= 0
    && olderIndex < newerIndex
    && older.isPinned === true
    && older.isMuted === true;
}

function preferencesCleared(token, conversationID) {
  const page = listPage(token);
  const item = page.items.find((candidate) => candidate.id === conversationID);
  return item && item.isPinned === false && item.isMuted === false;
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
  const startedAt = Date.now();
  const state = ensureState();
  const baseline = listPage(state.token);
  const deadline = startedAt + pollTimeoutMillis;

  const pinned = patchPreferences(state.token, state.olderID, true, true);
  if (!pinned || pinned.isPinned !== true || pinned.isMuted !== true) {
    preferenceErrors.add(true);
    return;
  }

  if (!pollUntil(deadline, () => pinnedAtTop(state.token, state.olderID, state.newerID))) {
    preferenceErrors.add(true);
    return;
  }
  if (!pollUntil(deadline, () => changesContainPreferences(state.token, state.olderID, baseline.snapshotToken, true, true))) {
    preferenceErrors.add(true);
    return;
  }

  const unpinnedBaseline = listPage(state.token);
  const cleared = patchPreferences(state.token, state.olderID, false, false);
  if (!cleared || cleared.isPinned !== false || cleared.isMuted !== false) {
    preferenceErrors.add(true);
    return;
  }

  if (!pollUntil(deadline, () => preferencesCleared(state.token, state.olderID))) {
    preferenceErrors.add(true);
    return;
  }
  if (!pollUntil(deadline, () => changesContainPreferences(state.token, state.olderID, unpinnedBaseline.snapshotToken, false, false))) {
    preferenceErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  preferenceErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
