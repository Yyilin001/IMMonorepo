package com.xmtx.imclientkit.persistence.imcache

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Transaction
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [
        IMCacheMetadataEntity::class,
        IMCachedConversationEntity::class,
        IMCachedMessageEntity::class,
        IMSyncCursorEntity::class,
        ContactCacheMetadataEntity::class,
        CachedContactEntity::class,
        CachedContactRequestEntity::class,
    ],
    version = 3,
    exportSchema = false,
)
abstract class IMCacheDatabase : RoomDatabase() {
    abstract fun imConversationCacheDao(): IMConversationCacheDao
    abstract fun contactStateCacheDao(): ContactStateCacheDao

    companion object {
        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS contact_cache_metadata (
                        ownerUserID TEXT NOT NULL PRIMARY KEY,
                        updatedAt TEXT
                    )
                    """.trimIndent(),
                )
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS cached_contacts (
                        ownerUserID TEXT NOT NULL,
                        contactUserID TEXT NOT NULL,
                        contactJson TEXT NOT NULL,
                        sortName TEXT NOT NULL,
                        PRIMARY KEY(ownerUserID, contactUserID)
                    )
                    """.trimIndent(),
                )
                db.execSQL("CREATE INDEX IF NOT EXISTS index_cached_contacts_ownerUserID_sortName ON cached_contacts(ownerUserID, sortName)")
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS cached_contact_requests (
                        ownerUserID TEXT NOT NULL,
                        requestID TEXT NOT NULL,
                        bucket TEXT NOT NULL,
                        requestJson TEXT NOT NULL,
                        updatedAt TEXT,
                        PRIMARY KEY(ownerUserID, requestID)
                    )
                    """.trimIndent(),
                )
                db.execSQL("CREATE INDEX IF NOT EXISTS index_cached_contact_requests_ownerUserID_bucket ON cached_contact_requests(ownerUserID, bucket)")
            }
        }

        val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE im_sync_cursors ADD COLUMN pendingReadSequence INTEGER")
            }
        }

        fun create(context: Context): IMCacheDatabase =
            Room.databaseBuilder(
                context.applicationContext,
                IMCacheDatabase::class.java,
                "im_conversation_cache.db",
            ).addMigrations(MIGRATION_1_2, MIGRATION_2_3).build()
    }
}

@Entity(tableName = "im_cache_metadata")
data class IMCacheMetadataEntity(
    @PrimaryKey val ownerUserID: String,
    val selectedConversationID: String?,
    val lastSummaryRefreshAt: String?,
    val summarySyncToken: String?,
    val summaryNextCursor: String?,
    val hasMoreConversationSummaries: Boolean,
)

@Entity(
    tableName = "im_cached_conversations",
    primaryKeys = ["ownerUserID", "conversationID"],
    indices = [Index(value = ["ownerUserID", "updatedAt"])],
)
data class IMCachedConversationEntity(
    val ownerUserID: String,
    val conversationID: String,
    val summaryJson: String,
    val serverLastReadSequence: Long,
    val serverUnreadCount: Int,
    val localUnreadDelta: Int,
    val updatedAt: String,
)

@Entity(
    tableName = "im_cached_messages",
    primaryKeys = ["ownerUserID", "conversationID", "messageID"],
    indices = [
        Index(value = ["ownerUserID", "conversationID", "serverSequence"]),
        Index(value = ["ownerUserID", "conversationID", "createdAt"]),
    ],
)
data class IMCachedMessageEntity(
    val ownerUserID: String,
    val conversationID: String,
    val messageID: String,
    val clientMessageID: String?,
    val serverMessageID: String?,
    val senderUserID: String?,
    val serverSequence: Long?,
    val contentJson: String,
    val direction: String,
    val createdAt: String,
    val deliveryState: String,
)

@Entity(
    tableName = "im_sync_cursors",
    primaryKeys = ["ownerUserID", "conversationID"],
)
data class IMSyncCursorEntity(
    val ownerUserID: String,
    val conversationID: String,
    val hasLoadedMessages: Boolean,
    val latestSyncedServerSequence: Long?,
    val oldestLoadedServerSequence: Long?,
    val pendingReadSequence: Long?,
)

@Entity(tableName = "contact_cache_metadata")
data class ContactCacheMetadataEntity(
    @PrimaryKey val ownerUserID: String,
    val updatedAt: String?,
)

@Entity(
    tableName = "cached_contacts",
    primaryKeys = ["ownerUserID", "contactUserID"],
    indices = [Index(value = ["ownerUserID", "sortName"])],
)
data class CachedContactEntity(
    val ownerUserID: String,
    val contactUserID: String,
    val contactJson: String,
    val sortName: String,
)

@Entity(
    tableName = "cached_contact_requests",
    primaryKeys = ["ownerUserID", "requestID"],
    indices = [Index(value = ["ownerUserID", "bucket"])],
)
data class CachedContactRequestEntity(
    val ownerUserID: String,
    val requestID: String,
    val bucket: String,
    val requestJson: String,
    val updatedAt: String?,
)

@Dao
abstract class IMConversationCacheDao {
    @Query("SELECT * FROM im_cache_metadata WHERE ownerUserID = :ownerUserID")
    abstract suspend fun metadata(ownerUserID: String): IMCacheMetadataEntity?

    @Query("SELECT * FROM im_cached_conversations WHERE ownerUserID = :ownerUserID ORDER BY updatedAt DESC")
    abstract suspend fun conversations(ownerUserID: String): List<IMCachedConversationEntity>

    @Query(
        """
        SELECT * FROM im_cached_messages
        WHERE ownerUserID = :ownerUserID AND conversationID = :conversationID
        ORDER BY COALESCE(serverSequence, 9223372036854775807), createdAt
        """,
    )
    abstract suspend fun messages(ownerUserID: String, conversationID: String): List<IMCachedMessageEntity>

    @Query("SELECT * FROM im_sync_cursors WHERE ownerUserID = :ownerUserID")
    abstract suspend fun cursors(ownerUserID: String): List<IMSyncCursorEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract suspend fun insertMetadata(entity: IMCacheMetadataEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract suspend fun insertConversations(entities: List<IMCachedConversationEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract suspend fun insertMessages(entities: List<IMCachedMessageEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract suspend fun insertCursors(entities: List<IMSyncCursorEntity>)

    @Query("DELETE FROM im_cache_metadata WHERE ownerUserID = :ownerUserID")
    abstract suspend fun deleteMetadata(ownerUserID: String)

    @Query("DELETE FROM im_cached_conversations WHERE ownerUserID = :ownerUserID")
    abstract suspend fun deleteConversations(ownerUserID: String)

    @Query("DELETE FROM im_cached_messages WHERE ownerUserID = :ownerUserID")
    abstract suspend fun deleteMessages(ownerUserID: String)

    @Query("DELETE FROM im_sync_cursors WHERE ownerUserID = :ownerUserID")
    abstract suspend fun deleteCursors(ownerUserID: String)

    @Transaction
    open suspend fun replaceSnapshot(
        ownerUserID: String,
        metadata: IMCacheMetadataEntity,
        conversations: List<IMCachedConversationEntity>,
        messages: List<IMCachedMessageEntity>,
        cursors: List<IMSyncCursorEntity>,
    ) {
        clear(ownerUserID)
        insertMetadata(metadata)
        if (conversations.isNotEmpty()) insertConversations(conversations)
        if (messages.isNotEmpty()) insertMessages(messages)
        if (cursors.isNotEmpty()) insertCursors(cursors)
    }

    @Transaction
    open suspend fun clear(ownerUserID: String) {
        deleteMessages(ownerUserID)
        deleteCursors(ownerUserID)
        deleteConversations(ownerUserID)
        deleteMetadata(ownerUserID)
    }
}

@Dao
abstract class ContactStateCacheDao {
    @Query("SELECT * FROM contact_cache_metadata WHERE ownerUserID = :ownerUserID")
    abstract suspend fun metadata(ownerUserID: String): ContactCacheMetadataEntity?

    @Query("SELECT * FROM cached_contacts WHERE ownerUserID = :ownerUserID ORDER BY sortName")
    abstract suspend fun contacts(ownerUserID: String): List<CachedContactEntity>

    @Query("SELECT * FROM cached_contact_requests WHERE ownerUserID = :ownerUserID")
    abstract suspend fun requests(ownerUserID: String): List<CachedContactRequestEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract suspend fun insertMetadata(entity: ContactCacheMetadataEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract suspend fun insertContacts(entities: List<CachedContactEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract suspend fun insertRequests(entities: List<CachedContactRequestEntity>)

    @Query("DELETE FROM contact_cache_metadata WHERE ownerUserID = :ownerUserID")
    abstract suspend fun deleteMetadata(ownerUserID: String)

    @Query("DELETE FROM cached_contacts WHERE ownerUserID = :ownerUserID")
    abstract suspend fun deleteContacts(ownerUserID: String)

    @Query("DELETE FROM cached_contact_requests WHERE ownerUserID = :ownerUserID")
    abstract suspend fun deleteRequests(ownerUserID: String)

    @Transaction
    open suspend fun replaceSnapshot(
        ownerUserID: String,
        metadata: ContactCacheMetadataEntity,
        contacts: List<CachedContactEntity>,
        requests: List<CachedContactRequestEntity>,
    ) {
        clear(ownerUserID)
        insertMetadata(metadata)
        if (contacts.isNotEmpty()) insertContacts(contacts)
        if (requests.isNotEmpty()) insertRequests(requests)
    }

    @Transaction
    open suspend fun clear(ownerUserID: String) {
        deleteRequests(ownerUserID)
        deleteContacts(ownerUserID)
        deleteMetadata(ownerUserID)
    }
}
