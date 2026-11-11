package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.Locale
import java.util.UUID

@Serializable
data class RegistrationCancellation(val device: DeviceId, val operation: String, val proof: String, val deadline: Long) {
    init {
        require(deadline > 0 && UUID.fromString(operation).toString().uppercase() == operation)
        require(proof.startsWith("imv2-cancel-registration-v1."))
        val encoded = proof.removePrefix("imv2-cancel-registration-v1."); val bytes = Base64.getUrlDecoder().decode(encoded)
        require(bytes.size == 32 && Base64.getUrlEncoder().withoutPadding().encodeToString(bytes) == encoded)
    }
    fun payload() = buildJsonObject {
        put("deviceID", buildJsonObject { put("rawValue", device.value) })
        put("operationID", operation); put("proof", proof); put("issueBeforeMilliseconds", deadline)
    }
    override fun toString() = "RegistrationCancellation(<redacted>)"
    companion object {
        internal fun from(registration: Registration) = RegistrationCancellation(registration.device, registration.operation, registration.proof, registration.deadline)
    }
}
@Serializable
data class RegistrationCancellationJob(val cancellation: RegistrationCancellation, val attempts: Long,
    val nextAttemptAt: Long, val pause: Pause? = null) {
    init { require(attempts in 0..0xffff_ffffL) }
    @Serializable enum class Pause { InvalidRequest, InvalidResponse }
    override fun toString() = "RegistrationCancellationJob(<redacted>)"
}
data class RegistrationActivity(val awaitingRegistration: Boolean, val cancellations: CredentialRevocationStatus)

/** Exact, non-serializable operation handle. Old handles cannot finish a newer operation. */
class PreparedDeviceRegistration internal constructor(val cancellation: RegistrationCancellation,
    private val scope: String, private val owner: DeviceRegistrationStore) {
    suspend fun load(): RegistrationCancellation = owner.requirePending(scope, cancellation)
    suspend fun finish() = owner.finish(scope, cancellation)
    suspend fun abandon() = owner.abandonPending(scope, cancellation)
    override fun toString() = "PreparedDeviceRegistration(<redacted>)"
}

/** One owner per encrypted namespace. Pending operations and cancellation jobs commit atomically. */
class DeviceRegistrationStore(private val persistence: SecretStore, private val now: () -> Long = System::currentTimeMillis) {
    private val mutex = Mutex()
    private val revision = MutableStateFlow(0L)
    internal val changes: StateFlow<Long> = revision.asStateFlow()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    @Serializable private data class Ledger(val version: Int, val pending: Map<String, RegistrationCancellation>,
        val abandoned: Map<String, RegistrationCancellationJob>)

