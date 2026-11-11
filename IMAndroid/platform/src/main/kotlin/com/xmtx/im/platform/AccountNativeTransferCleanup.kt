package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.LocalExitAccount
import com.xmtx.im.client.LocalExitFailure

/** Drains only the captured account/device. Preserves receipts and source files for later reconciliation. */
class AccountNativeTransferCleanup(context: Context,
    private val uploads: ResourceSystemUploadDriver = ResourceSystemUploadDriver(context),
    private val downloads: ResourceSystemDownloadDriver = ResourceSystemDownloadDriver(context),
    private val exitMarker: FileLocalExitMarker? = null) {
    private val context = context.applicationContext
    init { exitMarker?.requireContext(context) }
    suspend fun drain(account: LocalExitAccount?) {
        if (account == null) {
            val marker = exitMarker ?: return
            check(marker.isPending())
            val uploads = ResourceSystemUploadJournal.records(context)
            val downloads = ResourceSystemDownloadJournal.records(context)
            // Unknown credential identity cannot establish ownership of legacy unbound work.
            // Keep the exit pending instead of clearing its gate or cancelling another account.
            if (uploads.any { it.exitMarker == null && it.result == null } || downloads.any { it.exitMarker == null && it.result == null })
                throw LocalExitFailure(LocalExitFailure.Reason.Unavailable)
            for (row in uploads.filter { it.exitMarker == marker.identifier }) this.uploads.cancelAndDrain(row.mapping)
            for (row in downloads.filter { it.exitMarker == marker.identifier }) this.downloads.cancelAndDrain(row.mapping)
            return
        }
        val database = accountDatabaseFile(context, account.user, account.device)
        drainScope(database.name.removePrefix("im-").removeSuffix(".db"))
    }
    internal suspend fun drainScope(scope: String) {
        for (row in ResourceSystemUploadJournal.records(context).filter { it.scope == scope }) uploads.cancelAndDrain(row.mapping)
        for (row in ResourceSystemDownloadJournal.records(context).filter { it.scope == scope }) downloads.cancelAndDrain(row.mapping)
    }
}
