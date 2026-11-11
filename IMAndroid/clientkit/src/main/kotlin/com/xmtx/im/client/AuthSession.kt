package com.xmtx.im.client

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID

/** Store the entire journal atomically, encrypted with a device-bound key. */
interface SecretStore { suspend fun read(): String?; suspend fun write(value: String); suspend fun delete() }
@Serializable data class Credentials(val userId: UserId, val deviceId: DeviceId, val accessToken: String,
    val accessExpiresAt: Long, val refreshCredential: String, val revocationCredential: String, val revocationExpiresAt: Long) {
    init {
        require(accessToken.isNotBlank() && refreshCredential.isNotBlank() && !accessToken.any { it.code < 32 })
        require(revocationCredential.startsWith("imv2-revoke-v1."))
        val suffix = revocationCredential.removePrefix("imv2-revoke-v1.")
        val bytes = Base64.getUrlDecoder().decode(suffix)
        require(bytes.size == 32 && Base64.getUrlEncoder().withoutPadding().encodeToString(bytes) == suffix)
        require(accessExpiresAt > 0 && revocationExpiresAt > 0)
    }
    override fun toString() = "Credentials(<redacted>)"
}
@Serializable data class Registration(val account: String, val device: DeviceId, val operation: String, val proof: String, val deadline: Long) {
    fun cancellation(): JsonObject = buildJsonObject {
        put("deviceID", buildJsonObject { put("rawValue", device.value) })
        put("operationID", operation); put("proof", proof); put("issueBeforeMilliseconds", deadline)
    }
    override fun toString() = "Registration(<redacted>)"
}
@Serializable private data class AuthJournal(val credentials: Credentials? = null, val refreshOperation: String? = null,
    val registration: Registration? = null, val revoking: Boolean = false, val revocationOperation: String? = null) {
    override fun toString() = "AuthJournal(<redacted>)"
}

