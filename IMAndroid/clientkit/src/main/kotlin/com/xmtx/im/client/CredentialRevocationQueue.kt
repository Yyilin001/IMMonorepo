package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.util.Base64
import java.util.UUID

/** Purpose-limited authority. Never expose this value in UI or logs. */
@Serializable
data class CredentialRevocationIntent(val user: UserId, val device: DeviceId, val credential: String,
    val expiresAt: Long, val operation: String) {
    init {
        require(expiresAt > 0 && UUID.fromString(operation).toString().uppercase() == operation)
        require(credential.startsWith("imv2-revoke-v1."))
        val encoded = credential.removePrefix("imv2-revoke-v1.")
        val bytes = Base64.getUrlDecoder().decode(encoded)
        require(bytes.size == 32 && Base64.getUrlEncoder().withoutPadding().encodeToString(bytes) == encoded)
    }
    override fun toString() = "CredentialRevocationIntent(<redacted>)"
    companion object {
        fun received(credentials: Credentials, operation: String) = CredentialRevocationIntent(credentials.userId,
            credentials.deviceId, credentials.revocationCredential, credentials.revocationExpiresAt, operation)
    }
}

class CredentialRecoveryFailure(val reason: Reason) : Exception("Credential recovery: ${reason.name}") {
    enum class Reason { Unavailable, Malformed, Conflict, CapacityExceeded, InvalidRequest }
}

@Serializable
data class CredentialRevocationJob(val intent: CredentialRevocationIntent, val attempts: Long,
    val nextAttemptAt: Long, val pause: Pause? = null) {
    init { require(attempts in 0..0xffff_ffffL) }
    @Serializable enum class Pause { InvalidCredential, OperationConflict, InvalidRequest, InvalidResponse }
    override fun toString() = "CredentialRevocationJob(<redacted>)"
}
enum class CredentialRevocationStatus { Empty, Pending, Paused }

/** One owner per encrypted namespace. Mutex protects this instance, not other processes/instances. */
class CredentialRevocationQueue(private val persistence: SecretStore) {
    private val mutex = Mutex()
    private val changed = MutableStateFlow(0L)
    internal val changes: StateFlow<Long> = changed.asStateFlow()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    @Serializable private data class Ledger(val version: Int, val jobs: Map<String, CredentialRevocationJob>)

