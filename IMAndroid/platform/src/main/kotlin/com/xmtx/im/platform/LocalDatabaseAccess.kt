package com.xmtx.im.platform

import com.xmtx.im.client.LocalStoreFailure
import java.io.Closeable
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/** Same-process owners; all SqliteClientStore constructors participate, including legacy fixtures. */
internal object LocalDatabaseAccess {
    private data class Owners(var readers: Int = 0, var recovering: Boolean = false)
    private val owners = mutableMapOf<String, Owners>()
    private var installationRecovery = false
    fun acquire(file: File, recovery: Boolean = false, replacingInstallation: Boolean = false): Closeable = synchronized(owners) {
        require(!replacingInstallation || recovery)
        if (installationRecovery || replacingInstallation && owners.values.any { it.readers != 0 || it.recovering })
            throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable)
        val path = file.canonicalPath
        val state = owners.getOrPut(path) { Owners() }
        if (state.recovering || recovery && state.readers != 0)
            throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable)
        if (recovery) state.recovering = true else state.readers++
        if (replacingInstallation) installationRecovery = true
        val closed = AtomicBoolean()
        Closeable {
            if (closed.compareAndSet(false, true)) synchronized(owners) {
                if (recovery) state.recovering = false else state.readers--
                if (replacingInstallation) installationRecovery = false
                if (!state.recovering && state.readers == 0) owners.remove(path)
            }
        }
    }
}
