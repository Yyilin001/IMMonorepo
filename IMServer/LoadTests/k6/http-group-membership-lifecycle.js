import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'group-membership-smoke';
const profiles = {
  'group-membership-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_group_membership_errors: ['rate<0.001'],
      im_group_membership_create_latency: ['p(95)<1000', 'p(99)<2500'],
      im_group_membership_profile_latency: ['p(95)<800', 'p(99)<1500'],
      im_group_membership_role_latency: ['p(95)<1000', 'p(99)<2500'],
      im_group_membership_remove_latency: ['p(95)<1500', 'p(99)<3000'],
      im_group_membership_leave_latency: ['p(95)<1500', 'p(99)<3000'],
      im_group_membership_members_visible_latency: ['p(95)<3000', 'p(99)<6000'],
      im_group_membership_changes_latency: ['p(95)<3000', 'p(99)<6000'],
      im_group_membership_total_latency: ['p(95)<6000', 'p(99)<12000'],
    },
  },
  'group-membership-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_group_membership_errors: ['rate<0.001'],
      im_group_membership_create_latency: ['p(95)<1500', 'p(99)<3000'],
      im_group_membership_profile_latency: ['p(95)<1000', 'p(99)<2500'],
      im_group_membership_role_latency: ['p(95)<1500', 'p(99)<3000'],
      im_group_membership_remove_latency: ['p(95)<2500', 'p(99)<5000'],
      im_group_membership_leave_latency: ['p(95)<2500', 'p(99)<5000'],
      im_group_membership_members_visible_latency: ['p(95)<5000', 'p(99)<10000'],
      im_group_membership_changes_latency: ['p(95)<5000', 'p(99)<10000'],
      im_group_membership_total_latency: ['p(95)<12000', 'p(99)<25000'],
    },
  },
  'group-membership-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_group_membership_errors: ['rate<0.005'],
      im_group_membership_create_latency: ['p(95)<3000', 'p(99)<7000'],
      im_group_membership_profile_latency: ['p(95)<2000', 'p(99)<5000'],
      im_group_membership_role_latency: ['p(95)<3000', 'p(99)<7000'],
      im_group_membership_remove_latency: ['p(95)<5000', 'p(99)<10000'],
      im_group_membership_leave_latency: ['p(95)<5000', 'p(99)<10000'],
      im_group_membership_members_visible_latency: ['p(95)<10000', 'p(99)<30000'],
      im_group_membership_changes_latency: ['p(95)<10000', 'p(99)<30000'],
      im_group_membership_total_latency: ['p(95)<25000', 'p(99)<60000'],
    },
  },
};

export const options = profiles[profile] || profiles['group-membership-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const fallbackEmails = (
  __ENV.IM_MEMBER_LIFECYCLE_EMAILS
  || `${__ENV.IM_EMAIL || 'demo@example.com'},alice@example.com,bob@example.com,carol@example.com`
)
  .split(',')
  .map((value) => value.trim())
  .filter((value) => value.length > 0);
const pollTimeoutMillis = Number.parseInt(__ENV.IM_GROUP_MEMBERSHIP_TIMEOUT_MS || '10000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_GROUP_MEMBERSHIP_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_GROUP_MEMBERSHIP_SLEEP_MS || '250', 10);

export const membershipErrors = new Rate('im_group_membership_errors');
export const createLatency = new Trend('im_group_membership_create_latency');
export const profileLatency = new Trend('im_group_membership_profile_latency');
export const roleLatency = new Trend('im_group_membership_role_latency');
export const removeLatency = new Trend('im_group_membership_remove_latency');
export const leaveLatency = new Trend('im_group_membership_leave_latency');
export const membersVisibleLatency = new Trend('im_group_membership_members_visible_latency');
export const changesLatency = new Trend('im_group_membership_changes_latency');
export const totalLatency = new Trend('im_group_membership_total_latency');

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
  if (csvAccounts.length >= 4) {
    const start = (((__VU - 1) * 4) % csvAccounts.length);
    return {
      owner: csvAccounts[start],
      promoted: csvAccounts[(start + 1) % csvAccounts.length],
      removed: csvAccounts[(start + 2) % csvAccounts.length],
      leaving: csvAccounts[(start + 3) % csvAccounts.length],
    };
  }
  if (fallbackEmails.length < 4) {
    fail('group membership lifecycle needs at least 4 accounts.');
  }
  return {
    owner: { email: fallbackEmails[0], password: defaultPassword },
    promoted: { email: fallbackEmails[1], password: defaultPassword },
    removed: { email: fallbackEmails[2], password: defaultPassword },
    leaving: { email: fallbackEmails[3], password: defaultPassword },
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
        deviceID: `k6-group-membership-${role}-${__VU}`,
        deviceName: `k6-group-membership-${role}`,
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'group membership login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createConversation(token, accounts) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title: `k6-group-membership-${__VU}-${__ITER}-${Date.now()}`,
      memberEmails: [accounts.promoted.email, accounts.removed.email, accounts.leaving.email],
    }),
    jsonHeaders(token)
  );
  createLatency.add(Date.now() - startedAt);
  check(res, { 'group membership create ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function listSummary(token, conversationID) {
  const res = http.get(`${baseURL}/api/im/conversations?limit=100`, jsonHeaders(token));
  if (res.status !== 200) {
    return { snapshotToken: null, summary: null };
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  return {
    snapshotToken: body.snapshotToken || null,
    summary: items.find((item) => item.id === conversationID) || null,
  };
}

function listMembers(token, conversationID) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/im/conversations/${conversationID}/members?limit=100`, jsonHeaders(token));
  membersVisibleLatency.add(Date.now() - startedAt);
  if (res.status !== 200) {
    return null;
  }
  const body = res.json();
  return Array.isArray(body.items) ? body.items : [];
}

function updateMyMemberProfile(token, conversationID, nickname) {
  const startedAt = Date.now();
  const res = http.patch(
    `${baseURL}/api/im/conversations/${conversationID}/members/me`,
    JSON.stringify({ memberNickname: nickname }),
    jsonHeaders(token)
  );
  profileLatency.add(Date.now() - startedAt);
  check(res, { 'group membership profile ok': (r) => r.status === 200 });
  return res.status === 200;
}

function updateMemberRole(token, conversationID, memberUserID, role) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/members/${memberUserID}/role`,
    JSON.stringify({ role }),
    jsonHeaders(token)
  );
  roleLatency.add(Date.now() - startedAt);
  check(res, { 'group membership role ok': (r) => r.status === 200 });
  return res.status === 200;
}

