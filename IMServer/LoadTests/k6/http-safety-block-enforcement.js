import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'safety-block-enforcement-smoke';
const profiles = {
  'safety-block-enforcement-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_safety_block_enforcement_errors: ['rate<0.001'],
      im_safety_block_enforcement_block_latency: ['p(95)<500', 'p(99)<1000'],
      im_safety_block_enforcement_reject_latency: ['p(95)<800', 'p(99)<1500'],
      im_safety_block_enforcement_unblock_latency: ['p(95)<500', 'p(99)<1000'],
      im_safety_block_enforcement_allowed_latency: ['p(95)<1200', 'p(99)<2500'],
      im_safety_block_enforcement_total_latency: ['p(95)<5000', 'p(99)<10000'],
    },
  },
  'safety-block-enforcement-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_safety_block_enforcement_errors: ['rate<0.001'],
      im_safety_block_enforcement_block_latency: ['p(95)<800', 'p(99)<1500'],
      im_safety_block_enforcement_reject_latency: ['p(95)<1200', 'p(99)<2500'],
      im_safety_block_enforcement_unblock_latency: ['p(95)<800', 'p(99)<1500'],
      im_safety_block_enforcement_allowed_latency: ['p(95)<2000', 'p(99)<5000'],
      im_safety_block_enforcement_total_latency: ['p(95)<10000', 'p(99)<20000'],
    },
  },
  'safety-block-enforcement-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_safety_block_enforcement_errors: ['rate<0.005'],
      im_safety_block_enforcement_block_latency: ['p(95)<1500', 'p(99)<3000'],
      im_safety_block_enforcement_reject_latency: ['p(95)<2500', 'p(99)<6000'],
      im_safety_block_enforcement_unblock_latency: ['p(95)<1500', 'p(99)<3000'],
      im_safety_block_enforcement_allowed_latency: ['p(95)<5000', 'p(99)<10000'],
      im_safety_block_enforcement_total_latency: ['p(95)<20000', 'p(99)<40000'],
    },
  },
};

export const options = profiles[profile] || profiles['safety-block-enforcement-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const defaultPeerEmail = __ENV.IM_BLOCKED_EMAIL || (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultPeerPassword = __ENV.IM_BLOCKED_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const sleepMillis = Number.parseInt(__ENV.IM_SAFETY_BLOCK_ENFORCEMENT_SLEEP_MS || '250', 10);

export const enforcementErrors = new Rate('im_safety_block_enforcement_errors');
export const blockLatency = new Trend('im_safety_block_enforcement_block_latency');
export const rejectLatency = new Trend('im_safety_block_enforcement_reject_latency');
export const unblockLatency = new Trend('im_safety_block_enforcement_unblock_latency');
export const allowedLatency = new Trend('im_safety_block_enforcement_allowed_latency');
export const totalLatency = new Trend('im_safety_block_enforcement_total_latency');

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
        deviceID: `k6-safety-enforce-${role}-${__VU}`,
        deviceName: `k6-safety-enforce-${role}`,
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'safety enforcement login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function ensureState() {
  if (perVUState) {
    return perVUState;
  }
  const pair = accountPairForVU();
  const ownerAuth = login(pair.owner, 'owner');
  const peerAuth = login(pair.peer, 'peer');
  perVUState = {
    ownerToken: ownerAuth.accessToken,
    ownerUserID: ownerAuth.user.id,
    ownerEmail: pair.owner.email,
    peerToken: peerAuth.accessToken,
    peerUserID: peerAuth.user.id,
    peerEmail: pair.peer.email,
  };
  return perVUState;
}

function blockUser(token, blockedUserID, reason) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/users/${blockedUserID}/block`,
    JSON.stringify({ reason }),
    jsonHeaders(token)
  );
  blockLatency.add(Date.now() - startedAt);
  check(res, { 'safety enforcement block ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function unblockUser(token, blockedUserID) {
  const startedAt = Date.now();
  const res = http.del(`${baseURL}/api/users/${blockedUserID}/block`, null, jsonHeaders(token));
  unblockLatency.add(Date.now() - startedAt);
  check(res, { 'safety enforcement unblock ok': (r) => r.status === 200 });
  return res.status === 200;
}

function createDirect(token, peerEmail, metric, expectedStatus, label) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'direct',
      title: null,
      memberEmails: [peerEmail],
    }),
    jsonHeaders(token)
  );
  metric.add(Date.now() - startedAt);
  check(res, { [`${label} status`]: (r) => r.status === expectedStatus });
  return res.status === expectedStatus ? res : null;
}

export default function () {
  const startedAt = Date.now();
  const state = ensureState();
  const reason = `enforce-${__VU}-${__ITER}-${Date.now()}`;

  if (!blockUser(state.ownerToken, state.peerUserID, reason)) {
    enforcementErrors.add(true);
    return;
  }
  if (!createDirect(state.ownerToken, state.peerEmail, rejectLatency, 403, 'blocked owner direct create rejected')) {
    enforcementErrors.add(true);
    return;
  }
  if (!unblockUser(state.ownerToken, state.peerUserID)) {
    enforcementErrors.add(true);
    return;
  }
  const allowed = createDirect(state.ownerToken, state.peerEmail, allowedLatency, 200, 'unblocked direct create allowed');
  if (!allowed || allowed.json('kind') !== 'direct') {
    enforcementErrors.add(true);
    return;
  }

  if (!blockUser(state.peerToken, state.ownerUserID, `${reason}-reverse`)) {
    enforcementErrors.add(true);
    return;
  }
  if (!createDirect(state.ownerToken, state.peerEmail, rejectLatency, 403, 'blocked peer direct create rejected')) {
    enforcementErrors.add(true);
    return;
  }
  if (!unblockUser(state.peerToken, state.ownerUserID)) {
    enforcementErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  enforcementErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
