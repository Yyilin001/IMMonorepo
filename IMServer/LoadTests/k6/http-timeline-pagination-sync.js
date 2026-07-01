import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'timeline-pagination-smoke';
const profiles = {
  'timeline-pagination-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_timeline_pagination_errors: ['rate<0.001'],
      im_timeline_latest_latency: ['p(95)<1000', 'p(99)<2000'],
      im_timeline_history_page_latency: ['p(95)<1500', 'p(99)<3000'],
      im_timeline_since_catchup_latency: ['p(95)<1500', 'p(99)<3000'],
      im_timeline_conversation_list_latency: ['p(95)<1000', 'p(99)<2000'],
      im_timeline_member_search_latency: ['p(95)<1000', 'p(99)<2000'],
      im_timeline_pagination_total_latency: ['p(95)<4000', 'p(99)<8000'],
    },
  },
  'timeline-pagination-baseline': {
    vus: 200,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_timeline_pagination_errors: ['rate<0.001'],
      im_timeline_latest_latency: ['p(95)<1000', 'p(99)<2500'],
      im_timeline_history_page_latency: ['p(95)<2000', 'p(99)<5000'],
      im_timeline_since_catchup_latency: ['p(95)<2000', 'p(99)<5000'],
      im_timeline_conversation_list_latency: ['p(95)<1000', 'p(99)<2500'],
      im_timeline_member_search_latency: ['p(95)<1000', 'p(99)<2500'],
      im_timeline_pagination_total_latency: ['p(95)<6000', 'p(99)<12000'],
    },
  },
  'timeline-pagination-capacity': {
    vus: 1000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_timeline_pagination_errors: ['rate<0.005'],
      im_timeline_latest_latency: ['p(95)<2000', 'p(99)<5000'],
      im_timeline_history_page_latency: ['p(95)<4000', 'p(99)<10000'],
      im_timeline_since_catchup_latency: ['p(95)<4000', 'p(99)<10000'],
      im_timeline_conversation_list_latency: ['p(95)<2000', 'p(99)<5000'],
      im_timeline_member_search_latency: ['p(95)<2000', 'p(99)<5000'],
      im_timeline_pagination_total_latency: ['p(95)<10000', 'p(99)<20000'],
    },
  },
};

export const options = profiles[profile] || profiles['timeline-pagination-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const defaultMemberEmail = (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultMemberPassword = __ENV.IM_MEMBER_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const conversationKind = __ENV.IM_TIMELINE_CONVERSATION_KIND || 'group';
const seedMessageCount = Number.parseInt(__ENV.IM_TIMELINE_SEED_MESSAGES || '40', 10);
const pageLimit = Number.parseInt(__ENV.IM_TIMELINE_PAGE_LIMIT || '20', 10);
const sinceLimit = Number.parseInt(__ENV.IM_TIMELINE_SINCE_LIMIT || '50', 10);
const sinceWindow = Number.parseInt(__ENV.IM_TIMELINE_SINCE_WINDOW || '5', 10);
const listLimit = Number.parseInt(__ENV.IM_TIMELINE_CONVERSATION_LIST_LIMIT || '50', 10);
const memberLimit = Number.parseInt(__ENV.IM_TIMELINE_MEMBER_LIMIT || '50', 10);
const pollTimeoutMillis = Number.parseInt(__ENV.IM_TIMELINE_PAGINATION_TIMEOUT_MS || '10000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_TIMELINE_PAGINATION_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_TIMELINE_PAGINATION_SLEEP_MS || '250', 10);

export const paginationErrors = new Rate('im_timeline_pagination_errors');
export const latestLatency = new Trend('im_timeline_latest_latency');
export const historyPageLatency = new Trend('im_timeline_history_page_latency');
export const sinceCatchupLatency = new Trend('im_timeline_since_catchup_latency');
export const conversationListLatency = new Trend('im_timeline_conversation_list_latency');
export const memberSearchLatency = new Trend('im_timeline_member_search_latency');
export const totalLatency = new Trend('im_timeline_pagination_total_latency');

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
  check(res, { 'timeline pagination login ok': (r) => r.status === 200 });
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
      kind: conversationKind,
      title: conversationKind === 'direct' ? null : `k6-timeline-pagination-${Date.now()}`,
      memberEmails: [memberEmail],
    }),
    jsonHeaders(token)
  );
  check(res, { 'timeline pagination create conversation ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`create conversation failed: ${res.status} ${res.body}`);
  }
  return res.json('id');
}

function sendInternalMessage(senderUserID, conversationID, index) {
  const clientMessageID = `k6-timeline-page-${conversationID}-${index}-${Date.now()}`;
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
        content: { type: 'text', text: `timeline pagination ${index}` },
        derivedState: { reactions: [], editedAt: null, recalledAt: null },
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  check(res, { 'timeline pagination seed accepted': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`seed message failed: ${res.status} ${res.body}`);
  }
  return res.json('message');
}

