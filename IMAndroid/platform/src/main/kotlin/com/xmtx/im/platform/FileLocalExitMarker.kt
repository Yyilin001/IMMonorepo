package com.xmtx.im.platform

import android.content.Context
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import com.xmtx.im.client.LocalExitFailure
import com.xmtx.im.client.LocalExitMarker
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import java.io.File
import java.security.MessageDigest

/** Non-secret, no-backup marker independent of the encrypted credential key and journal. */
class FileLocalExitMarker private constructor(internal val path: File) : LocalExitMarker {
    constructor(context: Context, scope: String) : this(File(context.noBackupFilesDir, "local-exit-" + MessageDigest.getInstance("SHA-256")
        .digest(scope.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) } + ".json"))
    internal val identifier = path.name.removePrefix("local-exit-").removeSuffix(".json")
    internal fun requireContext(context: Context) { require(path.parentFile?.canonicalFile == context.noBackupFilesDir.canonicalFile) }
    private val file = AtomicFile(path)
    private fun malformed(): Nothing = throw LocalExitFailure(LocalExitFailure.Reason.Malformed)
    private fun existsRegular(candidate: File): Boolean = try {
        val stat = Os.lstat(candidate.path)
        if (!OsConstants.S_ISREG(stat.st_mode)) malformed()
        true
    } catch (error: android.system.ErrnoException) {
        if (error.errno == OsConstants.ENOENT) false else throw error
    }
    private fun read(): Boolean {
        val present = existsRegular(path)
        val backup = existsRegular(File("${path.path}.bak"))
        // An interrupted write is not evidence of completed logout or permission to restore.
        if (existsRegular(File("${path.path}.new"))) malformed()
        if (!present && !backup) return false
        val bytes = file.openRead().use { input ->
            val buffer = ByteArray(256); var size = 0
            while (size < buffer.size) { val count = input.read(buffer, size, buffer.size - size); if (count < 0) break; size += count }
            if (input.read() != -1) malformed()
            buffer.copyOf(size)
        }
        try {
            val record = Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
            require(record.keys == setOf("version", "pending"))
            val version = record.getValue("version").jsonPrimitive
            val pending = record.getValue("pending").jsonPrimitive
            require(!version.isString && version.intOrNull == 1 && !pending.isString)
            return pending.booleanOrNull ?: malformed()
        } catch (error: LocalExitFailure) { throw error }
        catch (_: Exception) { malformed() }
    }
    private fun write(pending: Boolean) {
        for (suffix in listOf("", ".bak", ".new")) existsRegular(File(path.path + suffix))
        val stream = file.startWrite()
        try {
            stream.write("{\"version\":1,\"pending\":$pending}".toByteArray(Charsets.UTF_8))
            stream.fd.sync()
            file.finishWrite(stream)
        } catch (error: Exception) { file.failWrite(stream); throw error }
        // AtomicFile logs some rename failures instead of throwing; verify the committed value.
        if (read() != pending) throw LocalExitFailure(LocalExitFailure.Reason.Unavailable)
        val directory = Os.open(requireNotNull(path.parent), OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
        try { if (!OsConstants.S_ISDIR(Os.fstat(directory).st_mode)) malformed(); Os.fsync(directory) }
        finally { Os.close(directory) }
    }
    private suspend fun <T> access(body: () -> T): T = operations.withLock { withContext(Dispatchers.IO) {
        try { body() }
        catch (error: CancellationException) { throw error }
        catch (error: LocalExitFailure) { throw error }
        catch (_: Exception) { throw LocalExitFailure(LocalExitFailure.Reason.Unavailable) }
    } }
    override suspend fun isPending(): Boolean = access { read() }
    override suspend fun markPending(): Unit = access { write(true) }
    override suspend fun clearPending(): Unit = access { write(false) }
    internal companion object {
        private val operations = Mutex()
        fun forIdentifier(context: Context, identifier: String): FileLocalExitMarker {
            require(identifier.matches(Regex("[0-9a-f]{64}")))
            return FileLocalExitMarker(File(context.noBackupFilesDir, "local-exit-$identifier.json"))
        }
    }
}
