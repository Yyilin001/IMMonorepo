package com.xmtx.im.platform

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.security.keystore.KeyPermanentlyInvalidatedException
import androidx.core.database.sqlite.transaction
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.security.MessageDigest
import javax.crypto.AEADBadTagException

class KeystoreInstallationBindingStore private constructor(context: Context, name: String) : InstallationBindingRepairing {
    constructor(context: Context) : this(context, "local-installation-binding")
    internal constructor(context: Context, name: String, isolated: Boolean) : this(context, name) { require(isolated && name.startsWith("binding-test-")) }
    private val record = KeystoreSecretStore(context, name)
    private val delegate = SecretInstallationBindingStore(object : SecretStore {
        override suspend fun read() = classified { record.read() }
        override suspend fun write(value: String) = classified { record.write(value) }
        override suspend fun delete() = classified { record.delete() }
    })
    override suspend fun load() = access.withLock { loadRecord() }
    private suspend fun loadRecord(): LocalInstallationBinding? {
        val value = delegate.load()
        // An interrupted first AtomicFile write is evidence, not a fresh installation.
        if (value == null && record.recordRevision() != null) throw LocalStoreFailure(LocalStoreFailure.Reason.BindingMalformed)
        return value
    }
    override suspend fun save(binding: LocalInstallationBinding) = access.withLock { delegate.save(binding) }
    override suspend fun delete() = access.withLock { delegate.delete() }
    override suspend fun inspectDamage() = access.withLock { damage() }
    private suspend fun terminalReason(): LocalStoreFailure.Reason? = try { loadRecord(); null }
        catch (error: LocalStoreFailure) {
            if (error.reason != LocalStoreFailure.Reason.BindingMalformed && error.reason != LocalStoreFailure.Reason.BindingInvalidated) throw error
            error.reason
        }
    private suspend fun damage(): InstallationBindingDamage? {
        val reason = terminalReason() ?: return null
        val revision = record.recordRevision() ?: throw LocalStoreFailure(LocalStoreFailure.Reason.BindingMismatch)
        if (terminalReason() != reason || record.recordRevision() != revision) throw LocalStoreFailure(LocalStoreFailure.Reason.BindingMismatch)
        return InstallationBindingDamage(reason, revision)
    }
    override suspend fun replaceDamagedBinding(expected: InstallationBindingDamage, replacement: LocalInstallationBinding) = access.withLock {
        if (damage() != expected) throw LocalStoreFailure(LocalStoreFailure.Reason.BindingMismatch)
        currentCoroutineContext().ensureActive()
        record.deleteAndRetireKey()
        delegate.save(replacement)
    }
    // Installation state is shared across bootstrapper instances. No read/save can interleave repair.
    private companion object { val access = Mutex() }
    private suspend fun <T> classified(body: suspend () -> T): T = try { body() }
    catch (error: KeystoreRecordFailure) { throw LocalStoreFailure(when (error.reason) {
        KeystoreRecordFailure.Reason.Malformed -> LocalStoreFailure.Reason.BindingMalformed
        KeystoreRecordFailure.Reason.KeyMissing -> LocalStoreFailure.Reason.BindingInvalidated
    }) }
    catch (_: KeyPermanentlyInvalidatedException) { throw LocalStoreFailure(LocalStoreFailure.Reason.BindingInvalidated) }
    catch (_: AEADBadTagException) { throw LocalStoreFailure(LocalStoreFailure.Reason.BindingMalformed) }
}

/** Opens bound stores without silently adopting or deleting an untrusted existing projection.
 * Callers must own the authenticated account lifecycle; this is not an authentication provider.
 */
