import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

http.setResponseCallback(
  http.expectedStatuses({ min: 200, max: 399 }, 400, 401, 403, 404, 409, 410, 416)
);

const profile = __ENV.PROFILE || 'media-failure-recovery-smoke';
const profiles = {
  'media-failure-recovery-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_media_failure_recovery_errors: ['rate<0.001'],
      im_media_failure_bad_auth_latency: ['p(95)<500', 'p(99)<1000'],
      im_media_failure_invalid_range_latency: ['p(95)<1000', 'p(99)<2000'],
      im_media_failure_missing_asset_latency: ['p(95)<1000', 'p(99)<2000'],
      im_media_failure_empty_complete_latency: ['p(95)<1000', 'p(99)<2000'],
      im_media_failure_invalid_session_latency: ['p(95)<1000', 'p(99)<2000'],
      im_media_failure_recovery_total_latency: ['p(95)<8000', 'p(99)<15000'],
    },
  },
  'media-failure-recovery-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_media_failure_recovery_errors: ['rate<0.001'],
      im_media_failure_bad_auth_latency: ['p(95)<1000', 'p(99)<2000'],
      im_media_failure_invalid_range_latency: ['p(95)<1500', 'p(99)<3000'],
      im_media_failure_missing_asset_latency: ['p(95)<1500', 'p(99)<3000'],
      im_media_failure_empty_complete_latency: ['p(95)<1500', 'p(99)<3000'],
      im_media_failure_invalid_session_latency: ['p(95)<1500', 'p(99)<3000'],
      im_media_failure_recovery_total_latency: ['p(95)<15000', 'p(99)<30000'],
    },
  },
  'media-failure-recovery-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.02'],
      im_media_failure_recovery_errors: ['rate<0.005'],
      im_media_failure_bad_auth_latency: ['p(95)<2000', 'p(99)<4000'],
      im_media_failure_invalid_range_latency: ['p(95)<3000', 'p(99)<6000'],
      im_media_failure_missing_asset_latency: ['p(95)<3000', 'p(99)<6000'],
      im_media_failure_empty_complete_latency: ['p(95)<3000', 'p(99)<6000'],
      im_media_failure_invalid_session_latency: ['p(95)<3000', 'p(99)<6000'],
      im_media_failure_recovery_total_latency: ['p(95)<30000', 'p(99)<60000'],
    },
  },
};

export const options = profiles[profile] || profiles['media-failure-recovery-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const payloadBytes = Number.parseInt(__ENV.IM_MEDIA_FAILURE_PAYLOAD_BYTES || '1024', 10);
const sleepMillis = Number.parseInt(__ENV.IM_MEDIA_FAILURE_SLEEP_MS || '250', 10);

export const mediaFailureRecoveryErrors = new Rate('im_media_failure_recovery_errors');
export const badAuthLatency = new Trend('im_media_failure_bad_auth_latency');
export const invalidRangeLatency = new Trend('im_media_failure_invalid_range_latency');
export const missingAssetLatency = new Trend('im_media_failure_missing_asset_latency');
export const emptyCompleteLatency = new Trend('im_media_failure_empty_complete_latency');
export const invalidSessionLatency = new Trend('im_media_failure_invalid_session_latency');
export const recoveryUploadLatency = new Trend('im_media_failure_recovery_upload_latency');
export const recoveryCompleteLatency = new Trend('im_media_failure_recovery_complete_latency');
export const recoveryDownloadLatency = new Trend('im_media_failure_recovery_download_latency');
export const totalLatency = new Trend('im_media_failure_recovery_total_latency');

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
let perVUAuth = null;

function accountForVU() {
  if (csvAccounts.length > 0) {
    return csvAccounts[(__VU - 1) % csvAccounts.length];
  }
  return { email: defaultEmail, password: defaultPassword };
}

function jsonHeaders(token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return { headers };
}

function binaryHeaders(token, extra = {}) {
  return {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/octet-stream',
      ...extra,
    },
  };
}