function removeMember(token, conversationID, memberUserID) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/members/${memberUserID}/remove`,
    null,
    jsonHeaders(token)
  );
  removeLatency.add(Date.now() - startedAt);
  check(res, { 'group membership remove ok': (r) => r.status === 200 });
  return res.status === 200;
}

function leaveConversation(token, conversationID) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/leave`,
    null,
    jsonHeaders(token)
  );
  leaveLatency.add(Date.now() - startedAt);
  check(res, { 'group membership leave ok': (r) => r.status === 200 });
  return res.status === 200;
}

function membersConverged(token, conversationID, promotedUserID, removedUserID, leavingUserID) {
  const members = listMembers(token, conversationID);
  if (!members) {
    return false;
  }
  const ids = members.map((item) => item.id || item.userID).filter((id) => id);
  return members.length === 2
    && ids.includes(promotedUserID)
    && !ids.includes(removedUserID)
    && !ids.includes(leavingUserID);
}

function changesConverged(token, conversationID, baselineToken) {
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
  return upserts.some((item) => item.id === conversationID && Number(item.memberCount || 0) === 2);
}

function pollUntil(deadline, action) {
  while (Date.now() < deadline) {
    if (action()) {
      return true;
    }
    sleep(Math.max(0.05, pollIntervalMillis / 1000));
  }
  return false;
}

export default function () {
  const startedAt = Date.now();
  const accounts = accountsForVU();
  const ownerAuth = login(accounts.owner, 'owner');
  const promotedAuth = login(accounts.promoted, 'promoted');
  const removedAuth = login(accounts.removed, 'removed');
  const leavingAuth = login(accounts.leaving, 'leaving');

  const conversation = createConversation(ownerAuth.accessToken, accounts);
  if (!conversation || !conversation.id || Number(conversation.memberCount || 0) < 4) {
    membershipErrors.add(true);
    return;
  }

  const baseline = listSummary(ownerAuth.accessToken, conversation.id);
  const nickname = `nick-${__VU}-${__ITER}`;
  if (!updateMyMemberProfile(promotedAuth.accessToken, conversation.id, nickname)) {
    membershipErrors.add(true);
    return;
  }

  if (!updateMemberRole(ownerAuth.accessToken, conversation.id, promotedAuth.user.id, 'admin')) {
    membershipErrors.add(true);
    return;
  }

  if (!removeMember(ownerAuth.accessToken, conversation.id, removedAuth.user.id)) {
    membershipErrors.add(true);
    return;
  }

  if (!leaveConversation(leavingAuth.accessToken, conversation.id)) {
    membershipErrors.add(true);
    return;
  }

  const deadline = startedAt + pollTimeoutMillis;
  const memberPageOK = pollUntil(
    deadline,
    () => membersConverged(ownerAuth.accessToken, conversation.id, promotedAuth.user.id, removedAuth.user.id, leavingAuth.user.id)
  );
  if (!memberPageOK) {
    membershipErrors.add(true);
    return;
  }

  const changesOK = pollUntil(
    deadline,
    () => changesConverged(ownerAuth.accessToken, conversation.id, baseline.snapshotToken)
  );
  if (!changesOK) {
    membershipErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  membershipErrors.add(false);

  if (sleepMillis > 0) {
    sleep(sleepMillis / 1000);
  }
}
