package com.xmtx.im.platform

import android.content.Context
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import com.xmtx.im.client.*
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.PersistentSet
import kotlinx.collections.immutable.toPersistentSet
import kotlinx.collections.immutable.persistentSetOf
import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*
import java.io.Closeable
import java.io.File
import java.io.FileInputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID

/** Opaque, process-local review; only its immutable summary is intended for UI state. */
class LocalStoreRecoveryPreview internal constructor(
    internal val account: UserId, internal val device: DeviceId,
    internal val binding: LocalInstallationBinding?, internal val artifacts: PersistentList<RecoveryArtifact>,
    internal val expires: Long, internal val damage: InstallationBindingDamage? = null,
    internal val interrupted: RecoveryPlan? = null, internal val archived: PersistentSet<RecoveryArtifactKind> = persistentSetOf(),
) {
    val summary = LocalStoreRecoverySummary(artifacts.filter { it.kind != RecoveryArtifactKind.Resources }.fold(0L) { total, item -> Math.addExact(total, item.bytes) },
        artifacts.any { it.kind == RecoveryArtifactKind.Resources }, damage != null || interrupted != null && binding == null, interrupted != null)
}

internal enum class RecoveryArtifactKind { Database, Wal, Shm, Journal, Resources }
internal data class RecoveryArtifact(val kind: RecoveryArtifactKind, val volume: Long, val inode: Long,
    val bytes: Long, val modified: Long, val digest: String?)
internal data class RecoveryPlan(val operation: String, val account: UserId, val device: DeviceId,
    val binding: LocalInstallationBinding, val artifacts: PersistentList<RecoveryArtifact>)

/** The calling bootstrapper serializes all entry points. A committed journal is durable consent to
 * finish this exact archive; it never authorizes adopting old commands into the replacement store.
 */
