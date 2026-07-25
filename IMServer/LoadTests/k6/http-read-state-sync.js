import http from 'k6/http';
import { richTextContent, initialDerivedState } from './im-message-payload.js';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'read-state-smoke';
const profiles = {
  'read-state-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_read_state_errors: ['rate<0.001'],
      im_read_state_timeline_latency: ['p(95)<1500', 'p(99)<3000'],
      im_read_state_unread_latency: ['p(95)<2000', 'p(99)<5000'],
      im_read_state_mark_read_latency: ['p(95)<500', 'p(99)<1000'],
      im_read_state_clear_latency: ['p(95)<2000', 'p(99)<5000'],
      im_read_state_changes_latency: ['p(95)<2000', 'p(99)<5000'],
      im_read_state_total_latency: ['p(95)<5000', 'p(99)<10000'],
    },
  },
  'read-state-baseline': {
    vus: 200,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_read_state_errors: ['rate<0.001'],
      im_read_state_timeline_latency: ['p(95)<1500', 'p(99)<3000'],
      im_read_state_unread_latency: ['p(95)<2500', 'p(99)<5000'],
      im_read_state_mark_read_latency: ['p(95)<500', 'p(99)<1000'],
      im_read_state_clear_latency: ['p(95)<2500', 'p(99)<5000'],
      im_read_state_changes_latency: ['p(95)<2500', 'p(99)<5000'],
      im_read_state_total_latency: ['p(95)<6000', 'p(99)<12000'],
    },
  },
  'read-state-capacity': {
    vus: 1000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_read_state_errors: ['rate<0.005'],
      im_read_state_timeline_latency: ['p(95)<3000', 'p(99)<7000'],
      im_read_state_unread_latency: ['p(95)<5000', 'p(99)<10000'],
      im_read_state_mark_read_latency: ['p(95)<1000', 'p(99)<2500'],
      im_read_state_clear_latency: ['p(95)<5000', 'p(99)<10000'],
      im_read_state_changes_latency: ['p(95)<5000', 'p(99)<10000'],
      im_read_state_total_latency: ['p(95)<10000', 'p(99)<20000'],
    },
  },
};

