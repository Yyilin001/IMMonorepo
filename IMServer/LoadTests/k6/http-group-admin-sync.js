import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'group-admin-smoke';
const profiles = {
  'group-admin-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_group_admin_errors: ['rate<0.001'],
      im_group_admin_create_latency: ['p(95)<1000', 'p(99)<2000'],
      im_group_admin_preferences_latency: ['p(95)<500', 'p(99)<1000'],
      im_group_admin_title_latency: ['p(95)<1000', 'p(99)<2000'],
      im_group_admin_metadata_latency: ['p(95)<1000', 'p(99)<2000'],
      im_group_admin_add_member_latency: ['p(95)<1500', 'p(99)<3000'],
      im_group_admin_members_latency: ['p(95)<1000', 'p(99)<2000'],
      im_group_admin_changes_latency: ['p(95)<3000', 'p(99)<6000'],
      im_group_admin_total_latency: ['p(95)<6000', 'p(99)<12000'],
    },
  },
  'group-admin-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_group_admin_errors: ['rate<0.001'],
      im_group_admin_create_latency: ['p(95)<1000', 'p(99)<2500'],
      im_group_admin_preferences_latency: ['p(95)<500', 'p(99)<1000'],
      im_group_admin_title_latency: ['p(95)<1000', 'p(99)<2500'],
      im_group_admin_metadata_latency: ['p(95)<1000', 'p(99)<2500'],
      im_group_admin_add_member_latency: ['p(95)<2000', 'p(99)<5000'],
      im_group_admin_members_latency: ['p(95)<1000', 'p(99)<2500'],
      im_group_admin_changes_latency: ['p(95)<5000', 'p(99)<10000'],
      im_group_admin_total_latency: ['p(95)<10000', 'p(99)<20000'],
    },
  },
  'group-admin-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_group_admin_errors: ['rate<0.005'],
      im_group_admin_create_latency: ['p(95)<2000', 'p(99)<5000'],
      im_group_admin_preferences_latency: ['p(95)<1000', 'p(99)<2500'],
      im_group_admin_title_latency: ['p(95)<2000', 'p(99)<5000'],
      im_group_admin_metadata_latency: ['p(95)<2000', 'p(99)<5000'],
      im_group_admin_add_member_latency: ['p(95)<5000', 'p(99)<10000'],
      im_group_admin_members_latency: ['p(95)<2000', 'p(99)<5000'],
      im_group_admin_changes_latency: ['p(95)<10000', 'p(99)<30000'],
      im_group_admin_total_latency: ['p(95)<20000', 'p(99)<60000'],
    },
  },
};