internal class LocalStoreRecoveryEngine(private val context: Context, private val bindings: InstallationBindingStore,
    private val nanoTime: () -> Long, private val afterArchive: suspend (RecoveryArtifactKind) -> Unit = {}) {
    private var review: LocalStoreRecoveryPreview? = null
    private data class FailedOpen(val account: UserId, val device: DeviceId, val binding: LocalInstallationBinding,
        val artifacts: PersistentList<RecoveryArtifact>)
    private var failedOpen: FailedOpen? = null
    private fun unavailable(): Nothing = throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable)
    private fun mismatch(): Nothing = throw LocalStoreFailure(LocalStoreFailure.Reason.BindingMismatch)
    private fun database(account: UserId, device: DeviceId) = accountDatabaseFile(context, account, device)
    private fun scope(file: File) = file.name.removePrefix("im-").removeSuffix(".db")
    private fun resources(file: File) = File(context.noBackupFilesDir.canonicalFile, "resources-${scope(file)}")
    private fun source(file: File, kind: RecoveryArtifactKind): File = when (kind) {
        RecoveryArtifactKind.Database -> file
        RecoveryArtifactKind.Wal -> File("${file.path}-wal")
        RecoveryArtifactKind.Shm -> File("${file.path}-shm")
        RecoveryArtifactKind.Journal -> File("${file.path}-journal")
        RecoveryArtifactKind.Resources -> resources(file)
    }
    private fun archive(file: File, operation: String) = File(File(File(context.noBackupFilesDir.canonicalFile,
        "local-recovery"), scope(file)), operation)
    private fun target(folder: File, kind: RecoveryArtifactKind) = File(folder, kind.name)
    private fun exists(file: File) = try { Os.lstat(file.path); true }
        catch (e: android.system.ErrnoException) { if (e.errno == OsConstants.ENOENT) false else throw e }

    private suspend fun observe(file: File, kind: RecoveryArtifactKind): RecoveryArtifact {
        currentCoroutineContext().ensureActive()
        val before = Os.lstat(file.path)
        if (kind == RecoveryArtifactKind.Resources) {
            if (!OsConstants.S_ISDIR(before.st_mode)) unavailable()
            // Directory rename preserves all contents. Its identity, not changing child metadata,
            // is reviewed; native writers are durably cancelled before the recovery journal commits.
            return RecoveryArtifact(kind, before.st_dev, before.st_ino, 0, 0, null)
        }
        if (!OsConstants.S_ISREG(before.st_mode)) unavailable()
        val digest = MessageDigest.getInstance("SHA-256")
        val fd = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
        FileInputStream(fd).use { input ->
            val opened = Os.fstat(fd)
            if (opened.st_dev != before.st_dev || opened.st_ino != before.st_ino) unavailable()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                currentCoroutineContext().ensureActive()
                val count = input.read(buffer); if (count < 0) break
                digest.update(buffer, 0, count)
            }
            val after = Os.fstat(fd)
            if (after.st_size != before.st_size || after.st_mtime != before.st_mtime) unavailable()
        }
        return RecoveryArtifact(kind, before.st_dev, before.st_ino, before.st_size, before.st_mtime,
            digest.digest().joinToString("") { "%02x".format(it) })
    }
    private suspend fun snapshot(file: File) = RecoveryArtifactKind.entries.mapNotNull { kind ->
        source(file, kind).takeIf(::exists)?.let { observe(it, kind) }
    }.toPersistentList()

    /** Only the bootstrapper calls this after a bound constructor actually failed and closed. */
    suspend fun rememberOpenFailure(account: UserId, device: DeviceId) {
        failedOpen = null
        val file = database(account, device)
        LocalDatabaseAccess.acquire(file, recovery = true).use {
            val binding = bindings.load() ?: return
            SqliteInstallationBinding.verifyFile(file, binding, account, device)
            failedOpen = FailedOpen(account, device, binding, snapshot(file))
        }
    }
    fun openedSuccessfully() { failedOpen = null; review = null }

    /** Requires the same file lock used by ManagedResourceFiles, without creating a lock file. */
    private fun mediaLock(root: File): Closeable {
        if (!exists(root)) return Closeable {}
        if (!OsConstants.S_ISDIR(Os.lstat(root.path).st_mode)) unavailable()
        val file = File(root, "owner.lock")
        if (!exists(file)) return Closeable {}
        if (!OsConstants.S_ISREG(Os.lstat(file.path).st_mode)) unavailable()
        val handle = RandomAccessFile(file, "rw")
        try {
            val lock = handle.channel.tryLock() ?: unavailable()
            return Closeable { try { lock.release() } finally { handle.close() } }
        } catch (error: Throwable) { handle.close(); throw error }
    }

    private data class BindingState(val binding: LocalInstallationBinding?, val damage: InstallationBindingDamage? = null)
    private suspend fun bindingState(): BindingState = try { BindingState(bindings.load()) }
        catch (error: LocalStoreFailure) {
            if (error.reason != LocalStoreFailure.Reason.BindingMalformed && error.reason != LocalStoreFailure.Reason.BindingInvalidated) throw error
            val repairing = bindings as? InstallationBindingRepairing ?: throw error
            val damage = repairing.inspectDamage() ?: mismatch()
            if (damage.reason != error.reason) mismatch()
            BindingState(null, damage)
        }

    suspend fun preview(account: UserId, device: DeviceId): LocalStoreRecoveryPreview {
        review = null
        val file = database(account, device)
        if (pending(file)) return previewInterrupted(file, account, device)
        return LocalDatabaseAccess.acquire(file, recovery = true).use {
            mediaLock(resources(file)).use {
                val state = bindingState()
                val binding = state.binding
                var requiresFailedOpen = false
                if (binding != null && exists(file)) {
                    val healthy = try { SqliteInstallationBinding.verifyFile(file, binding, account, device); true }
                    catch (error: LocalStoreFailure) {
                        if (error.reason != LocalStoreFailure.Reason.BindingMismatch &&
                            error.reason != LocalStoreFailure.Reason.StoreUnavailable) throw error
                        false
                    }
                    requiresFailedOpen = healthy
                }
                val artifacts = snapshot(file)
                if (artifacts.isEmpty() && state.damage == null) unavailable()
                if (requiresFailedOpen && failedOpen != FailedOpen(account, device, requireNotNull(binding), artifacts)) unavailable()
                if (bindingState() != state) mismatch()
                LocalStoreRecoveryPreview(account, device, binding, artifacts, nanoTime() + 60_000_000_000, state.damage).also { review = it }
            }
        }
    }

    suspend fun recover(preview: LocalStoreRecoveryPreview) {
        if (review !== preview || preview.expires - nanoTime() <= 0) unavailable()
        review = null
        val file = database(preview.account, preview.device)
        if (preview.interrupted != null) { recoverInterrupted(file, preview); return }
        LocalDatabaseAccess.acquire(file, recovery = true, replacingInstallation = preview.damage != null).use {
            mediaLock(resources(file)).use {
                val reviewedBinding = BindingState(preview.binding, preview.damage)
                if (pending(file) || bindingState() != reviewedBinding || snapshot(file) != preview.artifacts) mismatch()
                drainNative(scope(file))
                if (snapshot(file) != preview.artifacts || bindingState() != reviewedBinding) mismatch()
                currentCoroutineContext().ensureActive()
                val binding = preview.binding ?: LocalInstallationBinding.create().also {
                    val damage = preview.damage
                    if (damage == null) bindings.save(it)
                    else (bindings as? InstallationBindingRepairing ?: mismatch()).replaceDamagedBinding(damage, it)
                }
                if (bindings.load() != binding || snapshot(file) != preview.artifacts) mismatch()
                // With no database/resources there is nothing to archive or resume. A failed repair
                // still leaves the next open to re-evaluate the binding; no old projection is adopted.
                if (preview.artifacts.isEmpty()) return
                val plan = RecoveryPlan(UUID.randomUUID().toString().uppercase(), preview.account, preview.device, binding, preview.artifacts)
                save(file, plan)
                finish(file, plan)
            }
        }
    }

    /** Existing archive paths are checked without creating directories or following symlinks. */
    private fun checkedArchive(file: File, plan: RecoveryPlan): File {
        val folder = archive(file, plan.operation)
        for (directory in listOf(requireNotNull(folder.parentFile?.parentFile), requireNotNull(folder.parentFile), folder)) {
            if (exists(directory) && !OsConstants.S_ISDIR(Os.lstat(directory.path).st_mode)) unavailable()
        }
        if (exists(folder)) {
            val names = folder.list()?.toSet() ?: unavailable()
            if (names.any { name -> plan.artifacts.none { it.kind.name == name } }) mismatch()
        }
        return folder
    }

    /** Exactly one of the original and archived locations must hold every reviewed artifact. */
    private suspend fun interruptedLocations(file: File, plan: RecoveryPlan): PersistentSet<RecoveryArtifactKind> {
        val folder = checkedArchive(file, plan)
        val archived = mutableSetOf<RecoveryArtifactKind>()
        for (kind in RecoveryArtifactKind.entries) {
            val original = source(file, kind); val retained = target(folder, kind)
            val atSource = exists(original); val atArchive = exists(retained)
            val expected = plan.artifacts.firstOrNull { it.kind == kind }
            if (expected == null) { if (atSource || atArchive) mismatch(); continue }
            if (atSource == atArchive || observe(if (atSource) original else retained, kind) != expected) mismatch()
            if (atArchive) archived.add(kind)
        }
        return archived.toPersistentSet()
    }

    private fun retainedResources(file: File, plan: RecoveryPlan): File {
        val folder = checkedArchive(file, plan)
        val original = source(file, RecoveryArtifactKind.Resources)
        return if (exists(original)) original else target(folder, RecoveryArtifactKind.Resources)
    }

    private suspend fun previewInterrupted(file: File, account: UserId, device: DeviceId): LocalStoreRecoveryPreview =
        LocalDatabaseAccess.acquire(file, recovery = true).use {
            val plan = read(file)
            if (plan.account != account || plan.device != device) mismatch()
            mediaLock(retainedResources(file, plan)).use {
                val state = bindingState()
                val archived = interruptedLocations(file, plan)
                if (read(file) != plan || bindingState() != state) mismatch()
                LocalStoreRecoveryPreview(account, device, state.binding, plan.artifacts, nanoTime() + 60_000_000_000,
                    state.damage, plan, archived).also { review = it }
            }
        }

    private suspend fun recoverInterrupted(file: File, preview: LocalStoreRecoveryPreview) {
        val plan = requireNotNull(preview.interrupted)
        val expected = BindingState(preview.binding, preview.damage)
        LocalDatabaseAccess.acquire(file, recovery = true, replacingInstallation = preview.binding == null).use {
            mediaLock(retainedResources(file, plan)).use {
                suspend fun revalidate() {
                    if (read(file) != plan || interruptedLocations(file, plan) != preview.archived || bindingState() != expected) mismatch()
                }
                revalidate()
                drainNative(scope(file))
                revalidate()
                currentCoroutineContext().ensureActive()
                val binding = preview.binding ?: LocalInstallationBinding.create().also {
                    val damage = preview.damage
                    if (damage == null) bindings.save(it)
                    else (bindings as? InstallationBindingRepairing ?: mismatch()).replaceDamagedBinding(damage, it)
                }
                if (bindings.load() != binding || read(file) != plan || interruptedLocations(file, plan) != preview.archived) mismatch()
                // Only the binding changes. Retain original operation, artifact identities and folder.
                // A crash before this atomic update requires another review; after it, resume is safe.
                val rebound = plan.copy(binding = binding)
                if (rebound != plan) save(file, rebound)
                finish(file, rebound)
            }
        }
    }

    suspend fun resume(account: UserId, device: DeviceId) {
        val file = database(account, device)
        val plan = read(file)
        if (plan.account != account || plan.device != device || bindings.load() != plan.binding) mismatch()
        LocalDatabaseAccess.acquire(file, recovery = true).use {
            mediaLock(retainedResources(file, plan)).use {
                if (read(file) != plan) mismatch()
                interruptedLocations(file, plan)
                drainNative(scope(file))
                finish(file, plan)
            }
        }
    }

    private suspend fun drainNative(scope: String) {
        AccountNativeTransferCleanup(context).drainScope(scope)
    }
    private fun directory(file: File) {
        if (!exists(file)) { Os.mkdir(file.path, 448); sync(requireNotNull(file.parentFile)); sync(file) }
        if (!OsConstants.S_ISDIR(Os.lstat(file.path).st_mode)) unavailable()
    }
    private fun sync(directory: File) {
        val fd = Os.open(directory.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
        try { Os.fsync(fd) } finally { Os.close(fd) }
    }
    private fun payload(plan: RecoveryPlan) = buildJsonObject {
        put("format", 1); put("operation", plan.operation); put("account", plan.account.value); put("device", plan.device.value)
        put("binding", plan.binding.value)
        put("artifacts", buildJsonArray { plan.artifacts.forEach { artifact -> add(buildJsonObject {
            put("kind", artifact.kind.name); put("volume", artifact.volume); put("inode", artifact.inode)
            put("bytes", artifact.bytes); put("modified", artifact.modified); artifact.digest?.let { put("digest", it) }
        }) } })
    }
    private fun checkJournalArtifacts(file: File) {
        for (candidate in listOf(journal(file), File("${journal(file).path}.bak"), File("${journal(file).path}.new")))
            if (exists(candidate) && !OsConstants.S_ISREG(Os.lstat(candidate.path).st_mode)) unavailable()
    }
    private fun save(file: File, plan: RecoveryPlan) {
        checkJournalArtifacts(file)
        val atomic = AtomicFile(journal(file)); val output = atomic.startWrite()
        try { output.write(payload(plan).toString().toByteArray()); atomic.finishWrite(output) }
        catch (error: Throwable) { atomic.failWrite(output); throw error }
        sync(requireNotNull(file.parentFile))
    }
    private fun read(file: File): RecoveryPlan {
        checkJournalArtifacts(file)
        val atomic = AtomicFile(journal(file))
        val text = atomic.openRead().use { input ->
            val buffer = ByteArray(16_385); var count = 0
            while (count < buffer.size) { val n = input.read(buffer, count, buffer.size - count); if (n < 0) break; count += n }
            require(count < buffer.size); buffer.copyOf(count).toString(Charsets.UTF_8)
        }
        val value = Json.parseToJsonElement(text).jsonObject
        require(value.keys == setOf("format", "operation", "account", "device", "binding", "artifacts"))
        fun JsonObject.number(key: String): Long = getValue(key).jsonPrimitive.let { require(!it.isString); requireNotNull(it.longOrNull) }
        fun JsonObject.text(key: String): String = getValue(key).jsonPrimitive.let { require(it.isString); it.content }
        require(value.number("format") == 1L)
        val operation = value.text("operation")
        require(UUID.fromString(operation).toString().uppercase() == operation)
        val artifacts = value.getValue("artifacts").jsonArray.map { entry ->
            val item = entry.jsonObject
            val kind = RecoveryArtifactKind.valueOf(item.text("kind"))
            val digest = if ("digest" in item) item.text("digest") else null
            require(item.keys == setOf("kind", "volume", "inode", "bytes", "modified") + if (digest == null) emptySet() else setOf("digest"))
            require(if (kind == RecoveryArtifactKind.Resources) digest == null else digest?.matches(Regex("[0-9a-f]{64}")) == true)
            val bytes = item.number("bytes").also { require(it >= 0) }; val modified = item.number("modified")
            if (kind == RecoveryArtifactKind.Resources) require(bytes == 0L && modified == 0L)
            RecoveryArtifact(kind, item.number("volume"), item.number("inode"), bytes, modified, digest)
        }.toPersistentList()
        require(artifacts.isNotEmpty() && artifacts.size <= RecoveryArtifactKind.entries.size && artifacts.map { it.kind }.distinct().size == artifacts.size)
        return RecoveryPlan(operation, UserId(value.text("account")), DeviceId(value.text("device")),
            LocalInstallationBinding(value.text("binding")), artifacts)
    }
    private suspend fun finish(file: File, plan: RecoveryPlan) {
        if (bindings.load() != plan.binding) mismatch()
        val folder = archive(file, plan.operation)
        directory(requireNotNull(folder.parentFile?.parentFile)); directory(requireNotNull(folder.parentFile)); directory(folder)
        for (artifact in plan.artifacts) {
            currentCoroutineContext().ensureActive()
            val from = source(file, artifact.kind); val to = target(folder, artifact.kind)
            if (exists(to)) {
                if (exists(from) || observe(to, artifact.kind) != artifact) mismatch()
            } else {
                if (!exists(from) || observe(from, artifact.kind) != artifact) mismatch()
                Os.rename(from.path, to.path)
                sync(requireNotNull(from.parentFile)); sync(folder)
                afterArchive(artifact.kind)
            }
        }
        // Unexpected artifacts cannot be silently adopted into the newly empty account path.
        if (RecoveryArtifactKind.entries.any { exists(source(file, it)) } || bindings.load() != plan.binding) mismatch()
        val receipt = File(folder, "manifest.json")
        if (exists(receipt)) unavailable()
        Os.rename(journal(file).path, receipt.path)
        sync(folder); sync(requireNotNull(file.parentFile))
    }
    companion object {
        private fun journal(file: File) = File("${file.path}.recovery.json")
        fun pending(file: File) = listOf(journal(file), File("${journal(file).path}.bak")).any {
            try { Os.lstat(it.path); true } catch (error: android.system.ErrnoException) {
                if (error.errno == OsConstants.ENOENT) false else throw error
            }
        }
    }
}
