import http from 'k6/http';
import { richTextContent, initialDerivedState } from './im-message-payload.js';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'domain-events-smoke';
const profiles = {
  'domain-events-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_domain_events_errors: ['rate<0.001'],
      im_domain_events_accept_latency: ['p(95)<500', 'p(99)<1000'],
      im_domain_events_query_latency: ['p(95)<500', 'p(99)<1000'],
      im_domain_events_visible_latency: ['p(95)<2000', 'p(99)<5000'],
      im_domain_events_total_latency: ['p(95)<3000', 'p(99)<7000'],
    },
  },
  'domain-events-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_domain_events_errors: ['rate<0.001'],
      im_domain_events_accept_latency: ['p(95)<300', 'p(99)<800'],
      im_domain_events_query_latency: ['p(95)<500', 'p(99)<1000'],
      im_domain_events_visible_latency: ['p(95)<2500', 'p(99)<6000'],
      im_domain_events_total_latency: ['p(95)<3500', 'p(99)<8000'],
    },
  },
  'domain-events-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_domain_events_errors: ['rate<0.005'],
      im_domain_events_accept_latency: ['p(95)<800', 'p(99)<1500'],
      im_domain_events_query_latency: ['p(95)<1000', 'p(99)<2000'],
      im_domain_events_visible_latency: ['p(95)<5000', 'p(99)<10000'],
      im_domain_events_total_latency: ['p(95)<7000', 'p(99)<15000'],
    },
  },
};

export const options = profiles[profile] || profiles['domain-events-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultOwnerEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultOwnerPassword = __ENV.IM_PASSWORD || 'password1234';
const defaultRecipientEmail = __ENV.IM_RECIPIENT_EMAIL || (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultRecipientPassword = __ENV.IM_RECIPIENT_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_DOMAIN_EVENTS_TIMEOUT_MS || '10000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_DOMAIN_EVENTS_POLL_INTERVAL_MS || '250', 10);
const drainPageLimit = Number.parseInt(__ENV.IM_DOMAIN_EVENTS_DRAIN_PAGES || '20', 10);

export const domainEventErrors = new Rate('im_domain_events_errors');
export const acceptLatency = new Trend('im_domain_events_accept_latency');
export const queryLatency = new Trend('im_domain_events_query_latency');
export const visibleLatency = new Trend('im_domain_events_visible_latency');
export const pageSize = new Trend('im_domain_events_page_size');
export const totalLatency = new Trend('im_domain_events_total_latency');

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
    const recipientIndex = (ownerIndex + 1) % csvAccounts.length;
    return {
      owner: csvAccounts[ownerIndex],
      recipient: csvAccounts[recipientIndex],
    };
  }
  return {
    owner: { email: defaultOwnerEmail, password: defaultOwnerPassword },
    recipient: { email: defaultRecipientEmail, password: defaultRecipientPassword },
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
  check(res, { 'domain-events login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createConversation(ownerToken, recipientEmail) {
  if (__ENV.IM_CONVERSATION_ID) {
    return __ENV.IM_CONVERSATION_ID;
  }
  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title: `k6-domain-events-${__VU}-${Date.now()}`,
      memberEmails: [recipientEmail],
    }),
    jsonHeaders(ownerToken)
  );
  check(res, { 'domain-events create conversation ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`create conversation failed: ${res.status} ${res.body}`);
  }
  return res.json('id');
}

function listDomainEvents(token, afterCursor, limit) {
  const startedAt = Date.now();
  const res = http.get(
    `${baseURL}/api/im/domain-events?after=${afterCursor}&limit=${limit}`,
    jsonHeaders(token)
  );
  queryLatency.add(Date.now() - startedAt);
  if (res.status !== 200) {
    return { status: res.status, items: [], nextCursor: afterCursor, hasMore: false };
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  pageSize.add(items.length);
  return {
    status: res.status,
    items,
    nextCursor: Number(body.nextCursor || afterCursor),
    hasMore: Boolean(body.hasMore),
  };
}

function drainDomainEventCursor(token) {
  let cursor = 0;
  for (let i = 0; i < drainPageLimit; i += 1) {
    const page = listDomainEvents(token, cursor, 200);
    if (page.status !== 200) {
      fail(`domain-events baseline read failed: ${page.status}`);
    }
    cursor = page.nextCursor;
    if (!page.hasMore) {
      return cursor;
    }
  }
  fail(`domain-events baseline has more than ${drainPageLimit} pages; increase IM_DOMAIN_EVENTS_DRAIN_PAGES`);
  return cursor;
}

function sendInternalMessage(senderUserID, conversationID, clientMessageID) {
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
        content: richTextContent(`domain-events ${clientMessageID}`),
        derivedState: initialDerivedState(),
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  acceptLatency.add(Date.now() - startedAt);
  check(res, { 'domain-events seed message accepted': (r) => r.status === 200 });
  return res.status === 200;
}

function pollForDomainEvent(token, afterCursor, deadline) {
  while (Date.now() < deadline) {
    const page = listDomainEvents(token, afterCursor, 100);
    if (page.status !== 200) {
      return null;
    }
    if (page.items.length > 0 && page.nextCursor > afterCursor) {
      return page;
    }
    sleep(Math.max(0.05, pollIntervalMillis / 1000));
  }
  return null;
}

function ensureState() {
  if (perVUState) {
    return perVUState;
  }
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for domain-events sync checks.');
  }
  const pair = accountPairForVU();
  const ownerAuth = login(pair.owner, `k6-domain-owner-${__VU}`);
  const recipientAuth = login(pair.recipient, `k6-domain-recipient-${__VU}`);
  perVUState = {
    ownerUserID: ownerAuth.user.id,
    recipientToken: recipientAuth.accessToken,
    conversationID: createConversation(ownerAuth.accessToken, pair.recipient.email),
  };
  return perVUState;
}

export default function () {
  const state = ensureState();
  const clientMessageID = `k6-domain-events-${__VU}-${__ITER}-${Date.now()}`;
  const startedAt = Date.now();
  const baselineCursor = drainDomainEventCursor(state.recipientToken);

  if (!sendInternalMessage(state.ownerUserID, state.conversationID, clientMessageID)) {
    domainEventErrors.add(true);
    return;
  }

  const eventPage = pollForDomainEvent(
    state.recipientToken,
    baselineCursor,
    startedAt + pollTimeoutMillis
  );
  if (!eventPage) {
    domainEventErrors.add(true);
    return;
  }

  visibleLatency.add(Date.now() - startedAt);
  totalLatency.add(Date.now() - startedAt);
  domainEventErrors.add(false);
}
