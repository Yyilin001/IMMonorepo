import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'contact-request-smoke';
const profiles = {
  'contact-request-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_contact_request_moderation_errors: ['rate<0.001'],
      im_contact_request_send_latency: ['p(95)<1000', 'p(99)<2000'],
      im_contact_request_list_latency: ['p(95)<800', 'p(99)<1500'],
      im_contact_request_decline_latency: ['p(95)<1000', 'p(99)<2000'],
      im_contact_request_cancel_latency: ['p(95)<1000', 'p(99)<2000'],
      im_contact_request_changes_latency: ['p(95)<3000', 'p(99)<6000'],
      im_contact_request_total_latency: ['p(95)<5000', 'p(99)<10000'],
    },
  },
  'contact-request-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_contact_request_moderation_errors: ['rate<0.001'],
      im_contact_request_send_latency: ['p(95)<1500', 'p(99)<3000'],
      im_contact_request_list_latency: ['p(95)<1000', 'p(99)<2500'],
      im_contact_request_decline_latency: ['p(95)<1500', 'p(99)<3000'],
      im_contact_request_cancel_latency: ['p(95)<1500', 'p(99)<3000'],
      im_contact_request_changes_latency: ['p(95)<5000', 'p(99)<10000'],
      im_contact_request_total_latency: ['p(95)<9000', 'p(99)<18000'],
    },
  },
  'contact-request-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_contact_request_moderation_errors: ['rate<0.005'],
      im_contact_request_send_latency: ['p(95)<3000', 'p(99)<6000'],
      im_contact_request_list_latency: ['p(95)<2500', 'p(99)<5000'],
      im_contact_request_decline_latency: ['p(95)<3000', 'p(99)<6000'],
      im_contact_request_cancel_latency: ['p(95)<3000', 'p(99)<6000'],
      im_contact_request_changes_latency: ['p(95)<10000', 'p(99)<30000'],
      im_contact_request_total_latency: ['p(95)<20000', 'p(99)<45000'],
    },
  },
};

export const options = profiles[profile] || profiles['contact-request-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultRequesterEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultRequesterPassword = __ENV.IM_PASSWORD || 'password1234';
const defaultAddresseeEmail = __ENV.IM_CONTACT_EMAIL || (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultAddresseePassword = __ENV.IM_CONTACT_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_CONTACT_REQUEST_TIMEOUT_MS || '10000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_CONTACT_REQUEST_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_CONTACT_REQUEST_SLEEP_MS || '250', 10);

export const requestModerationErrors = new Rate('im_contact_request_moderation_errors');
export const sendLatency = new Trend('im_contact_request_send_latency');
export const listLatency = new Trend('im_contact_request_list_latency');
export const declineLatency = new Trend('im_contact_request_decline_latency');
export const cancelLatency = new Trend('im_contact_request_cancel_latency');
export const changesLatency = new Trend('im_contact_request_changes_latency');
export const totalLatency = new Trend('im_contact_request_total_latency');

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
    const requesterIndex = (((__VU - 1) * 2) % csvAccounts.length);
    return {
      requester: csvAccounts[requesterIndex],
      addressee: csvAccounts[(requesterIndex + 1) % csvAccounts.length],
    };
  }
  return {
    requester: { email: defaultRequesterEmail, password: defaultRequesterPassword },
    addressee: { email: defaultAddresseeEmail, password: defaultAddresseePassword },
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
        deviceID: `k6-contact-request-${role}-${__VU}`,
        deviceName: `k6-contact-request-${role}`,
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'contact-request login ok': (r) => r.status === 200 });
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
  const requesterAuth = login(pair.requester, 'requester');
  const addresseeAuth = login(pair.addressee, 'addressee');
  perVUState = {
    requesterToken: requesterAuth.accessToken,
    requesterEmail: pair.requester.email,
    addresseeToken: addresseeAuth.accessToken,
    addresseeEmail: pair.addressee.email,
  };
  return perVUState;
}

function sendRequest(state, label) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/contact-requests`,
    JSON.stringify({
      email: state.addresseeEmail,
      message: `contact-request-${label}-${__VU}-${__ITER}-${Date.now()}`,
      remark: `remark-${label}-${__VU}`,
    }),
    jsonHeaders(state.requesterToken)
  );
  sendLatency.add(Date.now() - startedAt);
  check(res, { 'contact-request send ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function listRequests(token, box) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/contact-requests?box=${box}`, jsonHeaders(token));
  listLatency.add(Date.now() - startedAt);
  if (res.status !== 200) {
    return null;
  }
  return Array.isArray(res.json()) ? res.json() : [];
}

