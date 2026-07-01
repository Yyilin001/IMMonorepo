import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'media-file-smoke';
const profiles = {
  'media-file-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_media_file_errors: ['rate<0.001'],
      im_file_upload_latency: ['p(95)<1000', 'p(99)<2000'],
      im_file_download_latency: ['p(95)<1000', 'p(99)<2000'],
      im_file_range_latency: ['p(95)<1000', 'p(99)<2000'],
      im_media_create_latency: ['p(95)<1000', 'p(99)<2000'],
      im_media_chunk_latency: ['p(95)<1500', 'p(99)<3000'],
      im_media_complete_latency: ['p(95)<1500', 'p(99)<3000'],
      im_media_download_latency: ['p(95)<1500', 'p(99)<3000'],
      im_media_file_total_latency: ['p(95)<8000', 'p(99)<15000'],
    },
  },
  'media-file-baseline': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_media_file_errors: ['rate<0.001'],
      im_file_upload_latency: ['p(95)<1500', 'p(99)<3000'],
      im_file_download_latency: ['p(95)<1500', 'p(99)<3000'],
      im_file_range_latency: ['p(95)<1000', 'p(99)<2500'],
      im_media_create_latency: ['p(95)<1500', 'p(99)<3000'],
      im_media_chunk_latency: ['p(95)<3000', 'p(99)<6000'],
      im_media_complete_latency: ['p(95)<3000', 'p(99)<6000'],
      im_media_download_latency: ['p(95)<3000', 'p(99)<6000'],
      im_media_file_total_latency: ['p(95)<15000', 'p(99)<30000'],
    },
  },
  'media-file-capacity': {
    vus: 500,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_media_file_errors: ['rate<0.005'],
      im_file_upload_latency: ['p(95)<3000', 'p(99)<6000'],
      im_file_download_latency: ['p(95)<3000', 'p(99)<6000'],
      im_file_range_latency: ['p(95)<2000', 'p(99)<5000'],
      im_media_create_latency: ['p(95)<3000', 'p(99)<6000'],
      im_media_chunk_latency: ['p(95)<6000', 'p(99)<12000'],
      im_media_complete_latency: ['p(95)<6000', 'p(99)<12000'],
      im_media_download_latency: ['p(95)<6000', 'p(99)<12000'],
      im_media_file_total_latency: ['p(95)<30000', 'p(99)<60000'],
    },
  },
};

export const options = profiles[profile] || profiles['media-file-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const payloadBytes = Number.parseInt(__ENV.IM_MEDIA_FILE_PAYLOAD_BYTES || '1024', 10);
const sleepMillis = Number.parseInt(__ENV.IM_MEDIA_FILE_SLEEP_MS || '250', 10);

export const mediaFileErrors = new Rate('im_media_file_errors');
export const fileUploadLatency = new Trend('im_file_upload_latency');
export const fileDownloadLatency = new Trend('im_file_download_latency');
export const fileRangeLatency = new Trend('im_file_range_latency');
export const mediaCreateLatency = new Trend('im_media_create_latency');
export const mediaChunkLatency = new Trend('im_media_chunk_latency');
export const mediaCompleteLatency = new Trend('im_media_complete_latency');
export const mediaDownloadLatency = new Trend('im_media_download_latency');
export const totalLatency = new Trend('im_media_file_total_latency');

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
        deviceID: `k6-media-file-${__VU}`,
        deviceName: 'k6-media-file',
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'media file login ok': (r) => r.status === 200 });
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

function uploadFile(token, body) {
  const startedAt = Date.now();
  const res = http.post(`${baseURL}/api/files/upload`, body, binaryHeaders(token));
  fileUploadLatency.add(Date.now() - startedAt);
  check(res, { 'file upload ok': (r) => r.status === 200 });
  return res.status === 200;
}

function downloadFile(token, expectedBody) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/files/download`, jsonHeaders(token));
  fileDownloadLatency.add(Date.now() - startedAt);
  check(res, { 'file download ok': (r) => r.status === 200 });
  return res.status === 200 && res.body === expectedBody;
}

function rangeDownloadFile(token, expectedSlice) {
  const startedAt = Date.now();
  const res = http.get(`${baseURL}/api/files/download`, {
    headers: {
      Authorization: `Bearer ${token}`,
      Range: 'bytes=6-13',
    },
  });
  fileRangeLatency.add(Date.now() - startedAt);
  check(res, { 'file range ok': (r) => r.status === 206 });
  return res.status === 206 && res.body === expectedSlice;
}

function createMediaUpload(token, body) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/media/uploads`,
    JSON.stringify({
      kind: 'file',
      mimeType: 'application/octet-stream',
      byteSize: body.length,
      filename: `k6-media-${__VU}-${__ITER}.bin`,
      width: null,
      height: null,
      durationMillis: null,
      previewAssetID: null,
    }),
    jsonHeaders(token)
  );
  mediaCreateLatency.add(Date.now() - startedAt);
  check(res, { 'media create ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function uploadMediaChunk(token, uploadID, body) {
  const startedAt = Date.now();
  const res = http.put(`${baseURL}/api/media/uploads/${uploadID}/chunk`, body, binaryHeaders(token));
  mediaChunkLatency.add(Date.now() - startedAt);
  check(res, { 'media chunk ok': (r) => r.status === 200 });
  return res.status === 200;
}

function completeMedia(token, uploadID, expectedSize) {
  const startedAt = Date.now();
  const res = http.post(`${baseURL}/api/media/uploads/${uploadID}/complete`, null, {
    headers: { Authorization: `Bearer ${token}` },
  });
  mediaCompleteLatency.add(Date.now() - startedAt);
  check(res, { 'media complete ok': (r) => r.status === 200 });
  if (res.status !== 200) {
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
  mediaDownloadLatency.add(Date.now() - startedAt);
  check(res, { 'media download ok': (r) => r.status === 200 });
  return res.status === 200 && res.body === expectedBody;
}

export default function () {
  const auth = login();
  const startedAt = Date.now();
  const filePayload = payload('file');
  const mediaPayload = payload('media');

  if (!uploadFile(auth.accessToken, filePayload)) {
    mediaFileErrors.add(true);
    return;
  }
  if (!downloadFile(auth.accessToken, filePayload)) {
    mediaFileErrors.add(true);
    return;
  }
  if (filePayload.length >= 14 && !rangeDownloadFile(auth.accessToken, filePayload.slice(6, 14))) {
    mediaFileErrors.add(true);
    return;
  }

  const session = createMediaUpload(auth.accessToken, mediaPayload);
  if (!session || !session.uploadID) {
    mediaFileErrors.add(true);
    return;
  }
  if (!uploadMediaChunk(auth.accessToken, session.uploadID, mediaPayload)) {
    mediaFileErrors.add(true);
    return;
  }
  const asset = completeMedia(auth.accessToken, session.uploadID, mediaPayload.length);
  if (!asset) {
    mediaFileErrors.add(true);
    return;
  }
  if (!downloadMedia(auth.accessToken, asset.assetID, mediaPayload)) {
    mediaFileErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  mediaFileErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
