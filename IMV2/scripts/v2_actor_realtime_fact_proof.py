"""Read-only aggregate proof for a fresh, owned planned-reconnect fixture.

The callback owns the connection, read-only/timeout policy and real SQL future.
This module never starts PostgreSQL, emits SQL rows or logs exception contents.
It is not an operation-specific lost-ACK proof: the Loader currently reports
closed event counters, not the identities of its injected operations.
"""
from __future__ import annotations

import json
from typing import Callable


FACT_PROOF_SQL = r"""
WITH receipts AS MATERIALIZED (
    SELECT *, operation_fingerprint IS NOT NULL AND operation_resolved_at_ms>0 AS is_accepted
    FROM im_v2.message_send_completions
), message_facts AS MATERIALIZED (
    SELECT m.*, c.is_accepted,
        (c.is_accepted IS TRUE AND c.message_id=m.message_id
         AND c.room_sequence=m.room_sequence AND c.timeline_sequence=m.timeline_sequence
         AND c.fingerprint_version=3 AND octet_length(c.request_fingerprint)=32
         AND octet_length(c.operation_fingerprint)=32 AND closure.room_id IS NULL) IS TRUE AS matches_receipt_and_domain
    FROM im_v2.messages m
    LEFT JOIN receipts c ON c.room_id=m.room_id AND c.sender_user_id=m.sender_user_id
        AND c.client_message_id=m.client_message_id
    LEFT JOIN im_v2.message_operation_closures closure ON closure.room_id=m.room_id
        AND closure.sender_user_id=m.sender_user_id AND closure.client_message_id=m.client_message_id
)
SELECT json_build_object(
    'databaseObservedAt', clock_timestamp(),
    'messages', (SELECT count(*) FROM message_facts),
    'distinctMessageKeys', (SELECT count(DISTINCT (room_id,sender_user_id,client_message_id)) FROM message_facts),
    'permanentReceipts', (SELECT count(*) FROM receipts),
    'acceptedReceipts', (SELECT count(*) FROM receipts WHERE is_accepted),
    'otherOrMalformedReceipts', (SELECT count(*) FROM receipts WHERE NOT is_accepted),
    'unmatchedMessageFacts', (SELECT count(*) FROM message_facts WHERE NOT matches_receipt_and_domain),
    'orphanAcceptedReceipts', (SELECT count(*) FROM receipts c WHERE c.is_accepted AND NOT EXISTS (
        SELECT 1 FROM im_v2.messages m WHERE m.room_id=c.room_id
            AND m.sender_user_id=c.sender_user_id AND m.client_message_id=c.client_message_id)),
    'completions', (SELECT count(*) FROM receipts),
    'closures', (SELECT count(*) FROM im_v2.message_operation_closures),
    'roomSequenceSum', (SELECT COALESCE(sum(room_sequence),0) FROM im_v2.rooms)
)::text
"""


def prove_message_facts(
    query: Callable[[str], str | bytes | dict],
    expected_acknowledged: int,
    *,
    fresh_fixture: bool,
) -> dict:
    """Execute one SQL snapshot and return only low-sensitivity aggregates.

    ``fresh_fixture`` asserts an exclusively owned direct-ring database with
    zero initial messages/receipts/closures/room sequences and no outside
    writers. Invoke after every Loader and server writer has actually drained,
    before stopping owned PostgreSQL. Pass whole-run ACKs, including injections.
    The callback must enforce read-only and bounded statement/acquisition time.
    """
    proof = {
        'formatVersion': 1,
        'scope': 'fresh_fixture_all_accepted_message_facts',
        'freshFixtureRequired': True,
        'freshFixtureAsserted': fresh_fixture,
        'expectedAcknowledged': expected_acknowledged,
        'passed': False,
        'status': 'unobserved',
        'reasons': [],
        'evidenceBoundary': (
            'One coherent SQL snapshot verifies full room/sender/operation keys, '
            'immutable success identity/fingerprints, acceptance message/sequence, '
            'domain completion and absence of a conflicting negative-outcome closure for every message. '
            'Unique-key counts alone do not prove fault recovery. This aggregate cannot '
            'identify the injected lost-ACK operations or prove App persistent recovery, '
            'automatic reconnect, delivery latency or absence of earlier rollback attempts.'
        ),
    }
    if not fresh_fixture:
        proof['reasons'] = ['fresh_fixture_not_asserted']
        return proof
    if type(expected_acknowledged) is not int or expected_acknowledged <= 0:
        proof['reasons'] = ['invalid_expected_acknowledged']
        return proof
    count_keys = (
        'messages', 'distinctMessageKeys', 'permanentReceipts', 'acceptedReceipts',
        'otherOrMalformedReceipts', 'unmatchedMessageFacts', 'orphanAcceptedReceipts',
        'completions', 'closures', 'roomSequenceSum',
    )
    try:
        raw = query(FACT_PROOF_SQL)
        observed = raw if isinstance(raw, dict) else json.loads(raw)
        if not isinstance(observed, dict) or not isinstance(observed.get('databaseObservedAt'), str):
            raise ValueError('invalid aggregate')
        if any(type(observed.get(k)) is not int or observed[k] < 0 for k in count_keys):
            raise ValueError('invalid counts')
        # Copy only a fixed field allowlist; never callback metadata or SQL rows.
        proof['observed'] = {k: observed[k] for k in ('databaseObservedAt', *count_keys)}
        proof['status'] = 'observed'
    except Exception:
        proof['reasons'] = ['fact_read_failed']
        return proof
    for key in ('messages', 'distinctMessageKeys', 'permanentReceipts', 'acceptedReceipts',
                'completions', 'roomSequenceSum'):
        if observed[key] != expected_acknowledged:
            proof['reasons'].append(key + '_ack_mismatch')
    for key in ('otherOrMalformedReceipts', 'unmatchedMessageFacts', 'orphanAcceptedReceipts', 'closures'):
        if observed[key] != 0:
            proof['reasons'].append(key + '_nonzero')
    proof['passed'] = not proof['reasons']
    return proof
