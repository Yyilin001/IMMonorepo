package com.xmtx.im.client

import java.util.UUID

/** Identifies one local database lifetime, not a sync cursor or an authentication grant. */
data class LocalDatabaseIdentity(val value: String) {
    init { require(uuidId(value) == value) }
    companion object { fun create() = LocalDatabaseIdentity(UUID.randomUUID().toString().uppercase()) }
}