class LocalStoreBootstrapper(context: Context,
    private val bindings: InstallationBindingStore = KeystoreInstallationBindingStore(context),
    nanoTime: () -> Long = System::nanoTime) {
    private val context = context.applicationContext
    private val recovery = LocalStoreRecoveryEngine(this.context, bindings, nanoTime)
    private val readOwner = Any()

    /** Local evidence only. Missing stores/bindings are errors, never a request to create them. */
    suspend fun localReadBootstrap(auth: AuthSession, exitMarker: LocalExitMarker): LocalReadBootstrap {
        currentCoroutineContext().ensureActive()
        if (exitMarker.isPending()) throw ClientFailure.SignedOut()
        val identity = auth.localAccountIdentity()
        val state = existingReadState(identity)
        auth.requireLocalIdentity(identity)
        if (exitMarker.isPending()) throw ClientFailure.SignedOut()
        auth.requireLocalIdentityEpoch(identity.epoch)
        currentCoroutineContext().ensureActive()
        return LocalReadBootstrap(identity, state.second, state.first, readOwner)
    }

    suspend fun requireLocalReadBootstrap(auth: AuthSession, permit: LocalReadBootstrap, exitMarker: LocalExitMarker) {
        if (permit.owner !== readOwner) throw ClientFailure.SessionInvalidated()
        auth.requireLocalIdentity(permit.identity)
        val current = localReadBootstrap(auth, exitMarker)
        if (current.identity != permit.identity || current.binding != permit.binding || current.databaseIdentity != permit.databaseIdentity)
            throw ClientFailure.SessionInvalidated()
    }

    /** A real SQLite read-only connection. Does not migrate, recover, build indexes or issue leases. */
    suspend fun openLocalReadSession(auth: AuthSession, permit: LocalReadBootstrap, exitMarker: LocalExitMarker): SqliteClientStore {
        requireLocalReadBootstrap(auth, permit, exitMarker)
        var opened: SqliteClientStore? = null
        try {
            val store = opening.withLock { withContext(Dispatchers.IO) {
                SqliteClientStore.openReadOnly(context, permit.identity.userId, permit.identity.deviceId, permit.binding).also { opened = it }
            } }
            if (store.databaseIdentity != permit.databaseIdentity) throw ClientFailure.SessionInvalidated()
            requireLocalReadBootstrap(auth, permit, exitMarker)
            currentCoroutineContext().ensureActive()
            return store
        } catch (error: Throwable) {
            withContext(NonCancellable + Dispatchers.IO) { opened?.close() }
            throw error
        }
    }

    /** Read-only presentation port: scoped identity checks surround every bounded read/publication. */
    suspend fun openLocalProjection(auth: AuthSession, exitMarker: LocalExitMarker, scope: CoroutineScope): LocalProjectionSession {
        scope.coroutineContext.ensureActive()
        requireNotNull(scope.coroutineContext[Job]) { "A lifecycle Job is required" }
        val permit = localReadBootstrap(auth, exitMarker)
        val store = openLocalReadSession(auth, permit, exitMarker)
        try {
            currentCoroutineContext().ensureActive(); scope.coroutineContext.ensureActive()
            return LocalProjectionSession(permit.identity, permit.databaseIdentity, store,
                { requireLocalReadBootstrap(auth, permit, exitMarker) }, auth.sessionUpdates(permit.identity.epoch), scope)
        } catch (error: Throwable) {
            withContext(NonCancellable + Dispatchers.IO) { store.close() }; throw error
        }
    }

    private suspend fun existingReadState(identity: LocalAccountIdentity): Pair<LocalInstallationBinding, LocalDatabaseIdentity> = opening.withLock {
        withContext(Dispatchers.IO) {
            val file = accountDatabaseFile(context, identity.userId, identity.deviceId)
            if (LocalStoreRecoveryEngine.pending(file)) throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable)
            val binding = bindings.load() ?: mismatch()
            val databaseIdentity = LocalDatabaseAccess.acquire(file).use {
                if (!file.isFile) throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable)
                SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS).use {
                    SqliteInstallationBinding.verify(it, binding, identity.userId, identity.deviceId)
                    SqliteDatabaseIdentity.read(it)
                }
            }
            if (bindings.load() != binding) mismatch()
            binding to databaseIdentity
        }
    }

    /** Local establishment only: validates the same credential lifetime before and after allocation.
     * Does not refresh credentials, start network work, or grant a display lease.
     */
    suspend fun open(auth: AuthSession, identity: LocalAccountIdentity): SqliteClientStore {
        auth.requireLocalIdentity(identity)
        val store = open(identity.userId, identity.deviceId)
        try {
            currentCoroutineContext().ensureActive()
            auth.requireLocalIdentity(identity)
            return store
        } catch (error: Throwable) {
            withContext(NonCancellable + Dispatchers.IO) { store.close() }
            throw error
        }
    }

    suspend fun open(account: UserId, device: DeviceId): SqliteClientStore = opening.withLock {
        var opened: SqliteClientStore? = null
        var constructing = false
        try {
            withContext(Dispatchers.IO) {
                val file = accountDatabaseFile(context, account, device)
                if (LocalStoreRecoveryEngine.pending(file)) recovery.resume(account, device)
                val binding = bindings.load() ?: run {
                    // Includes interrupted SQLite sidecars: a missing primary is not proof of a new store.
                    if (databaseArtifacts(file).any { it.exists() }) mismatch()
                    LocalInstallationBinding.create().also { bindings.save(it) }
                }
                if (file.exists()) SqliteInstallationBinding.verifyFile(file, binding, account, device)
                else if (databaseArtifacts(file).drop(1).any { it.exists() }) mismatch()
                currentCoroutineContext().ensureActive()
                constructing = true
                val store = SqliteClientStore(context, account, device, binding).also { opened = it }
                if (bindings.load() != binding) mismatch()
                currentCoroutineContext().ensureActive()
                recovery.openedSuccessfully()
                store
            }
        } catch (error: Throwable) {
            withContext(NonCancellable + Dispatchers.IO) { opened?.close() }
            if (constructing && opened == null && error is Exception && error !is CancellationException) {
                try { withContext(Dispatchers.IO) { recovery.rememberOpenFailure(account, device) } }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { /* No reusable evidence was obtained; keep the original failure. */ }
            }
            when (error) {
                is CancellationException, is LocalStoreFailure -> throw error
                is Exception -> throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable)
                else -> throw error
            }
        }
    }

    /** Read-only ownership check. Does not create, migrate, repair or adopt a database. */
    suspend fun verifyExistingBinding(account: UserId, device: DeviceId): LocalInstallationBinding = opening.withLock {
        withContext(Dispatchers.IO) {
            if (LocalStoreRecoveryEngine.pending(accountDatabaseFile(context, account, device)))
                throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable)
            val binding = bindings.load() ?: mismatch()
            SqliteInstallationBinding.verifyFile(accountDatabaseFile(context, account, device), binding, account, device)
            if (bindings.load() != binding) mismatch()
            binding
        }
    }
    suspend fun previewRecovery(account: UserId, device: DeviceId): LocalStoreRecoveryPreview = recoveryAction { recovery.preview(account, device) }
    /** Cold exit cleanup only; caller supplies the identity captured by AuthSession's drain callback. */
    suspend fun clearLocalProfileDisplaysForExit(account: LocalExitAccount?, marker: FileLocalExitMarker): Unit = recoveryAction {
        LocalProfileExitCleanup(context, bindings).clear(account, marker)
    }
    /** Explicitly confirmed recovery only. The caller must validate the current credential identity. */
    suspend fun recoverLocalStore(preview: LocalStoreRecoveryPreview): Unit = recoveryAction { recovery.recover(preview) }
    private suspend fun <T> recoveryAction(body: suspend () -> T): T = opening.withLock { withContext(Dispatchers.IO) {
        try { body() }
        catch (error: CancellationException) { throw error }
        catch (error: LocalStoreFailure) { throw error }
        catch (_: Exception) { throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable) }
    } }
    private companion object { val opening = Mutex() }
}

