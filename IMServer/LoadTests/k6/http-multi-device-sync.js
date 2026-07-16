import http from 'k6/http';
import { richTextContent, initialDerivedState } from './im-message-payload.js';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'multi-device-sync-smoke';
const profiles = {
  'multi-device-sync-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_multi_device_sync_errors: ['rate<0.001'],
      im_multi_device_timeline_latency: ['p(95)<1500', 'p(99)<3000'],
      im_multi_device_summary_latency: ['p(95)<2500', 'p(99)<5000'],
      im_multi_device_read_clear_latency: ['p(95)<2500', 'p(99)<5000'],
      im_multi_device_changes_latency: ['p(95)<2500', 'p(99)<5000'],
      im_multi_device_total_latency: ['p(95)<6000', 'p(99)<12000'],
    },
  },
  'multi-device-sync-baseline': {
    vus: 200,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_multi_device_sync_errors: ['rate<0.001'],
      im_multi_device_timeline_latency: ['p(95)<2000', 'p(99)<5000'],
      im_multi_device_summary_latency: ['p(95)<3500', 'p(99)<7000'],
      im_multi_device_read_clear_latency: ['p(95)<3500', 'p(99)<7000'],
      im_multi_device_changes_latency: ['p(95)<3500', 'p(99)<7000'],
      im_multi_device_total_latency: ['p(95)<8000', 'p(99)<16000'],
    },
  },
  'multi-device-sync-capacity': {
    vus: 1000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_multi_device_sync_errors: ['rate<0.005'],
      im_multi_device_timeline_latency: ['p(95)<4000', 'p(99)<8000'],
      im_multi_device_summary_latency: ['p(95)<7000', 'p(99)<15000'],
      im_multi_device_read_clear_latency: ['p(95)<7000', 'p(99)<15000'],
      im_multi_device_changes_latency: ['p(95)<7000', 'p(99)<15000'],
      im_multi_device_total_latency: ['p(95)<15000', 'p(99)<30000'],
    },
  },
};

export const options = profiles[profile] || profiles['multi-device-sync-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const defaultPeerEmail = __ENV.IM_MEMBER_EMAILS ? __ENV.IM_MEMBER_EMAILS.split(',')[0].trim() : 'alice@example.com';
const defaultPeerPassword = __ENV.IM_PEER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_MULTI_DEVICE_SYNC_TIMEOUT_MS || '12000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_MULTI_DEVICE_SYNC_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_MULTI_DEVICE_SYNC_SLEEP_MS || '250', 10);

export const syncErrors = new Rate('im_multi_device_sync_errors');
export const timelineLatency = new Trend('im_multi_device_timeline_latency');
export const summaryLatency = new Trend('im_multi_device_summary_latency');
export const readClearLatency = new Trend('im_multi_device_read_clear_latency');
export const changesLatency = new Trend('im_multi_device_changes_latency');
export const totalLatency = new Trend('im_multi_device_total_latency');

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
let state = null;

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
  check(res, { 'multi-device login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createConversation(ownerToken, peerEmail) {
  if (__ENV.IM_CONVERSATION_ID) {
    return __ENV.IM_CONVERSATION_ID;
  }
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title: `k6-multi-device-${__VU}-${Date.now()}`,
      memberEmails: [peerEmail],
    }),
    jsonHeaders(ownerToken)
  );
  check(res, { 'multi-device create conversation ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`create conversation failed: ${res.status} ${res.body}`);
  }
  return res.json('id');
}

function ensureState() {
  if (state) {
    return state;
  }
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for multi-device sync checks.');
  }

  const pair = accountPairForVU();
  const ownerA = login(pair.owner, `k6-md-owner-a-${__VU}`);
  const ownerB = login(pair.owner, `k6-md-owner-b-${__VU}`);
  const peer = login(pair.peer, `k6-md-peer-${__VU}`);
  const conversationID = createConversation(ownerA.accessToken, pair.peer.email);

  state = {
    ownerAToken: ownerA.accessToken,
    ownerBToken: ownerB.accessToken,
    peerUserID: peer.user.id,
    conversationID,
  };
  return state;
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

