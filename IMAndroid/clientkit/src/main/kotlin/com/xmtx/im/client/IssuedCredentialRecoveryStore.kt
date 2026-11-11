package com.xmtx.im.client

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

interface IssuedCredentialRecovering {
    suspend fun receive(credentials: Credentials, operation: String): CredentialRevocationIntent
    /** Call only after the authentication journal has durably adopted the credential session. */
    suspend fun adopt(receipt: CredentialRevocationIntent)
    suspend fun abandon(receipt: CredentialRevocationIntent)
}

/** Independent receipt journal: no access or refresh tokens. Use one owner per namespace. */
class IssuedCredentialRecoveryStore(private val persistence: SecretStore,
    private val revocations: CredentialRevocationQueue) : IssuedCredentialRecovering {
    private val mutex = Mutex()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    @Serializable private enum class Disposition { AwaitingAdoption, Abandoned }
    @Serializable private data class Record(val intent: CredentialRevocationIntent, val disposition: Disposition)
    @Serializable private data class Ledger(val version: Int, val records: Map<String, Record>)

    suspend fun hasPendingReceipts(): Boolean = mutex.withLock { load().records.isNotEmpty() }
    /** Terminal credential deletion shares the receipt queue and preserves any existing matching
     * authority's operation, attempts and pause. The caller journals operation before this handoff. */
    internal suspend fun enqueueRevocation(credentials: Credentials, operation: String) =
        revocations.enqueueRecovered(CredentialRevocationIntent.received(credentials, operation))
    internal suspend fun requiresAbandonment(operation: String, ownedBy: Credentials?): Boolean = mutex.withLock {
        val record = load().records[operation] ?: return@withLock false
        record.disposition == Disposition.Abandoned || !owns(ownedBy, record.intent)
    }
    private fun owns(credentials: Credentials?, intent: CredentialRevocationIntent) = credentials?.let {
        it.userId == intent.user && it.deviceId == intent.device &&
            it.revocationCredential == intent.credential && it.revocationExpiresAt == intent.expiresAt
    } == true

    override suspend fun receive(credentials: Credentials, operation: String): CredentialRevocationIntent = mutex.withLock {
        val intent = CredentialRevocationIntent.received(credentials, operation)
        val ledger = load()
        ledger.records[operation]?.let {
            if (it.intent != intent || it.disposition != Disposition.AwaitingAdoption) conflict()
            return@withLock intent
        }
        if (ledger.records.size >= 256) throw CredentialRecoveryFailure(CredentialRecoveryFailure.Reason.CapacityExceeded)
        save(ledger.copy(records = ledger.records + (operation to Record(intent, Disposition.AwaitingAdoption))))
        intent
    }
    override suspend fun adopt(receipt: CredentialRevocationIntent) = mutex.withLock {
        val ledger = load(); val existing = ledger.records[receipt.operation] ?: conflict()
        if (existing.intent != receipt || existing.disposition != Disposition.AwaitingAdoption) conflict()
        save(ledger.copy(records = ledger.records - receipt.operation))
    }
    override suspend fun abandon(receipt: CredentialRevocationIntent) = mutex.withLock {
        val ledger = load(); val existing = ledger.records[receipt.operation] ?: return@withLock
        if (existing.intent != receipt) conflict()
        if (existing.disposition != Disposition.Abandoned)
            save(ledger.copy(records = ledger.records + (receipt.operation to existing.copy(disposition = Disposition.Abandoned))))
        drainLocked()
    }
    /** Cold-start only, before interactive registration. Pass null for revoking/unowned sessions.
     * Ownership is based on user/device/revocation authority and expiry, allowing access-token rotation.
     * An unreadable auth journal is an error at the caller, never proof of null ownership.
     */
    suspend fun recoverUnclaimed(ownedBy: Credentials?) = mutex.withLock {
        val ledger = load(); var changed = false
        val records = ledger.records.toMutableMap()
        ledger.records.forEach { (key, record) ->
            if (record.disposition == Disposition.AwaitingAdoption) {
                val owned = owns(ownedBy, record.intent)
                if (owned) records.remove(key) else records[key] = record.copy(disposition = Disposition.Abandoned)
                changed = true
            }
        }
        if (changed) save(ledger.copy(records = records.toMap()))
        drainLocked()
    }
    suspend fun drainAbandoned() = mutex.withLock { drainLocked() }
    private suspend fun drainLocked() {
        val abandoned = load().records.values.filter { it.disposition == Disposition.Abandoned }
        for (record in abandoned) {
            revocations.enqueueRecovered(record.intent)
            val latest = load()
            if (latest.records[record.intent.operation] == record)
                save(latest.copy(records = latest.records - record.intent.operation))
        }
    }
    private suspend fun load(): Ledger {
        currentCoroutineContext().ensureActive()
        val raw = recoveryStorage { persistence.read() } ?: return Ledger(1, emptyMap())
        return try {
            require(raw.length <= 1_048_576)
            json.decodeFromString<Ledger>(raw).also {
                require(it.version == 1 && it.records.size <= 256 && it.records.all { (key, record) -> key == record.intent.operation })
            }
        } catch (_: Exception) { throw CredentialRecoveryFailure(CredentialRecoveryFailure.Reason.Malformed) }
    }
    private suspend fun save(ledger: Ledger) = persistRecoveryRecord(persistence,
        if (ledger.records.isEmpty()) null else json.encodeToString(ledger))
    private fun conflict(): Nothing = throw CredentialRecoveryFailure(CredentialRecoveryFailure.Reason.Conflict)
}
