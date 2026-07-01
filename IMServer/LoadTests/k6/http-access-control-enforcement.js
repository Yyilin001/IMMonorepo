import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'access-control-enforcement-smoke';
const profiles = {
  'access-control-enforcement-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_access_control_errors: ['rate<0.001'],
      im_access_control_total_latency: ['p(95)<6000', 'p(99)<12000'],
      im_access_control_forbidden_latency: ['p(95)<800', 'p(99)<1500'],
      im_access_control_promote_latency: ['p(95)<1000', 'p(99)<2500'],
      im_access_control_allowed_latency: ['p(95)<1500', 'p(99)<3000'],
      im_access_control_remove_latency: ['p(95)<1500', 'p(99)<3000'],
    },
  },
  'access-control-enforcement-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_access_control_errors: ['rate<0.001'],
      im_access_control_total_latency: ['p(95)<10000', 'p(99)<20000'],
      im_access_control_forbidden_latency: ['p(95)<1200', 'p(99)<3000'],
      im_access_control_promote_latency: ['p(95)<1500', 'p(99)<4000'],
      im_access_control_allowed_latency: ['p(95)<2500', 'p(99)<5000'],
      im_access_control_remove_latency: ['p(95)<2500', 'p(99)<5000'],
    },
  },
  'access-control-enforcement-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.02'],
      im_access_control_errors: ['rate<0.005'],
      im_access_control_total_latency: ['p(95)<20000', 'p(99)<40000'],
      im_access_control_forbidden_latency: ['p(95)<2500', 'p(99)<6000'],
      im_access_control_promote_latency: ['p(95)<4000', 'p(99)<10000'],
      im_access_control_allowed_latency: ['p(95)<5000', 'p(99)<12000'],
      im_access_control_remove_latency: ['p(95)<5000', 'p(99)<12000'],
    },
  },
};

export const options = profiles[profile] || profiles['access-control-enforcement-smoke'];

http.setResponseCallback(http.expectedStatuses({ min: 200, max: 399 }, 401, 403, 404));

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const fallbackEmails = (
  __ENV.IM_ACCESS_CONTROL_EMAILS
  || `${__ENV.IM_EMAIL || 'demo@example.com'},alice@example.com,bob@example.com,carol@example.com`
)
  .split(',')
  .map((value) => value.trim())
  .filter((value) => value.length > 0);
const sleepMillis = Number.parseInt(__ENV.IM_ACCESS_CONTROL_SLEEP_MS || '250', 10);

export const accessControlErrors = new Rate('im_access_control_errors');
export const totalLatency = new Trend('im_access_control_total_latency');
export const createLatency = new Trend('im_access_control_create_latency');
export const forbiddenLatency = new Trend('im_access_control_forbidden_latency');
export const promoteLatency = new Trend('im_access_control_promote_latency');
export const allowedLatency = new Trend('im_access_control_allowed_latency');
export const removeLatency = new Trend('im_access_control_remove_latency');
export const enforcementOK = new Counter('im_access_control_ok_total');

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
      member: csvAccounts[(start + 1) % csvAccounts.length],
      outsider: csvAccounts[(start + 2) % csvAccounts.length],
      candidate: csvAccounts[(start + 3) % csvAccounts.length],
    };
  }
  if (fallbackEmails.length < 4) {
    fail('access-control enforcement needs at least 4 accounts.');
  }
  return {
    owner: { email: fallbackEmails[0], password: defaultPassword },
    member: { email: fallbackEmails[1], password: defaultPassword },
    outsider: { email: fallbackEmails[2], password: defaultPassword },
    candidate: { email: fallbackEmails[3], password: defaultPassword },
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
        deviceID: `k6-access-control-${role}-${__VU}`,
        deviceName: `k6-access-control-${role}`,
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'access-control login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createConversation(ownerToken, memberEmail) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title: `k6-access-control-${__VU}-${__ITER}-${Date.now()}`,
      memberEmails: [memberEmail],
    }),
    jsonHeaders(ownerToken)
  );
  createLatency.add(Date.now() - startedAt);
  check(res, { 'access-control create group ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function expectRejected(requestFn, label) {
  const startedAt = Date.now();
  const res = requestFn();
  forbiddenLatency.add(Date.now() - startedAt);
  check(res, { [`${label} rejected`]: (r) => r.status === 401 || r.status === 403 || r.status === 404 });
  return res.status === 401 || res.status === 403 || res.status === 404;
}

function addMember(token, conversationID, email, metric, expectedStatus, label) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/members`,
    JSON.stringify({ memberEmails: [email] }),
    jsonHeaders(token)
  );
  metric.add(Date.now() - startedAt);
  check(res, { [`${label} status`]: (r) => r.status === expectedStatus });
  if (res.status === expectedStatus && expectedStatus !== 200) {
    return true;
  }
  return res.status === expectedStatus ? res.json() : null;
}

function updateMemberRole(token, conversationID, memberUserID, role) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/members/${memberUserID}/role`,
    JSON.stringify({ role }),
    jsonHeaders(token)
  );
  promoteLatency.add(Date.now() - startedAt);
  check(res, { 'access-control promote ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function removeMember(token, conversationID, memberUserID) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/members/${memberUserID}/remove`,
    null,
    jsonHeaders(token)
  );
  removeLatency.add(Date.now() - startedAt);
  check(res, { 'access-control remove ok': (r) => r.status === 200 });
  return res.status === 200;
}