internal fun accountDatabaseFile(context: Context, account: UserId, device: DeviceId): File {
    val identity = "${account.value}/${device.value}"
    val scope = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray()).joinToString("") { "%02x".format(it) }
    return File(context.noBackupFilesDir, "im-$scope.db")
}
private fun databaseArtifacts(file: File) = listOf(file, File("${file.path}-wal"), File("${file.path}-shm"), File("${file.path}-journal"))
private fun mismatch(): Nothing = throw LocalStoreFailure(LocalStoreFailure.Reason.BindingMismatch)

internal object SqliteInstallationBinding {
    private fun exists(db: SQLiteDatabase) = db.rawQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name='im_installation'", null).use { it.moveToFirst() }
    fun requireUnbound(db: SQLiteDatabase) { if (exists(db)) mismatch() }
    fun verify(db: SQLiteDatabase, binding: LocalInstallationBinding, account: UserId, device: DeviceId) {
        if (!exists(db)) mismatch()
        db.rawQuery("SELECT singleton,format,binding,user_id,device_id FROM im_installation", null).use { rows ->
            if (!rows.moveToFirst() || rows.getLong(0) != 1L || rows.getLong(1) != 1L || rows.getString(2) != binding.value ||
                rows.getString(3) != account.value || rows.getString(4) != device.value || rows.moveToNext()) mismatch()
        }
    }
    fun verifyFile(file: File, binding: LocalInstallationBinding, account: UserId, device: DeviceId) {
        if (!file.isFile) throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable)
        try {
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS).use {
                verify(it, binding, account, device)
            }
        } catch (error: LocalStoreFailure) { throw error }
        catch (_: Exception) { throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable) }
    }
    fun establish(db: SQLiteDatabase, binding: LocalInstallationBinding, account: UserId, device: DeviceId) {
        db.transaction {
            if (exists(db)) verify(db, binding, account, device)
            else {
                val populated = db.rawQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name<>'android_metadata' LIMIT 1", null).use { it.moveToFirst() }
                if (populated) mismatch()
                db.execSQL("CREATE TABLE im_installation(singleton INTEGER PRIMARY KEY CHECK(singleton=1),format INTEGER NOT NULL CHECK(format=1),binding TEXT NOT NULL,user_id TEXT NOT NULL,device_id TEXT NOT NULL)")
                db.execSQL("INSERT INTO im_installation VALUES(1,1,?,?,?)", arrayOf(binding.value, account.value, device.value))
            }
        }
    }
}
