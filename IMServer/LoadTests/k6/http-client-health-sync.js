import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'client-health-smoke';
const profiles = {
  'client-health-smoke': {
    vus: 10,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_client_health_errors: ['rate<0.001'],
      im_client_health_total_latency: ['p(95)<1500', 'p(99)<3000'],
      im_client_health_report_latency: ['p(95)<500', 'p(99)<1000'],
      im_client_health_diagnostics_report_latency: ['p(95)<500', 'p(99)<1000'],
    },
  },
  'client-health-baseline': {
    vus: 200,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_client_health_errors: ['rate<0.001'],
      im_client_health_total_latency: ['p(95)<2500', 'p(99)<5000'],
      im_client_health_report_latency: ['p(95)<800', 'p(99)<2000'],
      im_client_health_diagnostics_report_latency: ['p(95)<800', 'p(99)<2000'],
    },
  },
  'client-health-capacity': {
    vus: 1000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_client_health_errors: ['rate<0.005'],
      im_client_health_total_latency: ['p(95)<5000', 'p(99)<10000'],
      im_client_health_report_latency: ['p(95)<1500', 'p(99)<4000'],
      im_client_health_diagnostics_report_latency: ['p(95)<1500', 'p(99)<4000'],
    },
  },
};

export const options = profiles[profile] || profiles['client-health-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultPassword = __ENV.IM_PASSWORD || 'password1234';
const sleepMillis = Number.parseInt(__ENV.IM_CLIENT_HEALTH_SLEEP_MS || '250', 10);

export const clientHealthErrors = new Rate('im_client_health_errors');
export const totalLatency = new Trend('im_client_health_total_latency');
export const reportLatency = new Trend('im_client_health_report_latency');
export const diagnosticsReportLatency = new Trend('im_client_health_diagnostics_report_latency');
export const reportOK = new Counter('im_client_health_ok_total');

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

function login() {
  if (perVUAuth) {
    return perVUAuth;
  }
  const account = accountForVU();
  const deviceID = `k6-client-health-${__VU}`;
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
  check(res, { 'client health login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  perVUAuth = res.json();
  return perVUAuth;
}

function baseMetrics(seed) {
  return {
    invalidDomainEventMetadata: 0,
    missingRequiredNotice: 0,
    deferredStored: seed % 3,
    deferredEncodeFailed: 0,
    deferredNotDeferrable: 0,
    deferredReplayApplied: seed % 2,
    deferredExpired: 0,
    deferredFullRefreshRequested: seed % 5 === 0 ? 1 : 0,
    cacheDroppedCanonicalMessages: 0,
    cacheDroppedTimelineNotices: 0,
    invalidCanonicalMessageDTOs: 0,
    invalidProjectionDTOs: 0,
    sequenceDecodeOverflow: 0,
    realtimeMissingDeliveryRow: 0,
    catchUpCursorGap: seed % 7 === 0 ? 1 : 0,
    catchUpStoppedBeforeCursorAdvance: 0,
    invalidDeferredPayload: 0,
  };
}

function healthPayload(reason, includeDiagnostics) {
  const seed = (__VU * 100000) + __ITER;
  const snapshot = {
    domainEventCursor: seed,
    deferredDomainEventCount: seed % 4,
    fullRefreshConversationCount: seed % 6 === 0 ? 1 : 0,
    domainEventMetrics: baseMetrics(seed),
    timelineCatchUpDiagnostics: null,
    timelineCatchUpConfiguration: null,
  };

  if (includeDiagnostics) {
    snapshot.timelineCatchUpDiagnostics = {
      hintQueuedCount: 2,
      hintSkippedAlreadyLoadedCount: 1,
      deferredCount: seed % 3,
      sinceRequestCount: 2,
      sinceSuccessCount: 2,
      sinceFailureCount: 0,
      appliedPageCount: 1,
      appliedItemCount: 3,
      lastHintToRequestMilliseconds: 25,
      lastRequestMilliseconds: 80,
      lastHintToApplyMilliseconds: 150,
      lastConversationID: `load-health-${__VU}`,
      lastTargetTimelineSequence: seed + 10,
      lastAfterSequence: seed,
      lastAppliedLatestTimelineSequence: seed + 10,
      lastFailureReason: null,
    };
    snapshot.timelineCatchUpConfiguration = {
      selectedHintInitialJitterMilliseconds: 50,
      selectedHintMinimumIntervalMilliseconds: 250,
      selectedHintMicroBatchMilliseconds: 100,
    };
  }

  return {
    snapshot,
    reason,
    reportedAt: new Date().toISOString(),
  };
}

function postClientHealth(token, payload, metric, label) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/im/client-health`,
    JSON.stringify(payload),
    jsonHeaders(token)
  );
  metric.add(Date.now() - startedAt);
  check(res, { [`${label} ok`]: (r) => r.status === 204 });
  return res.status === 204;
}

export default function () {
  const startedAt = Date.now();
  const auth = login();
  const normalOK = postClientHealth(
    auth.accessToken,
    healthPayload('periodic', false),
    reportLatency,
    'client health report'
  );
  const diagnosticsOK = postClientHealth(
    auth.accessToken,
    healthPayload('timeline-catch-up', true),
    diagnosticsReportLatency,
    'client health diagnostics report'
  );

  const ok = normalOK && diagnosticsOK;
  clientHealthErrors.add(!ok);
  if (ok) {
    reportOK.add(1);
    totalLatency.add(Date.now() - startedAt);
  }

  if (sleepMillis > 0) {
    sleep(sleepMillis / 1000);
  }
}
