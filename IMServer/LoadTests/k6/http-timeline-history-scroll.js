import http from 'k6/http';
import { richTextContent, initialDerivedState } from './im-message-payload.js';
import { check, fail, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'timeline-history-scroll-smoke';
const profiles = {
  'timeline-history-scroll-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_timeline_history_scroll_errors: ['rate<0.001'],
      im_timeline_history_scroll_total_latency: ['p(95)<5000', 'p(99)<10000'],
      im_timeline_history_scroll_latest_latency: ['p(95)<1000', 'p(99)<2500'],
      im_timeline_history_scroll_page_latency: ['p(95)<1500', 'p(99)<3000'],
      im_timeline_history_scroll_repeat_latency: ['p(95)<1500', 'p(99)<3000'],
      im_timeline_history_scroll_since_latency: ['p(95)<1500', 'p(99)<3000'],
    },
  },
  'timeline-history-scroll-baseline': {
    vus: 200,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_timeline_history_scroll_errors: ['rate<0.001'],
      im_timeline_history_scroll_total_latency: ['p(95)<8000', 'p(99)<16000'],
      im_timeline_history_scroll_latest_latency: ['p(95)<1500', 'p(99)<3500'],
      im_timeline_history_scroll_page_latency: ['p(95)<2500', 'p(99)<5000'],
      im_timeline_history_scroll_repeat_latency: ['p(95)<2500', 'p(99)<5000'],
      im_timeline_history_scroll_since_latency: ['p(95)<2500', 'p(99)<5000'],
    },
  },
  'timeline-history-scroll-capacity': {
    vus: 1000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_timeline_history_scroll_errors: ['rate<0.005'],
      im_timeline_history_scroll_total_latency: ['p(95)<15000', 'p(99)<30000'],
      im_timeline_history_scroll_latest_latency: ['p(95)<3000', 'p(99)<7000'],
      im_timeline_history_scroll_page_latency: ['p(95)<5000', 'p(99)<12000'],
      im_timeline_history_scroll_repeat_latency: ['p(95)<5000', 'p(99)<12000'],
      im_timeline_history_scroll_since_latency: ['p(95)<5000', 'p(99)<12000'],
    },
  },
};