function timedGet(url, token, trend, checkName) {
  const startedAt = Date.now();
  const res = http.get(url, jsonHeaders(token));
  trend.add(Date.now() - startedAt);
  check(res, { [checkName]: (r) => r.status === 200 });
  return res;
}

function latestTimeline(token, conversationID) {
  return timedGet(
    `${baseURL}/api/im/conversations/${conversationID}/timeline?limit=${pageLimit}`,
    token,
    latestLatency,
    'latest timeline ok'
  );
}

function waitForSeededTimeline(token, conversationID, expectedCount) {
  const deadline = Date.now() + pollTimeoutMillis;
  while (Date.now() < deadline) {
    const res = http.get(
      `${baseURL}/api/im/conversations/${conversationID}/timeline?limit=${Math.min(Math.max(expectedCount, 1), 100)}`,
      jsonHeaders(token)
    );
    if (res.status === 200) {
      const body = res.json();
      const items = Array.isArray(body.items) ? body.items : [];
      if (items.length >= Math.min(expectedCount, pageLimit)) {
        return;
      }
    }
    sleep(Math.max(0.05, pollIntervalMillis / 1000));
  }
  fail(`seeded timeline did not become visible within ${pollTimeoutMillis}ms`);
}

function timelineItems(res) {
  if (res.status !== 200) {
    return [];
  }
  const body = res.json();
  return Array.isArray(body.items) ? body.items : [];
}

function sequenceOf(item) {
  return Number(item.timelineSequence || (item.message && item.message.timelineSequence) || 0);
}

export function setup() {
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for timeline pagination checks.');
  }
  const accounts = accountPair();
  const ownerAuth = login(accounts.owner, 'k6-timeline-pagination-owner');
  const memberAuth = login(accounts.member, 'k6-timeline-pagination-member');
  const conversationID = createConversation(ownerAuth.accessToken, accounts.member.email);
  const seeded = [];
  for (let index = 0; index < Math.max(seedMessageCount, pageLimit + 1); index += 1) {
    seeded.push(sendInternalMessage(ownerAuth.user.id, conversationID, index));
  }
  waitForSeededTimeline(ownerAuth.accessToken, conversationID, Math.min(seeded.length, pageLimit));
  return {
    token: ownerAuth.accessToken,
    memberEmail: accounts.member.email,
    memberUserID: memberAuth.user.id,
    conversationID,
    expectedLatestSequence: Number(seeded[seeded.length - 1].timelineSequence || seeded.length),
  };
}

export default function (data) {
  const startedAt = Date.now();
  let failed = false;

  const latestRes = latestTimeline(data.token, data.conversationID);
  const latestItems = timelineItems(latestRes);
  failed = failed || latestItems.length === 0;

  const oldestSequence = latestItems.reduce((min, item) => {
    const sequence = sequenceOf(item);
    if (sequence <= 0) {
      return min;
    }
    return min === 0 ? sequence : Math.min(min, sequence);
  }, 0);
  if (oldestSequence > 1) {
    const historyRes = timedGet(
      `${baseURL}/api/im/conversations/${data.conversationID}/timeline?beforeSequence=${oldestSequence}&limit=${pageLimit}`,
      data.token,
      historyPageLatency,
      'history timeline page ok'
    );
    failed = failed || historyRes.status !== 200 || timelineItems(historyRes).length === 0;
  } else {
    failed = true;
  }

  const targetSequence = Math.max(1, Number(data.expectedLatestSequence || 1));
  const afterSequence = Math.max(0, targetSequence - Math.max(1, sinceWindow));
  const sinceRes = timedGet(
    `${baseURL}/api/im/conversations/${data.conversationID}/timeline/since?afterSequence=${afterSequence}&targetSequence=${targetSequence}&limit=${sinceLimit}`,
    data.token,
    sinceCatchupLatency,
    'timeline since catch-up ok'
  );
  failed = failed || sinceRes.status !== 200 || timelineItems(sinceRes).length === 0;

  const listRes = timedGet(
    `${baseURL}/api/im/conversations?kind=${encodeURIComponent(conversationKind)}&limit=${listLimit}`,
    data.token,
    conversationListLatency,
    'conversation list by kind ok'
  );
  if (listRes.status !== 200) {
    failed = true;
  } else {
    const body = listRes.json();
    const items = Array.isArray(body.items) ? body.items : [];
    failed = failed || !items.some((item) => item.id === data.conversationID);
  }

  const memberQuery = encodeURIComponent(data.memberEmail.split('@')[0].slice(0, 8));
  const membersRes = timedGet(
    `${baseURL}/api/im/conversations/${data.conversationID}/members?q=${memberQuery}&limit=${memberLimit}`,
    data.token,
    memberSearchLatency,
    'member search ok'
  );
  if (membersRes.status !== 200) {
    failed = true;
  } else {
    const body = membersRes.json();
    const items = Array.isArray(body.items) ? body.items : [];
    failed = failed || !items.some((item) => item.id === data.memberUserID || item.email === data.memberEmail);
  }

  totalLatency.add(Date.now() - startedAt);
  paginationErrors.add(failed);
  sleep(Math.max(0, sleepMillis) / 1000);
}
