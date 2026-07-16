import http from 'k6/http';
import { richTextContent, initialDerivedState } from './im-message-payload.js';
import { check, fail, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'direct-message-lifecycle-smoke';
const profiles = {
  'direct-message-lifecycle-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_direct_message_lifecycle_errors: ['rate<0.001'],
      im_direct_message_lifecycle_total_latency: ['p(95)<6000', 'p(99)<12000'],
      im_direct_message_lifecycle_send_latency: ['p(95)<500', 'p(99)<1000'],
      im_direct_message_lifecycle_timeline_latency: ['p(95)<1500', 'p(99)<3000'],
      im_direct_message_lifecycle_summary_latency: ['p(95)<2500', 'p(99)<5000'],
      im_direct_message_lifecycle_mark_read_latency: ['p(95)<500', 'p(99)<1000'],
      im_direct_message_lifecycle_changes_latency: ['p(95)<2000', 'p(99)<5000'],
    },
  },
  'direct-message-lifecycle-baseline': {
    vus: 200,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_direct_message_lifecycle_errors: ['rate<0.001'],
      im_direct_message_lifecycle_total_latency: ['p(95)<8000', 'p(99)<16000'],
      im_direct_message_lifecycle_send_latency: ['p(95)<800', 'p(99)<2000'],
      im_direct_message_lifecycle_timeline_latency: ['p(95)<2500', 'p(99)<5000'],
      im_direct_message_lifecycle_summary_latency: ['p(95)<3500', 'p(99)<7000'],
      im_direct_message_lifecycle_mark_read_latency: ['p(95)<800', 'p(99)<2000'],
      im_direct_message_lifecycle_changes_latency: ['p(95)<3000', 'p(99)<7000'],
    },
  },
  'direct-message-lifecycle-capacity': {
    vus: 1000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_direct_message_lifecycle_errors: ['rate<0.005'],
      im_direct_message_lifecycle_total_latency: ['p(95)<15000', 'p(99)<30000'],
      im_direct_message_lifecycle_send_latency: ['p(95)<1500', 'p(99)<4000'],
      im_direct_message_lifecycle_timeline_latency: ['p(95)<5000', 'p(99)<10000'],
      im_direct_message_lifecycle_summary_latency: ['p(95)<7000', 'p(99)<15000'],
      im_direct_message_lifecycle_mark_read_latency: ['p(95)<1500', 'p(99)<4000'],
      im_direct_message_lifecycle_changes_latency: ['p(95)<7000', 'p(99)<15000'],
    },
  },
};

export const options = profiles[profile] || profiles['direct-message-lifecycle-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_OWNER_EMAIL || __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_OWNER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const defaultPeerEmail = __ENV.IM_PEER_EMAIL || (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultPeerPassword = __ENV.IM_PEER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_DIRECT_LIFECYCLE_TIMEOUT_MS || '15000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_DIRECT_LIFECYCLE_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_DIRECT_LIFECYCLE_SLEEP_MS || '250', 10);

export const lifecycleErrors = new Rate('im_direct_message_lifecycle_errors');
export const createLatency = new Trend('im_direct_message_lifecycle_create_latency');
export const sendLatency = new Trend('im_direct_message_lifecycle_send_latency');
export const timelineLatency = new Trend('im_direct_message_lifecycle_timeline_latency');
export const summaryLatency = new Trend('im_direct_message_lifecycle_summary_latency');
export const markReadLatency = new Trend('im_direct_message_lifecycle_mark_read_latency');
export const changesLatency = new Trend('im_direct_message_lifecycle_changes_latency');
export const totalLatency = new Trend('im_direct_message_lifecycle_total_latency');
export const lifecycleOK = new Counter('im_direct_message_lifecycle_ok_total');