function requestInList(token, box, requestID, status) {
  const requests = listRequests(token, box);
  if (!requests) {
    return false;
  }
  return requests.some((item) => item.id === requestID && item.status === status);
}

function declineRequest(state, requestID) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/contact-requests/${requestID}/decline`,
    null,
    jsonHeaders(state.addresseeToken)
  );
  declineLatency.add(Date.now() - startedAt);
  check(res, { 'contact-request decline ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function cancelRequest(state, requestID) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/contact-requests/${requestID}/cancel`,
    null,
    jsonHeaders(state.requesterToken)
  );
  cancelLatency.add(Date.now() - startedAt);
  check(res, { 'contact-request cancel ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function contactChanges(token, afterToken) {
  const startedAt = Date.now();
  const suffix = afterToken ? `?afterToken=${encodeURIComponent(afterToken)}&limit=50` : '?limit=50';
  const res = http.get(`${baseURL}/api/contacts/changes${suffix}`, jsonHeaders(token));
  changesLatency.add(Date.now() - startedAt);
  if (res.status !== 200) {
    return null;
  }
  return res.json();
}

function changesHasRequestStatus(changes, requestID, status) {
  const requests = Array.isArray(changes && changes.requestUpserts) ? changes.requestUpserts : [];
  return requests.some((item) => item.id === requestID && item.status === status);
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
  const state = ensureState();
  const startedAt = Date.now();
  const requesterBaseline = contactChanges(state.requesterToken, null);
  const addresseeBaseline = contactChanges(state.addresseeToken, null);
  const requesterToken = requesterBaseline && requesterBaseline.targetToken;
  const addresseeToken = addresseeBaseline && addresseeBaseline.targetToken;

  const declineCandidate = sendRequest(state, 'decline');
  if (!declineCandidate || !declineCandidate.id) {
    requestModerationErrors.add(true);
    return;
  }

  const deadline = startedAt + pollTimeoutMillis;
  const incomingVisible = pollUntil(
    deadline,
    () => requestInList(state.addresseeToken, 'incoming', declineCandidate.id, 'pending')
  );
  if (!incomingVisible) {
    requestModerationErrors.add(true);
    return;
  }

  const declined = declineRequest(state, declineCandidate.id);
  if (!declined || declined.status !== 'declined') {
    requestModerationErrors.add(true);
    return;
  }

  const declinedVisible = pollUntil(deadline, () => {
    const requesterChanges = contactChanges(state.requesterToken, requesterToken);
    const addresseeChanges = contactChanges(state.addresseeToken, addresseeToken);
    return changesHasRequestStatus(requesterChanges, declineCandidate.id, 'declined')
      && changesHasRequestStatus(addresseeChanges, declineCandidate.id, 'declined');
  });
  if (!declinedVisible) {
    requestModerationErrors.add(true);
    return;
  }

  const cancelCandidate = sendRequest(state, 'cancel');
  if (!cancelCandidate || !cancelCandidate.id) {
    requestModerationErrors.add(true);
    return;
  }

  const outgoingVisible = pollUntil(
    deadline,
    () => requestInList(state.requesterToken, 'outgoing', cancelCandidate.id, 'pending')
  );
  if (!outgoingVisible) {
    requestModerationErrors.add(true);
    return;
  }

  const cancelled = cancelRequest(state, cancelCandidate.id);
  if (!cancelled || cancelled.status !== 'cancelled') {
    requestModerationErrors.add(true);
    return;
  }

  const cancelledVisible = pollUntil(deadline, () => {
    const requesterChanges = contactChanges(state.requesterToken, requesterToken);
    const addresseeChanges = contactChanges(state.addresseeToken, addresseeToken);
    return changesHasRequestStatus(requesterChanges, cancelCandidate.id, 'cancelled')
      && changesHasRequestStatus(addresseeChanges, cancelCandidate.id, 'cancelled');
  });
  if (!cancelledVisible) {
    requestModerationErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  requestModerationErrors.add(false);

  if (sleepMillis > 0) {
    sleep(sleepMillis / 1000);
  }
}
