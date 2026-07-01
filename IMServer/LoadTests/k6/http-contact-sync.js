import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'contact-sync-smoke';
const profiles = {
  'contact-sync-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_contact_sync_errors: ['rate<0.001'],
      im_contact_request_latency: ['p(95)<1000', 'p(99)<2000'],
      im_contact_accept_latency: ['p(95)<1500', 'p(99)<3000'],
      im_contact_update_latency: ['p(95)<1000', 'p(99)<2000'],
      im_contact_delete_latency: ['p(95)<1000', 'p(99)<2000'],
      im_contact_changes_latency: ['p(95)<3000', 'p(99)<6000'],
      im_contact_total_latency: ['p(95)<8000', 'p(99)<15000'],
    },
  },
  'contact-sync-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_contact_sync_errors: ['rate<0.001'],
      im_contact_request_latency: ['p(95)<1500', 'p(99)<3000'],
      im_contact_accept_latency: ['p(95)<2000', 'p(99)<5000'],
      im_contact_update_latency: ['p(95)<1000', 'p(99)<2500'],
      im_contact_delete_latency: ['p(95)<1500', 'p(99)<3000'],
      im_contact_changes_latency: ['p(95)<5000', 'p(99)<10000'],
      im_contact_total_latency: ['p(95)<15000', 'p(99)<30000'],
    },
  },
  'contact-sync-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_contact_sync_errors: ['rate<0.005'],
      im_contact_request_latency: ['p(95)<3000', 'p(99)<6000'],
      im_contact_accept_latency: ['p(95)<5000', 'p(99)<10000'],
      im_contact_update_latency: ['p(95)<2000', 'p(99)<5000'],
      im_contact_delete_latency: ['p(95)<3000', 'p(99)<6000'],
      im_contact_changes_latency: ['p(95)<10000', 'p(99)<30000'],
      im_contact_total_latency: ['p(95)<30000', 'p(99)<60000'],
    },
  },
};

export const options = profiles[profile] || profiles['contact-sync-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultRequesterEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultRequesterPassword = __ENV.IM_PASSWORD || 'password1234';
const defaultAddresseeEmail = __ENV.IM_CONTACT_EMAIL || (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultAddresseePassword = __ENV.IM_CONTACT_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const pollTimeoutMillis = Number.parseInt(__ENV.IM_CONTACT_SYNC_TIMEOUT_MS || '30000', 10);
const pollIntervalMillis = Number.parseInt(__ENV.IM_CONTACT_SYNC_POLL_INTERVAL_MS || '250', 10);
const sleepMillis = Number.parseInt(__ENV.IM_CONTACT_SYNC_SLEEP_MS || '250', 10);

export const contactSyncErrors = new Rate('im_contact_sync_errors');
export const requestLatency = new Trend('im_contact_request_latency');
export const acceptLatency = new Trend('im_contact_accept_latency');
export const updateLatency = new Trend('im_contact_update_latency');
export const deleteLatency = new Trend('im_contact_delete_latency');
export const changesLatency = new Trend('im_contact_changes_latency');
export const totalLatency = new Trend('im_contact_total_latency');

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
        deviceID: `k6-contact-${role}-${__VU}`,
        deviceName: `k6-contact-${role}`,
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'contact login ok': (r) => r.status === 200 });
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
    requesterUserID: requesterAuth.user.id,
    requesterEmail: pair.requester.email,
    addresseeToken: addresseeAuth.accessToken,
    addresseeUserID: addresseeAuth.user.id,
    addresseeEmail: pair.addressee.email,
  };
  return perVUState;
}

function contactChanges(token, afterToken) {
  const startedAt = Date.now();
  const suffix = afterToken ? `?afterToken=${encodeURIComponent(afterToken)}&limit=20` : '?limit=20';
  const res = http.get(`${baseURL}/api/contacts/changes${suffix}`, jsonHeaders(token));
  changesLatency.add(Date.now() - startedAt);
  if (res.status !== 200) {
    return null;
  }
  return res.json();
}