    suspend fun prepare(accountHandle: String): PreparedDeviceRegistration {
        val canonical = accountHandle.lowercase(Locale.ROOT)
        require(canonical.matches(Regex("[a-z0-9_-]{3,64}")))
        return prepareKey("password-account-v1\u0000$canonical")
    }
    internal suspend fun prepareScope(scope: String): PreparedDeviceRegistration = if (scope.startsWith("assertion:"))
        prepareKey("assertion-account-v1\u0000${scope.removePrefix("assertion:")}") else prepare(scope)
    private suspend fun prepareKey(value: String): PreparedDeviceRegistration = mutex.withLock {
        val key = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
        var ledger = load(); val previous = ledger.pending[key]
        if (previous != null && previous.deadline > now()) return@withLock PreparedDeviceRegistration(previous, key, this)
        if (previous != null) ledger = abandon(ledger.copy(pending = ledger.pending - key), previous)
        if (ledger.pending.size + ledger.abandoned.size >= 256) capacity()
        val deadline = try { Math.addExact(now(), 600_000) } catch (_: ArithmeticException) { invalid() }
        if (deadline <= 0) invalid()
        val cancellation = RegistrationCancellation(DeviceId(UUID.randomUUID().toString().uppercase()), UUID.randomUUID().toString().uppercase(),
            "imv2-cancel-registration-v1." + Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) }), deadline)
        save(ledger.copy(pending = ledger.pending + (key to cancellation)))
        PreparedDeviceRegistration(cancellation, key, this)
    }
    suspend fun hasWork(): Boolean = mutex.withLock { load().let { it.pending.isNotEmpty() || it.abandoned.isNotEmpty() } }
    internal suspend fun pendingRegistrations(): PersistentList<RegistrationCancellation> = mutex.withLock { load().pending.values.toPersistentList() }
    suspend fun activity(): RegistrationActivity = mutex.withLock {
        val ledger = load()
        RegistrationActivity(ledger.pending.isNotEmpty(), when {
            ledger.abandoned.isEmpty() -> CredentialRevocationStatus.Empty
            ledger.abandoned.values.any { it.pause != null } -> CredentialRevocationStatus.Paused
            else -> CredentialRevocationStatus.Pending
        })
    }
    fun activityUpdates(): Flow<RegistrationActivity> = changes.map { activity() }.distinctUntilChanged()
    suspend fun jobs(): PersistentList<RegistrationCancellationJob> = mutex.withLock {
        load().abandoned.values.sortedBy { it.cancellation.operation }.toPersistentList()
    }
    internal suspend fun due(now: Long) = jobs().filter { it.pause == null && it.nextAttemptAt <= now }
        .sortedWith(compareBy({ it.nextAttemptAt }, { it.cancellation.operation })).take(4).toPersistentList()
    suspend fun enqueueCancellation(cancellation: RegistrationCancellation) = mutex.withLock {
        val ledger = load()
        // Transfer a matching pending identity and its proof in the same commit.
        if (ledger.pending.values.any { it.operation == cancellation.operation && it != cancellation }) conflict()
        val pending = ledger.pending.filterValues { it != cancellation }
        val updated = abandon(ledger.copy(pending = pending), cancellation)
        if (updated.pending.size + updated.abandoned.size > 256) capacity()
        if (updated != ledger) save(updated)
    }
    suspend fun discardPendingRegistrations() = recoverUnclaimed(null)
    /** Cold start only, before interactive prepare. Revoking/unreadable auth is not ownership. */
    suspend fun recoverUnclaimed(ownedBy: Credentials?) = mutex.withLock {
        val original = load(); var ledger = original.copy(pending = emptyMap())
        for (pending in original.pending.values) if (ownedBy?.deviceId != pending.device) ledger = abandon(ledger, pending)
        if (ledger != original) save(ledger)
    }
    internal suspend fun requirePending(scope: String, cancellation: RegistrationCancellation) = mutex.withLock {
        if (load().pending[scope] != cancellation) conflict(); cancellation
    }
    internal suspend fun finish(scope: String, cancellation: RegistrationCancellation) = mutex.withLock {
        val ledger = load()
        if (ledger.pending[scope] == cancellation) save(ledger.copy(pending = ledger.pending - scope))
    }
    internal suspend fun abandonPending(scope: String, cancellation: RegistrationCancellation) = mutex.withLock {
        val ledger = load()
        if (ledger.pending[scope] != cancellation) conflict()
        save(abandon(ledger.copy(pending = ledger.pending - scope), cancellation))
    }
    internal suspend fun complete(job: RegistrationCancellationJob) = mutex.withLock {
        val ledger = load()
        if (ledger.abandoned[job.cancellation.operation] == job) save(ledger.copy(abandoned = ledger.abandoned - job.cancellation.operation))
    }
    internal suspend fun recordFailure(job: RegistrationCancellationJob, retryAt: Long, pause: RegistrationCancellationJob.Pause?) = mutex.withLock {
        val ledger = load()
        if (ledger.abandoned[job.cancellation.operation] == job) save(ledger.copy(abandoned = ledger.abandoned +
            (job.cancellation.operation to job.copy(attempts = (job.attempts + 1).coerceAtMost(0xffff_ffffL), nextAttemptAt = retryAt, pause = pause))))
    }
    suspend fun retryPaused() = mutex.withLock {
        val ledger = load()
        if (ledger.abandoned.values.any { it.pause != null }) save(ledger.copy(abandoned = ledger.abandoned.mapValues { (_, job) ->
            if (job.pause == null) job else job.copy(pause = null, nextAttemptAt = Long.MIN_VALUE)
        }))
    }
    private fun abandon(ledger: Ledger, cancellation: RegistrationCancellation): Ledger {
        ledger.abandoned[cancellation.operation]?.let { if (it.cancellation != cancellation) conflict(); return ledger }
        return ledger.copy(abandoned = ledger.abandoned + (cancellation.operation to RegistrationCancellationJob(cancellation, 0, Long.MIN_VALUE)))
    }
    private suspend fun load(): Ledger {
        currentCoroutineContext().ensureActive()
        val raw = recoveryStorage { persistence.read() } ?: return Ledger(1, emptyMap(), emptyMap())
        return try {
            require(raw.length <= 1_048_576)
            json.decodeFromString<Ledger>(raw).also { ledger ->
                require(ledger.version == 1 && ledger.pending.size + ledger.abandoned.size <= 256)
                require(ledger.pending.keys.all { it.matches(Regex("[0-9a-f]{64}")) })
                require(ledger.abandoned.all { (key, job) -> key == job.cancellation.operation })
                val operations = ledger.pending.values.map { it.operation } + ledger.abandoned.keys
                require(operations.distinct().size == operations.size)
            }
        } catch (_: Exception) { throw CredentialRecoveryFailure(CredentialRecoveryFailure.Reason.Malformed) }
    }
    private suspend fun save(ledger: Ledger) = withContext(NonCancellable) {
        persistRecoveryRecord(persistence, if (ledger.pending.isEmpty() && ledger.abandoned.isEmpty()) null else json.encodeToString(ledger))
        revision.value += 1
    }
    private fun conflict(): Nothing = throw CredentialRecoveryFailure(CredentialRecoveryFailure.Reason.Conflict)
    private fun capacity(): Nothing = throw CredentialRecoveryFailure(CredentialRecoveryFailure.Reason.CapacityExceeded)
    private fun invalid(): Nothing = throw CredentialRecoveryFailure(CredentialRecoveryFailure.Reason.InvalidRequest)
}