let perVUState = null;

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
    const peerIndex = (ownerIndex + 1) % csvAccounts.length;
    return {
      owner: csvAccounts[ownerIndex],
      peer: csvAccounts[peerIndex],
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

function login(account, deviceRole) {
  const deviceID = `k6-direct-lifecycle-${deviceRole}-${__VU}`;
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
  check(res, { 'direct lifecycle login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createDirectConversation(token, peerEmail) {
  if (__ENV.IM_CONVERSATION_ID) {
    return { id: __ENV.IM_CONVERSATION_ID };
  }
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
  createLatency.add(Date.now() - startedAt);
  check(res, { 'direct lifecycle create direct ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`create direct conversation failed: ${res.status} ${res.body}`);
  }
  return res.json();
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

function sendInternalMessage(senderUserID, conversationID, clientMessageID, text) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/internal/im/messages/send`,
    JSON.stringify({
      senderUserID,
      payload: {
        clientMessageID,
        messageID: null,
        conversationID,
        senderUserID: null,
        serverSequence: null,
        serverTimestamp: null,
        content: richTextContent(text),
        derivedState: initialDerivedState(),
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  sendLatency.add(Date.now() - startedAt);
  check(res, { 'direct lifecycle send accepted': (r) => r.status === 200 });
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
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/read`,
    JSON.stringify({ readSequence }),
    jsonHeaders(token)
  );
  markReadLatency.add(Date.now() - startedAt);
  check(res, { 'direct lifecycle mark read ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function changesContainReadClear(token, conversationID, baselineToken, serverSequence) {
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

function waitForSummary(token, conversationID, deadline) {
  return pollUntil(deadline, () => listSummary(token, conversationID).summary);
}

function ensureState() {
  if (perVUState) {
    return perVUState;
  }
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for direct message lifecycle checks.');
  }
  const pair = accountPairForVU();
  const ownerAuth = login(pair.owner, 'owner');
  const peerAuth = login(pair.peer, 'peer');
  const conversation = createDirectConversation(ownerAuth.accessToken, pair.peer.email);
  const deadline = Date.now() + pollTimeoutMillis;
  if (!waitForSummary(ownerAuth.accessToken, conversation.id, deadline)) {
    fail('direct lifecycle owner conversation summary did not appear after create.');
  }
  if (!waitForSummary(peerAuth.accessToken, conversation.id, deadline)) {
    fail('direct lifecycle peer conversation summary did not appear after create.');
  }
  perVUState = {
    ownerToken: ownerAuth.accessToken,
    ownerUserID: ownerAuth.user.id,
    peerToken: peerAuth.accessToken,
    peerUserID: peerAuth.user.id,
    conversationID: conversation.id,
  };
  return perVUState;
}

function exerciseOneDirection(state, sender, receiver, label, startedAt, deadline) {
  const receiverBaseline = listSummary(receiver.token, state.conversationID);
  const senderBaseline = listSummary(sender.token, state.conversationID);
  const previousSequence = Number(
    receiverBaseline.summary && receiverBaseline.summary.lastMessage
      ? receiverBaseline.summary.lastMessage.serverSequence || 0
      : 0
  );
  const clientMessageID = `k6-direct-lifecycle-${label}-${__VU}-${__ITER}-${Date.now()}`;
  const message = sendInternalMessage(
    sender.userID,
    state.conversationID,
    clientMessageID,
    `direct lifecycle ${label} ${clientMessageID}`
  );
  if (!message || !message.serverSequence) {
    return false;
  }

  const timelineMessage = pollUntil(
    deadline,
    () => findTimelineMessage(receiver.token, state.conversationID, clientMessageID, previousSequence)
  );
  if (!timelineMessage) {
    return false;
  }
  timelineLatency.add(Date.now() - startedAt);

  const summaryVisible = pollUntil(deadline, () => {
    const senderSummary = listSummary(sender.token, state.conversationID).summary;
    const receiverSummary = listSummary(receiver.token, state.conversationID).summary;
    if (
      senderSummary
      && receiverSummary
      && senderSummary.lastMessage
      && receiverSummary.lastMessage
      && Number(senderSummary.lastMessage.serverSequence || 0) >= Number(message.serverSequence)
      && Number(receiverSummary.lastMessage.serverSequence || 0) >= Number(message.serverSequence)
      && Number(receiverSummary.unreadCount || 0) > 0
    ) {
      return true;
    }
    return false;
  });
  if (!summaryVisible) {
    return false;
  }
  summaryLatency.add(Date.now() - startedAt);

  const readResponse = markRead(receiver.token, state.conversationID, message.serverSequence);
  if (
    !readResponse
    || Number(readResponse.lastReadSequence || 0) < Number(message.serverSequence)
    || Number(readResponse.unreadCount || 0) !== 0
  ) {
    return false;
  }

  const receiverCleared = pollUntil(deadline, () => {
    const summary = listSummary(receiver.token, state.conversationID).summary;
    return summary
      && Number(summary.lastReadSequence || 0) >= Number(message.serverSequence)
      && Number(summary.unreadCount || 0) === 0;
  });
  if (!receiverCleared) {
    return false;
  }

  return Boolean(pollUntil(
    deadline,
    () => changesContainReadClear(
      receiver.token,
      state.conversationID,
      receiverBaseline.snapshotToken || senderBaseline.snapshotToken,
      message.serverSequence
    )
  ));
}

export default function () {
  const state = ensureState();
  const startedAt = Date.now();
  const deadline = startedAt + pollTimeoutMillis;

  const owner = { token: state.ownerToken, userID: state.ownerUserID };
  const peer = { token: state.peerToken, userID: state.peerUserID };
  const ownerToPeer = exerciseOneDirection(state, owner, peer, 'owner-peer', startedAt, deadline);
  const peerToOwner = ownerToPeer
    ? exerciseOneDirection(state, peer, owner, 'peer-owner', startedAt, deadline)
    : false;

  const ok = ownerToPeer && peerToOwner;
  lifecycleErrors.add(!ok);
  if (ok) {
    lifecycleOK.add(1);
    totalLatency.add(Date.now() - startedAt);
  }
  sleep(Math.max(0, sleepMillis) / 1000);
}
