package com.xmtx.im.platform

import android.content.Context
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import android.system.Os
import android.system.OsConstants
import androidx.core.database.sqlite.transaction
import com.xmtx.im.client.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.io.File

/** Called under the bootstrapper's opening/recovery lock, after live account owners have drained.
 * No account-store constructor, schema migration, key creation, directory scan or resource deletion.
 */
internal class LocalProfileExitCleanup(private val context: Context, private val bindings: InstallationBindingStore) {
    private data class FileIdentity(val volume: Long, val inode: Long)
    private fun unavailable(): Nothing = throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable)
    private fun identity(file: File): FileIdentity? = try {
        val stat = Os.lstat(file.path)
        if (!OsConstants.S_ISREG(stat.st_mode)) unavailable()
        FileIdentity(stat.st_dev, stat.st_ino)
    } catch (error: android.system.ErrnoException) {
        if (error.errno == OsConstants.ENOENT) null else throw error
    }
    private fun validateFiles(file: File, expected: FileIdentity) {
        if (identity(file) != expected) unavailable()
        for (suffix in listOf("-wal", "-shm", "-journal")) identity(File(file.path + suffix))
    }
    private fun open(file: File, readOnly: Boolean): SQLiteDatabase = SQLiteDatabase.openDatabase(file.path, null,
        (if (readOnly) SQLiteDatabase.OPEN_READONLY else SQLiteDatabase.OPEN_READWRITE) or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
        // The default corruption handler may delete a database. Exit never authorizes that recovery.
        DatabaseErrorHandler { unavailable() })
    private fun hasFacts(db: SQLiteDatabase): Boolean {
        val type = db.rawQuery("SELECT type FROM sqlite_master WHERE name='local_profile_displays'", null).use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: return false
        if (type != "table") unavailable()
        return db.rawQuery("SELECT 1 FROM local_profile_displays LIMIT 1", null).use { it.moveToFirst() }
    }
    private suspend fun requirePending(marker: FileLocalExitMarker) {
        currentCoroutineContext().ensureActive()
        if (!marker.isPending()) throw LocalExitFailure(LocalExitFailure.Reason.Unavailable)
    }
    suspend fun clear(account: LocalExitAccount?, marker: FileLocalExitMarker) {
        marker.requireContext(context); requirePending(marker)
        // Permanently unreadable credentials supply no identity. Never infer it from another file.
        if (account == null) return
        val file = accountDatabaseFile(context, account.user, account.device)
        LocalDatabaseAccess.acquire(file, recovery = true).use {
            if (LocalStoreRecoveryEngine.pending(file)) unavailable()
            val fileIdentity = identity(file)
            if (fileIdentity == null) {
                if (listOf("-wal", "-shm", "-journal").any { identity(File(file.path + it)) != null }) unavailable()
                return
            }
            validateFiles(file, fileIdentity)
            val trusted = open(file, readOnly = true).use { db ->
                // Legacy stores or an already-cleared cache have no work. Do not establish a binding.
                if (!hasFacts(db)) return
                val binding = bindings.load() ?: throw LocalStoreFailure(LocalStoreFailure.Reason.BindingMismatch)
                SqliteInstallationBinding.verify(db, binding, account.user, account.device)
                binding to SqliteDatabaseIdentity.read(db)
            }
            validateFiles(file, fileIdentity); requirePending(marker)
            if (bindings.load() != trusted.first) throw LocalStoreFailure(LocalStoreFailure.Reason.BindingMismatch)
            requirePending(marker); validateFiles(file, fileIdentity)
            val caller = currentCoroutineContext(); caller.ensureActive()
            open(file, readOnly = false).use { db -> db.transaction {
                validateFiles(file, fileIdentity)
                SqliteInstallationBinding.verify(db, trusted.first, account.user, account.device)
                if (SqliteDatabaseIdentity.read(db) != trusted.second) unavailable()
                caller.ensureActive()
                db.execSQL("DELETE FROM local_profile_displays")
                // Silent trigger rejection or reinsertion must roll back and keep exit pending.
                if (hasFacts(db)) unavailable()
                validateFiles(file, fileIdentity); caller.ensureActive()
            } }
            validateFiles(file, fileIdentity)
            if (bindings.load() != trusted.first) throw LocalStoreFailure(LocalStoreFailure.Reason.BindingMismatch)
            requirePending(marker)
        }
    }
}
