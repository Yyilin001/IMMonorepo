import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'profile-sync-smoke';
const profiles = {
  'profile-sync-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_profile_sync_errors: ['rate<0.001'],
      im_profile_create_direct_latency: ['p(95)<1000', 'p(99)<2000'],
      im_profile_update_latency: ['p(95)<1000', 'p(99)<2000'],
      im_profile_changes_latency: ['p(95)<3000', 'p(99)<6000'],
      im_profile_total_latency: ['p(95)<6000', 'p(99)<12000'],
    },
  },
  'profile-sync-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_profile_sync_errors: ['rate<0.001'],
      im_profile_create_direct_latency: ['p(95)<1500', 'p(99)<3000'],
      im_profile_update_latency: ['p(95)<1000', 'p(99)<2500'],
      im_profile_changes_latency: ['p(95)<5000', 'p(99)<10000'],
      im_profile_total_latency: ['p(95)<10000', 'p(99)<20000'],
    },
  },
  'profile-sync-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_profile_sync_errors: ['rate<0.005'],
      im_profile_create_direct_latency: ['p(95)<3000', 'p(99)<6000'],
      im_profile_update_latency: ['p(95)<2000', 'p(99)<5000'],
      im_profile_changes_latency: ['p(95)<10000', 'p(99)<30000'],
      im_profile_total_latency: ['p(95)<20000', 'p(99)<60000'],
    },
  },
};

export const options = profiles[profile] || profiles['profile-sync-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const defaultPeerEmail = __ENV.IM_PROFILE_PEER_EMAIL || (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultPeerPassword = __ENV.IM_PROFILE_PEER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_PROFILE_SYNC_TIMEOUT_MS || '30000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_PROFILE_SYNC_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_PROFILE_SYNC_SLEEP_MS || '250', 10);

export const profileSyncErrors = new Rate('im_profile_sync_errors');
export const createDirectLatency = new Trend('im_profile_create_direct_latency');
export const updateLatency = new Trend('im_profile_update_latency');
export const changesLatency = new Trend('im_profile_changes_latency');
export const totalLatency = new Trend('im_profile_total_latency');

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
        deviceID: `k6-profile-${role}-${__VU}`,
        deviceName: `k6-profile-${role}`,
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'profile login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createDirectConversation(token, peerEmail) {
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
  createDirectLatency.add(Date.now() - startedAt);
  check(res, { 'profile create direct ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function listSummary(token, conversationID) {
  const res = http.get(`${baseURL}/api/im/conversations?limit=100`, jsonHeaders(token));
  if (res.status !== 200) {
    return { summary: null, snapshotToken: null };
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  return {
    summary: items.find((item) => item.id === conversationID) || null,
    snapshotToken: body.snapshotToken || null,
  };
}

function updateProfile(token, displayName) {
  const startedAt = Date.now();
  const res = http.patch(
    `${baseURL}/api/me/profile`,
    JSON.stringify({ displayName, avatarPreset: null }),
    jsonHeaders(token)
  );
  updateLatency.add(Date.now() - startedAt);
  check(res, { 'profile update ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function changesContainDirectPeer(token, conversationID, baselineToken, peerUserID, displayName) {
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
    && item.directPeer
    && item.directPeer.id === peerUserID
    && item.directPeer.displayName === displayName
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
  const pair = accountPairForVU();
  const ownerAuth = login(pair.owner, 'owner');
  const peerAuth = login(pair.peer, 'peer');
  const conversation = createDirectConversation(ownerAuth.accessToken, pair.peer.email);
  if (!conversation || !conversation.id || !conversation.directPeer) {
    profileSyncErrors.add(true);
    return;
  }

  const baseline = listSummary(ownerAuth.accessToken, conversation.id);
  if (!baseline.snapshotToken || !baseline.summary || !baseline.summary.directPeer) {
    profileSyncErrors.add(true);
    return;
  }

  const displayName = `profile-${__VU}-${__ITER}-${Date.now()}`;
  const updated = updateProfile(peerAuth.accessToken, displayName);
  if (!updated || updated.displayName !== displayName) {
    profileSyncErrors.add(true);
    return;
  }

  const visible = pollUntil(
    startedAt + pollTimeoutMillis,
    () => changesContainDirectPeer(
      ownerAuth.accessToken,
      conversation.id,
      baseline.snapshotToken,
      peerAuth.user.id,
      displayName
    )
  );
  if (!visible) {
    profileSyncErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  profileSyncErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
