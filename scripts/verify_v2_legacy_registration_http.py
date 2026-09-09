"""Acceptance extension for the owned native HTTPS/PostgreSQL harness only."""
import base64
import http.client
import json
import os
import ssl
import subprocess
import time
import uuid


def verify_legacy_registration(port, ca, database_arguments, environment, output):
    endpoint = '/v2/device-credentials/cancel-legacy-registration'
    context = ssl.create_default_context(cafile=str(ca))

    def request(method, path, expected, body=None, credentials=None, opaque=False):
        connection = http.client.HTTPSConnection('localhost', port, timeout=15, context=context)
        headers = {'Content-Type': 'application/json'}
        if credentials:
            headers.update(Authorization='Bearer ' + credentials['accessToken'])
            headers['X-IM-Device-ID'] = credentials['deviceID']
        try:
            connection.request(method, path, None if body is None else json.dumps(body), headers)
            response = connection.getresponse()
            data = response.read()
            assert response.status == expected, '{} {} expected {} got {}'.format(method, path, expected, response.status)
            if opaque:
                assert data == b''
                assert response.getheader('Cache-Control') == 'no-store'
                assert response.getheader('Pragma') == 'no-cache'
            return json.loads(data) if data else None
        finally:
            connection.close()

    def sql(statement):
        return subprocess.check_output(['psql', '-X', '-A', '-t', *database_arguments,
            '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1', '-c', statement],
            env=environment, text=True, stderr=subprocess.PIPE).strip()

    def identifier():
        return str(uuid.uuid4()).upper()

    def factor(account, device, register=False):
        body = dict(accountHandle=account['handle'], password=account['password'], deviceID=device)
        if register:
            body.update(publicHandle=account['handle'], displayName='Legacy Recovery')
        return request('POST', '/v2/account-auth/password/' + ('register' if register else 'assertion'), 200, body)['accountAssertion']

    def issue(assertion, device, expected=200):
        operation = identifier()
        proof = dict(deviceID=dict(rawValue=device), operationID=operation,
            proof='imv2-cancel-registration-v1.' + base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('='),
            issueBeforeMilliseconds=int(time.time() * 1000) + 600000)
        return request('POST', '/v2/device-credentials', expected,
            dict(accountAssertion=assertion, deviceID=device, operationID=operation, cancellation=proof))

    account = dict(handle='legacy_' + uuid.uuid4().hex[:12], password=uuid.uuid4().hex + 'aA!7')
    other = dict(handle='legacy_' + uuid.uuid4().hex[:12], password=uuid.uuid4().hex + 'aA!7')
    old, current, unissued = identifier(), identifier(), identifier()
    old_credentials = issue(factor(account, old, register=True), old)
    user = str(uuid.UUID(old_credentials['userID']))
    fresh = factor(account, current)
    cancellation = dict(accountAssertion=fresh, assertionDeviceID=current, targetDeviceID=old, operationID=identifier())
    # The real factor is checked before any target effect. An access token,
    # changed assertion device, or caller-supplied account is never authority.
    request('POST', endpoint, 401, dict(cancellation, accountAssertion=old_credentials['accessToken']), opaque=True)
    request('POST', endpoint, 401, dict(cancellation, assertionDeviceID=identifier()), opaque=True)
    request('POST', endpoint, 400, dict(cancellation, userID=user), opaque=True)
    request('GET', '/v2/devices', 200, credentials=old_credentials)
    sql("""CREATE FUNCTION im_v2.test_legacy_http_failure() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN IF NEW.device_id = '{0}'::uuid THEN RAISE EXCEPTION 'injected legacy HTTP failure'; END IF; RETURN NEW; END $$;
        CREATE TRIGGER test_legacy_http_failure AFTER INSERT ON im_v2.device_revocation_events
        FOR EACH ROW EXECUTE FUNCTION im_v2.test_legacy_http_failure()""".format(old))
    request('POST', endpoint, 503, cancellation, opaque=True)
    def target_state():
        return sql("""SELECT
            (SELECT count(*) FROM im_v2.legacy_device_registration_cancellations WHERE user_id='{0}' AND device_id='{1}'),
            (SELECT count(*) FROM im_v2.auth_devices WHERE device_id='{1}' AND revoked_at IS NULL),
            (SELECT count(*) FROM im_v2.device_access_tokens WHERE device_id='{1}' AND revoked_at IS NULL),
            (SELECT count(*) FROM im_v2.device_refresh_sessions WHERE device_id='{1}' AND revoked_at IS NULL),
            (SELECT count(*) FROM im_v2.device_revocation_events WHERE device_id='{1}')""".format(user, old))
    assert target_state() == '0|1|1|1|0'
    request('GET', '/v2/devices', 200, credentials=old_credentials)
    sql('DROP TRIGGER test_legacy_http_failure ON im_v2.device_revocation_events; DROP FUNCTION im_v2.test_legacy_http_failure()')
    request('POST', endpoint, 204, cancellation, opaque=True)
    request('POST', endpoint, 204, cancellation, opaque=True)
    assert target_state() == '1|0|0|0|1'
    request('GET', '/v2/devices', 401, credentials=old_credentials)
    # Cleanup and subsequent new-device issuance share the same factor without
    # retaining or hashing the password twice in the prospective client flow.
    new_credentials = issue(fresh, current)
    request('POST', endpoint, 204, cancellation, opaque=True)
    request('GET', '/v2/devices', 200, credentials=new_credentials)
    pending = dict(cancellation, targetDeviceID=unissued, operationID=identifier())
    request('POST', endpoint, 204, pending, opaque=True)
    issue(factor(account, unissued), unissued, expected=403)
    # An account-scoped unissued tombstone does not reserve a global ID.
    other_credentials = issue(factor(other, unissued, register=True), unissued)
    request('POST', endpoint, 404, pending, opaque=True)
    request('GET', '/v2/devices', 200, credentials=other_credentials)
    # Capacity is permanent for this retained ledger, unlike address 429.
    sql("INSERT INTO im_v2.legacy_device_registration_cancellations SELECT '{0}'::uuid, gen_random_uuid(), gen_random_uuid(), CURRENT_TIMESTAMP FROM generate_series(1,254)".format(user))
    request('POST', endpoint, 507, dict(cancellation, targetDeviceID=identifier(), operationID=identifier()), opaque=True)
    request('POST', endpoint, 204, cancellation, opaque=True)
    request('POST', endpoint, 409, dict(cancellation, operationID=identifier()), opaque=True)
    assert sql("SELECT count(*) FROM im_v2.legacy_device_registration_cancellations WHERE user_id='{0}'".format(user)) == '256'
    assert target_state() == '1|0|0|0|1'
    request('GET', '/v2/devices', 200, credentials=new_credentials)
    request('GET', '/v2/devices', 200, credentials=other_credentials)
    (output / 'legacy-http.log').write_text(
        'PASS real password factor and HTTPS: rejected wrong-device/access-token/caller-account authority; '
        '503 transaction rollback 0|1|1|1|0; retry and repeated 204 state 1|0|0|0|1; '
        'same-factor new login preserved; cancelled unissued target cannot issue for the original account; '
        'another account can issue and survives 404 cleanup; 256 capacity returns 507 while replay remains 204 and conflicts 409.\n'
        'This extension runs after the baseline persistence checks and adds three devices, one revocation event, and 256 account-scoped tombstones.\n')