function sendRequest(state, message) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/contact-requests`,
    JSON.stringify({
      email: state.addresseeEmail,
      message,
      remark: `remark-${__VU}`,
    }),
    jsonHeaders(state.requesterToken)
  );
  requestLatency.add(Date.now() - startedAt);
  check(res, { 'contact request ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function acceptRequest(state, requestID, remark) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/contact-requests/${requestID}/accept`,
    JSON.stringify({ remark }),
    jsonHeaders(state.addresseeToken)
  );
  acceptLatency.add(Date.now() - startedAt);
  check(res, { 'contact accept ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function updateContactRemark(state, remark) {
  const startedAt = Date.now();
  const res = http.patch(
    `${baseURL}/api/contacts/${state.addresseeUserID}`,
    JSON.stringify({ remark }),
    jsonHeaders(state.requesterToken)
  );
  updateLatency.add(Date.now() - startedAt);
  check(res, { 'contact update ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function deleteContact(state) {
  const startedAt = Date.now();
  const res = http.del(`${baseURL}/api/contacts/${state.addresseeUserID}`, null, jsonHeaders(state.requesterToken));
  deleteLatency.add(Date.now() - startedAt);
  check(res, { 'contact delete ok': (r) => r.status === 200 });
  return res.status === 200;
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

function changesHasRequest(changes, requestID, status) {
  const requests = Array.isArray(changes && changes.requestUpserts) ? changes.requestUpserts : [];
  return requests.some((item) => item.id === requestID && item.status === status);
}

function changesHasContact(changes, contactUserID, remark) {
  const contacts = Array.isArray(changes && changes.contactUpserts) ? changes.contactUpserts : [];
  return contacts.some((item) => (
    item.id === contactUserID
    && (remark === undefined || item.remark === remark)
  ));
}

function changesHasRemoval(changes, contactUserID) {
  const removed = Array.isArray(changes && changes.removedContactIDs) ? changes.removedContactIDs : [];
  return removed.includes(contactUserID);
}

export default function () {
  const state = ensureState();
  const startedAt = Date.now();
  const requestMessage = `contact-sync-${__VU}-${__ITER}-${Date.now()}`;

  const request = sendRequest(state, requestMessage);
  if (!request || !request.id) {
    contactSyncErrors.add(true);
    return;
  }

  const deadline = startedAt + pollTimeoutMillis;
  const addresseePending = pollUntil(deadline, () => {
    const changes = contactChanges(state.addresseeToken, null);
    return changesHasRequest(changes, request.id, 'pending') ? changes : null;
  });
  if (!addresseePending) {
    contactSyncErrors.add(true);
    return;
  }
  const addresseePendingToken = addresseePending.targetToken;

  const accepted = acceptRequest(state, request.id, `accepted-${__VU}`);
  if (!accepted || accepted.id !== state.requesterUserID) {
    contactSyncErrors.add(true);
    return;
  }

  const requesterAccepted = pollUntil(deadline, () => {
    const changes = contactChanges(state.requesterToken, null);
    return (
      changesHasRequest(changes, request.id, 'accepted')
      && changesHasContact(changes, state.addresseeUserID, undefined)
    ) ? changes : null;
  });
  if (!requesterAccepted) {
    contactSyncErrors.add(true);
    return;
  }
  const requesterAcceptedToken = requesterAccepted.targetToken;

  const addresseeAccepted = pollUntil(deadline, () => {
    const changes = contactChanges(state.addresseeToken, addresseePendingToken);
    return (
      changesHasRequest(changes, request.id, 'accepted')
      && changesHasContact(changes, state.requesterUserID, undefined)
    ) ? changes : null;
  });
  if (!addresseeAccepted) {
    contactSyncErrors.add(true);
    return;
  }

  const updatedRemark = `updated-${__VU}-${__ITER}`;
  const updated = updateContactRemark(state, updatedRemark);
  if (!updated || updated.remark !== updatedRemark) {
    contactSyncErrors.add(true);
    return;
  }

  const requesterUpdated = pollUntil(deadline, () => {
    const changes = contactChanges(state.requesterToken, requesterAcceptedToken);
    return changesHasContact(changes, state.addresseeUserID, updatedRemark) ? changes : null;
  });
  if (!requesterUpdated) {
    contactSyncErrors.add(true);
    return;
  }
  const requesterUpdatedToken = requesterUpdated.targetToken;

  if (!deleteContact(state)) {
    contactSyncErrors.add(true);
    return;
  }

  const requesterRemoved = pollUntil(deadline, () => {
    const changes = contactChanges(state.requesterToken, requesterUpdatedToken);
    return changesHasRemoval(changes, state.addresseeUserID) ? changes : null;
  });
  if (!requesterRemoved) {
    contactSyncErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  contactSyncErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