    suspend fun enqueue(intent: CredentialRevocationIntent) = mutex.withLock { enqueueLocked(intent, recovered = false) }
    internal suspend fun enqueueRecovered(intent: CredentialRevocationIntent) = mutex.withLock { enqueueLocked(intent, recovered = true) }
    private suspend fun enqueueLocked(intent: CredentialRevocationIntent, recovered: Boolean) {
        val ledger = load()
        val sameDevice = ledger.jobs.values.firstOrNull { it.intent.user == intent.user && it.intent.device == intent.device }
        if (recovered && sameDevice != null) {
            if (sameDevice.intent.credential != intent.credential || sameDevice.intent.expiresAt != intent.expiresAt) conflict()
            return
        }
        ledger.jobs[intent.operation]?.let { if (it.intent != intent) conflict(); return }
        if (sameDevice != null) conflict()
        if (ledger.jobs.size >= 256) throw CredentialRecoveryFailure(CredentialRecoveryFailure.Reason.CapacityExceeded)
        save(ledger.copy(jobs = ledger.jobs + (intent.operation to CredentialRevocationJob(intent, 0, Long.MIN_VALUE))))
    }
    suspend fun jobs(): PersistentList<CredentialRevocationJob> = mutex.withLock {
        load().jobs.values.sortedBy { it.intent.operation }.toPersistentList()
    }
    suspend fun due(now: Long, limit: Int = 4): PersistentList<CredentialRevocationJob> {
        if (limit !in 1..32) throw CredentialRecoveryFailure(CredentialRecoveryFailure.Reason.InvalidRequest)
        return jobs().filter { it.pause == null && it.nextAttemptAt <= now }
            .sortedWith(compareBy({ it.nextAttemptAt }, { it.intent.operation })).take(limit).toPersistentList()
    }
    suspend fun status(): CredentialRevocationStatus = jobs().let { jobs -> when {
        jobs.isEmpty() -> CredentialRevocationStatus.Empty
        jobs.any { it.pause != null } -> CredentialRevocationStatus.Paused
        else -> CredentialRevocationStatus.Pending
    } }
    /** Initial read and later notifications contain no authority; read failures terminate collection. */
    fun statusUpdates(): Flow<CredentialRevocationStatus> = changes.map { status() }.distinctUntilChanged()
    suspend fun complete(job: CredentialRevocationJob): Boolean = mutex.withLock {
        currentCoroutineContext().ensureActive()
        val ledger = load(); if (ledger.jobs[job.intent.operation] != job) return@withLock false
        save(ledger.copy(jobs = ledger.jobs - job.intent.operation)); true
    }
    suspend fun recordFailure(job: CredentialRevocationJob, retryAt: Long, pause: CredentialRevocationJob.Pause? = null): Boolean = mutex.withLock {
        currentCoroutineContext().ensureActive()
        val ledger = load(); if (ledger.jobs[job.intent.operation] != job) return@withLock false
        val updated = job.copy(attempts = (job.attempts + 1).coerceAtMost(0xffff_ffffL), nextAttemptAt = retryAt, pause = pause)
        save(ledger.copy(jobs = ledger.jobs + (job.intent.operation to updated))); true
    }
    suspend fun retryPaused() = mutex.withLock {
        currentCoroutineContext().ensureActive(); val ledger = load()
        if (ledger.jobs.values.none { it.pause != null }) return@withLock
        save(ledger.copy(jobs = ledger.jobs.mapValues { (_, job) ->
            if (job.pause == null) job else job.copy(nextAttemptAt = Long.MIN_VALUE, pause = null)
        }))
    }
    private suspend fun load(): Ledger {
        currentCoroutineContext().ensureActive()
        val raw = recoveryStorage { persistence.read() } ?: return Ledger(1, emptyMap())
        return try {
            require(raw.length <= 1_048_576)
            json.decodeFromString<Ledger>(raw).also { ledger ->
                require(ledger.version == 1 && ledger.jobs.size <= 256)
                require(ledger.jobs.all { (key, job) -> key == job.intent.operation })
                require(ledger.jobs.values.map { it.intent.user to it.intent.device }.distinct().size == ledger.jobs.size)
            }
        } catch (_: Exception) { throw CredentialRecoveryFailure(CredentialRecoveryFailure.Reason.Malformed) }
    }
    private suspend fun save(ledger: Ledger) = withContext(NonCancellable) {
        persistRecoveryRecord(persistence, if (ledger.jobs.isEmpty()) null else json.encodeToString(ledger))
        changed.value += 1
    }
    private fun conflict(): Nothing = throw CredentialRecoveryFailure(CredentialRecoveryFailure.Reason.Conflict)
}

/** Once a local commit starts, finish both persistence and verification despite waiter cancellation. */
internal suspend fun persistRecoveryRecord(persistence: SecretStore, value: String?) = withContext(NonCancellable) {
    recoveryStorage {
        if (value == null) persistence.delete() else persistence.write(value)
        if (persistence.read() != value) throw CredentialRecoveryFailure(CredentialRecoveryFailure.Reason.Unavailable)
    }
}

internal suspend fun <T> recoveryStorage(body: suspend () -> T): T = try { body() }
catch (error: CancellationException) { throw error }
catch (error: CredentialRecoveryFailure) { throw error }
catch (error: CredentialStoreFailure) {
    throw CredentialRecoveryFailure(if (error.reason == CredentialStoreFailure.Reason.Malformed)
        CredentialRecoveryFailure.Reason.Malformed else CredentialRecoveryFailure.Reason.Unavailable)
}
catch (_: Exception) { throw CredentialRecoveryFailure(CredentialRecoveryFailure.Reason.Unavailable) }
