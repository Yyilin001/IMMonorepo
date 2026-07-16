import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'admin-report-smoke';
const profiles = {
  'admin-report-smoke': {
    vus: 5,
    duration: '1m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_admin_report_errors: ['rate<0.001'],
      im_admin_report_create_latency: ['p(95)<1000', 'p(99)<2000'],
      im_admin_report_list_latency: ['p(95)<1000', 'p(99)<2000'],
      im_admin_report_update_latency: ['p(95)<1000', 'p(99)<2000'],
      im_admin_report_total_latency: ['p(95)<4000', 'p(99)<8000'],
    },
  },
  'admin-report-baseline': {
    vus: 50,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_admin_report_errors: ['rate<0.001'],
      im_admin_report_create_latency: ['p(95)<1500', 'p(99)<3000'],
      im_admin_report_list_latency: ['p(95)<1500', 'p(99)<3000'],
      im_admin_report_update_latency: ['p(95)<1500', 'p(99)<3000'],
      im_admin_report_total_latency: ['p(95)<8000', 'p(99)<15000'],
    },
  },
  'admin-report-capacity': {
    vus: 200,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_admin_report_errors: ['rate<0.005'],
      im_admin_report_create_latency: ['p(95)<3000', 'p(99)<6000'],
      im_admin_report_list_latency: ['p(95)<3000', 'p(99)<6000'],
      im_admin_report_update_latency: ['p(95)<3000', 'p(99)<6000'],
      im_admin_report_total_latency: ['p(95)<15000', 'p(99)<30000'],
    },
  },
};

export const options = profiles[profile] || profiles['admin-report-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountFile = __ENV.ACCOUNT_FILE || __ENV.IM_ACCOUNT_FILE || '';
const defaultReporterEmail = __ENV.IM_EMAIL || 'demo@example.com';
const defaultReporterPassword = __ENV.IM_PASSWORD || 'password1234';
const defaultTargetEmail = __ENV.IM_REPORTED_EMAIL || (__ENV.IM_MEMBER_EMAILS || 'alice@example.com').split(',')[0].trim();
const defaultTargetPassword = __ENV.IM_REPORTED_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const sleepMillis = Number.parseInt(__ENV.IM_ADMIN_REPORT_SLEEP_MS || '250', 10);

export const adminReportErrors = new Rate('im_admin_report_errors');
export const createLatency = new Trend('im_admin_report_create_latency');
export const listLatency = new Trend('im_admin_report_list_latency');
export const updateLatency = new Trend('im_admin_report_update_latency');
export const totalLatency = new Trend('im_admin_report_total_latency');

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

function accountPairForVU() {
  if (csvAccounts.length >= 2) {
    const reporterIndex = (((__VU - 1) * 2) % csvAccounts.length);
    return {
      reporter: csvAccounts[reporterIndex],
      target: csvAccounts[(reporterIndex + 1) % csvAccounts.length],
    };
  }
  return {
    reporter: { email: defaultReporterEmail, password: defaultReporterPassword },
    target: { email: defaultTargetEmail, password: defaultTargetPassword },
  };
}

function jsonHeaders(token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return { headers };
}

function internalHeaders() {
  return {
    headers: {
      'Content-Type': 'application/json',
      'X-IM-Internal-Secret': internalSecret,
    },
  };
}

function login(account, role) {
  const res = http.post(
    `${baseURL}/api/auth/login`,
    JSON.stringify({
      email: account.email,
      password: account.password,
      device: {
        deviceID: `k6-admin-report-${role}-${__VU}`,
        deviceName: `k6-admin-report-${role}`,
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'admin report login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed for ${account.email}: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createReport(token, targetUserID, reason) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/reports`,
    JSON.stringify({
      targetType: 'user',
      targetID: targetUserID,
      conversationID: null,
      messageID: null,
      reason,
      detail: `k6 admin moderation ${__VU}/${__ITER}`,
    }),
    jsonHeaders(token)
  );
  createLatency.add(Date.now() - startedAt);
  check(res, { 'admin report create ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function listReports(reason, targetUserID) {
  const startedAt = Date.now();
  const res = http.get(
    `${baseURL}/internal/reports?status=pending&targetType=user&limit=100`,
    internalHeaders()
  );
  listLatency.add(Date.now() - startedAt);
  check(res, { 'admin report list ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    return null;
  }
  const body = res.json();
  const items = Array.isArray(body.items) ? body.items : [];
  return items.find((item) => item.reason === reason && item.targetID === targetUserID) || null;
}

function updateReport(reportID, status, note, resolutionCategory) {
  const startedAt = Date.now();
  const res = http.patch(
    `${baseURL}/internal/reports/${reportID}`,
    JSON.stringify({ status, handledNote: note, resolutionCategory }),
    internalHeaders()
  );
  updateLatency.add(Date.now() - startedAt);
  check(res, { [`admin report ${status} ok`]: (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

export default function () {
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for admin report moderation tests.');
  }

  const startedAt = Date.now();
  const pair = accountPairForVU();
  const reporterAuth = login(pair.reporter, 'reporter');
  const targetAuth = login(pair.target, 'target');
  const reason = `admin-report-${__VU}-${__ITER}-${Date.now()}`;

  const report = createReport(reporterAuth.accessToken, targetAuth.user.id, reason);
  if (!report || report.status !== 'pending') {
    adminReportErrors.add(true);
    return;
  }

  const listed = listReports(reason, targetAuth.user.id);
  if (!listed || listed.id !== report.id) {
    adminReportErrors.add(true);
    return;
  }

  const reviewing = updateReport(report.id, 'reviewing', `reviewing ${reason}`);
  if (!reviewing || reviewing.status !== 'reviewing') {
    adminReportErrors.add(true);
    return;
  }

  const resolved = updateReport(report.id, 'resolved', `resolved ${reason}`, 'action_taken');
  if (!resolved || resolved.status !== 'resolved') {
    adminReportErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  adminReportErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