export const options = profiles[profile] || profiles['timeline-history-scroll-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const defaultMemberEmail = (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultMemberPassword = __ENV.IM_MEMBER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const seedMessageCount = Number.parseInt(__ENV.IM_HISTORY_SCROLL_SEED_MESSAGES || '80', 10);
const pageLimit = Number.parseInt(__ENV.IM_HISTORY_SCROLL_PAGE_LIMIT || '12', 10);
const pageCount = Number.parseInt(__ENV.IM_HISTORY_SCROLL_PAGE_COUNT || '4', 10);
const sinceWindow = Number.parseInt(__ENV.IM_HISTORY_SCROLL_SINCE_WINDOW || '8', 10);
const pollTimeoutMillis = Number.parseInt(__ENV.IM_HISTORY_SCROLL_TIMEOUT_MS || '15000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_HISTORY_SCROLL_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_HISTORY_SCROLL_SLEEP_MS || '250', 10);

export const scrollErrors = new Rate('im_timeline_history_scroll_errors');
export const totalLatency = new Trend('im_timeline_history_scroll_total_latency');
export const latestLatency = new Trend('im_timeline_history_scroll_latest_latency');
export const pageLatency = new Trend('im_timeline_history_scroll_page_latency');
export const repeatLatency = new Trend('im_timeline_history_scroll_repeat_latency');
export const sinceLatency = new Trend('im_timeline_history_scroll_since_latency');
export const scrollOK = new Counter('im_timeline_history_scroll_ok_total');

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

function accountPair() {
  if (csvAccounts.length >= 2) {
    return {
      owner: csvAccounts[0],
      member: csvAccounts[1],
    };
  }
  return {
    owner: { email: defaultOwnerEmail, password: defaultOwnerPassword },
    member: { email: defaultMemberEmail, password: defaultMemberPassword },
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
  check(res, { 'history scroll login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createConversation(token, memberEmail) {
  if (__ENV.IM_CONVERSATION_ID) {
    return __ENV.IM_CONVERSATION_ID;
  }
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title: `k6-history-scroll-${Date.now()}`,
      memberEmails: [memberEmail],
    }),
    jsonHeaders(token)
  );
  check(res, { 'history scroll create conversation ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`create conversation failed: ${res.status} ${res.body}`);
  }
  return res.json('id');
}

function sendInternalMessage(senderUserID, conversationID, index) {
  const clientMessageID = `k6-history-scroll-${index}-${Date.now()}`;
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
        content: richTextContent(`history scroll ${index}`),
        derivedState: initialDerivedState(),
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  check(res, { 'history scroll seed accepted': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`seed message failed: ${res.status} ${res.body}`);
  }
  return res.json('message');
}

function pageItems(res) {
  if (res.status !== 200) {
    return [];
  }
  const body = res.json();
  return Array.isArray(body.items) ? body.items : [];
}

function sequenceOf(item) {
  return Number(item.timelineSequence || (item.message && item.message.timelineSequence) || 0);
}

function messageIDs(items) {
  return items
    .map((item) => item.message && item.message.id)
    .filter((id) => id);
}

function sequences(items) {
  return items.map(sequenceOf).filter((sequence) => sequence > 0);
}

function isStrictlyIncreasing(values) {
  for (let index = 1; index < values.length; index += 1) {
    if (values[index] <= values[index - 1]) {
      return false;
    }
  }
  return true;
}

function sameNumberList(lhs, rhs) {
  return lhs.length === rhs.length && lhs.every((value, index) => value === rhs[index]);
}

function fetchTimeline(token, conversationID, query, metric, label) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/im/conversations/${conversationID}/timeline${query}`, jsonHeaders(token));
  metric.add(Date.now() - startedAt);
  check(res, { [`${label} ok`]: (r) => r.status === 200 });
  return res;
}

function fetchSince(token, conversationID, afterSequence, targetSequence) {
  const startedAt = Date.now();
  const res = http.get(
    `${baseURL}/api/im/conversations/${conversationID}/timeline/since?afterSequence=${afterSequence}&targetSequence=${targetSequence}&limit=${Math.max(sinceWindow * 2, pageLimit)}`,
    jsonHeaders(token)
  );
  sinceLatency.add(Date.now() - startedAt);
  check(res, { 'history scroll since ok': (r) => r.status === 200 });
  return res;
}

function waitForLatestMessage(token, conversationID, clientMessageID) {
  const deadline = Date.now() + pollTimeoutMillis;
  while (Date.now() < deadline) {
    const res = http.get(`${baseURL}/api/im/conversations/${conversationID}/timeline?limit=${pageLimit}`, jsonHeaders(token));
    if (res.status === 200) {
      const items = pageItems(res);
      if (items.some((item) => item.message && item.message.clientMessageID === clientMessageID)) {
        return;
      }
    }
    sleep(Math.max(0.05, pollIntervalMillis / 1000));
  }
  fail(`latest seeded message did not appear within ${pollTimeoutMillis}ms`);
}

export function setup() {
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for history scroll checks.');
  }
  const accounts = accountPair();
  const ownerAuth = login(accounts.owner, 'k6-history-scroll-owner');
  const conversationID = createConversation(ownerAuth.accessToken, accounts.member.email);
  const count = Math.max(seedMessageCount, (pageLimit * pageCount) + sinceWindow + 1);
  const seeded = [];
  for (let index = 0; index < count; index += 1) {
    seeded.push(sendInternalMessage(ownerAuth.user.id, conversationID, index));
  }
  const last = seeded[seeded.length - 1];
  waitForLatestMessage(ownerAuth.accessToken, conversationID, last.clientMessageID);
  return {
    token: ownerAuth.accessToken,
    conversationID,
    latestTimelineSequence: Number(last.timelineSequence || 0),
  };
}

export default function (data) {
  const startedAt = Date.now();
  let failed = false;
  const seenSequences = new Set();
  const seenMessageIDs = new Set();

  const latest = fetchTimeline(data.token, data.conversationID, `?limit=${pageLimit}`, latestLatency, 'history scroll latest');
  const latestItems = pageItems(latest);
  const latestSequences = sequences(latestItems);
  failed = failed || latest.status !== 200 || latestSequences.length === 0 || !isStrictlyIncreasing(latestSequences);

  let beforeSequence = latestSequences.length > 0 ? latestSequences[0] : 0;
  for (const sequence of latestSequences) {
    if (seenSequences.has(sequence)) {
      failed = true;
    }
    seenSequences.add(sequence);
  }
  for (const id of messageIDs(latestItems)) {
    if (seenMessageIDs.has(id)) {
      failed = true;
    }
    seenMessageIDs.add(id);
  }

  for (let page = 0; page < pageCount; page += 1) {
    if (beforeSequence <= 1) {
      failed = true;
      break;
    }
    const history = fetchTimeline(
      data.token,
      data.conversationID,
      `?beforeSequence=${beforeSequence}&limit=${pageLimit}`,
      pageLatency,
      'history scroll page'
    );
    const items = pageItems(history);
    const seqs = sequences(items);
    failed = failed || history.status !== 200 || seqs.length === 0 || !isStrictlyIncreasing(seqs);
    failed = failed || seqs.some((sequence) => sequence >= beforeSequence);

    const repeat = fetchTimeline(
      data.token,
      data.conversationID,
      `?beforeSequence=${beforeSequence}&limit=${pageLimit}`,
      repeatLatency,
      'history scroll repeat page'
    );
    failed = failed || !sameNumberList(seqs, sequences(pageItems(repeat)));

    for (const sequence of seqs) {
      if (seenSequences.has(sequence)) {
        failed = true;
      }
      seenSequences.add(sequence);
    }
    for (const id of messageIDs(items)) {
      if (seenMessageIDs.has(id)) {
        failed = true;
      }
      seenMessageIDs.add(id);
    }
    beforeSequence = seqs[0] || beforeSequence;
  }

  const targetSequence = Number(data.latestTimelineSequence || Math.max(...Array.from(seenSequences)));
  const afterSequence = Math.max(0, targetSequence - Math.max(1, sinceWindow));
  const since = fetchSince(data.token, data.conversationID, afterSequence, targetSequence);
  const sinceSequences = sequences(pageItems(since));
  failed = failed
    || since.status !== 200
    || sinceSequences.length === 0
    || !isStrictlyIncreasing(sinceSequences)
    || !sinceSequences.some((sequence) => sequence >= targetSequence)
    || sinceSequences.some((sequence) => sequence <= afterSequence);

  totalLatency.add(Date.now() - startedAt);
  scrollErrors.add(failed);
  if (!failed) {
    scrollOK.add(1);
  }
  sleep(Math.max(0, sleepMillis) / 1000);
}
