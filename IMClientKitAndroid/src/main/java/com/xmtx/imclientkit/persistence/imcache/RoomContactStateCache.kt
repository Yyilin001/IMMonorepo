package com.xmtx.imclientkit.persistence.imcache

import android.content.Context
import com.xmtx.imclientkit.features.contacts.ContactRequestResponseBody
import com.xmtx.imclientkit.features.contacts.ContactResponseBody
import com.xmtx.imclientkit.features.contacts.ContactState
import com.xmtx.imclientkit.features.contacts.ContactStateCaching
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.time.Instant

class RoomContactStateCache private constructor(
    database: IMCacheDatabase,
    private val json: Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    },
) : ContactStateCaching {
    private val dao = database.contactStateCacheDao()

    override suspend fun loadSnapshot(userID: String): ContactState? {
        dao.metadata(userID) ?: return null
        val contacts = dao.contacts(userID).map { json.decodeFromString<ContactResponseBody>(it.contactJson) }
        val requests = dao.requests(userID).map { entity ->
            entity.bucket to json.decodeFromString<ContactRequestResponseBody>(entity.requestJson)
        }
        return ContactState(
            contacts = contacts,
            incomingRequests = requests.filter { it.first == BUCKET_INCOMING }.map { it.second },
            outgoingRequests = requests.filter { it.first == BUCKET_OUTGOING }.map { it.second },
            resolvedRequests = requests.filter { it.first == BUCKET_RESOLVED }.map { it.second },
        )
    }

    override suspend fun saveSnapshot(userID: String, snapshot: ContactState) {
        dao.replaceSnapshot(
            ownerUserID = userID,
            metadata = ContactCacheMetadataEntity(userID, Instant.now().toString()),
            contacts = snapshot.contacts.map {
                CachedContactEntity(
                    ownerUserID = userID,
                    contactUserID = it.id,
                    contactJson = json.encodeToString(it),
                    sortName = it.preferredDisplayName.lowercase(),
                )
            },
            requests = listOf(
                snapshot.incomingRequests.map { it.toEntity(userID, BUCKET_INCOMING, json) },
                snapshot.outgoingRequests.map { it.toEntity(userID, BUCKET_OUTGOING, json) },
                snapshot.resolvedRequests.map { it.toEntity(userID, BUCKET_RESOLVED, json) },
            ).flatten(),
        )
    }

    override suspend fun clear(userID: String) {
        dao.clear(userID)
    }

    companion object {
        private const val BUCKET_INCOMING = "incoming"
        private const val BUCKET_OUTGOING = "outgoing"
        private const val BUCKET_RESOLVED = "resolved"

        fun create(database: IMCacheDatabase): RoomContactStateCache =
            RoomContactStateCache(database)

        fun create(context: Context): RoomContactStateCache =
            RoomContactStateCache(IMCacheDatabase.create(context))
    }
}

private fun ContactRequestResponseBody.toEntity(
    ownerUserID: String,
    bucket: String,
    json: Json,
): CachedContactRequestEntity =
    CachedContactRequestEntity(
        ownerUserID = ownerUserID,
        requestID = id,
        bucket = bucket,
        requestJson = json.encodeToString(this),
        updatedAt = updatedAt ?: createdAt,
    )
