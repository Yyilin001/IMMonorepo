import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'safety-block-smoke';
const profiles = {
  'safety-block-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_safety_block_errors: ['rate<0.001'],
      im_safety_block_latency: ['p(95)<500', 'p(99)<1000'],
      im_safety_blocks_list_latency: ['p(95)<500', 'p(99)<1000'],
      im_safety_report_latency: ['p(95)<1000', 'p(99)<2000'],
      im_safety_unblock_latency: ['p(95)<500', 'p(99)<1000'],
      im_safety_total_latency: ['p(95)<3000', 'p(99)<6000'],
    },
  },
  'safety-block-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_safety_block_errors: ['rate<0.001'],
      im_safety_block_latency: ['p(95)<800', 'p(99)<1500'],
      im_safety_blocks_list_latency: ['p(95)<800', 'p(99)<1500'],
      im_safety_report_latency: ['p(95)<1500', 'p(99)<3000'],
      im_safety_unblock_latency: ['p(95)<800', 'p(99)<1500'],
      im_safety_total_latency: ['p(95)<6000', 'p(99)<12000'],
    },
  },
  'safety-block-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_safety_block_errors: ['rate<0.005'],
      im_safety_block_latency: ['p(95)<1500', 'p(99)<3000'],
      im_safety_blocks_list_latency: ['p(95)<1500', 'p(99)<3000'],
      im_safety_report_latency: ['p(95)<3000', 'p(99)<6000'],
      im_safety_unblock_latency: ['p(95)<1500', 'p(99)<3000'],
      im_safety_total_latency: ['p(95)<15000', 'p(99)<30000'],
    },
  },
};

export const options = profiles[profile] || profiles['safety-block-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const defaultBlockedEmail = __ENV.IM_BLOCKED_EMAIL || (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultBlockedPassword = __ENV.IM_BLOCKED_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const sleepMillis = Number.parseInt(__ENV.IM_SAFETY_BLOCK_SLEEP_MS || '250', 10);

export const safetyBlockErrors = new Rate('im_safety_block_errors');
export const blockLatency = new Trend('im_safety_block_latency');
export const blocksListLatency = new Trend('im_safety_blocks_list_latency');
export const reportLatency = new Trend('im_safety_report_latency');
export const unblockLatency = new Trend('im_safety_unblock_latency');
export const totalLatency = new Trend('im_safety_total_latency');

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

function accountPairForVU() {
  if (csvAccounts.length >= 2) {
    const ownerIndex = (((__VU - 1) * 2) % csvAccounts.length);
    return {
      owner: csvAccounts[ownerIndex],
      blocked: csvAccounts[(ownerIndex + 1) % csvAccounts.length],
    };
  }
  return {
    owner: { email: defaultOwnerEmail, password: defaultOwnerPassword },
    blocked: { email: defaultBlockedEmail, password: defaultBlockedPassword },
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
        deviceID: `k6-safety-${role}-${__VU}`,
        deviceName: `k6-safety-${role}`,
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'safety login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function blockUser(token, blockedUserID, reason) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/users/${blockedUserID}/block`,
    JSON.stringify({ reason }),
    jsonHeaders(token)
  );
  blockLatency.add(Date.now() - startedAt);
  check(res, { 'block ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function listBlocks(token) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/blocks`, jsonHeaders(token));
  blocksListLatency.add(Date.now() - startedAt);
  if (res.status !== 200) {
    return null;
  }
  return res.json();
}

function createReport(token, targetUserID, reason) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/reports`,
    JSON.stringify({
      targetType: 'user',
      targetID: targetUserID,
      conversationID: null,
      messageID: null,
      reason,
      detail: `k6 safety report ${__VU}/${__ITER}`,
    }),
    jsonHeaders(token)
  );
  reportLatency.add(Date.now() - startedAt);
  check(res, { 'report ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function unblockUser(token, blockedUserID) {
  const startedAt = Date.now();
  const res = http.del(`${baseURL}/api/users/${blockedUserID}/block`, null, jsonHeaders(token));
  unblockLatency.add(Date.now() - startedAt);
  check(res, { 'unblock ok': (r) => r.status === 200 });
  return res.status === 200;
}

function containsBlock(blocks, blockedUserID) {
  return Array.isArray(blocks) && blocks.some((item) => item.blockedUserID === blockedUserID);
}

export default function () {
  const startedAt = Date.now();
  const pair = accountPairForVU();
  const ownerAuth = login(pair.owner, 'owner');
  const blockedAuth = login(pair.blocked, 'blocked');
  const reason = `safety-${__VU}-${__ITER}`;

  const block = blockUser(ownerAuth.accessToken, blockedAuth.user.id, reason);
  if (!block || block.blockedUserID !== blockedAuth.user.id || block.reason !== reason) {
    safetyBlockErrors.add(true);
    return;
  }

  const blocksAfterBlock = listBlocks(ownerAuth.accessToken);
  if (!containsBlock(blocksAfterBlock, blockedAuth.user.id)) {
    safetyBlockErrors.add(true);
    return;
  }

  const report = createReport(ownerAuth.accessToken, blockedAuth.user.id, reason);
  if (!report || report.targetType !== 'user' || report.targetID !== blockedAuth.user.id) {
    safetyBlockErrors.add(true);
    return;
  }

  if (!unblockUser(ownerAuth.accessToken, blockedAuth.user.id)) {
    safetyBlockErrors.add(true);
    return;
  }

  const blocksAfterUnblock = listBlocks(ownerAuth.accessToken);
  if (containsBlock(blocksAfterUnblock, blockedAuth.user.id)) {
    safetyBlockErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  safetyBlockErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
