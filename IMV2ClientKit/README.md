# IM V2 Client Kit

`IMV2ClientKit` has its own local cache and protocol boundary. Its
currently implemented durable boundaries are:

- `V2AuthSession`: the sole owner of device credentials and refresh rotation.
- `V2KeychainCredentialStore`: one device-only Keychain record using
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- `V2SyncEngine` and `GRDBV2LocalSyncStore`: persisted-before-ACK incremental
  sync and snapshot-reset fencing in a separate SQLite schema. A reset fetches
  a signed manifest, stages and verifies each opaque page durably, then swaps
  the complete snapshot atomically before its ACK. A process interruption
  resumes only missing pages; it never clears the last ready projection.
  The opaque next-sync token and matching pending ACK receipt are stored with
  the local watermark, so a restart cannot ACK a different range by mistake.
  Accepted-message records are decoded into a queryable local message
  projection in that same SQLite transaction; malformed message payloads roll
  the batch back instead of advancing the watermark.
- `GRDBV2LocalSyncStore` excludes its managed directory, SQLite database, WAL,
  and SHM from device backup at creation and after each reopen. Local unsent
  commands are deliberately device-local, never a restore/migration channel.
- `V2CommandOutboxEngine` and `V2MembershipCommandOutboxEngine`: independent
  durable outboxes for messages and membership mutations. Membership changes
  retain their generated operation ID, expected revision, retry schedule, and
  terminal result. A `REVISION_CONFLICT` stores the server's current revision
  and is never retried as stale intent.
- `V2LocalStoreBootstrapper` is the only production entry point for the local
  store. It binds the SQLite database to a device-only Keychain marker. A
  database with no marker or a mismatched marker is treated as imported data,
  discarded, and rebuilt through authenticated sync; temporary Keychain
  unavailability pauses startup without touching the database.

`V2AuthSession.establish(_:)` is the sole credential-establishment boundary for
the separately trusted account/device-registration service. It writes the first
device credential record atomically and fences any older refresh. The session
writes `(predecessor credential, pending refresh operation ID)` before
contacting the refresh transport, shares one refresh task among callers, keeps
a retryable pending ID after network failure, and only returns a successor token
after the successor record is durable. Temporary Keychain unavailability pauses
the session instead of deleting credentials. A confirmed terminal server
rejection deletes the record and returns the session to unauthenticated state;
a stale refresh cannot recreate it afterward.

`V2ClientSessionBootstrapper` is the app-facing startup boundary: it requires
an authenticated V2 session before opening the installation-bound local store,
and accepts first credentials only from an injected trusted account/device
provider. It accepts credentials only through that explicit current provider;
there is no implicit login source.

`V2HTTPDeviceCredentialAuthTransport` is the native HTTPS refresh adapter for
`POST /v2/device-credentials/refresh`. It sends the durable refresh operation
ID with `no-store` request semantics, treats only 401/403 as terminal
credential rejection, and leaves network, 5xx, and malformed-response failures
retryable through `V2AuthSession`. The initial account-factor assertion and
first-credential provider remain deployment-injected; this kit does not select
or emulate a login method.

`V2HTTPAccountAssertionDeviceCredentialProvider` is the corresponding generic
initial-credential adapter for `POST /v2/device-credentials`. It receives an
opaque assertion only from an injected account-factor provider and a device ID
from an injected identity provider. The App's `V2DeviceRegistrationStore`
keeps account-scoped device/operation identities and a purpose-limited random
cancellation proof in device-local Keychain before requesting the factor;
the generic `V2KeychainDeviceCredentialRegistrationOperationStore` remains a
device-only adapter. Neither stores the account assertion. Registration replay
still requires a valid account factor and the server's bounded replay window.
HTTP issuance requires the exact cancellation identity and confirms it in the
response. A missing or mismatched confirmation durably hands off any received
revocation authority before rejecting login. New attempts have a ten-minute
issuance deadline; expiry rotates both IDs while retaining the old proof.
The issuer requires `V2IssuedCredentialRecovering`: production composition uses
`V2IssuedCredentialRecoveryStore` to persist received revocation authority
before returning credentials. After durable login adoption, finalization clears
the operation and received-result record. Cold recovery must precede interactive
registration so it does not abandon an in-flight result.