function sendInternalMessage(peerUserID, conversationID, clientMessageID) {
  const res = http.post(
    `${baseURL}/internal/im/messages/send`,
    JSON.stringify({
      senderUserID: peerUserID,
      payload: {
        clientMessageID,
        messageID: null,
        conversationID,
        senderUserID: null,
        serverSequence: null,
        serverTimestamp: null,
        content: richTextContent(`multi-device ${clientMessageID}`),
        derivedState: initialDerivedState(),
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  check(res, { 'multi-device seed message accepted': (r) => r.status === 200 });
  return res.status === 200 ? res.json('message') : null;
}

function findTimelineMessage(token, conversationID, clientMessageID, afterSequence) {
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
    if (message && message.clientMessageID === clientMessageID) {
      return message;
    }
  }
  return null;
}

function markRead(token, conversationID, readSequence) {
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/read`,
    JSON.stringify({ readSequence }),
    jsonHeaders(token)
  );
  check(res, { 'multi-device mark read ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function changesContainReadClear(token, conversationID, baselineToken, serverSequence) {
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
  const upserts = Array.isArray(body.upserts) ? body.upserts : [];
  return upserts.some((item) => (
    item.id === conversationID
    && Number(item.lastReadSequence || 0) >= Number(serverSequence || 0)
    && Number(item.unreadCount || 0) === 0
  ));
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
  const current = ensureState();
  const startedAt = Date.now();
  const baselineA = listSummary(current.ownerAToken, current.conversationID);
  const baselineB = listSummary(current.ownerBToken, current.conversationID);
  const previousSequence = Number(
    baselineA.summary && baselineA.summary.lastMessage ? baselineA.summary.lastMessage.serverSequence || 0 : 0
  );
  const clientMessageID = `k6-multi-device-${__VU}-${__ITER}-${Date.now()}`;
  const message = sendInternalMessage(current.peerUserID, current.conversationID, clientMessageID);
  if (!message || !message.serverSequence) {
    syncErrors.add(true);
    return;
  }

  const deadline = startedAt + pollTimeoutMillis;
  const timelineA = pollUntil(
    deadline,
    () => findTimelineMessage(current.ownerAToken, current.conversationID, clientMessageID, previousSequence)
  );
  const timelineB = pollUntil(
    deadline,
    () => findTimelineMessage(current.ownerBToken, current.conversationID, clientMessageID, previousSequence)
  );
  if (!timelineA || !timelineB) {
    syncErrors.add(true);
    return;
  }
  timelineLatency.add(Date.now() - startedAt);

  const summaryVisible = pollUntil(deadline, () => {
    const summaryA = listSummary(current.ownerAToken, current.conversationID).summary;
    const summaryB = listSummary(current.ownerBToken, current.conversationID).summary;
    if (
      summaryA
      && summaryB
      && summaryA.lastMessage
      && summaryB.lastMessage
      && Number(summaryA.lastMessage.serverSequence || 0) >= Number(message.serverSequence)
      && Number(summaryB.lastMessage.serverSequence || 0) >= Number(message.serverSequence)
      && Number(summaryA.unreadCount || 0) > 0
      && Number(summaryB.unreadCount || 0) > 0
    ) {
      return true;
    }
    return false;
  });
  if (!summaryVisible) {
    syncErrors.add(true);
    return;
  }
  summaryLatency.add(Date.now() - startedAt);

  const readStartedAt = Date.now();
  const readResponse = markRead(current.ownerBToken, current.conversationID, message.serverSequence);
  if (
    !readResponse
    || Number(readResponse.lastReadSequence || 0) < Number(message.serverSequence)
    || Number(readResponse.unreadCount || 0) !== 0
  ) {
    syncErrors.add(true);
    return;
  }

  const deviceACleared = pollUntil(deadline, () => {
    const summaryA = listSummary(current.ownerAToken, current.conversationID).summary;
    return summaryA
      && Number(summaryA.lastReadSequence || 0) >= Number(message.serverSequence)
      && Number(summaryA.unreadCount || 0) === 0;
  });
  if (!deviceACleared) {
    syncErrors.add(true);
    return;
  }
  readClearLatency.add(Date.now() - readStartedAt);

  const changesStartedAt = Date.now();
  const changesVisible = pollUntil(
    deadline,
    () => changesContainReadClear(
      current.ownerAToken,
      current.conversationID,
      baselineA.snapshotToken || baselineB.snapshotToken,
      message.serverSequence
    )
  );
  if (!changesVisible) {
    syncErrors.add(true);
    return;
  }
  changesLatency.add(Date.now() - changesStartedAt);

  totalLatency.add(Date.now() - startedAt);
  syncErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
