import http from 'k6/http';
import { richTextContent, initialDerivedState } from './im-message-payload.js';
import { check, fail, sleep } from 'k6';
import { Gauge, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'local-hot-smoke';
const profiles = {
  'local-hot-smoke': {
    vus: 50,
    duration: '1m',
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_hot_write_errors: ['rate<0.001'],
      im_hot_write_send_latency: ['p(95)<800', 'p(99)<1500'],
    },
  },
  'staging-hot-baseline': {
    vus: 500,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_hot_write_errors: ['rate<0.001'],
      im_hot_write_send_latency: ['p(95)<500', 'p(99)<1000'],
    },
  },
  'capacity-hot-target': {
    vus: 2000,
    duration: '20m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_hot_write_errors: ['rate<0.001'],
      im_hot_write_send_latency: ['p(95)<300', 'p(99)<800'],
    },
  },
};

export const options = profiles[profile] || profiles['local-hot-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const commandBaseURL = (__ENV.IM_COMMAND_BASE_URL || baseURL).replace(/\/$/, '');
const email = __ENV.IM_EMAIL || 'demo@example.com';
const password = __ENV.IM_PASSWORD || 'password1234';
const memberEmails = (__ENV.IM_MEMBER_EMAILS || 'alice@example.com')
  .split(',')
  .map((value) => value.trim())
  .filter((value) => value.length > 0);
const internalSecret = __ENV.IM_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || '';
const metricsURL = (__ENV.IM_METRICS_URL || `${baseURL}/internal/metrics`).replace(/\/$/, '');
const metricsSecret =
  __ENV.IM_METRICS_SECRET || __ENV.IM_METRICS_INTERNAL_SECRET || __ENV.IM_INTERNAL_SHARED_SECRET || internalSecret;
const metricsSampleEvery = Number.parseInt(__ENV.IM_METRICS_SAMPLE_EVERY || '20', 10);
const sendIntervalMillis = Number.parseInt(__ENV.IM_SEND_INTERVAL_MS || '0', 10);

export const hotWriteErrors = new Rate('im_hot_write_errors');
export const hotWriteSendLatency = new Trend('im_hot_write_send_latency');
export const hotWriteQueueDepth = new Gauge('im_hot_write_queue_depth');
export const hotWriteOutboxBacklog = new Gauge('im_hot_write_outbox_backlog');
export const hotWriteProjectionLagMillis = new Gauge('im_hot_write_projection_lag_millis');

function jsonHeaders(token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return { headers };
}

function login() {
  const res = http.post(
    `${baseURL}/api/auth/login`,
    JSON.stringify({
      email,
      password,
      device: {
        deviceID: 'k6-hot-conversation-owner',
        deviceName: 'k6-hot-conversation',
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  check(res, { 'login ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`login failed: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createConversation(token) {
  if (__ENV.IM_CONVERSATION_ID) {
    return __ENV.IM_CONVERSATION_ID;
  }

  const res = http.post(
    `${baseURL}/api/im/conversations`,
    JSON.stringify({
      kind: 'group',
      title: `k6-hot-conversation-${Date.now()}`,
      memberEmails,
    }),
    jsonHeaders(token)
  );
  check(res, { 'create hot conversation ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    fail(`create conversation failed: ${res.status} ${res.body}`);
  }
  return res.json('id');
}

export function setup() {
  if (!internalSecret) {
    fail('IM_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET is required for hot conversation writes.');
  }

  const auth = login();
  return {
    senderUserID: auth.user.id,
    conversationID: createConversation(auth.accessToken),
  };
}

function sendInternalMessage(senderUserID, conversationID) {
  const startedAt = Date.now();
  const res = http.post(
    `${commandBaseURL}/internal/im/messages/send`,
    JSON.stringify({
      senderUserID,
      payload: {
        clientMessageID: `k6-hot-${__VU}-${__ITER}-${Date.now()}`,
        messageID: null,
        conversationID,
        senderUserID: null,
        serverSequence: null,
        serverTimestamp: null,
        content: richTextContent(`hot ${__VU}/${__ITER}`),
        derivedState: initialDerivedState(),
      },
    }),
    { headers: { 'Content-Type': 'application/json', 'X-IM-Internal-Secret': internalSecret } }
  );
  hotWriteSendLatency.add(Date.now() - startedAt);
  hotWriteErrors.add(res.status !== 200);
  check(res, { 'hot send accepted': (r) => r.status === 200 });
}

function metricValue(body, name) {
  const pattern = new RegExp(`^${name}(?:\\{[^}]*\\})?\\s+([-+]?\\d+(?:\\.\\d+)?)$`, 'm');
  const match = body.match(pattern);
  return match ? Number.parseFloat(match[1]) : null;
}

function sampleServerMetrics() {
  if (!metricsSecret || !Number.isFinite(metricsSampleEvery) || metricsSampleEvery <= 0) {
    return;
  }
  if (__VU !== 1 || __ITER % metricsSampleEvery !== 0) {
    return;
  }

  const res = http.get(metricsURL, { headers: { 'X-IM-Metrics-Secret': metricsSecret } });
  if (res.status !== 200) {
    return;
  }

  const writeQueueDepth = metricValue(res.body, 'im_conversation_write_queue_depth');
  const outboxBacklog = metricValue(res.body, 'im_outbox_backlog_events');
  const projectionLag = metricValue(res.body, 'im_projection_lag_millis');

  if (writeQueueDepth !== null) {
    hotWriteQueueDepth.add(writeQueueDepth);
  }
  if (outboxBacklog !== null) {
    hotWriteOutboxBacklog.add(outboxBacklog);
  }
  if (projectionLag !== null) {
    hotWriteProjectionLagMillis.add(projectionLag);
  }
}

export default function (data) {
  sendInternalMessage(data.senderUserID, data.conversationID);
  sampleServerMetrics();

  if (sendIntervalMillis > 0) {
    sleep(sendIntervalMillis / 1000);
  }
}