`V2HTTPDeviceRegistrationCancellationClient` sends a caller-owned
`V2DeviceRegistrationCancellation` to
`POST /v2/device-credentials/cancel-registration` without account authentication.
Its exact device, operation, proof and issue deadline survive retries; only an
empty 204 confirms cancellation, while an empty 410 reports server expiry.
The cancellation JSON encodes its typed device as
`"deviceID":{"rawValue":"CANONICAL-UUID"}`; the outer issuance request's
`deviceID` remains a string. Non-Swift callers must preserve this distinction.
The server can fence an unissued operation or revoke its bound issued session.
The registration ledger uses format 3, atomically migrating format 2 proofs
into jobs with durable retry state. Logout moves pending proofs to its
abandoned collection; `pendingCancellations()` and exact-match
`completeCancellation(_:)` allow recovery after a completely lost response.
`V2DeviceRegistrationCancellationRunner` observes this queue, retries transient
failures with bounded backoff, and pauses invalid requests/responses. Its App
owner runs while active, cancels and drains on background entry, and shares
aggregate cleanup status and manual retry with session revocation. Cold startup
must call `recoverUnclaimed(ownedBy:)` before interactive registration: pending
proofs matching an owned durable device are retired locally; unowned proofs
are queued. Only server cancellation or expiry settles a queued proof.
Legacy format-1 IDs are archived without fabricating proof;
their server cleanup needs an explicit deployment/recovery policy. The generic
device-only Keychain adapter retains unsupported old records and fails closed.

The package contains framework-neutral WebAuthn building blocks, but the app
does not expose them until the account service owns a complete challenge,
origin, RP-ID, signature-counter and credential-revocation implementation.
Password support currently lives in `V2HTTPPasswordAccountAuthenticator`;
callers pass the password only to a one-shot method and it is never persisted
by ClientKit.

`V2RealtimeSessionCoordinator` is the only app-facing transition from the
device-auth session to `V2TLSFrameConnection`: it obtains one coherent
user/device/access-token tuple (refreshing if needed), shares a concurrent
handshake, accepts only a matching authenticated identity, and clears the
local session after a terminal gateway rejection. The app can then pass the
same connected `V2TLSFrameConnection` to `V2ProtobufSyncTransport`; no view or
feature owns bearer-token handling.

`V2ClientRuntime` is the foreground lifecycle owner after that handshake. Its
`start()` shares concurrent attempts, completes the initial durable sync (and
any pending snapshot reset) before starting live-hint and heartbeat loops, and
its `stop()` owns cancellation plus connection shutdown. Views should only
drive foreground/background intent through this boundary; a live hint is never
treated as delivery state.

The app must inject concrete V2 auth and sync transports, plus a
`V2KeychainInstallationBindingStore` into `V2LocalStoreBootstrapper` before
opening the local database. No external transport, cache, credential, or
database-table state is read by this package.

## Verify

```sh
swift test --package-path IMV2ClientKit
```

For the native, disposable-scratch invocation used by this repository, run
`scripts/run_v2_clientkit_native_tests.sh`. It defaults to four compiler jobs
to avoid monopolizing the local Mac and explicitly uses the Xcode default Swift
toolchain so it matches macOS's test helper; set
`IMV2_CLIENTKIT_TEST_JOBS` when a different local resource limit is appropriate.

Unit tests use actor-isolated fake stores and transports. Keychain behavior
under device lock, reboot-before-first-unlock, entitlement/access-group changes,
and real terminal server errors still require simulator/device and backend
integration validation.


For format-1 legacy archives, use the prepared lease's
`recoveringLegacyRegistration(using:client:)` to wrap the fresh factor provider
with `V2HTTPLegacyRegistrationCancellationClient`. The App uses this composition
before new credential issuance. The same factor authorizes only its account's
old device, and only empty 204 permits exact archive completion. Failures retain
the archive; a new login attempt obtains a new factor and replays the original
operation. Full pending-lease and archived-identity comparisons fence late
completion. No password or account assertion is persisted. Format 3 retains a
single extra recovery slot (maximum 257 entries) when 256 legacy entries would
otherwise prevent recovery; ordinary registrations cannot consume that slot.
See the [recovery contract](../docs/reviews/legacy-registration-client-recovery-contract.md).