export default function () {
  const startedAt = Date.now();
  const accounts = accountsForVU();
  const ownerAuth = login(accounts.owner, 'owner');
  const memberAuth = login(accounts.member, 'member');
  const outsiderAuth = login(accounts.outsider, 'outsider');

  const conversation = createConversation(ownerAuth.accessToken, accounts.member.email);
  if (!conversation || !conversation.id) {
    accessControlErrors.add(true);
    return;
  }

  if (!expectRejected(
    () => http.get(
      `${baseURL}/api/im/conversations/${conversation.id}/members?limit=100`,
      jsonHeaders(outsiderAuth.accessToken)
    ),
    'outsider members read'
  )) {
    accessControlErrors.add(true);
    return;
  }

  if (!expectRejected(
    () => http.get(
      `${baseURL}/api/im/conversations/${conversation.id}/messages/since?afterSequence=0&limit=20`,
      jsonHeaders(outsiderAuth.accessToken)
    ),
    'outsider timeline read'
  )) {
    accessControlErrors.add(true);
    return;
  }

  if (!addMember(
    memberAuth.accessToken,
    conversation.id,
    accounts.candidate.email,
    forbiddenLatency,
    403,
    'member add before promotion'
  )) {
    accessControlErrors.add(true);
    return;
  }

  const promoted = updateMemberRole(ownerAuth.accessToken, conversation.id, memberAuth.user.id, 'admin');
  if (!promoted) {
    accessControlErrors.add(true);
    return;
  }

  const allowed = addMember(
    memberAuth.accessToken,
    conversation.id,
    accounts.candidate.email,
    allowedLatency,
    200,
    'admin add after promotion'
  );
  if (!allowed || Number(allowed.memberCount || 0) < 3) {
    accessControlErrors.add(true);
    return;
  }

  if (!removeMember(ownerAuth.accessToken, conversation.id, memberAuth.user.id)) {
    accessControlErrors.add(true);
    return;
  }

  if (!expectRejected(
    () => http.get(
      `${baseURL}/api/im/conversations/${conversation.id}/messages/since?afterSequence=0&limit=20`,
      jsonHeaders(memberAuth.accessToken)
    ),
    'removed member timeline read'
  )) {
    accessControlErrors.add(true);
    return;
  }

  if (!expectRejected(
    () => http.post(
      `${baseURL}/api/im/conversations/${conversation.id}/read`,
      JSON.stringify({ readSequence: 1 }),
      jsonHeaders(memberAuth.accessToken)
    ),
    'removed member mark read'
  )) {
    accessControlErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  enforcementOK.add(1);
  accessControlErrors.add(false);

  if (sleepMillis > 0) {
    sleep(sleepMillis / 1000);
  }
}