export const options = profiles[profile] || profiles['group-admin-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const fallbackMembers = (__ENV.IM_MEMBER_EMAILS || 'alice@example.com,bob@example.com')
  .split(',')
  .map((value) => value.trim())
  .filter((value) => value.length > 0);
const defaultMemberPassword = __ENV.IM_MEMBER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_GROUP_ADMIN_TIMEOUT_MS || '10000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_GROUP_ADMIN_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_GROUP_ADMIN_SLEEP_MS || '250', 10);

export const groupAdminErrors = new Rate('im_group_admin_errors');
export const createLatency = new Trend('im_group_admin_create_latency');
export const preferencesLatency = new Trend('im_group_admin_preferences_latency');
export const titleLatency = new Trend('im_group_admin_title_latency');
export const metadataLatency = new Trend('im_group_admin_metadata_latency');
export const addMemberLatency = new Trend('im_group_admin_add_member_latency');
export const membersLatency = new Trend('im_group_admin_members_latency');
export const changesLatency = new Trend('im_group_admin_changes_latency');
export const totalLatency = new Trend('im_group_admin_total_latency');

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
  if (csvAccounts.length >= 3) {
    const start = (((__VU - 1) * 3) % csvAccounts.length);
    return {
      owner: csvAccounts[start],
      initialMember: csvAccounts[(start + 1) % csvAccounts.length],
      addedMember: csvAccounts[(start + 2) % csvAccounts.length],
    };
  }
  return {
    owner: { email: defaultOwnerEmail, password: defaultOwnerPassword },
    initialMember: { email: fallbackMembers[0] || 'alice@example.com', password: defaultMemberPassword },
    addedMember: { email: fallbackMembers[1] || fallbackMembers[0] || 'bob@example.com', password: defaultMemberPassword },
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
        deviceID: `k6-group-admin-${__VU}-${account.email}`,
        deviceName: 'k6-group-admin',
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'group admin login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createConversation(token, initialMemberEmail, title) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title,
      memberEmails: [initialMemberEmail],
    }),
    jsonHeaders(token)
  );
  createLatency.add(Date.now() - startedAt);
  check(res, { 'group admin create ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function listSummary(token, conversationID) {
  const res = http.get(`${baseURL}/api/im/conversations?limit=100`, jsonHeaders(token));
  if (res.status !== 200) {
    return { status: res.status, summary: null, snapshotToken: null };
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  return {
    status: res.status,
    summary: items.find((item) => item.id === conversationID) || null,
    snapshotToken: body.snapshotToken || null,
  };
}

function patchPreferences(token, conversationID) {
  const startedAt = Date.now();
  const res = http.patch(
    `${baseURL}/api/im/conversations/${conversationID}/preferences`,
    JSON.stringify({ isPinned: true, isMuted: true }),
    jsonHeaders(token)
  );
  preferencesLatency.add(Date.now() - startedAt);
  check(res, { 'group admin preferences ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function updateTitle(token, conversationID, title) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/title`,
    JSON.stringify({ title }),
    jsonHeaders(token)
  );
  titleLatency.add(Date.now() - startedAt);
  check(res, { 'group admin title ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function patchMetadata(token, conversationID, title, notice) {
  const startedAt = Date.now();
  const res = http.patch(
    `${baseURL}/api/im/conversations/${conversationID}/metadata`,
    JSON.stringify({ title, notice, muteAll: false }),
    jsonHeaders(token)
  );
  metadataLatency.add(Date.now() - startedAt);
  check(res, { 'group admin metadata ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function addMember(token, conversationID, email) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/members`,
    JSON.stringify({ memberEmails: [email] }),
    jsonHeaders(token)
  );
  addMemberLatency.add(Date.now() - startedAt);
  check(res, { 'group admin add member ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function listMembers(token, conversationID, expectedTotal) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/im/conversations/${conversationID}/members?limit=100`, jsonHeaders(token));
  membersLatency.add(Date.now() - startedAt);
  if (res.status !== 200) {
    return false;
  }
  const body = res.json();
  return Number(body.total || 0) >= expectedTotal;
}

function changesContainGroupState(token, conversationID, baselineToken, expectedTitle, expectedMemberCount) {
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
    && item.title === expectedTitle
    && item.isPinned === true
    && item.isMuted === true
    && Number(item.memberCount || 0) >= expectedMemberCount
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
  const startedAt = Date.now();
  const accounts = accountsForVU();
  const ownerAuth = login(accounts.owner);
  const initialTitle = `k6-group-admin-${__VU}-${__ITER}-${Date.now()}`;
  const commandTitle = `${initialTitle}-title`;
  const updatedTitle = `${initialTitle}-updated`;
  const notice = `notice-${__VU}-${__ITER}`;
  const conversation = createConversation(ownerAuth.accessToken, accounts.initialMember.email, initialTitle);
  if (!conversation || !conversation.id) {
    groupAdminErrors.add(true);
    return;
  }

  const baseline = listSummary(ownerAuth.accessToken, conversation.id);
  if (!baseline.snapshotToken) {
    groupAdminErrors.add(true);
    return;
  }

  const preferences = patchPreferences(ownerAuth.accessToken, conversation.id);
  if (!preferences || preferences.isPinned !== true || preferences.isMuted !== true) {
    groupAdminErrors.add(true);
    return;
  }

  const titleResponse = updateTitle(ownerAuth.accessToken, conversation.id, commandTitle);
  if (!titleResponse || titleResponse.title !== commandTitle) {
    groupAdminErrors.add(true);
    return;
  }

  const metadata = patchMetadata(ownerAuth.accessToken, conversation.id, updatedTitle, notice);
  if (!metadata || metadata.title !== updatedTitle || metadata.notice !== notice) {
    groupAdminErrors.add(true);
    return;
  }

  const added = addMember(ownerAuth.accessToken, conversation.id, accounts.addedMember.email);
  if (!added || Number(added.memberCount || 0) < 3) {
    groupAdminErrors.add(true);
    return;
  }

  const deadline = startedAt + pollTimeoutMillis;
  const membersVisible = pollUntil(
    deadline,
    () => listMembers(ownerAuth.accessToken, conversation.id, 3)
  );
  if (!membersVisible) {
    groupAdminErrors.add(true);
    return;
  }

  const changesVisible = pollUntil(
    deadline,
    () => changesContainGroupState(ownerAuth.accessToken, conversation.id, baseline.snapshotToken, updatedTitle, 3)
  );
  if (!changesVisible) {
    groupAdminErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  groupAdminErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