export const options = profiles[profile] || profiles['read-state-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const commandBaseURL = (__ENV.IM_COMMAND_BASE_URL || baseURL).replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultReaderEmail = __ENV.IM_READER_EMAIL || __ENV.IM_EMAIL || 'demo@example.com';
const defaultReaderPassword = __ENV.IM_READER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const defaultSenderEmail = __ENV.IM_SENDER_EMAIL || (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultSenderPassword = __ENV.IM_SENDER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_READ_STATE_TIMEOUT_MS || '10000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_READ_STATE_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_READ_STATE_SLEEP_MS || '250', 10);

export const readStateErrors = new Rate('im_read_state_errors');
export const timelineLatency = new Trend('im_read_state_timeline_latency');
export const unreadLatency = new Trend('im_read_state_unread_latency');
export const markReadLatency = new Trend('im_read_state_mark_read_latency');
export const clearLatency = new Trend('im_read_state_clear_latency');
export const changesLatency = new Trend('im_read_state_changes_latency');
export const totalLatency = new Trend('im_read_state_total_latency');

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
    const readerIndex = (((__VU - 1) * 2) % csvAccounts.length);
    const senderIndex = (readerIndex + 1) % csvAccounts.length;
    return {
      reader: csvAccounts[readerIndex],
      sender: csvAccounts[senderIndex],
    };
  }
  return {
    reader: { email: defaultReaderEmail, password: defaultReaderPassword },
    sender: { email: defaultSenderEmail, password: defaultSenderPassword },
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
  check(res, { 'read-state login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createConversation(readerToken, senderEmail) {
  if (__ENV.IM_CONVERSATION_ID) {
    return __ENV.IM_CONVERSATION_ID;
  }
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title: `k6-read-state-${__VU}-${Date.now()}`,
      memberEmails: [senderEmail],
    }),
    jsonHeaders(readerToken)
  );
  check(res, { 'read-state create conversation ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`create conversation failed: ${res.status} ${res.body}`);
  }
  return res.json('id');
}

function ensureState() {
  if (perVUState) {
    return perVUState;
  }
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for read-state sync checks.');
  }
  const pair = accountPairForVU();
  const readerAuth = login(pair.reader, `k6-read-reader-${__VU}`);
  const senderAuth = login(pair.sender, `k6-read-sender-${__VU}`);
  const conversationID = createConversation(readerAuth.accessToken, pair.sender.email);
  perVUState = {
    readerToken: readerAuth.accessToken,
    senderUserID: senderAuth.user.id,
    conversationID,
  };
  return perVUState;
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

function sendInternalMessage(senderUserID, conversationID, clientMessageID) {
  const res = http.post(
    `${commandBaseURL}/internal/im/messages/send`,
    JSON.stringify({
      senderUserID,
      payload: {
        clientMessageID,
        messageID: null,
        conversationID,
        senderUserID: null,
        serverSequence: null,
        serverTimestamp: null,
        content: richTextContent(`read-state ${clientMessageID}`),
        derivedState: initialDerivedState(),
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  check(res, { 'read-state seed message accepted': (r) => r.status === 200 });
  if (res.status !== 200) {
    return null;
  }
  return res.json('message');
}

function findTimelineMessage(token, conversationID, clientMessageID, afterSequence) {
  const res = http.get(
    `${baseURL}/api/im/conversations/${conversationID}/timeline/since?afterSequence=${afterSequence}&limit=100`,
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

function markRead(token, conversationID, readSequence) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${conversationID}/read`,
    JSON.stringify({ readSequence }),
    jsonHeaders(token)
  );
  markReadLatency.add(Date.now() - startedAt);
  check(res, { 'mark read ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function changesContainClearedRead(token, conversationID, baselineToken, serverSequence) {
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

export default function () {
  const state = ensureState();
  const startedAt = Date.now();
  const baseline = listSummary(state.readerToken, state.conversationID);
  const previousSequence = Number(
    baseline.summary && baseline.summary.lastMessage ? baseline.summary.lastMessage.timelineSequence || 0 : 0
  );
  const clientMessageID = `k6-read-state-${__VU}-${__ITER}-${Date.now()}`;
  const message = sendInternalMessage(state.senderUserID, state.conversationID, clientMessageID);
  if (!message || !message.serverSequence) {
    readStateErrors.add(true);
    return;
  }

  const deadline = startedAt + pollTimeoutMillis;
  const timelineMessage = pollUntil(
    deadline,
    () => findTimelineMessage(state.readerToken, state.conversationID, clientMessageID, previousSequence)
  );
  if (!timelineMessage) {
    readStateErrors.add(true);
    return;
  }
  timelineLatency.add(Date.now() - startedAt);

  const unreadSummary = pollUntil(deadline, () => {
    const current = listSummary(state.readerToken, state.conversationID);
    if (
      current.summary
      && current.summary.lastMessage
      && Number(current.summary.lastMessage.serverSequence || 0) >= Number(message.serverSequence)
      && Number(current.summary.unreadCount || 0) > 0
    ) {
      return current.summary;
    }
    return null;
  });
  if (!unreadSummary) {
    readStateErrors.add(true);
    return;
  }
  unreadLatency.add(Date.now() - startedAt);

  const readResponse = markRead(state.readerToken, state.conversationID, message.serverSequence);
  if (
    !readResponse
    || Number(readResponse.lastReadSequence || 0) < Number(message.serverSequence)
    || Number(readResponse.unreadCount || 0) !== 0
  ) {
    readStateErrors.add(true);
    return;
  }

  const clearedSummary = pollUntil(deadline, () => {
    const current = listSummary(state.readerToken, state.conversationID);
    if (
      current.summary
      && Number(current.summary.lastReadSequence || 0) >= Number(message.serverSequence)
      && Number(current.summary.unreadCount || 0) === 0
    ) {
      return current.summary;
    }
    return null;
  });
  if (!clearedSummary) {
    readStateErrors.add(true);
    return;
  }
  clearLatency.add(Date.now() - startedAt);

  const changesStartedAt = Date.now();
  const changesVisible = pollUntil(
    deadline,
    () => changesContainClearedRead(
      state.readerToken,
      state.conversationID,
      baseline.snapshotToken,
      message.serverSequence
    )
  );
  if (!changesVisible) {
    readStateErrors.add(true);
    return;
  }
  changesLatency.add(Date.now() - changesStartedAt);

  totalLatency.add(Date.now() - startedAt);
  readStateErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
