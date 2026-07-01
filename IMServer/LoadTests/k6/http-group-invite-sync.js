import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'group-invite-smoke';
const profiles = {
  'group-invite-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_group_invite_errors: ['rate<0.001'],
      im_group_invite_total_latency: ['p(95)<7000', 'p(99)<15000'],
      im_group_invite_create_group_latency: ['p(95)<1000', 'p(99)<2000'],
      im_group_invite_create_latency: ['p(95)<1000', 'p(99)<2000'],
      im_group_invite_join_latency: ['p(95)<2000', 'p(99)<5000'],
      im_group_invite_members_visible_latency: ['p(95)<3000', 'p(99)<7000'],
      im_group_invite_revoke_latency: ['p(95)<1000', 'p(99)<2500'],
    },
  },
  'group-invite-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_group_invite_errors: ['rate<0.001'],
      im_group_invite_total_latency: ['p(95)<12000', 'p(99)<30000'],
      im_group_invite_create_group_latency: ['p(95)<1500', 'p(99)<4000'],
      im_group_invite_create_latency: ['p(95)<1500', 'p(99)<4000'],
      im_group_invite_join_latency: ['p(95)<5000', 'p(99)<10000'],
      im_group_invite_members_visible_latency: ['p(95)<7000', 'p(99)<15000'],
      im_group_invite_revoke_latency: ['p(95)<1500', 'p(99)<4000'],
    },
  },
  'group-invite-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_group_invite_errors: ['rate<0.005'],
      im_group_invite_total_latency: ['p(95)<30000', 'p(99)<60000'],
      im_group_invite_create_group_latency: ['p(95)<3000', 'p(99)<7000'],
      im_group_invite_create_latency: ['p(95)<3000', 'p(99)<7000'],
      im_group_invite_join_latency: ['p(95)<10000', 'p(99)<30000'],
      im_group_invite_members_visible_latency: ['p(95)<15000', 'p(99)<30000'],
      im_group_invite_revoke_latency: ['p(95)<3000', 'p(99)<7000'],
    },
  },
};

export const options = profiles[profile] || profiles['group-invite-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const fallbackMembers = (__ENV.IM_MEMBER_EMAILS || 'alice@example.com,bob@example.com')
  .split(',')
  .map((value) => value.trim())
  .filter((value) => value.length > 0);
const defaultMemberPassword = __ENV.IM_MEMBER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_GROUP_INVITE_TIMEOUT_MS || '15000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_GROUP_INVITE_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_GROUP_INVITE_SLEEP_MS || '250', 10);

export const inviteErrors = new Rate('im_group_invite_errors');
export const totalLatency = new Trend('im_group_invite_total_latency');
export const createGroupLatency = new Trend('im_group_invite_create_group_latency');
export const createInviteLatency = new Trend('im_group_invite_create_latency');
export const listInviteLatency = new Trend('im_group_invite_list_latency');
export const joinInviteLatency = new Trend('im_group_invite_join_latency');
export const membersVisibleLatency = new Trend('im_group_invite_members_visible_latency');
export const revokeInviteLatency = new Trend('im_group_invite_revoke_latency');

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
      invitedMember: csvAccounts[(start + 2) % csvAccounts.length],
    };
  }
  return {
    owner: { email: defaultOwnerEmail, password: defaultOwnerPassword },
    initialMember: { email: fallbackMembers[0] || 'alice@example.com', password: defaultMemberPassword },
    invitedMember: { email: fallbackMembers[1] || fallbackMembers[0] || 'bob@example.com', password: defaultMemberPassword },
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
        deviceID: `k6-group-invite-${role}-${__VU}-${__ITER}`,
        deviceName: `k6-group-invite-${role}`,
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'group invite login ok': (r) => r.status === 200 });
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
  createGroupLatency.add(Date.now() - startedAt);
  check(res, { 'group invite create group ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function createInvite(token, conversationID) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/invites`,
    JSON.stringify({ expiresInSeconds: 3600 }),
    jsonHeaders(token)
  );
  createInviteLatency.add(Date.now() - startedAt);
  check(res, { 'group invite create invite ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function listInvites(token, conversationID, expectedToken, expectedRevoked) {
  const startedAt = Date.now();
  const res = http.get(
    `${baseURL}/api/im/conversations/${conversationID}/invites`,
    jsonHeaders(token)
  );
  listInviteLatency.add(Date.now() - startedAt);
  if (res.status !== 200) {
    return false;
  }
  const invites = res.json();
  if (!Array.isArray(invites)) {
    return false;
  }
  const invite = invites.find((item) => item.token === expectedToken);
  if (!invite) {
    return false;
  }
  return expectedRevoked ? Boolean(invite.revokedAt) : !invite.revokedAt;
}

function joinInvite(token, inviteToken, conversationID) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/invites/${inviteToken}/join`,
    '{}',
    jsonHeaders(token)
  );
  joinInviteLatency.add(Date.now() - startedAt);
  check(res, { 'group invite join ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    return false;
  }
  return res.json('id') === conversationID;
}

function listMembers(token, conversationID) {
  const res = http.get(
    `${baseURL}/api/im/conversations/${conversationID}/members?limit=100`,
    jsonHeaders(token)
  );
  if (res.status !== 200) {
    return [];
  }
  const body = res.json();
  if (Array.isArray(body.items)) {
    return body.items;
  }
  return Array.isArray(body) ? body : [];
}

function revokeInvite(token, conversationID, inviteToken) {
  const startedAt = Date.now();
  const res = http.del(
    `${baseURL}/api/im/conversations/${conversationID}/invites/${inviteToken}`,
    null,
    jsonHeaders(token)
  );
  revokeInviteLatency.add(Date.now() - startedAt);
  check(res, { 'group invite revoke ok': (r) => r.status === 200 });
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

function memberVisible(token, conversationID, email) {
  return listMembers(token, conversationID).some((member) => member.email === email);
}

export default function () {
  const startedAt = Date.now();
  const accounts = accountsForVU();
  const ownerAuth = login(accounts.owner, 'owner');
  const invitedAuth = login(accounts.invitedMember, 'invited');
  const title = `k6-group-invite-${__VU}-${__ITER}-${Date.now()}`;
  const conversation = createConversation(ownerAuth.accessToken, accounts.initialMember.email, title);
  if (!conversation || !conversation.id) {
    inviteErrors.add(true);
    return;
  }

  const invite = createInvite(ownerAuth.accessToken, conversation.id);
  if (!invite || !invite.token) {
    inviteErrors.add(true);
    return;
  }

  if (!listInvites(ownerAuth.accessToken, conversation.id, invite.token, false)) {
    inviteErrors.add(true);
    return;
  }

  if (!joinInvite(invitedAuth.accessToken, invite.token, conversation.id)) {
    inviteErrors.add(true);
    return;
  }

  const memberStartedAt = Date.now();
  const deadline = startedAt + pollTimeoutMillis;
  const visible = pollUntil(
    deadline,
    () => memberVisible(ownerAuth.accessToken, conversation.id, accounts.invitedMember.email)
  );
  if (!visible) {
    inviteErrors.add(true);
    return;
  }
  membersVisibleLatency.add(Date.now() - memberStartedAt);

  if (!revokeInvite(ownerAuth.accessToken, conversation.id, invite.token)) {
    inviteErrors.add(true);
    return;
  }

  if (!listInvites(ownerAuth.accessToken, conversation.id, invite.token, true)) {
    inviteErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  inviteErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
