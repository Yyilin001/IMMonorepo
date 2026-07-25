import http from 'k6/http';
import { richTextContent, initialDerivedState } from './im-message-payload.js';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'message-forward-smoke';
const profiles = {
  'message-forward-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_message_forward_errors: ['rate<0.001'],
      im_message_forward_seed_latency: ['p(95)<800', 'p(99)<1500'],
      im_message_forward_command_latency: ['p(95)<1000', 'p(99)<2500'],
      im_message_forward_timeline_latency: ['p(95)<2000', 'p(99)<5000'],
      im_message_forward_summary_latency: ['p(95)<3000', 'p(99)<7000'],
      im_message_forward_total_latency: ['p(95)<5000', 'p(99)<10000'],
    },
  },
  'message-forward-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_message_forward_errors: ['rate<0.001'],
      im_message_forward_seed_latency: ['p(95)<800', 'p(99)<2000'],
      im_message_forward_command_latency: ['p(95)<1500', 'p(99)<3000'],
      im_message_forward_timeline_latency: ['p(95)<3000', 'p(99)<7000'],
      im_message_forward_summary_latency: ['p(95)<5000', 'p(99)<10000'],
      im_message_forward_total_latency: ['p(95)<8000', 'p(99)<16000'],
    },
  },
  'message-forward-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_message_forward_errors: ['rate<0.005'],
      im_message_forward_seed_latency: ['p(95)<1500', 'p(99)<4000'],
      im_message_forward_command_latency: ['p(95)<3000', 'p(99)<7000'],
      im_message_forward_timeline_latency: ['p(95)<7000', 'p(99)<15000'],
      im_message_forward_summary_latency: ['p(95)<10000', 'p(99)<30000'],
      im_message_forward_total_latency: ['p(95)<15000', 'p(99)<45000'],
    },
  },
};

export const options = profiles[profile] || profiles['message-forward-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const commandBaseURL = (__ENV.IM_COMMAND_BASE_URL || baseURL).replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const fallbackMemberEmail = (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultMemberPassword = __ENV.IM_MEMBER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_MESSAGE_FORWARD_TIMEOUT_MS || '10000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_MESSAGE_FORWARD_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_MESSAGE_FORWARD_SLEEP_MS || '250', 10);

export const forwardErrors = new Rate('im_message_forward_errors');
export const seedLatency = new Trend('im_message_forward_seed_latency');
export const commandLatency = new Trend('im_message_forward_command_latency');
export const timelineLatency = new Trend('im_message_forward_timeline_latency');
export const summaryLatency = new Trend('im_message_forward_summary_latency');
export const totalLatency = new Trend('im_message_forward_total_latency');

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

function accountsForVU() {
  if (csvAccounts.length >= 2) {
    const start = (((__VU - 1) * 2) % csvAccounts.length);
    return {
      owner: csvAccounts[start],
      member: csvAccounts[(start + 1) % csvAccounts.length],
    };
  }
  return {
    owner: { email: defaultOwnerEmail, password: defaultOwnerPassword },
    member: { email: fallbackMemberEmail, password: defaultMemberPassword },
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
        deviceID: `k6-message-forward-${__VU}-${account.email}`,
        deviceName: 'k6-message-forward',
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'message-forward login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createConversation(token, memberEmail, title) {
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title,
      memberEmails: [memberEmail],
    }),
    jsonHeaders(token)
  );
  check(res, { 'message-forward create conversation ok': (r) => r.status === 200 });
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
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for message-forward checks.');
  }
  const accounts = accountsForVU();
  const ownerAuth = login(accounts.owner);
  const stamp = `${__VU}-${Date.now()}`;
  perVUState = {
    ownerToken: ownerAuth.accessToken,
    ownerUserID: ownerAuth.user.id,
    sourceConversationID: createConversation(ownerAuth.accessToken, accounts.member.email, `k6-forward-source-${stamp}`),
    targetConversationID: createConversation(ownerAuth.accessToken, accounts.member.email, `k6-forward-target-${stamp}`),
  };
  return perVUState;
}