function login() {
  if (perVUAuth) {
    return perVUAuth;
  }
  const account = accountForVU();
  const res = http.post(
    `${baseURL}/api/auth/login`,
    JSON.stringify({
      email: account.email,
      password: account.password,
      device: {
        deviceID: `k6-media-failure-${__VU}`,
        deviceName: 'k6-media-failure',
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'media failure login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  perVUAuth = res.json();
  return perVUAuth;
}

function payload(prefix) {
  const base = `${prefix}-${__VU}-${__ITER}-`;
  const target = Math.max(base.length, payloadBytes);
  return base + 'x'.repeat(target - base.length);
}

function expectStatus(res, allowed) {
  return allowed.includes(res.status);
}

function checkBadAuth() {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/files/download`, jsonHeaders(`bad-token-${__VU}-${__ITER}`));
  badAuthLatency.add(Date.now() - startedAt);
  return check(res, {
    'bad file download auth rejected': (r) => expectStatus(r, [401, 403]),
  });
}

function uploadFile(token, body) {
  const res = http.post(`${baseURL}/api/files/upload`, body, binaryHeaders(token));
  return check(res, { 'recovery file upload ok': (r) => r.status === 200 });
}

function checkInvalidRange(token) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/files/download`, {
    headers: {
      Authorization: `Bearer ${token}`,
      Range: 'bytes=999999-1000000',
    },
  });
  invalidRangeLatency.add(Date.now() - startedAt);
  return check(res, {
    'invalid file range rejected': (r) => r.status === 416,
  });
}

function createMediaUpload(token, body) {
  const res = http.post(
    `${baseURL}/api/media/uploads`,
    JSON.stringify({
      kind: 'file',
      mimeType: 'application/octet-stream',
      byteSize: body.length,
      filename: `k6-media-failure-${__VU}-${__ITER}.bin`,
      width: null,
      height: null,
      durationMillis: null,
      previewAssetID: null,
    }),
    jsonHeaders(token)
  );
  return res.status === 200 ? res.json() : null;
}

function checkEmptyComplete(token, uploadID) {
  const startedAt = Date.now();
  const res = http.post(`${baseURL}/api/media/uploads/${uploadID}/complete`, null, {
    headers: { Authorization: `Bearer ${token}` },
  });
  emptyCompleteLatency.add(Date.now() - startedAt);
  return check(res, {
    'empty media complete rejected': (r) => r.status === 400,
  });
}

function checkInvalidSession(token, body) {
  const startedAt = Date.now();
  const res = http.put(
    `${baseURL}/api/media/uploads/00000000-0000-0000-0000-000000000000/chunk`,
    body,
    binaryHeaders(token)
  );
  invalidSessionLatency.add(Date.now() - startedAt);
  return check(res, {
    'invalid media session rejected': (r) => r.status === 404,
  });
}

function checkMissingAsset(token) {
  const startedAt = Date.now();
  const res = http.get(
    `${baseURL}/api/media/assets/00000000-0000-0000-0000-000000000000`,
    jsonHeaders(token)
  );
  missingAssetLatency.add(Date.now() - startedAt);
  return check(res, {
    'missing media asset rejected': (r) => r.status === 404,
  });
}

function uploadMediaChunk(token, uploadID, body) {
  const startedAt = Date.now();
  const res = http.put(`${baseURL}/api/media/uploads/${uploadID}/chunk`, body, binaryHeaders(token));
  recoveryUploadLatency.add(Date.now() - startedAt);
  return check(res, { 'recovery media chunk ok': (r) => r.status === 200 });
}

function completeMedia(token, uploadID, expectedSize) {
  const startedAt = Date.now();
  const res = http.post(`${baseURL}/api/media/uploads/${uploadID}/complete`, null, {
    headers: { Authorization: `Bearer ${token}` },
  });
  recoveryCompleteLatency.add(Date.now() - startedAt);
  const ok = check(res, { 'recovery media complete ok': (r) => r.status === 200 });
  if (!ok) {
    return null;
  }
  const asset = res.json();
  if (!asset || asset.assetID !== uploadID || Number(asset.byteSize || 0) !== expectedSize) {
    return null;
  }
  return asset;
}

function downloadMedia(token, assetID, expectedBody) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/media/assets/${assetID}`, jsonHeaders(token));
  recoveryDownloadLatency.add(Date.now() - startedAt);
  return check(res, { 'recovery media download ok': (r) => r.status === 200 }) && res.body === expectedBody;
}

export default function () {
  const auth = login();
  const startedAt = Date.now();
  const body = payload('media-failure');

  if (!checkBadAuth()) {
    mediaFailureRecoveryErrors.add(true);
    return;
  }

  if (!uploadFile(auth.accessToken, body)) {
    mediaFailureRecoveryErrors.add(true);
    return;
  }
  if (!checkInvalidRange(auth.accessToken)) {
    mediaFailureRecoveryErrors.add(true);
    return;
  }
  if (!checkMissingAsset(auth.accessToken)) {
    mediaFailureRecoveryErrors.add(true);
    return;
  }
  if (!checkInvalidSession(auth.accessToken, body)) {
    mediaFailureRecoveryErrors.add(true);
    return;
  }

  const session = createMediaUpload(auth.accessToken, body);
  if (!session || !session.uploadID) {
    mediaFailureRecoveryErrors.add(true);
    return;
  }
  if (!checkEmptyComplete(auth.accessToken, session.uploadID)) {
    mediaFailureRecoveryErrors.add(true);
    return;
  }
  if (!uploadMediaChunk(auth.accessToken, session.uploadID, body)) {
    mediaFailureRecoveryErrors.add(true);
    return;
  }
  const asset = completeMedia(auth.accessToken, session.uploadID, body.length);
  if (!asset || !downloadMedia(auth.accessToken, asset.assetID, body)) {
    mediaFailureRecoveryErrors.add(true);
    return;
  }

  mediaFailureRecoveryErrors.add(false);
  totalLatency.add(Date.now() - startedAt);
  if (sleepMillis > 0) {
    sleep(sleepMillis / 1000);
  }
}
