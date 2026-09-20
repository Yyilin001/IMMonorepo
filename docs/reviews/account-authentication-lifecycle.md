# Account authentication lifecycle

The current branch adds account security to the password-based V2 deployment.
Passkey remains an extension point, with no public WebAuthn verifier advertised.

## Account factors

- Login names and public handles have separate conflicts. Password registration
  returns JSON `{ "code": "account_handle_taken" }` or
  `{ "code": "public_handle_taken" }` with 409 and no-store headers.
- Password login, password changes and recovery-code enrollment atomically debit
  the canonical account attempt budget **before** password derivation. Incomplete,
  cancelled and infrastructure-failed attempts remain charged until a successful
  authentication resets the budget or its window/lockout permits another attempt.
  This deliberately prevents disconnect-based refunds. There is no database
  connection held during Argon2 work. The per-process KDF cap and trusted edge
  address budget remain separate protections.
- 429 responses carry Retry-After delta seconds. The client displays a positive
  delay, with a generic throttling message when it is absent or malformed.

## Short-lived assertions

The HMAC assertion is a short-lived bearer credential, not a one-use ticket or
proof of a device private key. It is reusable within its lifetime for the bound
installation's registration and legacy registration cleanup. Operation ledgers
own idempotency and cancellation. Never persist the assertion on the client.

Password assertions include the credential revision. Device registration and
legacy registration cleanup compare this revision inside the same account-state
lock used by password changes. A pre-change assertion cannot recreate a session
or authorize cleanup after a password change or recovery commits. Independently
trusted non-password factors can use the existing verifier extension boundary.

## Password and recovery endpoints

All endpoints use the existing trusted account edge, HTTPS externally, the
shared address budget, no-store responses and an 8 KiB request limit. They return
empty 204 on success; 401 means factor rejection, 400 invalid input, 429 throttling,
and 503 unavailable or bounded KDF saturation. No endpoint returns secrets.

| Endpoint under `/v2/account-auth/password/` | Factor | Effect |
| --- | --- | --- |
| `change` | Login name + current password | Set new password, advance revision, clear recovery code, revoke every device |
| `recovery-code` | Login name + current password | Replace the recovery code digest |
| `recover` | Login name + saved recovery code | Set new password, consume code, advance revision, revoke every device |

The native Account Security page is reachable from the signed-out page and the
account menu. The client generates a 256-bit recovery code as 64 lowercase hex
characters and requires the user to save it outside the app before enrollment.
Only a domain-separated HMAC digest is stored, using the existing token HMAC key.
Key rotation therefore also invalidates recovery codes and requires an explicit
re-enrollment plan. The client does not automatically store codes or copy them to
the clipboard. The user may select the code for saving to their chosen vault.

A recovery code cannot bypass permanent account disable. Without the password or
a previously enrolled recovery code, there is no self-service identity proof;
public profile information is never accepted as a recovery factor. Recovery does
not share the password lockout (which an attacker could trigger); its 256-bit
secret and the trusted edge budget protect it. Successful mutation and bounded
security audit are committed together. Concurrent recovery consumes the code
once. Password changes revoke all sessions and require a fresh login and recovery
code enrollment.

Responses can be lost after commit. The UI treats network failures as an unknown
outcome: try the new password after a change/reset, or retry enrollment with the
same saved code. It never silently generates a replacement or automatically
retries a mutation. Do not log passwords, recovery codes, request bodies or hashes.

## Deployment

Schema `im-v2-current-36` adds a positive credential revision and nullable recovery
HMAC to password credentials, and expands bounded password audit outcomes.
New installations use `IMV2/sql/schema.sql`. Existing current-35 installations
must stop/drain account issuers, back up the database, apply
`IMV2/sql/upgrades/account-lifecycle-35-to-36.sql`, and restart services on the new
code. The migration preserves accounts and existing device sessions. Legacy
unversioned assertions are rejected; interrupted initial logins retry. Do not run
old issuers alongside the new password mutation endpoints. Migration failure
rolls back the transaction; after accepting new lifecycle operations, rollback
requires restoring a pre-upgrade backup with corresponding credential invalidation,
not deleting the new columns from live data.

## Verification

Regression coverage includes distinct registration errors, Retry-After parsing,
20 concurrent account-budget debits admitting only 3 attempts, password mutation,
old-password rejection, device-token rejection, old assertion revision rejection,
and concurrent recovery with exactly one successful consumer. Run database tests
only with an explicitly disposable PostgreSQL database.
