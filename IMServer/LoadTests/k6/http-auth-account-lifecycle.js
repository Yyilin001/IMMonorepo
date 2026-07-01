import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'account-lifecycle-smoke';
const profiles = {
  'account-lifecycle-smoke': {
    vus: 2,
    duration: '30s',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_account_lifecycle_errors: ['rate<0.001'],
      im_account_register_latency: ['p(95)<2000', 'p(99)<5000'],
      im_account_verification_resend_latency: ['p(95)<1000', 'p(99)<2500'],
      im_account_password_reset_request_latency: ['p(95)<1000', 'p(99)<2500'],
      im_account_lifecycle_total_latency: ['p(95)<5000', 'p(99)<10000'],
    },
  },
  'account-lifecycle-confirm-smoke': {
    vus: 1,
    duration: '30s',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_account_lifecycle_errors: ['rate<0.001'],
      im_account_register_latency: ['p(95)<2000', 'p(99)<5000'],
      im_account_verification_resend_latency: ['p(95)<1000', 'p(99)<2500'],
      im_account_verification_confirm_latency: ['p(95)<1000', 'p(99)<2500'],
      im_account_password_reset_request_latency: ['p(95)<1000', 'p(99)<2500'],
      im_account_password_reset_confirm_latency: ['p(95)<2000', 'p(99)<5000'],
      im_account_lifecycle_total_latency: ['p(95)<8000', 'p(99)<15000'],
    },
  },
  'account-lifecycle-baseline': {
    vus: 50,
    duration: '5m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_account_lifecycle_errors: ['rate<0.001'],
      im_account_register_latency: ['p(95)<3000', 'p(99)<7000'],
      im_account_verification_resend_latency: ['p(95)<1500', 'p(99)<3000'],
      im_account_password_reset_request_latency: ['p(95)<1500', 'p(99)<3000'],
      im_account_lifecycle_total_latency: ['p(95)<8000', 'p(99)<15000'],
    },
  },
  'account-lifecycle-confirm-baseline': {
    vus: 20,
    duration: '5m',
    thresholds: {
      http_req_failed: ['rate<0.005'],
      im_account_lifecycle_errors: ['rate<0.001'],
      im_account_register_latency: ['p(95)<3000', 'p(99)<7000'],
      im_account_verification_resend_latency: ['p(95)<1500', 'p(99)<3000'],
      im_account_verification_confirm_latency: ['p(95)<1500', 'p(99)<3000'],
      im_account_password_reset_request_latency: ['p(95)<1500', 'p(99)<3000'],
      im_account_password_reset_confirm_latency: ['p(95)<3000', 'p(99)<7000'],
      im_account_lifecycle_total_latency: ['p(95)<12000', 'p(99)<25000'],
    },
  },
  'account-lifecycle-capacity': {
    vus: 200,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_account_lifecycle_errors: ['rate<0.005'],
      im_account_register_latency: ['p(95)<5000', 'p(99)<10000'],
      im_account_verification_resend_latency: ['p(95)<3000', 'p(99)<6000'],
      im_account_password_reset_request_latency: ['p(95)<3000', 'p(99)<6000'],
      im_account_lifecycle_total_latency: ['p(95)<15000', 'p(99)<30000'],
    },
  },
  'account-lifecycle-confirm-capacity': {
    vus: 100,
    duration: '10m',
    thresholds: {
      http_req_failed: ['rate<0.01'],
      im_account_lifecycle_errors: ['rate<0.005'],
      im_account_register_latency: ['p(95)<5000', 'p(99)<10000'],
      im_account_verification_resend_latency: ['p(95)<3000', 'p(99)<6000'],
      im_account_verification_confirm_latency: ['p(95)<3000', 'p(99)<6000'],
      im_account_password_reset_request_latency: ['p(95)<3000', 'p(99)<6000'],
      im_account_password_reset_confirm_latency: ['p(95)<6000', 'p(99)<12000'],
      im_account_lifecycle_total_latency: ['p(95)<25000', 'p(99)<45000'],
    },
  },
};

export const options = profiles[profile] || profiles['account-lifecycle-smoke'];

const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const accountPrefix = __ENV.IM_ACCOUNT_LIFECYCLE_PREFIX || __ENV.IM_ACCOUNT_PREFIX || 'k6-account';
const accountDomain = __ENV.IM_ACCOUNT_DOMAIN || 'example.com';
const accountPassword = __ENV.IM_ACCOUNT_LIFECYCLE_PASSWORD || __ENV.IM_ACCOUNT_PASSWORD || __ENV.IM_PASSWORD || 'password1234';
const resetNewPassword = __ENV.IM_ACCOUNT_LIFECYCLE_NEW_PASSWORD || 'changed12345';
const sleepMillis = Number.parseInt(__ENV.IM_ACCOUNT_LIFECYCLE_SLEEP_MS || '250', 10);
const confirmLifecycle = (__ENV.IM_ACCOUNT_LIFECYCLE_CONFIRM || '').toLowerCase() === 'true' || profile.includes('confirm');
const authEmailSinkURL = (__ENV.IM_AUTH_EMAIL_WEBHOOK_SINK_URL || '').replace(/\/$/, '');
const verificationCodeOverride = __ENV.IM_ACCOUNT_VERIFICATION_CODE || '';
const passwordResetCodeOverride = __ENV.IM_ACCOUNT_PASSWORD_RESET_CODE || '';
const codePollTimeoutMillis = Number.parseInt(__ENV.IM_ACCOUNT_CODE_POLL_TIMEOUT_MS || '10000', 10);
const codePollIntervalMillis = Number.parseInt(__ENV.IM_ACCOUNT_CODE_POLL_INTERVAL_MS || '250', 10);