/** A single owner serializes refresh, registration and logout; retries reuse persisted identities. */
class AuthSession private constructor(private val store: SecretStore, private val api: AccountTransport,
    private val now: () -> Long, private val exitMarker: LocalExitMarker?, private val issuedRecovery: IssuedCredentialRecoveryStore? = null,
    private val registrations: DeviceRegistrationStore? = null) {
    constructor(store: SecretStore, api: AccountTransport, now: () -> Long = System::currentTimeMillis) : this(store, api, now, null)
    constructor(store: SecretStore, api: AccountTransport, exitMarker: LocalExitMarker,
        now: () -> Long = System::currentTimeMillis) : this(store, api, now, exitMarker)
    constructor(store: SecretStore, api: AccountTransport, exitMarker: LocalExitMarker,
        issuedRecovery: IssuedCredentialRecoveryStore, now: () -> Long = System::currentTimeMillis) : this(store, api, now, exitMarker, issuedRecovery)
    constructor(store: SecretStore, api: AccountTransport, exitMarker: LocalExitMarker,
        issuedRecovery: IssuedCredentialRecoveryStore, registrations: DeviceRegistrationStore,
        now: () -> Long = System::currentTimeMillis) : this(store, api, now, exitMarker, issuedRecovery, registrations)
    private val mutex = Mutex()
    private val json = Json { ignoreUnknownKeys = true }
    @Volatile private var epoch = AuthSessionEpoch()
    private val updates = AuthSessionUpdates(epoch)
    private var observed = false
    private var observedIdentity: Pair<UserId, DeviceId>? = null
    private var terminal = false
    private data class RefreshFlight(val id: Any, val epoch: AuthSessionEpoch, val source: AuthJournal, val operation: SharedOperation<Credentials>)
    private val refreshFlights = mutableMapOf<Any, RefreshFlight>()

    private fun observe(value: AuthJournal) {
        val identity = value.takeUnless { it.revoking || it.revocationOperation != null }?.credentials?.let { it.userId to it.deviceId }
        if (!terminal && observed && observedIdentity != identity) advanceEpoch(when {
            value.revoking || value.revocationOperation != null -> AuthSessionSnapshot.EndReason.CredentialDeletionPending
            identity == null -> AuthSessionSnapshot.EndReason.AuthenticationRequired
            else -> AuthSessionSnapshot.EndReason.Superseded
        })
        observed = true; observedIdentity = identity
        if (!terminal) updates.publish(when {
            value.revoking || value.revocationOperation != null -> AuthSessionState.CleanupPending
            value.credentials != null -> if (refreshFlights.values.any { it.epoch === epoch && it.source == value })
                AuthSessionState.Refreshing else AuthSessionState.Authenticated(value.credentials.accessExpiresAt)
            value.registration != null -> AuthSessionState.Establishing
            else -> AuthSessionState.Unauthenticated
        })
    }
    private suspend fun read(): AuthJournal {
        refreshFlights.entries.removeAll { it.value.operation.isCompleted }
        val record = credentialIO { store.read() }
        val value = try { record?.let { json.decodeFromString<AuthJournal>(it) } ?: AuthJournal() }
        catch (_: Exception) {
            if (!terminal) updates.publish(AuthSessionState.CredentialsUnavailable(CredentialStoreFailure.Reason.Malformed))
            throw CredentialStoreFailure(CredentialStoreFailure.Reason.Malformed)
        }
        observe(value); return value
    }
    private suspend fun save(value: AuthJournal) { credentialIO { store.write(json.encodeToString(value)) }; observe(value) }
    private suspend fun <T> credentialIO(body: suspend () -> T): T = try { body() }
    catch (error: kotlinx.coroutines.CancellationException) { throw error }
    catch (error: Exception) {
        if (!terminal) updates.publish(AuthSessionState.CredentialsUnavailable(
            (error as? CredentialStoreFailure)?.reason ?: CredentialStoreFailure.Reason.Unavailable))
        throw error
    }
    private fun advanceEpoch(reason: AuthSessionSnapshot.EndReason) {
        val next = AuthSessionEpoch(); updates.advance(next, reason); epoch = next
    }
    private fun beginTerminal() {
        if (!terminal) advanceEpoch(AuthSessionSnapshot.EndReason.CredentialDeletionPending)
        terminal = true; updates.publish(AuthSessionState.CleanupPending)
    }
    private suspend fun pendingExit(): Boolean = try { (exitMarker?.isPending() == true).also { if (it) beginTerminal() } }
    catch (error: kotlinx.coroutines.CancellationException) { throw error }
    catch (error: Exception) {
        if (!terminal) updates.publish(AuthSessionState.ExitUnavailable((error as? LocalExitFailure)?.reason ?: LocalExitFailure.Reason.Unavailable))
        throw error
    }
    private fun checkEpoch(expected: AuthSessionEpoch?) {
        if (expected != null && expected !== epoch) throw ClientFailure.SessionInvalidated()
    }
    fun currentEpoch(): AuthSessionEpoch = epoch
    fun currentState(): AuthSessionState = updates.current()
    fun sessionUpdates(expected: AuthSessionEpoch) = updates.stream(expected)
    /** Local restore only, without access-token refresh or network activity. */
    suspend fun restoreState(): AuthSessionState = mutex.withLock {
        if (!terminal && !pendingExit()) read()
        updates.current()
    }

    /** Reads local evidence without refreshing even an expired access token or pending refresh. */
    suspend fun localAccountIdentity(): LocalAccountIdentity = mutex.withLock { localIdentityLocked() }
    private suspend fun localIdentityLocked(): LocalAccountIdentity {
        kotlinx.coroutines.currentCoroutineContext().ensureActive()
        if (terminal || pendingExit()) throw ClientFailure.SignedOut()
        val credentials = read().takeUnless { it.revoking || it.revocationOperation != null }?.credentials ?: throw ClientFailure.SignedOut()
        kotlinx.coroutines.currentCoroutineContext().ensureActive()
        return LocalAccountIdentity(credentials.userId, credentials.deviceId, epoch)
    }
    suspend fun requireLocalIdentity(expected: LocalAccountIdentity) = mutex.withLock {
        checkEpoch(expected.epoch)
        if (localIdentityLocked() != expected) throw ClientFailure.SessionInvalidated()
    }
    suspend fun requireLocalIdentityEpoch(expected: AuthSessionEpoch) = mutex.withLock {
        checkEpoch(expected); localIdentityLocked(); checkEpoch(expected)
    }

    suspend fun current(expectedEpoch: AuthSessionEpoch? = null): Credentials? = mutex.withLock {
        val credentials = if (terminal || pendingExit()) null else read().takeUnless { it.revoking || it.revocationOperation != null }?.credentials
        if (expectedEpoch != null && expectedEpoch !== epoch && credentials == null) throw ClientFailure.SignedOut()
        checkEpoch(expectedEpoch); credentials
    }
    suspend fun login(account: String, password: String, register: Boolean = false,
        publicHandle: String = "", displayName: String = ""): Credentials = mutex.withLock {
        require(account.matches(Regex("[A-Za-z0-9_-]{3,64}"))) { "账号需为 3–64 位字母、数字、下划线或连字符" }
        require(password.toByteArray().size in 12..1024 && '\u0000' !in password) { "密码需为 12–1024 个 UTF-8 字节" }
        registerLocked(account) {device->
            AccountAssertion(api.post("/v2/account-auth/password/${if (register) "register" else "assertion"}", buildJsonObject {
                put("accountHandle", account); put("password", password); put("deviceID", device.value)
                if (register) { put("publicHandle", publicHandle); put("displayName", displayName) }
            }).string("accountAssertion"))
        }
    }

    /** Scope is a stable local deployment/account label for retries, never an assertion or signature.
     * The provider is called anew on each attempt with the already-journaled device identity. */
    suspend fun registerDevice(registrationScope:String,provider:DeviceBoundAccountAssertionProvider):Credentials=mutex.withLock {
        require(registrationScope.isNotBlank() && registrationScope.length<=256 && registrationScope.none {it.code<32 || it.code==127}) {"注册范围无效"}
        registerLocked("assertion:$registrationScope",provider::accountAssertion)
    }

    private suspend fun registerLocked(account:String,assertions:suspend (DeviceId)->AccountAssertion):Credentials {
        recoverIssuedLocked()
        check(!terminal && !pendingExit()) { "请先完成退出登录" }
        var journal = read()
        check(!terminal && !journal.revoking && journal.revocationOperation == null) { "请先完成退出登录" }
        check(journal.credentials == null) { "请先完成退出登录" }
        advanceEpoch(AuthSessionSnapshot.EndReason.Superseded)
        updates.publish(AuthSessionState.Establishing)
        journal.registration?.let { old ->
            if (registrations != null || old.account != account || old.deadline <= now()) {
                if (registrations != null) registrations.enqueueCancellation(RegistrationCancellation.from(old)) else cancelRegistration(old)
                journal = journal.copy(registration = null); save(journal)
            }
        }
        val prepared = registrations?.prepareScope(account)
        val pending = prepared?.load()?.let { Registration(account, it.device, it.operation, it.proof, it.deadline) }
            ?: journal.registration ?: Registration(account, DeviceId(UUID.randomUUID().toString().uppercase()),
            UUID.randomUUID().toString().uppercase(), "imv2-cancel-registration-v1." + Base64.getUrlEncoder().withoutPadding()
                .encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) }), now() + 600_000)
        // A managed registration has exactly one authoritative pending record, not a second copy
        // in the auth journal that could be replayed after its cancellation job has completed.
        val source = if (prepared == null) journal.copy(registration = pending) else journal
        if (prepared == null) save(source)
        val establishmentEpoch = epoch
        val assertion=assertions(pending.device)
        kotlinx.coroutines.currentCoroutineContext().ensureActive()
        check(pending.deadline>now()) {"设备注册已过期，请重试"}
        val issued = api.post("/v2/device-credentials", buildJsonObject {
            put("accountAssertion", assertion.value); put("deviceID", pending.device.value); put("operationID", pending.operation)
            put("cancellation", pending.cancellation()); put("deviceName", "Android"); put("platform", "Android")
        })
        val credentials = decodeCredentials(issued)
        val recovery = issuedRecovery
        if (recovery != null) {
            // Received authority outlives the initiating waiter. Lost HTTP responses remain covered
            // by the registration cancellation proof persisted before issuing the request.
            val receipt = withContext(NonCancellable) { recovery.receive(credentials, pending.operation) }
            try {
                currentCoroutineContext().ensureActive()
                checkEpoch(establishmentEpoch)
                if (read() != source) throw ClientFailure.SessionInvalidated()
                checkEpoch(establishmentEpoch)
                if (credentials.deviceId != pending.device || issued["registrationCancellation"] != pending.cancellation()) throw ClientFailure.Protocol()
                save(AuthJournal(credentials = credentials))
                currentCoroutineContext().ensureActive()
                if (read() != AuthJournal(credentials = credentials)) {
                    updates.publish(AuthSessionState.CredentialsUnavailable(CredentialStoreFailure.Reason.Unavailable))
                    throw CredentialStoreFailure(CredentialStoreFailure.Reason.Unavailable)
                }
                withContext(NonCancellable) { prepared?.finish(); recovery.adopt(receipt) }
                return credentials
            } catch (error: Exception) {
                // Unknown save failures leave an awaiting receipt for comparison with durable truth.
                if (error is CancellationException || error is ClientFailure.SessionInvalidated || error is ClientFailure.Protocol) {
                    withContext(NonCancellable) { settleInterruptedIssue(source, credentials, receipt, recovery, prepared) }
                }
                throw error
            }
        }
        // Persist a received credential as revoking until exact registration confirmation is verified.
        save(AuthJournal(credentials = credentials, registration = pending, revoking = true))
        if (credentials.deviceId != pending.device || issued["registrationCancellation"] != pending.cancellation()) throw ClientFailure.Protocol()
        save(AuthJournal(credentials = credentials))
        return credentials
    }

    private suspend fun settleInterruptedIssue(source: AuthJournal, credentials: Credentials,
        receipt: CredentialRevocationIntent, recovery: IssuedCredentialRecoveryStore, prepared: PreparedDeviceRegistration?) {
        val current = read()
        val owned = !terminal && !pendingExit() && !current.revoking && current.revocationOperation == null &&
            current.credentials?.let { it.userId == credentials.userId && it.deviceId == credentials.deviceId &&
                it.revocationCredential == credentials.revocationCredential && it.revocationExpiresAt == credentials.revocationExpiresAt } == true
        if (owned) { prepared?.finish(); recovery.adopt(receipt); return }
        if (current == source) {
            // Never replay an operation whose issued result has been handed to revocation.
            beginTerminal(); exitMarker?.markPending(); save(source.copy(revoking = true))
        }
        recovery.abandon(receipt)
        if (prepared != null) {
            if (prepared.cancellation.device == credentials.deviceId) prepared.finish() else prepared.abandon()
        }
    }

    /** Local startup recovery, serialized with registration. Does not send revocations or guess
     * ownership when the auth journal/exit marker is unreadable. */
    suspend fun recoverIssuedCredentials() = mutex.withLock { recoverIssuedLocked(recoverRegistrations = true) }
    private suspend fun recoverIssuedLocked(recoverRegistrations: Boolean = false) {
        val recovery = issuedRecovery ?: return
        val exiting = terminal || pendingExit()
        var journal = read()
        var owned = journal.takeUnless { exiting || it.revoking || it.revocationOperation != null }?.credentials
        if (journal.registration?.let { recovery.requiresAbandonment(it.operation, owned) } == true) {
            beginTerminal(); exitMarker?.markPending(); journal = journal.copy(revoking = true); save(journal)
            owned = null
        }
        registrations?.pendingRegistrations()?.forEach { pending ->
            if (recovery.requiresAbandonment(pending.operation, owned)) registrations.enqueueCancellation(pending)
        }
        recovery.recoverUnclaimed(owned)
        if (recoverRegistrations && registrations != null) {
            journal.registration?.let { legacy ->
                if (owned?.deviceId != legacy.device) registrations.enqueueCancellation(RegistrationCancellation.from(legacy))
                journal = journal.copy(registration = null); save(journal)
            }
            registrations.recoverUnclaimed(owned)
        }
    }

    suspend fun access(rejectedAccess: Credentials? = null, expectedEpoch: AuthSessionEpoch? = null): Credentials {
        val context = currentCoroutineContext()
        context.ensureActive()
        var immediate: Credentials? = null
        val flight = mutex.withLock {
            if (terminal || pendingExit()) throw ClientFailure.SignedOut()
            val journal = read()
            val current = journal.takeUnless { it.revoking || it.revocationOperation != null }?.credentials ?: throw ClientFailure.SignedOut()
            checkEpoch(expectedEpoch)
            if (rejectedAccess != null && (rejectedAccess.userId != current.userId || rejectedAccess.deviceId != current.deviceId)) throw ClientFailure.SignedOut()
            refreshFlights.values.firstOrNull { it.epoch === epoch && it.source == journal }?.let { return@withLock it }
            refreshFlights.values.filter { it.epoch === epoch }.forEach { it.operation.cancel() }
            if (current.accessExpiresAt - now() > 60_000 && journal.refreshOperation == null && current != rejectedAccess) {
                immediate = current; return@withLock null
            }
            val pending = journal.copy(refreshOperation = journal.refreshOperation ?: UUID.randomUUID().toString().uppercase())
            save(pending)
            context.ensureActive()
            val id = Any(); val sourceEpoch = epoch
            val operation = SharedOperation(context) { performRefresh(id, sourceEpoch, pending, current) }
            RefreshFlight(id, sourceEpoch, pending, operation).also { refreshFlights[id] = it; updates.publish(AuthSessionState.Refreshing) }
        }
        immediate?.let { return it }
        val owned = requireNotNull(flight)
        val result = owned.operation.await()
        // Every waiter validates its own lifetime after the shared result; none can adopt a newer account.
        return mutex.withLock {
            if (terminal || pendingExit()) throw ClientFailure.SignedOut()
            checkEpoch(owned.epoch); checkEpoch(expectedEpoch)
            val latest = read().takeUnless { it.revoking || it.revocationOperation != null }?.credentials ?: throw ClientFailure.SignedOut()
            checkEpoch(owned.epoch)
            if (latest.userId != result.userId || latest.deviceId != result.deviceId) throw ClientFailure.SessionInvalidated()
            latest
        }
    }

    private suspend fun requireRefreshSource(sourceEpoch: AuthSessionEpoch, source: AuthJournal) {
        checkEpoch(sourceEpoch)
        if (terminal || pendingExit()) throw ClientFailure.SignedOut()
        val current = read()
        checkEpoch(sourceEpoch)
        if (current != source) throw ClientFailure.SessionInvalidated()
    }
    private suspend fun performRefresh(id: Any, sourceEpoch: AuthSessionEpoch, journal: AuthJournal, current: Credentials): Credentials {
        try {
            val refreshed = decodeCredentials(api.post("/v2/device-credentials/refresh", buildJsonObject {
                put("userID", current.userId.value); put("deviceID", current.deviceId.value)
                put("refreshCredential", current.refreshCredential); put("revocationCredential", current.revocationCredential)
                put("operationID", requireNotNull(journal.refreshOperation))
            }))
            if (refreshed.userId != current.userId || refreshed.deviceId != current.deviceId) throw ClientFailure.Protocol()
            return mutex.withLock {
                currentCoroutineContext().ensureActive()
                requireRefreshSource(sourceEpoch, journal)
                save(journal.copy(credentials = refreshed, refreshOperation = null)); refreshed
            }
        } catch (error: ClientFailure.Http) {
            if (error.status == 401 || error.status == 403) mutex.withLock {
                requireRefreshSource(sourceEpoch, journal)
                beginTerminal(); exitMarker?.markPending(); save(journal.copy(revoking = true))
            }
            throw error
        } finally {
            withContext(NonCancellable) { mutex.withLock { finishRefresh(id, sourceEpoch, current) } }
        }
    }

    private fun finishRefresh(id: Any, sourceEpoch: AuthSessionEpoch, source: Credentials) {
        refreshFlights.remove(id)
        if (!terminal && epoch === sourceEpoch && refreshFlights.values.none { it.epoch === sourceEpoch } && updates.current() == AuthSessionState.Refreshing)
            updates.publish(AuthSessionState.Authenticated(source.accessExpiresAt))
    }

    private suspend fun retireRefreshes(retiring: List<RefreshFlight>) = withContext(NonCancellable) {
        retiring.forEach { it.operation.cancel() }
        retiring.forEach { it.operation.cancelAndDrain() }
        // Cancellation before async dispatch never enters performRefresh's finally block.
        mutex.withLock { retiring.forEach { finishRefresh(it.id, it.epoch, requireNotNull(it.source.credentials)) } }
    }

    /** Owner retirement only. Waiter cancellation must use its own coroutine, not this method. */
    suspend fun cancelRefreshAndDrain(expectedEpoch: AuthSessionEpoch? = null) {
        val retiring = mutex.withLock { refreshFlights.values.filter { expectedEpoch == null || it.epoch === expectedEpoch } }
        retireRefreshes(retiring)
    }

    /** Commit independent exit intent before the caller drains local account resources. */
    suspend fun prepareLocalExit(expectedEpoch: AuthSessionEpoch? = null) { prepareLocalExitAndDrain(expectedEpoch) }

    private suspend fun prepareLocalExitAndDrain(expectedEpoch: AuthSessionEpoch?): AuthSessionEpoch {
        var retiring = emptyList<RefreshFlight>()
        try { return mutex.withLock {
            checkEpoch(expectedEpoch)
            retiring = refreshFlights.values.toList()
            beginTerminal(); exitMarker?.markPending(); epoch
        } } finally { retireRefreshes(retiring) }
    }

    /** Resume local cleanup without network or credential deletion. The callback must not reenter
     * this AuthSession; its identity is only a scope for draining already-admitted work. */
    suspend fun drainLocalExitWork(drain: suspend (LocalExitAccount?) -> Unit) {
        val exitingEpoch = prepareLocalExitAndDrain(null)
        mutex.withLock {
            checkEpoch(exitingEpoch)
            if (!terminal) throw ClientFailure.SessionInvalidated()
            drain(readForDeletion()?.credentials?.let { LocalExitAccount(it.userId, it.deviceId) })
        }
    }

    /** Explicit exit. Permanently unreadable credentials can be deleted only after the independent
     * exit marker, local drain and available recovery authorities have durably handed off. */
    suspend fun logout(beforeCredentialDeletion: suspend (LocalExitAccount?) -> Unit = {}) {
        val exitingEpoch = prepareLocalExitAndDrain(null)
        mutex.withLock {
            checkEpoch(exitingEpoch)
            if (!terminal) throw ClientFailure.SessionInvalidated()
            val previous = readForDeletion()
            val journal = previous?.copy(revoking = true, revocationOperation = previous.revocationOperation ?: UUID.randomUUID().toString().uppercase())
                ?: AuthJournal(revoking = true)
            // Never overwrite damaged ciphertext or try to encrypt with a permanently invalid key.
            if (previous != null && previous != AuthJournal()) {
                save(journal)
                if (read() != journal) throw CredentialStoreFailure(CredentialStoreFailure.Reason.Unavailable)
            }
            beforeCredentialDeletion(journal.credentials?.let { LocalExitAccount(it.userId, it.deviceId) })
            if (previous == null) issuedRecovery?.recoverUnclaimed(null) else recoverIssuedLocked()
            if (registrations != null) {
                journal.registration?.let { registrations.enqueueCancellation(RegistrationCancellation.from(it)) }
                registrations.discardPendingRegistrations()
            } else journal.registration?.let { cancelRegistration(it) }
            journal.credentials?.let { c ->
                if (issuedRecovery != null) {
                    issuedRecovery.enqueueRevocation(c, requireNotNull(journal.revocationOperation))
                    return@let
                }
                // Legacy constructors without an independent recovery owner keep their direct
                // revocation behavior; production uses the durable handoff above.
                try { api.post("/v2/device-credentials/revoke", buildJsonObject {
                    put("credential", c.revocationCredential); put("operationID", journal.revocationOperation)
                }, expectedStatus = 204) } catch (e: ClientFailure.Http) { if (e.status != 401 && e.status != 410) throw e }
            }
            currentCoroutineContext().ensureActive()
            credentialIO { store.delete() }
            if (credentialIO { store.read() } != null) throw ClientFailure.Storage()
            currentCoroutineContext().ensureActive()
            exitMarker?.clearPending()
            observe(AuthJournal()); terminal = false; updates.publish(AuthSessionState.Unauthenticated)
        }
    }
    /** Null is permitted only inside an explicit, durably marked exit. Temporary failures propagate. */
    private suspend fun readForDeletion(): AuthJournal? = try { read() }
    catch (error: CredentialStoreFailure) {
        if (error.reason == CredentialStoreFailure.Reason.Unavailable) throw error
        null
    }
    suspend fun hasCleanup(): Boolean = mutex.withLock { terminal || pendingExit() || read().let { it.revoking || it.revocationOperation != null } }
    private suspend fun cancelRegistration(r: Registration) {
        try { api.post("/v2/device-credentials/cancel-registration", r.cancellation(), expectedStatus = 204) }
        catch (e: ClientFailure.Http) { if (e.status != 410) throw e }
    }
    private fun decodeCredentials(v: JsonObject) = Credentials(UserId(v.string("userID")), DeviceId(v.string("deviceID")),
        v.string("accessToken"), v.number("accessTokenExpiresAtMilliseconds"), v.string("refreshCredential"),
        v.string("revocationCredential"), v.number("revocationCredentialExpiresAtMilliseconds"))
}
