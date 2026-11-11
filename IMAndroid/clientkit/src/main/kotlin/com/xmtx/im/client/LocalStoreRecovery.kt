package com.xmtx.im.client

/** UI review data contains no paths, credentials, file contents or mutable collections. */
data class LocalStoreRecoverySummary(val databaseBytes: Long, val includesResources: Boolean,
    val rebuildsInstallationBinding: Boolean = false, val continuesRecovery: Boolean = false) {
    init { require(databaseBytes >= 0) }
}