function latestSummarySequence(token, conversationID) {
  const res = http.get(`${baseURL}/api/im/conversations?limit=100`, jsonHeaders(token));
  if (res.status !== 200) {
    return 0;
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  const summary = items.find((item) => item.id === conversationID);
  return Number(summary && summary.lastMessage ? summary.lastMessage.timelineSequence || 0 : 0);
}

function sendInternalMessage(senderUserID, conversationID, clientMessageID) {
  const startedAt = Date.now();
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
        content: richTextContent(`forward ${clientMessageID}`),
        derivedState: initialDerivedState(),
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  seedLatency.add(Date.now() - startedAt);
  check(res, { 'message-forward seed accepted': (r) => r.status === 200 });
  return res.status === 200 ? res.json('message') : null;
}

function forwardMessage(token, sourceConversationID, targetConversationID, messageID) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/conversations/${sourceConversationID}/messages/forward`,
    JSON.stringify({
      messageIDs: [messageID],
      targetConversationIDs: [targetConversationID],
    }),
    jsonHeaders(token)
  );
  commandLatency.add(Date.now() - startedAt);
  check(res, { 'message-forward command ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    return null;
  }
  const body = res.json();
  return Array.isArray(body) && body.length > 0 ? body[0] : null;
}

function findForwardedTimelineMessage(token, conversationID, forwardedMessageID, afterSequence) {
  const res = http.get(
    `${baseURL}/api/im/conversations/${conversationID}/timeline/since?afterSequence=${afterSequence}&limit=100`,
    jsonHeaders(token)
  );
  if (res.status !== 200) {
    return false;
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  return items.some((item) => item.message && item.message.id === forwardedMessageID);
}

function summaryHasForwardedMessage(token, conversationID, forwardedMessageID, serverSequence) {
  const res = http.get(`${baseURL}/api/im/conversations?limit=100`, jsonHeaders(token));
  if (res.status !== 200) {
    return false;
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  return items.some((item) => (
    item.id === conversationID
    && item.lastMessage
    && item.lastMessage.id === forwardedMessageID
    && Number(item.lastMessage.serverSequence || 0) >= Number(serverSequence || 0)
  ));
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
  const state = ensureState();
  const startedAt = Date.now();
  const clientMessageID = `k6-forward-${__VU}-${__ITER}-${Date.now()}`;
  const targetPreviousSequence = latestSummarySequence(state.ownerToken, state.targetConversationID);
  const sourceMessage = sendInternalMessage(state.ownerUserID, state.sourceConversationID, clientMessageID);
  if (!sourceMessage || !sourceMessage.id) {
    forwardErrors.add(true);
    return;
  }

  const forwarded = forwardMessage(
    state.ownerToken,
    state.sourceConversationID,
    state.targetConversationID,
    sourceMessage.id
  );
  if (!forwarded || !forwarded.id) {
    forwardErrors.add(true);
    return;
  }

  const deadline = startedAt + pollTimeoutMillis;
  const timelineOK = pollUntil(
    deadline,
    () => findForwardedTimelineMessage(
      state.ownerToken,
      state.targetConversationID,
      forwarded.id,
      targetPreviousSequence
    )
  );
  if (!timelineOK) {
    forwardErrors.add(true);
    return;
  }
  timelineLatency.add(Date.now() - startedAt);

  const summaryOK = pollUntil(
    deadline,
    () => summaryHasForwardedMessage(
      state.ownerToken,
      state.targetConversationID,
      forwarded.id,
      forwarded.serverSequence
    )
  );
  if (!summaryOK) {
    forwardErrors.add(true);
    return;
  }
  summaryLatency.add(Date.now() - startedAt);
  totalLatency.add(Date.now() - startedAt);
  forwardErrors.add(false);

  if (sleepMillis > 0) {
    sleep(sleepMillis / 1000);
  }
}