export const lifecycleErrors = new Rate('im_account_lifecycle_errors');
export const registerLatency = new Trend('im_account_register_latency');
export const verificationResendLatency = new Trend('im_account_verification_resend_latency');
export const verificationConfirmLatency = new Trend('im_account_verification_confirm_latency');
export const passwordResetRequestLatency = new Trend('im_account_password_reset_request_latency');
export const passwordResetConfirmLatency = new Trend('im_account_password_reset_confirm_latency');
export const totalLatency = new Trend('im_account_lifecycle_total_latency');

function jsonHeaders(token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return { headers };
}

function uniqueEmail() {
  return `${accountPrefix}-${Date.now()}-${__VU}-${__ITER}@${accountDomain}`;
}

function register(email) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/auth/register`,
    JSON.stringify({
      email,
      password: accountPassword,
      device: {
        deviceID: `k6-account-lifecycle-${__VU}-${__ITER}`,
        deviceName: 'k6-account-lifecycle',
        platform: 'load-test',
        appVersion: 'k6',
      },
    }),
    jsonHeaders()
  );
  registerLatency.add(Date.now() - startedAt);
  check(res, { 'account register ok': (r) => r.status === 200 });
  if (res.status !== 200) {
    return null;
  }
  const body = res.json();
  return body && (body.state === 'signedIn' || body.state === 'verificationRequired') ? body : null;
}

function resendVerification(email) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/auth/email-verifications/resend`,
    JSON.stringify({ email }),
    jsonHeaders()
  );
  verificationResendLatency.add(Date.now() - startedAt);
  check(res, { 'account verification resend ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function requestPasswordReset(email) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/auth/password-resets/request`,
    JSON.stringify({ email }),
    jsonHeaders()
  );
  passwordResetRequestLatency.add(Date.now() - startedAt);
  check(res, { 'account password reset request ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function latestCode(type, email, overrideCode) {
  if (overrideCode) {
    return overrideCode;
  }
  if (!authEmailSinkURL) {
    return '';
  }

  const deadline = Date.now() + Math.max(0, codePollTimeoutMillis);
  while (Date.now() <= deadline) {
    const res = http.get(
      `${authEmailSinkURL}/codes?type=${encodeURIComponent(type)}&email=${encodeURIComponent(email)}`
    );
    if (res.status === 200) {
      const body = res.json();
      if (body && body.code) {
        return body.code;
      }
    }
    sleep(Math.max(1, codePollIntervalMillis) / 1000);
  }
  return '';
}

function confirmVerification(email, code) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/auth/email-verifications/confirm`,
    JSON.stringify({ email, code }),
    jsonHeaders()
  );
  verificationConfirmLatency.add(Date.now() - startedAt);
  check(res, { 'account verification confirm ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function confirmPasswordReset(email, code) {
  const startedAt = Date.now();
  const res = http.post(
    `${baseURL}/api/auth/password-resets/confirm`,
    JSON.stringify({ email, code, newPassword: resetNewPassword }),
    jsonHeaders()
  );
  passwordResetConfirmLatency.add(Date.now() - startedAt);
  check(res, { 'account password reset confirm ok': (r) => r.status === 200 });
  return res.status === 200 ? res.json() : null;
}

function logout(auth) {
  if (!auth || !auth.accessToken) {
    return true;
  }
  const res = http.post(`${baseURL}/api/auth/logout`, null, {
    headers: { Authorization: `Bearer ${auth.accessToken}` },
  });
  return res.status === 200;
}

export default function () {
  const startedAt = Date.now();
  const email = uniqueEmail();

  const registered = register(email);
  if (!registered) {
    lifecycleErrors.add(true);
    return;
  }

  const resend = resendVerification(email);
  if (!resend || resend.email !== email) {
    lifecycleErrors.add(true);
    return;
  }
  if (confirmLifecycle) {
    const code = latestCode('email_verification', email, verificationCodeOverride);
    if (!code || !confirmVerification(email, code)) {
      lifecycleErrors.add(true);
      return;
    }
  }

  const reset = requestPasswordReset(email);
  if (!reset || reset.email !== email) {
    lifecycleErrors.add(true);
    return;
  }
  if (confirmLifecycle) {
    const code = latestCode('password_reset', email, passwordResetCodeOverride);
    if (!code || !confirmPasswordReset(email, code)) {
      lifecycleErrors.add(true);
      return;
    }
  }

  if (!confirmLifecycle && registered.auth && !logout(registered.auth)) {
    lifecycleErrors.add(true);
    return;
  }

  totalLatency.add(Date.now() - startedAt);
  lifecycleErrors.add(false);
  sleep(Math.max(0, sleepMillis) / 1000);
}
