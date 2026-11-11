package com.xmtx.im.platform

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.PersistentSet
import kotlinx.collections.immutable.PersistentMap
import kotlinx.collections.immutable.toPersistentMap
import kotlinx.collections.immutable.toPersistentList
import kotlinx.collections.immutable.toPersistentSet
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import java.io.Closeable
import java.io.File
import java.security.MessageDigest

/** Account/device scoped, no-backup SQLite. Every sync transition is a single WAL transaction.
 * Production callers use LocalStoreBootstrapper. The unbound constructor supports legacy fixtures
 * and cannot open an already-bound database without its installation marker.
 */
class SqliteClientStore private constructor(context: Context, private val account: UserId, private val device: DeviceId, installationBinding: LocalInstallationBinding?, val isReadOnly: Boolean, operationLimits: OperationAdmissionLimits) : OperationAdmissionReading, SyncStore, OutboxStore, LiveRoomStore, RoomContentStore, DirectSendingCapabilityStore, RoomDirectoryStore, RoomLatestVisibleStore, AccountRoomHeadStore, DirectRoomStore, LocalDirectMessageStore, SocialStore, GroupCreationStore, MembershipStore, GroupCapabilityStore, AccountPreferenceStore, PersonalPreferenceStore, MessageMutationStore, MessageReactionStore, ForwardPlanStore, InvitationStore, AdministrationStore, ModerationStore, RolePolicyRecoveryStore, ReadReceiptStore, RoomReadWatermarkReading, RelationshipWindowStore, NameOperationClaimStore, OwnProfileOperationClaimStore, ConversationDraftStore, ConversationImportDraftStore, SendIntentStore, ProfileIntentStore, GroupAvatarIntentStore, ResourceFileJournal, ResourceUploadJournal, ResourceBackgroundUploadJournal, ResourceImportJournal, ResourceDownloadJournal,ResourceBackgroundDownloadJournal,ResourceDownloadNetworkSettings, ResourceTransferStore, ResourcePreparationCancellationStore, ResourceUnboundCancellationStore, ResourceBusinessOwnerStore, ConversationTimelineStore, MessageSourceStore, FavoriteMessageStore, SendHistoryStore, TextSendReplacementStore, TextSendAbandonmentStore, MessageSearchStore, ResourceCatalogStore, GroupAvatarResourceSelectionStore, MessageResourceReadStore, Closeable {
    constructor(context: Context, account: UserId, device: DeviceId, installationBinding: LocalInstallationBinding? = null, operationLimits: OperationAdmissionLimits = OperationAdmissionLimits())
        : this(context, account, device, installationBinding, false, operationLimits)
    internal companion object {
        fun openReadOnly(context: Context, account: UserId, device: DeviceId, binding: LocalInstallationBinding) =
            SqliteClientStore(context, account, device, binding, true, OperationAdmissionLimits())
    }
    override val resourceDirectoryChanges: kotlinx.coroutines.flow.StateFlow<Long> get() = resourceChanges
    private val catalog: SqliteResourceCatalog
    private val resourceChanges = kotlinx.coroutines.flow.MutableStateFlow(0L)
    override val resourceImportChanges: kotlinx.coroutines.flow.StateFlow<Long> = resourceChanges
    override val resourceBackgroundUploadChanges:kotlinx.coroutines.flow.StateFlow<Long> = resourceChanges
    override val resourceUploadChanges: kotlinx.coroutines.flow.StateFlow<Long> = resourceChanges
    override val resourceTransferChanges:kotlinx.coroutines.flow.StateFlow<Long> = resourceChanges
    override val resourceBusinessOwnerChanges:kotlinx.coroutines.flow.StateFlow<Long> = resourceChanges
    override val resourceDownloadChanges: kotlinx.coroutines.flow.StateFlow<Long> = resourceChanges
    override val sendIntentChanges: kotlinx.coroutines.flow.StateFlow<Long> = resourceChanges
    override val profileIntentChanges: kotlinx.coroutines.flow.StateFlow<Long> = resourceChanges
    override val groupAvatarIntentChanges: kotlinx.coroutines.flow.StateFlow<Long> = resourceChanges
    internal val resourceActor get()=account
    internal val resourceScope: String
    val databaseIdentity: LocalDatabaseIdentity
    private val mutex = Mutex()
    private val databaseLifecycle = Any()
    private var databaseClosed = false
    private var projectionDiagnostics: SqliteProjectionDiagnostics? = null
    private var operationAdmission: SqliteOperationAdmission? = null
    override suspend fun operationAdmissionUsage() = access { transaction { requireNotNull(operationAdmission).usage() } }
    suspend fun installNetworkDiagnostics(diagnostics: NetworkDiagnostics) = access {
        check(!isReadOnly) { "Read-only stores do not observe writes" }
        val current=projectionDiagnostics
        check(current==null || current.diagnostics===diagnostics) { "Diagnostics owner cannot change" }
        if(current==null) projectionDiagnostics=SqliteProjectionDiagnostics(db,diagnostics)
    }
    override val syncMutex=Mutex()
    private val policyRecovery: SqlitePolicyRecovery
    private val imports: SqliteResourceImports
    private val backgroundUploads:SqliteBackgroundUploads
    private val resources: SqliteResourceFiles
    private val ownProfile: SqliteOwnProfile
    private val retention:SqliteResourceRetention
    private val storagePolicy:SqliteResourceStoragePolicy
    private val backgroundDownloadSources:SqliteBackgroundDownloadSources
    private val downloads:SqliteResourceDownloads
    private val conversationDrafts: SqliteConversationDrafts
    private val sendIntents: SqliteSendIntents
    private val profileIntents: SqliteProfileIntents
    private val names: SqliteNameOperations
    private val operationWorkJournal: SqliteOperationWork
    private val nameClaims: SqliteNameOperationClaims
    private val profileClaims: SqliteOwnProfileClaims
    private fun registerProfileExecution(work: OwnProfileWork, now: Long?) { profileClaims.ensure(work, now) }
    private fun retryProfileExecution(operation: String, now: Long) { profileClaims.retry(operation, now) }
    override val operationWorkKinds = kotlinx.collections.immutable.persistentSetOf(OperationKind.ContactAlias, OperationKind.GroupNickname, OperationKind.ProfileUpdate)
    override suspend fun operationWork(id: String) = access { operationWorkJournal.read(id) }
    override suspend fun dueOperationWork(now: Long, limit: Int, kinds: kotlinx.collections.immutable.PersistentSet<OperationKind>?) = access { transaction { operationWorkJournal.due(now, limit, kinds) } }
    private val readReceipts: SqliteReadReceipts
    private val profilePresentations: SqliteProfilePresentations
    private val localDirectMessages: SqliteLocalDirectMessages
    override val localDirectMessageChanges: kotlinx.coroutines.flow.StateFlow<Long> = resourceChanges
    private val directIdentities: SqliteDirectRoomIdentities
    private val relationshipPages: SqliteRelationshipPages
    private val localProfileDisplays: SqliteLocalProfileDisplays
    private val localProfileChanges = MutableStateFlow(0L)
    /** Recheck signal, not a commit receipt. Readers serialize behind the current transaction. */
    val localDisplayChanges = localProfileChanges.asStateFlow()
    private fun signalLocalDisplay() { localProfileChanges.value += 1 }
    private val groupAvatars: SqliteGroupAvatars
    private val groupAvatarIntents: SqliteGroupAvatarIntents
    private val accountRoomHeads: SqliteAccountRoomHeads
    private val roomDirectory: SqliteRoomDirectory
    private val latestVisible: SqliteLatestVisible
    private val search: SqliteMessageSearch
    private val sendRecovery: SqliteSendRecovery
    private val outboxEchoes: SqliteOutboxEchoes
    private val favorites: SqliteFavoriteMessages
    private val timelineActivities: SqliteTimelineActivities
    private val directSendingCapabilities: SqliteDirectSendingCapabilities
    private val timeline: SqliteConversationTimeline
    private val db: SQLiteDatabase
    private val databaseAccess: Closeable
    init {
        val identity = "${account.value}/${device.value}"
        val digest = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray()).joinToString("") { "%02x".format(it) }
        resourceScope = digest
        if (LocalStoreRecoveryEngine.pending(accountDatabaseFile(context, account, device)))
            throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable)
        databaseAccess = LocalDatabaseAccess.acquire(accountDatabaseFile(context, account, device))
        db = try {
            val file = accountDatabaseFile(context, account, device)
            if (isReadOnly) SqliteLocalReadConnection.open(file)
            else SQLiteDatabase.openOrCreateDatabase(file, null)
        }
        catch (error: Throwable) { databaseAccess.close(); throw error }
        try {
        if (isReadOnly) {
            SqliteInstallationBinding.verify(db, requireNotNull(installationBinding), account, device)
            databaseIdentity = SqliteDatabaseIdentity.read(db)
            SqliteLocalReadSchema.verify(db)
        } else {
        if (installationBinding != null) SqliteInstallationBinding.establish(db, installationBinding, account, device)
        else SqliteInstallationBinding.requireUnbound(db)
        db.enableWriteAheadLogging()
        db.execSQL("PRAGMA synchronous=FULL")
        databaseIdentity = SqliteDatabaseIdentity.establish(db)
        db.execSQL("CREATE TABLE IF NOT EXISTS cursor (id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL, sequence INTEGER NOT NULL, token TEXT NOT NULL, receipt TEXT)")
        db.execSQL("INSERT OR IGNORE INTO cursor(id,generation,sequence,token,receipt) VALUES (1,0,0,'',NULL)")
        val hasReceiptSequence=db.rawQuery("PRAGMA table_info(cursor)",null).use {rows->
            var found=false;while(rows.moveToNext()) if(rows.getString(1)=="receipt_sequence") found=true
            found
        }
        if(!hasReceiptSequence) transaction {
            db.execSQL("ALTER TABLE cursor ADD COLUMN receipt_sequence INTEGER")
            db.execSQL("UPDATE cursor SET receipt_sequence=sequence WHERE receipt IS NOT NULL")
        }
        db.execSQL("CREATE TABLE IF NOT EXISTS sync_history(sequence INTEGER PRIMARY KEY,event TEXT NOT NULL,kind TEXT NOT NULL,digest TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS sync_reset(id INTEGER PRIMARY KEY CHECK(id=1),snapshot_id TEXT NOT NULL,generation INTEGER NOT NULL CHECK(generation>0),base_sequence INTEGER NOT NULL CHECK(base_sequence>=0),expires_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS sync_rebuild(id INTEGER PRIMARY KEY CHECK(id=1))")
        db.execSQL("CREATE TABLE IF NOT EXISTS records (event TEXT NOT NULL, kind TEXT NOT NULL, payload BLOB NOT NULL, room TEXT, PRIMARY KEY(event,kind))")
        db.execSQL("CREATE TABLE IF NOT EXISTS snapshot (id INTEGER PRIMARY KEY CHECK(id=1), manifest BLOB NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS pages (page INTEGER PRIMARY KEY, payload BLOB NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS snapshot_import(id INTEGER PRIMARY KEY CHECK(id=1),next_page INTEGER NOT NULL,item_count INTEGER NOT NULL,byte_count INTEGER NOT NULL,digest TEXT NOT NULL,last_kind TEXT,last_key TEXT)")
        db.execSQL("CREATE TABLE IF NOT EXISTS snapshot_items(kind TEXT NOT NULL,entity_key TEXT NOT NULL,source TEXT NOT NULL,sequence INTEGER NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(kind,entity_key))")
        db.execSQL("CREATE TABLE IF NOT EXISTS forward_operations (id TEXT PRIMARY KEY, work TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS reaction_operations (id TEXT PRIMARY KEY, work TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS reaction_effects (source TEXT NOT NULL, message TEXT NOT NULL, actor TEXT NOT NULL, reaction TEXT NOT NULL, room TEXT NOT NULL, effect TEXT NOT NULL, PRIMARY KEY(source,message,actor,reaction))")
        db.execSQL("CREATE TABLE IF NOT EXISTS reaction_versions (message TEXT NOT NULL, actor TEXT NOT NULL, reaction TEXT NOT NULL, room TEXT NOT NULL, present INTEGER NOT NULL, effect TEXT NOT NULL, PRIMARY KEY(message,actor,reaction))")
        db.execSQL("CREATE TABLE IF NOT EXISTS message_mutations (id TEXT PRIMARY KEY, work TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS message_tombstones (id TEXT PRIMARY KEY, room TEXT NOT NULL, revision INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, room TEXT NOT NULL, sender TEXT NOT NULL, text TEXT NOT NULL, time INTEGER NOT NULL, revision INTEGER NOT NULL, sequence INTEGER NOT NULL)")
        db.rawQuery("PRAGMA table_info(messages)", null).use { rows ->
            var found = false; while(rows.moveToNext()) if(rows.getString(1) == "withdrawn") found = true
            if(!found) db.execSQL("ALTER TABLE messages ADD COLUMN withdrawn INTEGER NOT NULL DEFAULT 0")
        }
        val messageColumns = db.rawQuery("PRAGMA table_info(messages)", null).use { rows -> buildSet { while(rows.moveToNext()) add(rows.getString(1)) } }
        listOf("forwarded_message", "forwarded_sender").filter { it !in messageColumns }.forEach { db.execSQL("ALTER TABLE messages ADD COLUMN $it TEXT") }
        if("accepted_sequence" !in messageColumns) transaction {
            db.execSQL("ALTER TABLE messages ADD COLUMN accepted_sequence INTEGER NOT NULL DEFAULT 0")
            // The old sequence column is a timeline sort key. Recover room positions only from actual accepted payloads.
            db.rawQuery("SELECT payload FROM records WHERE kind='message'",null).use { rows -> while(rows.moveToNext()) {
                val raw = Json.parseToJsonElement(rows.getBlob(0).toString(Charsets.UTF_8)).jsonObject
                val value = if(raw["event_type"]?.jsonPrimitive?.content == "message.edited") raw["replacement"]?.jsonObject?.get("state")?.jsonObject else raw
                if(value?.get("event_type")?.jsonPrimitive?.content != "message.accepted") continue
                val sequence = value["room_sequence"]?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: continue
                if(sequence <= 0) throw ClientFailure.Protocol()
                val id = MessageId(value.required("message_id")).value;val room = RoomId(value.required("room_id")).value
                val old = db.rawQuery("SELECT accepted_sequence FROM messages WHERE id=? AND room=?",arrayOf(id,room)).use { if(it.moveToFirst()) it.getLong(0) else 0 }
                if(old != 0L && old != sequence) throw ClientFailure.Protocol()
                db.execSQL("UPDATE messages SET accepted_sequence=? WHERE id=? AND room=?",arrayOf<Any>(sequence,id,room))
            } }
        }
        if("media" !in messageColumns) transaction { migrateMessageMedia(db) }
        if("rich" !in messageColumns) transaction { migrateMessageRich(db) }
        if("source_text" !in messageColumns) db.execSQL("ALTER TABLE messages ADD COLUMN source_text TEXT")
        val tombstoneColumns = db.rawQuery("PRAGMA table_info(message_tombstones)",null).use { rows -> buildSet { while(rows.moveToNext()) add(rows.getString(1)) } }
        if("redacted" !in tombstoneColumns) transaction {
            db.execSQL("ALTER TABLE message_tombstones ADD COLUMN redacted INTEGER NOT NULL DEFAULT 0")
            // Existing versions retained original room events; recover the removal label without restoring content.
            db.rawQuery("SELECT payload FROM records WHERE kind='message'",null).use { rows -> while(rows.moveToNext()) {
                val value = Json.parseToJsonElement(rows.getBlob(0).toString(Charsets.UTF_8)).jsonObject
                if(value["event_type"]?.jsonPrimitive?.content == "message.redacted") {
                    val message = MessageId(value.required("message_id")).value;val room = RoomId(value.required("room_id")).value
                    db.execSQL("UPDATE message_tombstones SET redacted=1 WHERE id=? AND room=?",arrayOf(message,room))
                    db.execSQL("UPDATE messages SET text=? WHERE id=? AND room=? AND withdrawn=1",arrayOf("消息已由管理员移除",message,room))
                }
            } }
        }
        db.execSQL("CREATE TABLE IF NOT EXISTS role_policy_effects (source TEXT NOT NULL,room TEXT NOT NULL,effect TEXT NOT NULL,PRIMARY KEY(source,room))")
        db.execSQL("CREATE TABLE IF NOT EXISTS role_policy_observations (room TEXT NOT NULL,role TEXT NOT NULL,effect TEXT NOT NULL,PRIMARY KEY(room,role))")
        db.execSQL("CREATE TABLE IF NOT EXISTS member_access_effects (source TEXT NOT NULL,user TEXT NOT NULL,room TEXT NOT NULL,revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),effect TEXT NOT NULL,PRIMARY KEY(source,user),UNIQUE(room,user,revision))")
        db.execSQL("CREATE TABLE IF NOT EXISTS member_access_observations (room TEXT NOT NULL,user TEXT NOT NULL,effect TEXT NOT NULL,PRIMARY KEY(room,user))")
        db.execSQL("CREATE TABLE IF NOT EXISTS group_metadata_effects (room TEXT NOT NULL, source TEXT NOT NULL, kind TEXT NOT NULL, effect TEXT NOT NULL, PRIMARY KEY(room,source,kind))")
        db.execSQL("CREATE TABLE IF NOT EXISTS group_announcements (room TEXT PRIMARY KEY, effect TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS group_pins (room TEXT NOT NULL, message TEXT NOT NULL, effect TEXT NOT NULL, PRIMARY KEY(room,message))")
        db.execSQL("CREATE TABLE IF NOT EXISTS rooms (id TEXT PRIMARY KEY, title TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS outbox (id TEXT PRIMARY KEY, command BLOB NOT NULL, receipt BLOB)")
        db.execSQL("CREATE TABLE IF NOT EXISTS direct_operations (id TEXT PRIMARY KEY, work TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS social_operations (id TEXT PRIMARY KEY, work TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS social_proposals (id TEXT PRIMARY KEY, proposal TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS preference_operations (id TEXT PRIMARY KEY, work TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS preference_authority (kind TEXT PRIMARY KEY, snapshot TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS preference_projections (kind TEXT PRIMARY KEY, snapshot TEXT NOT NULL, time INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS message_moderation_operations (id TEXT PRIMARY KEY, work TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS administration_operations (id TEXT PRIMARY KEY, work TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS moderation_facts (source TEXT PRIMARY KEY, room TEXT NOT NULL, effect TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS invitation_operations (id TEXT PRIMARY KEY, work TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS capability_operations (id TEXT PRIMARY KEY, work TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS membership_operations (id TEXT PRIMARY KEY, work TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS group_creations (id TEXT PRIMARY KEY, work TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS user_blocks (id TEXT PRIMARY KEY, blocked INTEGER NOT NULL, time INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS memberships (room TEXT PRIMARY KEY, revision INTEGER NOT NULL, source TEXT NOT NULL, member INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS room_kinds (room TEXT PRIMARY KEY, kind TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS room_cursors (room TEXT PRIMARY KEY, sequence INTEGER NOT NULL, incomplete INTEGER NOT NULL, owner INTEGER NOT NULL, membership INTEGER NOT NULL, unread INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS contacts (id TEXT PRIMARY KEY, state TEXT NOT NULL, requester TEXT, time INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS personal_operations (id TEXT PRIMARY KEY, work TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS personal_confirmed (key TEXT PRIMARY KEY, state TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS personal_projections (key TEXT PRIMARY KEY, state TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS conversation_state (room TEXT PRIMARY KEY, pinned INTEGER NOT NULL, archived INTEGER NOT NULL, mute INTEGER NOT NULL, revision INTEGER NOT NULL)")
        }
        accountRoomHeads = initialize {SqliteAccountRoomHeads(db)}
        roomDirectory = initialize {SqliteRoomDirectory(db)}
        outboxEchoes = initialize {SqliteOutboxEchoes(db,account,::revoked)}
        sendRecovery = initialize {SqliteSendRecovery(db,account,::revoked)}
        latestVisible = initialize {SqliteLatestVisible(db)}
        policyRecovery = SqlitePolicyRecovery(db,account,device,::snapshotRecoveryPendingNow)
        readReceipts = SqliteReadReceipts(db,account)
        profilePresentations = SqliteProfilePresentations(db, ::signalLocalDisplay)
        localProfileDisplays = SqliteLocalProfileDisplays(db, account)
        relationshipPages = initialize {SqliteRelationshipPages(db,account,localProfileDisplays)}
        directIdentities = SqliteDirectRoomIdentities(db, account)
        localDirectMessages = SqliteLocalDirectMessages(db, account)
        groupAvatars = SqliteGroupAvatars(db)
        names = SqliteNameOperations(db,account,profilePresentations)
        ownProfile = SqliteOwnProfile(db,account,profilePresentations,::registerProfileExecution)
        resources = initialize { SqliteResourceFiles(db,account) }
        backgroundUploads=initialize {SqliteBackgroundUploads(db,resources)}
        imports = SqliteResourceImports(db,account)
        sendIntents = initialize { SqliteSendIntents(db,account,resources,imports,::revoked,outboxEchoes::enqueue) }
        conversationDrafts = initialize { SqliteConversationDrafts(db,resources,sendIntents,{catalog.currentAttachment(it)},::revoked,{sendingPolicyNow(it).restriction}) }
        profileIntents = initialize { SqliteProfileIntents(db,account,ownProfile,resources,imports,::retryProfileExecution) }
        groupAvatarIntents = initialize { SqliteGroupAvatarIntents(db,account,device,resources,groupAvatars,imports) }
        catalog = initialize { SqliteResourceCatalog(db) }
        retention=SqliteResourceRetention(db,catalog,resources)
        storagePolicy=SqliteResourceStoragePolicy(db)
        downloads=SqliteResourceDownloads(db,catalog,resources)
        backgroundDownloadSources=initialize {SqliteBackgroundDownloadSources(db,downloads,resources)}
        if (!isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS projection_migrations (name TEXT PRIMARY KEY)")
        if(db.rawQuery("SELECT 1 FROM projection_migrations WHERE name='resource_catalog_v1'",null).use { !it.moveToFirst() }) transaction {
            catalog.enqueueExisting();db.execSQL("INSERT INTO projection_migrations VALUES ('resource_catalog_v1')")
        }
        if(db.rawQuery("SELECT 1 FROM projection_migrations WHERE name='group_avatar_fences_v1'",null).use { !it.moveToFirst() }) transaction {
            val migrated=mutableListOf<String>()
            db.rawQuery("SELECT event,payload,room FROM records WHERE kind='group_capability'",null).use { rows -> while(rows.moveToNext()) {
                val value=Json.parseToJsonElement(rows.getBlob(1).toString(Charsets.UTF_8)).jsonObject
                if(value["event_type"]?.jsonPrimitive?.content!="group.avatar_changed") continue
                val effect=GroupAvatarEffect.decode(rows.getString(0),value,rows.getString(2)?.let { RoomId(it) })
                if(!revoked(effect.room.value)) groupAvatars.project(effect)
                migrated.add(rows.getString(0))
            } }
            migrated.forEach { db.execSQL("DELETE FROM records WHERE event=? AND kind='group_capability'",arrayOf(it)) }
            db.execSQL("INSERT INTO projection_migrations VALUES ('group_avatar_fences_v1')")
        }
        if(db.rawQuery("SELECT 1 FROM projection_migrations WHERE name='profile_fences_v1'",null).use { !it.moveToFirst() }) transaction {
            db.rawQuery("SELECT event,kind,payload FROM records WHERE kind IN ('profile_invalidation','contact_alias','group_capability')",null).use { rows -> while(rows.moveToNext()) {
                val value = Json.parseToJsonElement(rows.getBlob(2).toString(Charsets.UTF_8)).jsonObject
                if(rows.getString(1) != "group_capability" || value["event_type"]?.jsonPrimitive?.content == "group.nickname_changed")
                    profilePresentations.project(rows.getString(0),rows.getString(1),value,null)
            } }
            db.execSQL("INSERT INTO projection_migrations VALUES ('profile_fences_v1')")
        }
        if(db.rawQuery("SELECT 1 FROM projection_migrations WHERE name='direct_lookup_v1'",null).use { !it.moveToFirst() }) transaction {
            db.rawQuery("SELECT payload FROM records WHERE kind='direct_room_profile'",null).use { rows -> while(rows.moveToNext()) {
                profilePresentations.direct(Json.parseToJsonElement(rows.getBlob(0).toString(Charsets.UTF_8)).jsonObject,account)
            } }
            db.execSQL("UPDATE rooms SET title='会话' WHERE id IN (SELECT room FROM direct_profile_bindings) OR id IN (SELECT room FROM room_kinds WHERE kind='Direct')")
            db.execSQL("DELETE FROM records WHERE kind='direct_room_profile'")
            db.execSQL("INSERT INTO projection_migrations VALUES ('direct_lookup_v1')")
        }
        if(db.rawQuery("SELECT 1 FROM projection_migrations WHERE name='discovery_floors_v1'",null).use { !it.moveToFirst() }) transaction {
            profilePresentations.preserveDirectVersions()
            db.execSQL("INSERT INTO projection_migrations VALUES ('discovery_floors_v1')")
        }
        if(db.rawQuery("SELECT 1 FROM projection_migrations WHERE name='read_receipts_v1'",null).use { !it.moveToFirst() }) transaction {
            db.rawQuery("SELECT kind,payload FROM records WHERE kind IN ('own_read_watermark','direct_read_receipt')",null).use { rows -> while(rows.moveToNext()) {
                readReceipts.project(rows.getString(0),Json.parseToJsonElement(rows.getBlob(1).toString(Charsets.UTF_8)).jsonObject)
            } }
            db.execSQL("INSERT INTO projection_migrations VALUES ('read_receipts_v1')")
        }
        if(db.rawQuery("SELECT 1 FROM projection_migrations WHERE name='group_access_v1'",null).use { !it.moveToFirst() }) transaction {
            db.rawQuery("SELECT event,kind,payload FROM records WHERE kind IN ('membership','group_capability')",null).use { rows -> while(rows.moveToNext()) {
                val value = Json.parseToJsonElement(rows.getBlob(2).toString(Charsets.UTF_8)).jsonObject
                val type = value["event_type"]?.jsonPrimitive?.content
                if(type !in setOf("membership_changed","group.ownership_transferred","group.member_role_changed","group.role_permissions_changed")) continue
                val room = RoomId(value.required("room_id"));if(revoked(room.value)) continue
                val source = rows.getString(0).substringBefore('/')
                val sequence = value["room_sequence"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull
                if(rows.getString(1) == "group_capability" && sequence == null) {
                    // Older stores discarded the outer sequence. Re-read the room log instead of inventing event identity.
                    db.execSQL("UPDATE room_cursors SET sequence=0 WHERE room=?",arrayOf(room.value));continue
                }
                if(type == "group.role_permissions_changed") projectRolePolicy(RolePolicyEffect.decode(source,value,room,requireNotNull(sequence)))
                else MemberAccessEffect.decode(source,rows.getString(1),value,room,sequence).forEach(::projectMemberAccess)
            } }
            db.execSQL("INSERT INTO projection_migrations VALUES ('group_access_v1')")
        }
        }
        favorites = initialize {
            SqliteFavoriteMessages(db,account).also {favorites->
                if(!isReadOnly && db.rawQuery("SELECT 1 FROM projection_migrations WHERE name='favorite_sources_v1'",null).use {!it.moveToFirst()}) {
                    listOf("personal_confirmed","personal_projections").forEach {table->personalStatesNow(table).forEach {favorites.project(table,it)}}
                    db.execSQL("INSERT INTO projection_migrations VALUES ('favorite_sources_v1')")
                }
            }
        }
        timelineActivities = SqliteTimelineActivities(db,::revoked)
        directSendingCapabilities = SqliteDirectSendingCapabilities(db,::revoked)
        timeline = SqliteConversationTimeline(db, account, ::revoked, ::decodeTimelineMessage) {room->outboxEchoes.tail(room,account)}
        search = SqliteMessageSearch(db, account, ::decodeTimelineMessage) {cursorNow().generation}
        operationAdmission = initialize { SqliteOperationAdmission(db, account, operationLimits) }
        operationWorkJournal = initialize { SqliteOperationWork(db, account) }
        nameClaims = initialize { SqliteNameOperationClaims(db, account, names, operationWorkJournal) }
        profileClaims = initialize { SqliteOwnProfileClaims(db, account, ownProfile, operationWorkJournal) }
        } catch (error: Throwable) { try { db.close() } finally { databaseAccess.close() }; throw error }
    }
    private suspend fun <T> access(body: () -> T): T = mutex.withLock { withContext(Dispatchers.IO) {
        synchronized(databaseLifecycle) { check(!databaseClosed) { "Local store closed" }; body() }
    } }
    private fun <T> initialize(body: () -> T): T = if (isReadOnly) body() else transaction(body)
    private fun <T> transaction(body: () -> T): T {
        if (isReadOnly) return SqliteLocalReadConnection.snapshot(db, body)
        val outer=!db.inTransaction()
        val tracker=projectionDiagnostics?.takeIf {outer && !it.diagnostics.snapshot().closed}
        db.beginTransaction()
        var observed=false;var succeeded=false;var started=0L
        var scopes=kotlinx.collections.immutable.persistentSetOf<ProjectionScope>()
        try {
            if(tracker!=null) observed=try {tracker.begin();true} catch(_:Exception) {false}
            val value=body()
            if(outer) operationAdmission?.reconcile()
            if(observed) scopes=try {requireNotNull(tracker).changed()} catch(_:Exception) {kotlinx.collections.immutable.persistentSetOf()}
            started=System.nanoTime();db.setTransactionSuccessful();succeeded=true
            return value
        } finally {
            db.endTransaction()
            if(succeeded && observed) tracker?.committed(scopes,started,System.nanoTime())
        }
    }
    private fun cursorNow(): SyncCursor = db.rawQuery("SELECT generation,sequence,token,receipt,receipt_sequence FROM cursor WHERE id=1", null).use {
        check(it.moveToFirst()); SyncCursor(it.getLong(0), it.getLong(1), it.getString(2), if (it.isNull(3)) null else it.getString(3),if(it.isNull(4)) null else it.getLong(4))
    }
    private fun writeCursor(cursor: SyncCursor) {
        if(cursorNow().generation != cursor.generation) roomDirectory.reset()
        db.execSQL("UPDATE cursor SET generation=?,sequence=?,token=?,receipt=?,receipt_sequence=? WHERE id=1", arrayOf<Any?>(cursor.generation, cursor.sequence, cursor.token, cursor.pendingReceipt,cursor.pendingSequence))
    }
    override suspend fun enqueueRead(room: RoomId,sequence: Long) = access { transaction { readReceipts.enqueue(room,sequence) } }
    override suspend fun prepareReads(limit: Int) = access { transaction { readReceipts.prepare(limit) } }
    override suspend fun readWorks() = access { readReceipts.works() }
    override suspend fun readWork(operation:String): ReadWork? = access {
        db.rawQuery("SELECT work FROM read_operations WHERE id=?",arrayOf(operation)).use { rows->
            if(rows.moveToFirst()) Json.decodeFromString<ReadWork>(rows.getString(0)).also {require(it.command.actor==account && it.command.operation==operation)} else null
        }
    }
    override suspend fun updateRead(expected: ReadWork,updated: ReadWork) = access { transaction { readReceipts.update(expected,updated) } }
    override suspend fun archiveRead(operation: String,now: Long) = access { transaction { readReceipts.archive(operation,now) } }
    override suspend fun restoreRead(operation: String,now: Long) = access { transaction { readReceipts.restore(operation,now) } }
    override suspend fun admitReadResubmission(expected: ReadWork,updated: ReadWork) = access { transaction {
        val allowed = requireNotNull(operationAdmission).canAdmitOrdinary(updated.command.payload().toString().toByteArray(Charsets.UTF_8).size.toLong())
        readReceipts.admit(expected,updated,allowed)
    } }
    override suspend fun allowsReadPublication(room: RoomId) = access {
        val policy = PreferencePublicationPolicy.derive(preferenceSnapshotsNow(),preferenceWorksNow())
        val kind = db.rawQuery("SELECT k.kind FROM room_kinds k JOIN memberships m ON m.room=k.room AND m.member=1 WHERE k.room=?",arrayOf(room.value)).use { if(it.moveToFirst()) it.getString(0) else null }
        when(kind) { "Direct" -> policy.directRead; "Group" -> policy.groupRead; else -> false }
    }
    override suspend fun roomReadWatermarks(rooms: PersistentList<RoomId>) = access { transaction { readReceipts.watermarks(rooms) } }
    suspend fun latestReadSequence(room: RoomId) = access { readReceipts.latest(room) }
    override suspend fun cursor() = access { cursorNow() }
    override suspend fun commit(batch: SyncBatch, expected: SyncCursor) = resourceWrite {
        check(cursorNow() == expected)
        check(pendingSnapshotNow()==null && pendingResetNow()==null && !rebuildRequiredNow())
        if(batch.generation<=0 || expected.generation!=0L && batch.generation!=expected.generation) throw ClientFailure.Protocol()
        var applied=expected.sequence
        var previous:Long?=null
        batch.recordsList.forEach { record ->
            if(record.userSyncSequence<=0 || previous?.let {it==Long.MAX_VALUE || record.userSyncSequence!=it+1}==true) throw ClientFailure.Protocol()
            previous=record.userSyncSequence
            if (record.projectionKind in setOf("message", "message_reaction", "moderation", "group_capability")) throw ClientFailure.Protocol()
            val digest=MessageDigest.getInstance("SHA-256").digest(record.payload.toByteArray()).joinToString("") {"%02x".format(it)}
            if(record.userSyncSequence<=applied) {
                db.rawQuery("SELECT event,kind,digest FROM sync_history WHERE sequence=?",arrayOf(record.userSyncSequence.toString())).use {row->
                    if(!row.moveToFirst()) throw SyncReplayUnavailable()
                    if(row.getString(0)!=record.sourceEventId || row.getString(1)!=record.projectionKind || row.getString(2)!=digest) throw ClientFailure.Protocol()
                }
            } else {
                if(applied==Long.MAX_VALUE || record.userSyncSequence!=applied+1) throw ClientFailure.Protocol()
                project(record.sourceEventId, record.projectionKind, record.payload.toByteArray())
                db.execSQL("INSERT INTO sync_history VALUES (?,?,?,?)",arrayOf(record.userSyncSequence,record.sourceEventId,record.projectionKind,digest))
                applied=record.userSyncSequence
            }
        }
        writeCursor(SyncCursor(batch.generation,applied,batch.nextSyncToken,batch.syncReceipt.takeIf { batch.recordsCount > 0 },batch.recordsList.lastOrNull()?.userSyncSequence))
    }
    override suspend fun acknowledged(expected: SyncCursor) = access { transaction {
        check(cursorNow() == expected); writeCursor(expected.copy(pendingReceipt = null,pendingSequence=null))
    } }
    override suspend fun discardSyncCapabilities(expected: SyncCursor) = access { transaction {
        check(cursorNow()==expected && pendingSnapshotNow()==null && pendingResetNow()==null)
        writeCursor(expected.copy(token="",pendingReceipt=null,pendingSequence=null))
    } }
    private fun rebuildRequiredNow()=db.rawQuery("SELECT 1 FROM sync_rebuild",null).use {it.moveToFirst()}
    override suspend fun requiresSnapshotRebuild()=access {rebuildRequiredNow()}
    override suspend fun requestSnapshotRebuild()=access {db.execSQL("INSERT OR IGNORE INTO sync_rebuild VALUES (1)")}
    override suspend fun cancelSnapshot(expected: SnapshotManifest)=access {transaction {
        check(pendingSnapshotNow()==expected)
        clearSnapshotImport();db.execSQL("DELETE FROM snapshot")
        writeCursor(cursorNow().copy(token="",pendingReceipt=null,pendingSequence=null))
    } }
    private fun snapshotRecoveryPendingNow() = pendingSnapshotNow()!=null || pendingResetNow()!=null
    private fun pendingResetNow(): SyncReset? {
        // Read-only openings of an older database do not create the new optional journal.
        if (isReadOnly && !db.rawQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name='sync_reset'",null).use { it.moveToFirst() }) return null
        return db.rawQuery("SELECT snapshot_id,generation,base_sequence,expires_at FROM sync_reset WHERE id=1",null).use {
            if (it.moveToFirst()) SyncReset(it.getString(0),it.getLong(1),it.getLong(2),it.getLong(3)) else null
        }
    }
    override suspend fun pendingReset() = access { pendingResetNow() }
    override suspend fun stageReset(expected: SyncCursor, reset: SyncReset) = access { transaction {
        check(cursorNow()==expected && pendingSnapshotNow()==null)
        val old = pendingResetNow(); check(old==null || old==reset)
        if (old==null) db.execSQL("INSERT INTO sync_reset VALUES (1,?,?,?,?)",arrayOf<Any>(reset.snapshotId,reset.generation,reset.baseSequence,reset.expiresAtMillis))
    } }
    override suspend fun cancelReset(expected: SyncReset) = access { transaction {
        check(pendingResetNow()==expected && pendingSnapshotNow()==null)
        db.execSQL("DELETE FROM sync_reset")
        writeCursor(cursorNow().copy(token="",pendingReceipt=null,pendingSequence=null))
    } }
    override suspend fun pendingSnapshot(): SnapshotManifest? = access {pendingSnapshotNow()}
    private fun pendingSnapshotNow(): SnapshotManifest? =
        db.rawQuery("SELECT manifest FROM snapshot WHERE id=1", null).use { if (it.moveToFirst()) SnapshotManifest.parseFrom(it.getBlob(0)) else null }
    override suspend fun stage(manifest: SnapshotManifest) = access { transaction {
        val old=pendingSnapshotNow();check(old==null || old==manifest)
        pendingResetNow()?.let { reset ->
            check(reset.snapshotId==manifest.snapshotId && reset.generation==manifest.generation && reset.baseSequence==manifest.baseUserSyncSequence)
        }
        if(old==null) {
            clearSnapshotImport()
            db.execSQL("INSERT INTO snapshot VALUES (1,?)", arrayOf(manifest.toByteArray()))
        }
        db.execSQL("DELETE FROM sync_reset")
    } }
    override suspend fun page(index: Int): SnapshotPage? = access {
        db.rawQuery("SELECT payload FROM pages WHERE page=?", arrayOf(index.toString())).use { if (it.moveToFirst()) SnapshotPage.parseFrom(it.getBlob(0)) else null }
    }
    override suspend fun stage(page: SnapshotPage) = access {
        val manifest=requireNotNull(pendingSnapshotNow())
        check(page.snapshotId==manifest.snapshotId && page.generation==manifest.generation && page.rootDigest==manifest.rootDigest && page.pageIndex in 0 until manifest.pageCount)
        check(page.pageIndex>=snapshotImportProgressNow(manifest).nextPage)
        db.execSQL("INSERT OR REPLACE INTO pages VALUES (?,?)", arrayOf(page.pageIndex, page.toByteArray()))
    }
    private fun clearSnapshotImport() {
        db.execSQL("DELETE FROM pages");db.execSQL("DELETE FROM snapshot_import");db.execSQL("DELETE FROM snapshot_items")
    }
    private fun snapshotImportProgressNow(manifest:SnapshotManifest):SnapshotImportProgress {
        check(pendingSnapshotNow()==manifest)
        return db.rawQuery("SELECT next_page,item_count,byte_count,digest,last_kind,last_key FROM snapshot_import WHERE id=1",null).use {
            if(it.moveToFirst()) SnapshotImportProgress(it.getInt(0),it.getLong(1),it.getLong(2),it.getString(3),if(it.isNull(4)) null else it.getString(4),if(it.isNull(5)) null else it.getString(5))
            else SnapshotImportProgress.initial(manifest)
        }
    }
    override suspend fun snapshotImportProgress(manifest:SnapshotManifest)=access {snapshotImportProgressNow(manifest)}
    override suspend fun importSnapshotPage(manifest:SnapshotManifest,page:SnapshotPage)=access {transaction {
        val imported=SnapshotImportValidation.advance(manifest,snapshotImportProgressNow(manifest),page)
        for(item in imported.items) db.execSQL("INSERT INTO snapshot_items VALUES (?,?,?,?,?)",arrayOf(item.kind,item.key,item.sourceEvent,item.sequence,item.payload.toByteArray()))
        // Decoded rows are now authoritative; discard the legacy/raw copy of this page.
        db.execSQL("DELETE FROM pages WHERE page=?",arrayOf(page.pageIndex))
        val p=imported.progress
        db.execSQL("INSERT OR REPLACE INTO snapshot_import VALUES (1,?,?,?,?,?,?)",arrayOf(p.nextPage,p.itemCount,p.byteCount,p.digest,p.lastKind,p.lastKey))
        p
    }}
    private fun validateSnapshotImportNow(manifest:SnapshotManifest) {
        SnapshotImportValidation.validateComplete(manifest,snapshotImportProgressNow(manifest))
        db.rawQuery("SELECT COUNT(*) FROM snapshot_items",null).use {it.moveToFirst();check(it.getLong(0)==manifest.totalItems)}
    }
    /** Membership fences are installed first, while only the current SQLite row is decoded. */
    private fun projectSnapshotImportNow() {
        retainMetadataForSnapshot();clearProjections()
        for(filter in listOf("kind IN ('room','membership')","kind NOT IN ('room','membership')")) {
            db.rawQuery("SELECT kind,entity_key,source,payload FROM snapshot_items WHERE $filter ORDER BY kind,entity_key",null).use {rows->
                while(rows.moveToNext()) {
                    val kind=rows.getString(0);val key=rows.getString(1);val source=rows.getString(2)
                    project("$source/$kind/$key",kind,rows.getBlob(3),snapshot=true,origin=source)
                }
            }
        }
        finishMetadataSnapshot()
    }
    override suspend fun prepareSnapshotActivation(manifest:SnapshotManifest)=access {
        db.beginTransaction()
        try {validateSnapshotImportNow(manifest);projectSnapshotImportNow()}
        finally {db.endTransaction()} // Preflight every projection, then roll back before network ACK.
    }
    override suspend fun activateAcknowledgedSnapshot(manifest:SnapshotManifest)=resourceWrite {
        validateSnapshotImportNow(manifest);projectSnapshotImportNow()
        db.execSQL("DELETE FROM sync_history");db.execSQL("DELETE FROM sync_rebuild")
        writeCursor(SyncCursor(manifest.generation,manifest.baseUserSyncSequence,manifest.nextSyncToken))
        db.execSQL("DELETE FROM snapshot");clearSnapshotImport()
    }
    override suspend fun validateSnapshot(items: PersistentList<SnapshotItem>) = access {
        db.beginTransaction()
        try {
            retainMetadataForSnapshot()
            clearProjections()
            // Install membership fences before content, independently of snapshot lexical ordering.
            items.sortedBy { if (it.kind == "room" || it.kind == "membership") 0 else 1 }.forEach {
                project(it.sourceEvent + "/" + it.kind + "/" + it.key, it.kind, it.payload.toByteArray(), snapshot = true, origin = it.sourceEvent)
            }
            finishMetadataSnapshot()
        } finally { db.endTransaction() } // Always rollback: prior live projection remains readable until server ACK.
    }
    override suspend fun activate(manifest: SnapshotManifest, items: PersistentList<SnapshotItem>) = resourceWrite {
        check(pendingSnapshotNow()==manifest)
        retainMetadataForSnapshot()
        clearProjections()
        // Install membership fences before content, independently of snapshot lexical ordering.
            items.sortedBy { if (it.kind == "room" || it.kind == "membership") 0 else 1 }.forEach {
                project(it.sourceEvent + "/" + it.kind + "/" + it.key, it.kind, it.payload.toByteArray(), snapshot = true, origin = it.sourceEvent)
            }
        finishMetadataSnapshot()
        db.execSQL("DELETE FROM sync_history");db.execSQL("DELETE FROM sync_rebuild")
        writeCursor(SyncCursor(manifest.generation, manifest.baseUserSyncSequence, manifest.nextSyncToken))
        db.execSQL("DELETE FROM snapshot"); clearSnapshotImport()
    }
    override suspend fun ensureLatestVisible(scope: String,rooms: PersistentList<RoomId>) = resourceWrite {
        require(rooms.size<=100)
        val generation=cursorNow().generation
        roomDirectory.scan(scope,generation)
        for(room in rooms.distinct()) {
            if(!revoked(room.value) && latestVisible.read(room,generation)==null) roomDirectory.ensureSummary(room.value)
        }
    }
    override suspend fun beginLatestVisible(scope: String) = access {transaction {
        val generation=cursorNow().generation
        roomDirectory.scan(scope,generation)
        if(generation<=0 || snapshotRecoveryPendingNow()) throw ClientFailure.ResetRequired()
        LatestVisibleRequest(scope,generation)
    }}
    override suspend fun commitLatestVisible(request: LatestVisibleRequest,work: RoomDirectoryWork,snapshot: LatestVisibleSnapshot) =
        work.room in commitLatestVisibleBatch(request,kotlinx.collections.immutable.persistentListOf(LatestVisibleCommit(work,snapshot)))
    override suspend fun commitLatestVisibleBatch(request: LatestVisibleRequest,entries: PersistentList<LatestVisibleCommit>) = resourceWrite {
        require(entries.size in 1..100 && entries.map {it.work.room}.toSet().size==entries.size)
        val generation=cursorNow().generation
        roomDirectory.scan(request.scope,generation)
        if(request.generation!=generation || snapshotRecoveryPendingNow()) return@resourceWrite emptySet<RoomId>().toPersistentSet()
        buildSet {for(entry in entries) if(latestVisible.commit(entry.snapshot,generation,entry.work)) add(entry.work.room)}.toPersistentSet()
    }
    override suspend fun beginDirectory() = resourceWrite {roomDirectory.begin()}
    override suspend fun directoryScan(scope: String) = access {roomDirectory.scan(scope,cursorNow().generation)}
    override suspend fun restartDirectory(scope: String) = resourceWrite {roomDirectory.restart(scope,cursorNow().generation)}
    override suspend fun commitDirectoryPage(request: RoomDirectoryScan,page: RoomDirectoryPage) = resourceWrite {roomDirectory.commit(request,page,cursorNow().generation)}
    override suspend fun directoryWork(scope: String,now: Long,limit: Int,oldestFirst: Boolean) = access {roomDirectory.work(scope,cursorNow().generation,now,limit,oldestFirst)}
    override suspend fun finishDirectoryWork(scope: String,work: RoomDirectoryWork,retryAt: Long?) = resourceWrite {roomDirectory.finish(scope,cursorNow().generation,work,retryAt)}
    override suspend fun directoryProgress(scope: String) = access {roomDirectory.progress(scope,cursorNow().generation)}
    override suspend fun recoveryCandidate(scope: String) = access {transaction {roomDirectory.candidate(scope,cursorNow(),accountRoomHeads.pending(null,1).isNotEmpty() || snapshotRecoveryPendingNow() )}}
    override suspend fun verifyRecoveryCandidate(candidate: RoomRecoveryCandidate,personal: SyncCursor) = access {transaction {roomDirectory.verify(candidate,cursorNow(),personal,accountRoomHeads.pending(null,1).isNotEmpty() || snapshotRecoveryPendingNow() )}}
    override suspend fun pendingRoomHeads(after: RoomId?,limit: Int) = access {accountRoomHeads.pending(after,limit)}
    override suspend fun reconcileDirectory(rooms: PersistentMap<RoomId, RoomKind>) = resourceWrite {
        val cached = db.rawQuery("SELECT room FROM room_cursors UNION SELECT id FROM rooms UNION SELECT room FROM group_announcements UNION SELECT room FROM group_pins UNION SELECT room FROM group_avatar_effects UNION SELECT room FROM group_avatar_epochs UNION SELECT room FROM resource_catalog_rooms WHERE denied=0 UNION SELECT room FROM account_room_heads WHERE blocked=0", null).use { rows -> buildList { while(rows.moveToNext()) add(rows.getString(0)) } }
        cached.filter { RoomId(it) !in rooms }.forEach { purgeRoom(it); db.execSQL("DELETE FROM room_cursors WHERE room=?", arrayOf(it));denyMembership(it) }
        db.execSQL("DELETE FROM room_kinds")
        rooms.forEach { (id, kind) -> db.execSQL("INSERT INTO room_kinds VALUES (?,?)", arrayOf(id.value, kind.name)) }
    }
    override suspend fun acceptState(room: RoomId, state: RoomSyncState) = resourceWrite {acceptStateNow(room,state)}
    override suspend fun acceptStates(states: PersistentMap<RoomId,RoomSyncState>) = resourceWrite {
        require(states.size in 1..100)
        states.forEach { (room,state) -> RoomSyncEngine.validateState(room,state) }
        states.forEach { (room,state) -> acceptStateNow(room,state) }
    }
    private fun acceptStateNow(room: RoomId, state: RoomSyncState) {
        val prior = db.rawQuery("SELECT owner,membership FROM room_cursors WHERE room=?", arrayOf(room.value)).use {
            if (it.moveToFirst()) it.getLong(0) to it.getLong(1) else null
        }
        val member = db.rawQuery("SELECT revision,member FROM memberships WHERE room=?", arrayOf(room.value)).use {
            if (it.moveToFirst()) it.getLong(0) to (it.getInt(1) == 1) else null
        }
        if (member != null && (member.first > state.viewerMembershipRevision || (member.first == state.viewerMembershipRevision && !member.second))) throw ClientFailure.Protocol()
        if (prior != null && (prior.first > state.ownerEpoch || prior.second > state.viewerMembershipRevision)) throw ClientFailure.Protocol()
        if(prior == null || prior.second != state.viewerMembershipRevision) profilePresentations.invalidate()
        if (prior != null && prior.second != state.viewerMembershipRevision) {
            purgeRoom(room.value); db.execSQL("DELETE FROM room_cursors WHERE room=?", arrayOf(room.value))
        }
        if(prior == null || prior.second != state.viewerMembershipRevision) groupAvatars.invalidate(room.value)
        val current = roomCursorNow(room)
        if (current.sequence > state.head) throw ClientFailure.Protocol()
        db.execSQL("INSERT OR REPLACE INTO room_cursors VALUES (?,?,?,?,?,?)", arrayOf<Any>(room.value, current.sequence,
            if(current.historyIncomplete) 1 else 0, state.ownerEpoch, state.viewerMembershipRevision, state.unreadCount))
        if (member == null || member.first < state.viewerMembershipRevision) db.execSQL("INSERT OR REPLACE INTO memberships VALUES (?,?,?,1)", arrayOf<Any>(room.value, state.viewerMembershipRevision, "state"))
        db.execSQL("INSERT OR IGNORE INTO rooms VALUES (?,?)", arrayOf(room.value, "聊天 ${room.value.takeLast(6)}"))
        latestVisible.state(room,state)
        policyRecovery.authorizedState(room,state.viewerMembershipRevision)
        readReceipts.state(room,state.head,state.latestOwnMessageSequence,state.readThrough)
        catalog.authorizedRoom(room.value)
        accountRoomHeads.authorize(room.value)
    }
    /** Negative local access evidence only; false does not grant server subscription authority. */
    suspend fun isRoomLocallyRevoked(room: RoomId): Boolean = access { revoked(room.value) }
    override suspend fun unavailable(room: RoomId) = resourceWrite {unavailableNow(room)}
    private fun unavailableNow(room: RoomId) {
        purgeRoom(room.value); db.execSQL("DELETE FROM room_cursors WHERE room=?", arrayOf(room.value))
        denyMembership(room.value)
        roomDirectory.discard(room.value)
    }
    private fun denyMembership(room: String) {
        // -1 is a local absence-of-version marker, never a wire revision. A fresh direct-room state
        // may legitimately have revision 0. Existing observed floors must remain unchanged.
        db.execSQL("INSERT OR IGNORE INTO memberships(room,revision,source,member) VALUES (?,-1,'unavailable',0)",arrayOf(room))
        db.execSQL("UPDATE memberships SET member=0 WHERE room=?",arrayOf(room))
    }
    private fun roomCursorNow(room: RoomId): RoomCursor = db.rawQuery("SELECT sequence,incomplete FROM room_cursors WHERE room=?", arrayOf(room.value)).use {
        if (it.moveToFirst()) RoomCursor(it.getLong(0), it.getInt(1) == 1) else RoomCursor()
    }
    override suspend fun roomCursor(room: RoomId) = access { roomCursorNow(room) }
    private fun roomContentFence(room: RoomId): RoomContentFence {
        val member=db.rawQuery("SELECT revision,source,member FROM memberships WHERE room=?",arrayOf(room.value)).use {
            if(it.moveToFirst()) RoomMembershipFence(it.getLong(0),it.getString(1),it.getInt(2)==1) else null
        }
        return db.rawQuery("SELECT sequence,incomplete,owner,membership FROM room_cursors WHERE room=?",arrayOf(room.value)).use {
            if(!it.moveToFirst() || revoked(room.value)) throw ClientFailure.Protocol()
            val fence=RoomContentFence(RoomCursor(it.getLong(0),it.getInt(1)==1),it.getLong(2),it.getLong(3),member)
            if(fence.cursor.sequence<0 || fence.owner<0 || fence.membership<0 ||
                (member!=null && (member.revision>fence.membership || (member.revision==fence.membership && !member.active)))) throw ClientFailure.Protocol()
            fence
        }
    }
    private fun requireContentScope(scope: String,generation: Long) {
        val current=cursorNow().generation
        roomDirectory.scan(scope,current)
        if(generation<=0 || current!=generation || snapshotRecoveryPendingNow()) throw ClientFailure.ResetRequired()
    }
    override suspend fun beginRoomContent(scope: String,work: PersistentList<RoomDirectoryWork>) = access {transaction {
        require(work.size in 1..16 && work.map {it.room}.toSet().size==work.size)
        val generation=cursorNow().generation;requireContentScope(scope,generation)
        val fences=work.associate {item -> item.room to roomContentFence(item.room).also {
            if(it.owner<item.minimumOwner || it.membership<item.minimumMembership) throw ClientFailure.Protocol()
        }}.toPersistentMap()
        RoomContentRequest(scope,generation,fences)
    }}
    override suspend fun commitRoomContent(request: RoomContentRequest,response: RoomContentResponse) = resourceWrite {
        require(request.fences.size in 1..16 && response.pages.keys.intersect(response.unavailable).isEmpty() &&
            response.pages.keys+response.unavailable==request.fences.keys)
        requireContentScope(request.scope,request.generation)
        // Check every authority/cursor before applying any projection or denial.
        request.fences.forEach {(room,fence) -> if(roomContentFence(room)!=fence) throw ClientFailure.Protocol()}
        response.pages.forEach {(room,page) -> RoomSyncEngine.validateBatchPage(room,request.fences.getValue(room).cursor,page)}
        response.pages.forEach {(room,page) -> commitRoomNow(room,page,request.fences.getValue(room).cursor)}
        response.unavailable.forEach {unavailableNow(it)}
        response.pages.keys.associateWith {roomCursorNow(it)}.toPersistentMap()
    }
    override suspend fun commitRoom(page: GroupEventPage, expected: RoomCursor) = resourceWrite {
        val room = RoomId(page.roomId)
        check(roomCursorNow(room) == expected)
        RoomSyncEngine.validatePage(room, expected, page)
        commitRoomNow(room,page,expected)
    }
    override suspend fun commitLiveRoom(page: GroupEventPage, expected: RoomCursor): Boolean = resourceWrite {
        val room=RoomId(page.roomId)
        val authorized=db.rawQuery("SELECT 1 FROM room_cursors WHERE room=?",arrayOf(room.value)).use {it.moveToFirst()}
        if(!authorized || revoked(room.value) || roomCursorNow(room) != expected) return@resourceWrite false
        RoomSyncEngine.validateLivePage(room,expected,page)
        commitRoomNow(room,page,expected)
        true
    }
    private fun commitRoomNow(room: RoomId, page: GroupEventPage, expected: RoomCursor) {
        if (revoked(room.value)) throw ClientFailure.Protocol()
        page.eventsList.forEach { project(it.sourceEventId, it.projectionKind, it.payload.toByteArray(), roomSequence = it.roomSequence) }
        db.execSQL("UPDATE room_cursors SET sequence=?,incomplete=? WHERE room=?", arrayOf<Any>(page.nextRoomSequence,
            if(expected.historyIncomplete || expected.sequence < page.logTrimmedThroughRoomSequence) 1 else 0, room.value))
        // A caller must establish an authorized state before it can commit content.
        check(db.compileStatement("SELECT changes()").use { it.simpleQueryForLong() } == 1L)
    }
    private fun purgeRoom(room: String) {
        accountRoomHeads.deny(room)
        catalog.invalidateRoom(room)
        db.execSQL("DELETE FROM direct_read_projections WHERE room=?",arrayOf(room));db.execSQL("DELETE FROM read_room_state WHERE room=?",arrayOf(room))
        purgeMetadata(room)
        listOf("reaction_versions", "reaction_effects").forEach { db.execSQL("DELETE FROM $it WHERE room=?", arrayOf(room)) }
        db.execSQL("DELETE FROM message_tombstones WHERE room=?", arrayOf(room)); db.execSQL("DELETE FROM messages WHERE room=?", arrayOf(room)); db.execSQL("DELETE FROM rooms WHERE id=?", arrayOf(room))
        db.execSQL("DELETE FROM direct_sending_capabilities WHERE room=?",arrayOf(room));db.execSQL("DELETE FROM timeline_activities WHERE room=?",arrayOf(room));db.execSQL("DELETE FROM records WHERE room=?", arrayOf(room)); db.execSQL("DELETE FROM conversation_state WHERE room=?", arrayOf(room))
    }
    override suspend fun enqueue(command: MessageSendOperation) = access { transaction {
        check(!revoked(command.roomId)) { "此会话已不可访问，消息未保存" }
        outboxEchoes.enqueue(command)
    } }
    override suspend fun abandonUnsentText(room: RoomId,viewer: UserId,operation: String) = access {transaction {outboxEchoes.abandonText(room,viewer,operation)}}
    override suspend fun replaceUnsentText(room: RoomId,viewer: UserId,operation: String,now: Long) = access {transaction {outboxEchoes.replaceText(room,viewer,operation,now)}}
    override suspend fun claimSend(now: Long) = access {transaction {sendRecovery.claim(now)}}
    override suspend fun observeSend(attempt:SendAttempt,now:Long) = access {sendRecovery.observe(attempt,now)}
    override suspend fun deferSend(attempt: SendAttempt,state: SendRecovery) = access {transaction {sendRecovery.defer(attempt,state)}}
    override suspend fun resumeSend(room: RoomId,viewer: UserId,operation: String,now: Long) = access {transaction {sendRecovery.resume(room,viewer,operation,now)}}
    override suspend fun resumeNetworkWaitingSends(viewer: UserId,now: Long) = access {transaction {sendRecovery.connected(viewer,now)}}
    override suspend fun completeSend(attempt: SendAttempt,receipt: MessageSendOperationReceipt) = resourceWrite {
        if(sendRecovery.matches(attempt)) {
            validateSendReceipt(attempt.command,receipt)
            sendIntents.validateReceipt(attempt.command.clientMessageId,receipt)
            outboxEchoes.complete(attempt.command.clientMessageId,receipt);sendIntents.reconcile()
        }
    }
    suspend fun pending(): PersistentList<MessageSendOperation> = access {
        db.rawQuery("SELECT command FROM outbox WHERE receipt IS NULL ORDER BY rowid", null).use { rows ->
            buildList { while (rows.moveToNext()) { val command = MessageSendOperation.parseFrom(rows.getBlob(0)); if (!revoked(command.roomId)) add(command) } }.toPersistentList()
        }
    }
    suspend fun complete(operation: String, receipt: MessageSendOperationReceipt) = resourceWrite {
        sendIntents.validateReceipt(operation,receipt)
        outboxEchoes.complete(operation,receipt)
        sendIntents.reconcile()
    }
    private fun directWorksNow(): PersistentList<DirectRoomWork> = db.rawQuery("SELECT work FROM direct_operations ORDER BY rowid DESC", null).use { rows ->
        buildList { while (rows.moveToNext()) add(Json.decodeFromString<DirectRoomWork>(rows.getString(0))) }.toPersistentList()
    }
    override suspend fun directWorks() = access { directWorksNow() }
    override suspend fun directWork(operation:String): DirectRoomWork? = access {
        db.rawQuery("SELECT work FROM direct_operations WHERE id=?",arrayOf(operation)).use { rows->
            if(rows.moveToFirst()) Json.decodeFromString<DirectRoomWork>(rows.getString(0)).also {require(it.command.actor==account && it.command.operation==operation)} else null
        }
    }
    suspend fun localDirectRoomIdentities() = access { directIdentities.all() }
    override suspend fun prepareDirect(command: DirectRoomCommand): DirectRoomWork = prepareDirectOwned(command, null)
    override suspend fun prepareDirect(command: DirectRoomCommand, identity: PublicIdentity): DirectRoomWork = prepareDirectOwned(command, identity)
    private suspend fun prepareDirectOwned(command: DirectRoomCommand, identity: PublicIdentity?): DirectRoomWork = resourceWrite {
        require(command.actor == account && (identity == null || identity.user == command.target))
        directWorksNow().firstOrNull { !it.terminal && it.command.target == command.target } ?: DirectRoomWork.fresh(command, identity).also {
            db.execSQL("INSERT INTO direct_operations VALUES (?,?)", arrayOf(command.operation, Json.encodeToString(it)))
            localDirectMessages.reassign(command.target, command.operation)
        }
    }
    override suspend fun updateDirect(expected: DirectRoomWork, updated: DirectRoomWork) = resourceWrite {
        require(expected.executionStarted != true || updated.executionStarted == true) { "Command execution evidence cannot be erased" }
        require(expected.command.actor == account && expected.command == updated.command && expected.publicIdentity == updated.publicIdentity && !expected.terminal)
        check(directWorksNow().firstOrNull { it.command.operation == expected.command.operation } == expected)
        if (updated.terminal) {
            val receipt = DirectRoomClient.decodeReceipt(updated.command, Json.parseToJsonElement(updated.receipt ?: throw ClientFailure.Protocol()).jsonObject)
            require(receipt.room == updated.room && updated.status == when { receipt.room != null -> DirectWorkStatus.Opened; receipt.closed -> DirectWorkStatus.Closed; else -> DirectWorkStatus.Rejected })
            val openedRoom = receipt.room; val selectedIdentity = updated.publicIdentity
            if (openedRoom != null && selectedIdentity != null) {
                val created = Json.parseToJsonElement(receipt.wire).jsonObject.getValue("outcome").jsonObject
                    .getValue("opened").jsonObject.getValue("createdAtMilliseconds").jsonPrimitive.long
                directIdentities.save(DirectRoomIdentity(openedRoom, selectedIdentity, created, System.currentTimeMillis()))
            }
        } else require(updated.receipt == null && updated.room == null)
        db.execSQL("UPDATE direct_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(updated), updated.command.operation))
    }
    override suspend fun existingDirectRoom(actor: UserId, target: UserId) = access { transaction {
        require(actor == account && target != actor)
        val rooms = directIdentities.all().filter { it.publicIdentity.user == target }.map { it.room } +
            profilePresentations.peers().filterValues { it == target }.keys
        rooms.distinct().firstOrNull { room -> !revoked(room.value) && SqliteLocalProjection(db, account).allows(room) &&
            !db.rawQuery("SELECT 1 FROM room_kinds WHERE room=? AND kind='Group'", arrayOf(room.value)).use { it.moveToFirst() } }
    } }
    override suspend fun saveLocalDirectMessage(actor: UserId, message: LocalDirectMessage) = resourceWrite {
        require(actor == account); localDirectMessages.save(message)
    }
    override suspend fun localDirectMessages(actor: UserId, operation: String?) = access {
        require(actor == account); operation?.let { localDirectMessages.work(it) }; localDirectMessages.all(operation)
    }
    override suspend fun prepareNextLocalDirectMessage(actor: UserId, now: Long) = resourceWrite {
        require(actor == account); localDirectMessages.prepareNext(now, sendIntents)
    }
    suspend fun enterLocalDirectRoom(actor: UserId, operation: String, text: String): RoomId? = resourceWrite {
        require(actor == account)
        val work = localDirectMessages.work(operation)
        val room = localDirectMessages.openedRoom(work) ?: return@resourceWrite null
        if (localDirectMessages.all(operation).isNotEmpty()) return@resourceWrite null
        if (text.isNotBlank()) {
            val draft = conversationDrafts.restore(room)
            check(draft.empty || draft.text == text && draft.attachments.isEmpty() && draft.imports.isEmpty() && draft.rich == MessageRichContent.Empty) { "会话中已有其他草稿；请先保存或发送当前输入" }
            if (draft.empty) conversationDrafts.saveText(draft, text, System.currentTimeMillis())
        }
        room
    }
    private fun socialProposalsNow(): PersistentList<SocialProposal> = db.rawQuery("SELECT proposal FROM social_proposals ORDER BY rowid", null).use { rows ->
        buildList { while (rows.moveToNext()) add(Json.decodeFromString<SocialProposal>(rows.getString(0))) }.toPersistentList()
    }
    private fun socialWorksNow(): PersistentList<SocialWork> = db.rawQuery("SELECT work FROM social_operations ORDER BY rowid DESC", null).use { rows ->
        buildList { while (rows.moveToNext()) add(Json.decodeFromString<SocialWork>(rows.getString(0))) }.toPersistentList()
    }
    override suspend fun socialProposals() = access { socialProposalsNow() }
    override suspend fun socialWorks() = access { socialWorksNow() }
    override suspend fun socialWork(operation:String): SocialWork? = access {
        db.rawQuery("SELECT work FROM social_operations WHERE id=?",arrayOf(operation)).use { rows->
            if(rows.moveToFirst()) Json.decodeFromString<SocialWork>(rows.getString(0)).also {require(it.command.actor==account && it.command.operation==operation)} else null
        }
    }
    override suspend fun saveSocialProposal(proposal: SocialProposal): SocialProposal = access { transaction {
        require(proposal.actor == account)
        check(socialWorksNow().none { !it.terminal && it.command.target == proposal.target && it.command.action.kind == proposal.action.kind }) { "该用户还有待确认的操作，请先查看操作记录" }
        val prior = socialProposalsNow().firstOrNull { it.target == proposal.target && it.action.kind == proposal.action.kind }
        if (prior != null) {
            check(prior.action == proposal.action) { "请先确认或取消该用户已保存的操作" }; prior
        } else proposal.also { db.execSQL("INSERT INTO social_proposals VALUES (?,?)", arrayOf(it.id, Json.encodeToString(it))) }
    } }
    override suspend fun discardSocialProposal(id: String) = access { transaction { db.execSQL("DELETE FROM social_proposals WHERE id=?", arrayOf(id)) } }
    override suspend fun confirmSocial(proposal: SocialProposal, command: SocialCommand): SocialWork = access { transaction {
        require(proposal.actor == account && command.actor == account && proposal.target == command.target && proposal.action == command.action)
        check(socialProposalsNow().firstOrNull { it.id == proposal.id } == proposal) { "操作已确认或取消，请刷新" }
        check(socialWorksNow().none { !it.terminal && it.command.target == command.target && it.command.action.kind == command.action.kind })
        SocialWork.fresh(command).also {
            db.execSQL("INSERT INTO social_operations VALUES (?,?)", arrayOf(command.operation, Json.encodeToString(it)))
            db.execSQL("DELETE FROM social_proposals WHERE id=?", arrayOf(proposal.id))
        }
    } }
    override suspend fun updateSocial(expected: SocialWork, updated: SocialWork) = access { transaction {
        require(expected.executionStarted != true || updated.executionStarted == true) { "Command execution evidence cannot be erased" }
        require(expected.command.actor == account && expected.command == updated.command && !expected.terminal)
        check(socialWorksNow().firstOrNull { it.command.operation == expected.command.operation } == expected)
        if (updated.terminal) {
            val receipt = SocialClient.decodeReceipt(updated.command, Json.parseToJsonElement(updated.receipt ?: throw ClientFailure.Protocol()).jsonObject)
            require(updated.status == receipt.status && updated.rejection == receipt.rejection)
        } else require(updated.receipt == null && updated.rejection == null)
        // A receipt settles this command; only the personal stream updates the visible relationship/block state.
        db.execSQL("UPDATE social_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(updated), updated.command.operation))
    } }
    private fun groupWorksNow(): PersistentList<GroupCreationWork> = db.rawQuery("SELECT work FROM group_creations ORDER BY rowid DESC", null).use { rows ->
        buildList { while (rows.moveToNext()) add(Json.decodeFromString<GroupCreationWork>(rows.getString(0))) }.toPersistentList()
    }
    override suspend fun groupWorks() = access { groupWorksNow() }
    override suspend fun groupWork(id: String): GroupCreationWork? = access {
        db.rawQuery("SELECT work FROM group_creations WHERE id=?", arrayOf(id)).use { rows ->
            if(rows.moveToFirst()) Json.decodeFromString<GroupCreationWork>(rows.getString(0)).also { require(it.command.actor == account); require(it.command.operation == id) } else null
        }
    }
    override suspend fun prepareGroup(command: GroupCreationCommand): GroupCreationWork = access { transaction {
        require(command.actor == account)
        val works = groupWorksNow()
        val matching = works.firstOrNull { it.command.operation == command.operation }
        if (matching != null) { require(matching.command == command); matching }
        else {
            val active = works.firstOrNull { !it.terminal }
            if (active != null) {
                check(!active.cancellationRequested && active.command.title == command.title && active.command.members == command.members) { "请先核对上一次建群结果" }
                active
            } else GroupCreationWork.fresh(command).also {
                val encoded = Json.encodeToString(it)
                require(encoded.toByteArray().size <= 8_388_608)
                db.execSQL("INSERT INTO group_creations VALUES (?,?)", arrayOf(command.operation, encoded))
            }
        }
    } }
    override suspend fun updateGroup(expected: GroupCreationWork, updated: GroupCreationWork) = access { transaction {
        require(expected.command.actor == account && expected.command == updated.command && !expected.terminal)
        check(groupWorksNow().firstOrNull { it.command.operation == expected.command.operation } == expected)
        require(!expected.cancellationRequested || updated.cancellationRequested)
        require(expected.progress == null || updated.progress != null)
        updated.progress?.validate(updated.command, expected.progress)
        if (updated.terminal) {
            val receipt = GroupCreationClient.decodeReceipt(updated.command, Json.parseToJsonElement(updated.receipt ?: throw ClientFailure.Protocol()).jsonObject)
            require(receipt.room == updated.room && receipt.rejection == updated.rejection && updated.status == when {
                receipt.room != null -> GroupCreationStatus.Created; receipt.closed -> GroupCreationStatus.Closed; else -> GroupCreationStatus.Rejected
            })
            updated.progress?.let { if (receipt.room != null && receipt.room != it.room) throw ClientFailure.Protocol() }
        } else require(updated.receipt == null && updated.room == null && updated.rejection == null)
        // Creation evidence never grants room content or fabricates a membership projection.
        db.execSQL("UPDATE group_creations SET work=? WHERE id=?", arrayOf(Json.encodeToString(updated), updated.command.operation))
    } }
    private fun membershipWorksNow(): PersistentList<MembershipWork> = db.rawQuery("SELECT work FROM membership_operations ORDER BY rowid DESC", null).use { rows ->
        buildList { while (rows.moveToNext()) add(Json.decodeFromString<MembershipWork>(rows.getString(0))) }.toPersistentList()
    }
    override suspend fun membershipWorks() = access { membershipWorksNow() }
    override suspend fun membershipWork(operation:String): MembershipWork? = access {
        db.rawQuery("SELECT work FROM membership_operations WHERE id=?",arrayOf(operation)).use { rows->
            if(rows.moveToFirst()) Json.decodeFromString<MembershipWork>(rows.getString(0)).also {require(it.intent.actor==account && it.intent.operation==operation)} else null
        }
    }
    override suspend fun prepareMembership(intent: MembershipIntent, activation: String): MembershipWork = access { transaction {
        require(intent.actor == account)
        val works = membershipWorksNow()
        val existing = works.firstOrNull { it.intent.operation == intent.operation }
        if (existing != null) { require(existing.intent == intent && existing.activation == activation); existing }
        else {
            check(works.none { !it.terminal && it.intent.room == intent.room }) { "这个群还有待确认的成员操作，请先查看操作记录" }
            MembershipWork(intent, activation).also { db.execSQL("INSERT INTO membership_operations VALUES (?,?)", arrayOf(intent.operation, Json.encodeToString(it))) }
        }
    } }
    override suspend fun replaceMembershipDraft(expected: MembershipWork, intent: MembershipIntent, activation: String): MembershipWork = access { transaction {
        require(expected.intent.actor == account && intent.actor == account && expected.intent.room == intent.room && expected.intent.target == intent.target && expected.intent.action == intent.action)
        require(expected.status == MembershipStatus.DraftPaused && expected.admission == null && expected.intent.operation != intent.operation)
        check(membershipWorksNow().firstOrNull { it.intent.operation == expected.intent.operation } == expected)
        val cancelled = expected.copy(status = MembershipStatus.DraftCancelled)
        db.execSQL("UPDATE membership_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(cancelled), expected.intent.operation))
        MembershipWork(intent, activation, nextAttemptMilliseconds = expected.nextAttemptMilliseconds).also {
            db.execSQL("INSERT INTO membership_operations VALUES (?,?)", arrayOf(intent.operation, Json.encodeToString(it)))
        }
    } }
    override suspend fun updateMembership(expected: MembershipWork, updated: MembershipWork) = access { transaction {
        require(expected.executionStarted != true || updated.executionStarted == true) { "Command execution evidence cannot be erased" }
        require(expected.intent.actor == account && expected.intent == updated.intent && expected.activation == updated.activation && !expected.terminal)
        check(membershipWorksNow().firstOrNull { it.intent.operation == expected.intent.operation } == expected)
        require(updated.preparationAttempts in 0..5 && updated.attempts >= 0 && updated.nextAttemptMilliseconds >= 0)
        val draft = updated.status in setOf(MembershipStatus.DraftReady, MembershipStatus.DraftPaused, MembershipStatus.DraftCancelled)
        if (expected.admission != null) require(expected.admission == updated.admission && !draft)
        else require(expected.status == MembershipStatus.DraftReady || updated.status == MembershipStatus.DraftCancelled)
        require(draft == (updated.admission == null))
        updated.admission?.validate(updated.intent)
        if (updated.terminal && updated.status != MembershipStatus.DraftCancelled) {
            val receipt = MembershipClient.decodeReceipt(updated.command(), Json.parseToJsonElement(updated.receipt ?: throw ClientFailure.Protocol()).jsonObject)
            require(receipt.status == updated.status && receipt.rejection == updated.reason)
        } else require(updated.receipt == null)
        // Only personal/room sync can project membership changes or revoke cached content.
        db.execSQL("UPDATE membership_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(updated), updated.intent.operation))
    } }
    private fun moderationWorksNow(): PersistentList<ModerationWork> = db.rawQuery("SELECT work FROM message_moderation_operations ORDER BY rowid",null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<ModerationWork>(rows.getString(0)).also(::validateModeration)) }.toPersistentList()
    }
    private fun validateModeration(work: ModerationWork) {
        require(work.intent.actor == account && work.attempts in 0..5 && work.roundEnd > 0 && work.nextAttempt >= 0)
        require(!work.submissionStarted || work.admission != null)
        work.admission?.validate(work.intent)
        if(work.terminal) {
            val wire = requireNotNull(work.receipt);require(wire.toByteArray().size <= 65536)
            val receipt = MessageModerationClient.decodeReceipt(work.intent,Json.parseToJsonElement(wire).jsonObject)
            require(receipt.status == work.status && receipt.reason == work.reason && receipt.wire == wire)
        } else require(work.receipt == null)
    }
    override suspend fun moderationWorks() = access { moderationWorksNow() }
    override suspend fun moderationWork(id: String): ModerationWork? = access {
        db.rawQuery("SELECT work FROM message_moderation_operations WHERE id=?", arrayOf(id)).use { rows ->
            if(rows.moveToFirst()) Json.decodeFromString<ModerationWork>(rows.getString(0)).also { validateModeration(it); require(it.intent.key == id) } else null
        }
    }
    override suspend fun enqueueModeration(work: ModerationWork): ModerationWork = access { transaction {
        validateModeration(work);require(work.status == ModerationStatus.Pending && work.admission == null && work.attempts == 0 && !work.submissionStarted && !work.recoveryOnly && !work.reconcile)
        val works = moderationWorksNow();val existing = works.firstOrNull { it.intent.key == work.intent.key }
        if(existing != null) { require(existing.intent == work.intent);existing }
        else {
            check(works.none { !it.terminal && it.intent.room == work.intent.room && it.intent.message == work.intent.message }) { "此消息还有待确认的审核操作" }
            require(works.count { !it.terminal } < 128)
            db.execSQL("INSERT INTO message_moderation_operations VALUES (?,?)",arrayOf(work.intent.key,Json.encodeToString(work)));work
        }
    } }
    override suspend fun updateModeration(expected: ModerationWork,updated: ModerationWork) = access { transaction {
        require(expected.intent == updated.intent && expected.activation == updated.activation && !expected.terminal)
        check(moderationWorksNow().firstOrNull { it.intent.key == expected.intent.key } == expected)
        require(expected.executionStarted != true || updated.executionStarted == true)
        if(expected.admission != null) require(expected.admission == updated.admission)
        require(!expected.submissionStarted || updated.submissionStarted);require(!expected.recoveryOnly || updated.recoveryOnly)
        validateModeration(updated)
        db.execSQL("UPDATE message_moderation_operations SET work=? WHERE id=?",arrayOf(Json.encodeToString(updated),updated.intent.key))
    } }
    private fun administrationWorksNow(): PersistentList<AdministrationWork> = db.rawQuery("SELECT work FROM administration_operations ORDER BY rowid",null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<AdministrationWork>(rows.getString(0)).also(::validateAdministration)) }.toPersistentList()
    }
    private fun validateAdministration(work: AdministrationWork) {
        require(work.intent.actor == account && work.preparationAttempts in 0..5 && work.attempts in 0..5 && work.preparationEnd >= 0 && work.roundEnd >= 0 && work.nextAttempt >= 0)
        require(work.draft == (work.admission == null));require(!work.draft || !work.submissionStarted)
        work.admission?.validate(work.intent)
        if(work.terminal && work.status != AdministrationStatus.DraftCancelled) {
            val wire = requireNotNull(work.receipt);require(wire.toByteArray().size <= 65536)
            val receipt = AdministrationClient.decodeReceipt(work.command(),Json.parseToJsonElement(wire).jsonObject)
            require(receipt.status == work.status && receipt.reason == work.reason && receipt.wire == wire)
        } else require(work.receipt == null)
    }
    override suspend fun administrationWorks() = access { administrationWorksNow() }
    override suspend fun administrationWork(id: String): AdministrationWork? = access {
        db.rawQuery("SELECT work FROM administration_operations WHERE id=?", arrayOf(id)).use { rows ->
            if(rows.moveToFirst()) Json.decodeFromString<AdministrationWork>(rows.getString(0)).also { validateAdministration(it); require(it.intent.key == id) } else null
        }
    }
    override suspend fun prepareAdministration(intent: AdministrationIntent,activation: String): AdministrationWork = access { transaction {
        require(intent.actor == account)
        val works = administrationWorksNow();val existing = works.firstOrNull { it.intent.key == intent.key }
        if(existing != null) { require(existing.intent == intent);existing }
        else {
            check(works.none { !it.terminal && it.intent.room == intent.room && it.intent.target == intent.target }) { "此成员还有待确认的管理操作" }
            require(works.count { !it.terminal } < 128)
            AdministrationWork(intent,activation).also { validateAdministration(it);db.execSQL("INSERT INTO administration_operations VALUES (?,?)",arrayOf(intent.key,Json.encodeToString(it))) }
        }
    } }
    override suspend fun replaceAdministrationDraft(expected: AdministrationWork,intent: AdministrationIntent,activation: String): AdministrationWork = access { transaction {
        require(expected.status == AdministrationStatus.DraftPaused && expected.admission == null && expected.intent.key != intent.key)
        require(intent.actor == account && expected.intent.actor == account && intent.room == expected.intent.room && intent.target == expected.intent.target && intent.action == expected.intent.action && intent.reason == expected.intent.reason)
        check(administrationWorksNow().firstOrNull { it.intent.key == expected.intent.key } == expected)
        db.execSQL("UPDATE administration_operations SET work=? WHERE id=?",arrayOf(Json.encodeToString(expected.copy(status = AdministrationStatus.DraftCancelled)),expected.intent.key))
        AdministrationWork(intent,activation,nextAttempt = expected.nextAttempt).also { validateAdministration(it);db.execSQL("INSERT INTO administration_operations VALUES (?,?)",arrayOf(intent.key,Json.encodeToString(it))) }
    } }
    override suspend fun updateAdministration(expected: AdministrationWork,updated: AdministrationWork) = access { transaction {
        require(expected.executionStarted != true || updated.executionStarted == true) { "Command execution evidence cannot be erased" }
        require(expected.intent == updated.intent && expected.activation == updated.activation && !expected.terminal)
        check(administrationWorksNow().firstOrNull { it.intent.key == expected.intent.key } == expected)
        if(expected.admission != null) require(expected.admission == updated.admission && !updated.draft)
        else require(expected.status == AdministrationStatus.DraftReady || updated.status == AdministrationStatus.DraftCancelled)
        require(!expected.submissionStarted || updated.submissionStarted)
        validateAdministration(updated)
        db.execSQL("UPDATE administration_operations SET work=? WHERE id=?",arrayOf(Json.encodeToString(updated),updated.intent.key))
    } }
    private fun moderationFactsNow(): PersistentList<MemberMuteFact> = db.rawQuery("SELECT effect FROM moderation_facts ORDER BY rowid",null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<MemberMuteFact>(rows.getString(0))) }.toPersistentList()
    }
    private fun invitationWorksNow(): PersistentList<InvitationWork> = db.rawQuery("SELECT work FROM invitation_operations ORDER BY rowid", null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<InvitationWork>(rows.getString(0)).also(::validateInvitation)) }.toPersistentList()
    }
    private fun validateInvitation(work: InvitationWork) {
        require(work.intent.actor == account && work.preparationAttempts in 0..5 && work.attempts in 0..5 && work.nextAttempt >= 0 && work.preparationEnd >= 0 && work.roundEnd >= 0)
        work.secretReference?.let { require(java.util.UUID.fromString(it).toString().uppercase() == it && work.intent.action is InvitationAction.Submit) }
        require(!work.releaseSecret || work.terminal && work.secretReference != null)
        require(!work.terminal || work.secretReference == null || work.releaseSecret)
        require(!work.draft || work.admission == null && !work.recoveryOnly && !work.submissionStarted)
        require(work.draft || work.admission != null || work.recoveryOnly)
        require(work.intent.action !is InvitationAction.Submit || work.secretReference != null || work.terminal)
        work.admission?.validate(work.intent)
        if(work.terminal && work.status != InvitationStatus.DraftCancelled) {
            val receipt = requireNotNull(work.receipt); require(receipt.toByteArray().size <= 65536)
            val decoded = InvitationClient.decodeReceipt(work.intent, Json.parseToJsonElement(receipt).jsonObject)
            require(decoded.status == work.status && decoded.reason == work.reason && decoded.wire == receipt)
        } else require(work.receipt == null)
    }
    override suspend fun invitationWorks() = access { invitationWorksNow() }
    override suspend fun invitationWork(id: String): InvitationWork? = access {
        db.rawQuery("SELECT work FROM invitation_operations WHERE id=?", arrayOf(id)).use { rows ->
            if(rows.moveToFirst()) Json.decodeFromString<InvitationWork>(rows.getString(0)).also { validateInvitation(it); require(it.intent.key == id) } else null
        }
    }
    override suspend fun prepareInvitation(intent: InvitationIntent, activation: String, secretReference: String?): InvitationWork = access { transaction {
        require(intent.actor == account && (intent.action is InvitationAction.Submit) == (secretReference != null))
        val works = invitationWorksNow(); val existing = works.firstOrNull { it.intent.key == intent.key }
        if(existing != null) { require(existing.intent == intent); existing }
        else {
            require(works.count { !it.terminal } < 128)
            check(works.none { !it.terminal && it.intent.room == intent.room }) { "此群仍有待确认的邀请操作" }
            InvitationWork(intent, activation, secretReference = secretReference).also {
                validateInvitation(it); db.execSQL("INSERT INTO invitation_operations VALUES (?,?)", arrayOf(intent.key, Json.encodeToString(it)))
            }
        }
    } }
    override suspend fun replaceInvitationDraft(expected: InvitationWork, intent: InvitationIntent, activation: String): InvitationWork = access { transaction {
        require(expected.intent.actor == account && intent.actor == account && expected.intent.room == intent.room && expected.intent.action.sameProposal(intent.action))
        require(expected.status == InvitationStatus.DraftPaused && expected.admission == null && !expected.recoveryOnly && expected.intent.key != intent.key)
        check(invitationWorksNow().firstOrNull { it.intent.key == expected.intent.key } == expected)
        val cancelled = expected.copy(status = InvitationStatus.DraftCancelled, secretReference = null, releaseSecret = false)
        db.execSQL("UPDATE invitation_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(cancelled), expected.intent.key))
        InvitationWork(intent, activation, secretReference = expected.secretReference, nextAttempt = expected.nextAttempt).also {
            validateInvitation(it); db.execSQL("INSERT INTO invitation_operations VALUES (?,?)", arrayOf(intent.key, Json.encodeToString(it)))
        }
    } }
    override suspend fun updateInvitation(expected: InvitationWork, updated: InvitationWork) = access { transaction {
        require(expected.executionStarted != true || updated.executionStarted == true) { "Command execution evidence cannot be erased" }
        require(expected.intent == updated.intent && expected.activation == updated.activation)
        check(invitationWorksNow().firstOrNull { it.intent.key == expected.intent.key } == expected)
        if(expected.terminal) require(expected.releaseSecret && updated == expected.copy(secretReference = null, releaseSecret = false))
        else {
            require(!expected.submissionStarted || updated.submissionStarted)
            require(!expected.recoveryOnly || updated.recoveryOnly)
            if(expected.admission != null) require(expected.admission == updated.admission && !updated.draft)
            if(!expected.draft) require(!updated.draft)
            if(expected.status == InvitationStatus.DraftPaused) require(updated.status in setOf(InvitationStatus.DraftCancelled, InvitationStatus.Pending))
            require(expected.secretReference == updated.secretReference)
        }
        validateInvitation(updated)
        // Receipt proves the operation, never projects group access or stores an invitation bearer.
        db.execSQL("UPDATE invitation_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(updated), updated.intent.key))
    } }
    private fun capabilityWorksNow(): PersistentList<GroupCapabilityWork> = db.rawQuery("SELECT work FROM capability_operations ORDER BY rowid DESC", null).use { rows ->
        buildList { while (rows.moveToNext()) add(Json.decodeFromString<GroupCapabilityWork>(rows.getString(0))) }.toPersistentList()
    }
    override suspend fun capabilityWorks() = access { capabilityWorksNow() }
    override suspend fun capabilityWork(operation:String): GroupCapabilityWork? = access {
        db.rawQuery("SELECT work FROM capability_operations WHERE id=?",arrayOf(operation)).use { rows->
            if(rows.moveToFirst()) Json.decodeFromString<GroupCapabilityWork>(rows.getString(0)).also {require(it.intent.actor==account && it.intent.operation==operation)} else null
        }
    }
    override suspend fun prepareCapability(intent: GroupCapabilityIntent, activation: String): GroupCapabilityWork = access { transaction {
        require(intent.actor == account)
        val works = capabilityWorksNow()
        val existing = works.firstOrNull { it.intent.operation == intent.operation }
        if (existing != null) { require(existing.intent == intent && existing.activation == activation); existing }
        else {
            check(works.none { !it.terminal && it.intent.room == intent.room }) { "这个群还有待确认的管理操作，请先查看操作记录" }
            GroupCapabilityWork(intent, activation).also { db.execSQL("INSERT INTO capability_operations VALUES (?,?)", arrayOf(intent.operation, Json.encodeToString(it))) }
        }
    } }
    override suspend fun replaceCapabilityDraft(expected: GroupCapabilityWork, intent: GroupCapabilityIntent, activation: String): GroupCapabilityWork = access { transaction {
        require(expected.intent.actor == account && intent.actor == account && expected.intent.room == intent.room && expected.intent.action.sameDesiredValue(intent.action))
        require(expected.status == GroupCapabilityStatus.DraftPaused && expected.admission == null && expected.intent.operation != intent.operation)
        check(capabilityWorksNow().firstOrNull { it.intent.operation == expected.intent.operation } == expected)
        val cancelled = expected.copy(status = GroupCapabilityStatus.DraftCancelled)
        db.execSQL("UPDATE capability_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(cancelled), expected.intent.operation))
        GroupCapabilityWork(intent, activation, nextAttemptMilliseconds = expected.nextAttemptMilliseconds).also {
            db.execSQL("INSERT INTO capability_operations VALUES (?,?)", arrayOf(intent.operation, Json.encodeToString(it)))
        }
    } }
    override suspend fun updateCapability(expected: GroupCapabilityWork, updated: GroupCapabilityWork) = access { transaction {
        require(expected.executionStarted != true || updated.executionStarted == true) { "Command execution evidence cannot be erased" }
        require(expected.intent.actor == account && expected.intent == updated.intent && expected.activation == updated.activation && !expected.terminal)
        check(capabilityWorksNow().firstOrNull { it.intent.operation == expected.intent.operation } == expected)
        require(updated.preparationAttempts in 0..5 && updated.attempts >= 0 && updated.nextAttemptMilliseconds >= 0)
        val draft = updated.status in setOf(GroupCapabilityStatus.DraftReady, GroupCapabilityStatus.DraftPaused, GroupCapabilityStatus.DraftCancelled)
        if (expected.admission != null) require(expected.admission == updated.admission && !draft)
        else require(expected.status == GroupCapabilityStatus.DraftReady || updated.status == GroupCapabilityStatus.DraftCancelled)
        require(draft == (updated.admission == null))
        updated.admission?.validate(updated.intent)
        if (updated.terminal && updated.status != GroupCapabilityStatus.DraftCancelled) {
            val receipt = GroupCapabilityClient.decodeReceipt(updated.command(), Json.parseToJsonElement(updated.receipt ?: throw ClientFailure.Protocol()).jsonObject)
            require(receipt.status == updated.status && receipt.rejection == updated.reason)
        } else require(updated.receipt == null)
        // Only personal/room sync can project membership changes or revoke cached content.
        db.execSQL("UPDATE capability_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(updated), updated.intent.operation))
    } }
    private fun preferenceWorksNow(): PersistentList<PreferenceWork> = db.rawQuery("SELECT work FROM preference_operations ORDER BY rowid DESC", null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<PreferenceWork>(rows.getString(0))) }.toPersistentList()
    }
    private fun preferenceSnapshotsNow(): PersistentList<PreferenceSnapshot> = db.rawQuery("SELECT snapshot FROM preference_authority ORDER BY kind", null).use { rows ->
        buildList { while(rows.moveToNext()) { val value = Json.decodeFromString<PreferenceSnapshot>(rows.getString(0)); require(value.actor == account); add(value) } }.toPersistentList()
    }
    private fun savePreferenceNow(snapshot: PreferenceSnapshot) {
        require(snapshot.actor == account)
        val existing = preferenceSnapshotsNow().firstOrNull { it.value.kind == snapshot.value.kind }
        if(existing != null) {
            if(existing.revision > snapshot.revision) return
            if(existing.revision == snapshot.revision) { if(existing != snapshot) throw ClientFailure.Protocol(); return }
        }
        db.execSQL("INSERT OR REPLACE INTO preference_authority VALUES (?,?)", arrayOf(snapshot.value.kind.name, Json.encodeToString(snapshot)))
    }
    override suspend fun preferenceWorks() = access { preferenceWorksNow() }
    override suspend fun preferenceWork(operation:String): PreferenceWork? = access {
        db.rawQuery("SELECT work FROM preference_operations WHERE id=?",arrayOf(operation)).use { rows->
            if(rows.moveToFirst()) Json.decodeFromString<PreferenceWork>(rows.getString(0)).also {require(it.actor==account && it.operation==operation)} else null
        }
    }
    override suspend fun preferenceSnapshots() = access { preferenceSnapshotsNow() }
    override suspend fun savePreference(snapshot: PreferenceSnapshot) = access { transaction { savePreferenceNow(snapshot) } }
    override suspend fun preparePreference(work: PreferenceWork): PreferenceWork = access { transaction {
        require(work.actor == account && work.status == PreferenceStatus.DraftReady && work.command == null && work.preparationAttempts == 0 && work.attempts == 0 && work.receipt == null)
        val existing = preferenceWorksNow().firstOrNull { it.operation == work.operation }
        if(existing != null) { require(existing == work); existing } else {
            check(preferenceWorksNow().none { !it.terminal && it.patch.kind == work.patch.kind }) { "这项设置还有待确认的修改，请先核对操作记录" }
            db.execSQL("INSERT INTO preference_operations VALUES (?,?)", arrayOf(work.operation, Json.encodeToString(work))); work
        }
    } }
    override suspend fun replacePreferenceDraft(expected: PreferenceWork, replacement: PreferenceWork): PreferenceWork = access { transaction {
        require(expected.actor == account && replacement.actor == account && expected.patch == replacement.patch && expected.operation != replacement.operation)
        require(expected.status == PreferenceStatus.DraftPaused && expected.command == null && replacement.status == PreferenceStatus.DraftReady && replacement.command == null)
        check(preferenceWorksNow().firstOrNull { it.operation == expected.operation } == expected)
        db.execSQL("UPDATE preference_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(expected.copy(status = PreferenceStatus.DraftCancelled)), expected.operation))
        val fresh = replacement.copy(nextAttemptMilliseconds = maxOf(expected.nextAttemptMilliseconds, replacement.nextAttemptMilliseconds))
        db.execSQL("INSERT INTO preference_operations VALUES (?,?)", arrayOf(fresh.operation, Json.encodeToString(fresh))); fresh
    } }
    override suspend fun updatePreference(expected: PreferenceWork, updated: PreferenceWork) = access { transaction {
        require(expected.executionStarted != true || updated.executionStarted == true) { "Command execution evidence cannot be erased" }
        require(expected.actor == account && updated.actor == account && expected.operation == updated.operation && expected.patch == updated.patch && expected.activation == updated.activation && expected.confirmedUntil == updated.confirmedUntil && !expected.terminal)
        check(preferenceWorksNow().firstOrNull { it.operation == expected.operation } == expected)
        require(updated.preparationAttempts in 0..5 && updated.attempts >= 0 && updated.nextAttemptMilliseconds >= 0)
        val draft = updated.status in setOf(PreferenceStatus.DraftReady, PreferenceStatus.DraftPaused, PreferenceStatus.DraftCancelled)
        if(expected.command != null) require(expected.command == updated.command && !draft)
        else require(expected.status == PreferenceStatus.DraftReady || updated.status == PreferenceStatus.DraftCancelled)
        require(draft == (updated.command == null))
        updated.command?.let { require(it.actor == account && it.operation == updated.operation && updated.patch.matches(it.value) && it.deadline <= updated.confirmedUntil) }
        if(updated.terminal && updated.status != PreferenceStatus.DraftCancelled) {
            val receipt = AccountPreferenceClient.decodeReceipt(requireNotNull(updated.command), Json.parseToJsonElement(updated.receipt ?: throw ClientFailure.Protocol()).jsonObject)
            require(receipt.status == updated.status && receipt.rejection == updated.reason)
            receipt.applied?.let(::savePreferenceNow)
        } else require(updated.receipt == null)
        db.execSQL("UPDATE preference_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(updated), updated.operation))
    } }
    private fun personalWorksNow(): PersistentList<PersonalWork> = db.rawQuery("SELECT work FROM personal_operations ORDER BY rowid", null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<PersonalWork>(rows.getString(0))) }.toPersistentList()
    }
    private fun personalStatesNow(table: String): PersistentList<PersonalState> = db.rawQuery("SELECT state FROM $table ORDER BY key", null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<PersonalState>(rows.getString(0))) }.toPersistentList()
    }
    private fun personalStateFrom(table: String,key: String): PersonalState? = db.rawQuery("SELECT state FROM $table WHERE key=?",arrayOf(key)).use {
        if(it.moveToFirst()) Json.decodeFromString<PersonalState>(it.getString(0)) else null
    }
    private fun personalStateNow(key: String): PersonalState? {
        val states = listOfNotNull(personalStateFrom("personal_confirmed",key),personalStateFrom("personal_projections",key))
        val legacy = if(key.startsWith("conversationPreference/")) db.rawQuery("SELECT pinned,archived,mute,revision FROM conversation_state WHERE room=?", arrayOf(key.substringAfter('/'))).use {
            if(it.moveToFirst()) PersonalState(PersonalTarget.Conversation(RoomId(key.substringAfter('/')), it.getInt(0) == 1, it.getInt(1) == 1, it.getLong(2)), it.getLong(3), 0) else null
        } else null
        return (states + listOfNotNull(legacy)).maxByOrNull { it.revision }
    }
    private fun savePersonalStateNow(table: String, state: PersonalState) {
        val existing = personalStateFrom(table,state.target.key)
        if(existing != null) {
            if(existing.revision > state.revision) return
            if(existing.revision == state.revision) { if(existing != state) throw ClientFailure.Protocol(); return }
        }
        val authority = listOfNotNull(personalStateFrom("personal_confirmed",state.target.key),personalStateFrom("personal_projections",state.target.key)).maxByOrNull { it.revision }
        if(authority?.revision == state.revision && authority != state) throw ClientFailure.Protocol()
        db.execSQL("INSERT OR REPLACE INTO $table VALUES (?,?)", arrayOf(state.target.key, Json.encodeToString(state)))
        favorites.project(table,state)
    }
    private fun personalTargetNow(fallback: PersonalTarget, now: Long): PersonalTarget = personalWorksNow().lastOrNull {
        it.target.key == fallback.key && !it.terminal && (it.command != null || it.deadline > now)
    }?.target ?: personalStateNow(fallback.key)?.target ?: fallback
    override suspend fun personalWorks() = access { personalWorksNow() }
    override suspend fun personalWork(operation:String): PersonalWork? = access {
        db.rawQuery("SELECT work FROM personal_operations WHERE id=?",arrayOf(operation)).use { rows->
            if(rows.moveToFirst()) Json.decodeFromString<PersonalWork>(rows.getString(0)).also {require(it.actor==account && it.operation==operation)} else null
        }
    }
    override suspend fun enqueueConversation(room: RoomId, patch: ConversationPatch, now: Long): PersonalWork = access { transaction {
        check(!revoked(room.value)) { "此会话已不可访问" }
        val target = personalTargetNow(PersonalTarget.Conversation(room), now) as PersonalTarget.Conversation
        enqueuePersonalNow(patch.apply(target), now)
    } }
    override suspend fun enqueueFavorite(room: RoomId, message: MessageId, favorite: Boolean, now: Long): PersonalWork = access { transaction {
        check(!favorite || !revoked(room.value)) { "此会话已不可访问" }
        enqueuePersonalNow(PersonalTarget.Favorite(room, message, favorite), now)
    } }
    private fun enqueuePersonalNow(target: PersonalTarget, now: Long): PersonalWork {
        require(now >= 0)
        val works = personalWorksNow()
        val existing = works.lastOrNull { it.target.key == target.key && it.status == PersonalStatus.Queued && it.command == null && it.deadline > now }
        if(existing != null) {
            return existing.copy(target = target).also { db.execSQL("UPDATE personal_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(it), it.operation)) }
        }
        val work = PersonalWork(account, java.util.UUID.randomUUID().toString().uppercase(), target, Math.addExact(now, 7 * 86_400_000L - 5000))
        // Validate canonical wire identities before recording any intent.
        PersonalCommand(account, work.operation, target, 0, work.deadline)
        db.execSQL("INSERT INTO personal_operations VALUES (?,?)", arrayOf(work.operation, Json.encodeToString(work)))
        return work
    }
    override suspend fun preparePersonal(now: Long) = access { transaction {
        val keys = mutableSetOf<String>()
        for(work in personalWorksNow()) {
            require(work.actor == account)
            if(work.terminal || !keys.add(work.target.key) || work.status != PersonalStatus.Queued) continue
            val updated = if(work.deadline <= now) work.copy(status = PersonalStatus.Expired)
            else {
                val revision = personalStateNow(work.target.key)?.revision ?: 0
                if(revision == Long.MAX_VALUE) work.copy(status = PersonalStatus.Expired, reason = "revisionExhausted")
                else work.copy(status = PersonalStatus.Pending, command = PersonalCommand(account, work.operation, work.target, revision, work.deadline))
            }
            db.execSQL("UPDATE personal_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(updated), work.operation))
        }
    } }
    override suspend fun updatePersonal(expected: PersonalWork, updated: PersonalWork) = access { transaction {
        require(expected.actor == account && expected.actor == updated.actor && expected.operation == updated.operation && expected.target == updated.target && expected.deadline == updated.deadline && !expected.terminal)
        check(personalWorksNow().firstOrNull { it.operation == expected.operation } == expected)
        require(expected.command == updated.command && updated.attempts >= 0 && updated.nextAttempt >= 0 && (!expected.submissionStarted || updated.submissionStarted))
        require(updated.status != PersonalStatus.Queued || updated.command == null)
        if(updated.status == PersonalStatus.Cancelled) require(!expected.submissionStarted && !updated.submissionStarted)
        else require(updated.command != null)
        if(updated.terminal && updated.status != PersonalStatus.Cancelled) {
            val receipt = PersonalPreferenceClient.decodeReceipt(requireNotNull(updated.command), Json.parseToJsonElement(updated.receipt ?: throw ClientFailure.Protocol()).jsonObject)
            require(receipt.status == updated.status && receipt.reason == updated.reason)
            receipt.state?.let { savePersonalStateNow("personal_confirmed", it) }
        } else require(updated.receipt == null)
        db.execSQL("UPDATE personal_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(updated), updated.operation))
    } }
    private fun mutationWorksNow(): PersistentList<MessageMutationWork> = db.rawQuery("SELECT work FROM message_mutations ORDER BY rowid", null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<MessageMutationWork>(rows.getString(0))) }.toPersistentList()
    }
    override suspend fun mutationWorks() = access { mutationWorksNow() }
    override suspend fun mutationWork(operation:String): MessageMutationWork? = access {
        db.rawQuery("SELECT work FROM message_mutations WHERE id=?",arrayOf(operation)).use { rows->
            if(rows.moveToFirst()) Json.decodeFromString<MessageMutationWork>(rows.getString(0)).also {require(it.command.actor==account && it.command.operation==operation)} else null
        }
    }
    override suspend fun enqueueMutation(command: MessageMutationCommand): MessageMutationWork = access { transaction {
        require(command.actor == account)
        val works = mutationWorksNow()
        val exact = works.firstOrNull { it.command.operation == command.operation }
        if(exact != null) { require(exact.command == command); exact } else {
            check(!revoked(command.room.value)) { "此会话已不可访问" }
            val duplicate = works.firstOrNull { !it.terminal && it.command.orderingKey == command.orderingKey && it.command.kind == command.kind && it.command.revision == command.revision }
            if(duplicate != null) {
                check(duplicate.command.text == command.text) { "上一份编辑结果尚未确认，请先核对原操作" }; duplicate
            } else {
                MessageMutationWork.fresh(command).also { db.execSQL("INSERT INTO message_mutations VALUES (?,?)", arrayOf(command.operation, Json.encodeToString(it))) }
            }
        }
    } }
    override suspend fun updateMutation(expected: MessageMutationWork, updated: MessageMutationWork) = access { transaction {
        require(expected.command.actor == account && expected.command == updated.command && !expected.terminal && updated.attempts >= 0 && updated.nextAttempt >= 0)
        check(mutationWorksNow().firstOrNull { it.command.operation == expected.command.operation } == expected)
        require(expected.executionStarted != true || updated.executionStarted == true)
        if(updated.terminal) {
            val receipt = MessageMutationClient.decodeReceipt(updated.command, Json.parseToJsonElement(updated.receipt ?: throw ClientFailure.Protocol()).jsonObject)
            require(receipt.status == updated.status && receipt.reason == updated.reason)
        } else require(updated.receipt == null)
        // A mutation receipt proves historical execution, never current message content.
        db.execSQL("UPDATE message_mutations SET work=? WHERE id=?", arrayOf(Json.encodeToString(updated), updated.command.operation))
    } }
    private fun forwardWorksNow(): PersistentList<ForwardWork> = db.rawQuery("SELECT work FROM forward_operations ORDER BY rowid", null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<ForwardWork>(rows.getString(0))) }.toPersistentList()
    }
    override suspend fun forwardWorks() = access { forwardWorksNow() }
    override suspend fun forwardWork(operation:String): ForwardWork? = access {
        db.rawQuery("SELECT work FROM forward_operations WHERE id=?",arrayOf(operation)).use { rows->
            if(rows.moveToFirst()) Json.decodeFromString<ForwardWork>(rows.getString(0)).also {require(it.command.actor==account && it.command.operation==operation)} else null
        }
    }
    override suspend fun enqueueForward(command: ForwardCommand): ForwardWork = access { transaction {
        require(command.actor == account && command.payload().toString().toByteArray().size <= 65536)
        val works = forwardWorksNow(); val exact = works.firstOrNull { it.command.operation == command.operation }
        if(exact != null) { require(exact.command == command); exact } else {
            check((command.sources.map { it.room } + command.targets).none { revoked(it.value) }) { "来源或目标会话已不可访问" }
            val active = works.filter { !it.terminal }
            val duplicate = active.firstOrNull { it.command.sources == command.sources && it.command.targets == command.targets }
            if(duplicate != null) duplicate else {
                check(active.none { prior -> prior.command.sources.any { source -> command.sources.any { it.message == source.message } } && prior.command.targets.any { it in command.targets } }) { "存在重叠的未确认转发，请先核对原计划" }
                // Bound pending plans: each server response may contain up to 1 MiB of evidence.
                check(active.size < 32) { "待确认转发过多，请先核对已有计划" }
                ForwardWork(command).also { db.execSQL("INSERT INTO forward_operations VALUES (?,?)", arrayOf(command.operation, Json.encodeToString(it))) }
            }
        }
    } }
    override suspend fun updateForward(expected: ForwardWork, updated: ForwardWork) = access { transaction {
        require(expected.command.actor == account && expected.command == updated.command && !expected.terminal && updated.attempts >= 0 && updated.nextAttempt >= 0)
        require(!expected.submissionStarted || updated.submissionStarted); require(!expected.cancelRequested || updated.cancelRequested)
        check(forwardWorksNow().firstOrNull { it.command.operation == expected.command.operation } == expected)
        val progress = updated.progress
        if(progress != null) {
            require(updated.submissionStarted && progress.wire.toByteArray().size <= 1_048_576)
            require(ForwardPlanClient.decodeProgress(updated.command, Json.parseToJsonElement(progress.wire).jsonObject) == progress)
            expected.progress?.let { if(!progress.advances(it)) throw ClientFailure.Protocol() }
        } else require(expected.progress == null)
        if(updated.status in setOf(ForwardStatus.Cancelled, ForwardStatus.Expired)) require(!updated.submissionStarted && progress == null && updated.receipt == null)
        else if(updated.terminal) {
            val receipt = updated.receipt ?: throw ClientFailure.Protocol(); require(receipt.toByteArray().size <= 1_048_576)
            val resolved = ForwardPlanClient.decodeResolved(updated.command, Json.parseToJsonElement(receipt).jsonObject)
            require(resolved.status == updated.status && resolved.progress == progress)
        } else require(updated.receipt == null)
        db.execSQL("UPDATE forward_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(updated), updated.command.operation))
    } }
    private fun reactionWorksNow(): PersistentList<ReactionWork> = db.rawQuery("SELECT work FROM reaction_operations ORDER BY rowid", null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<ReactionWork>(rows.getString(0))) }.toPersistentList()
    }
    override suspend fun reactionWorks() = access { reactionWorksNow() }
    override suspend fun reactionWork(operation:String): ReactionWork? = access {
        db.rawQuery("SELECT work FROM reaction_operations WHERE id=?",arrayOf(operation)).use { rows->
            if(rows.moveToFirst()) Json.decodeFromString<ReactionWork>(rows.getString(0)).also {require(it.intent.actor==account && it.intent.operation==operation)} else null
        }
    }
    override suspend fun enqueueReaction(intent: ReactionIntent): ReactionWork = access { transaction {
        require(intent.actor == account)
        val works = reactionWorksNow()
        val exact = works.firstOrNull { it.intent.operation == intent.operation }
        if(exact != null) { require(exact.intent == intent); exact } else {
            check(!revoked(intent.room.value)) { "此会话已不可访问" }
            val previous = works.lastOrNull { it.intent.orderingKey == intent.orderingKey && it.command == null && !it.terminal }
            if(previous != null) {
                // Coalescing never renews the identity, deadline, retry floor or preparation budget.
                previous.copy(intent = previous.intent.copy(present = intent.present)).also {
                    db.execSQL("UPDATE reaction_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(it), it.intent.operation))
                }
            } else {
                ReactionWork(intent).also { db.execSQL("INSERT INTO reaction_operations VALUES (?,?)", arrayOf(intent.operation, Json.encodeToString(it))) }
            }
        }
    } }
    override suspend fun updateReaction(expected: ReactionWork, updated: ReactionWork) = access { transaction {
        require(expected.executionStarted != true || updated.executionStarted == true) { "Command execution evidence cannot be erased" }
        require(expected.intent.actor == account && expected.intent == updated.intent && !expected.terminal)
        require(updated.attempts >= 0 && updated.preparationAttempts >= 0 && updated.nextAttempt >= 0)
        check(reactionWorksNow().firstOrNull { it.intent.operation == expected.intent.operation } == expected)
        if(expected.command != null) require(expected.command == updated.command)
        updated.command?.let { require(it.intent == updated.intent) }
        if(updated.status in setOf(ReactionStatus.Draft, ReactionStatus.PreparationPaused, ReactionStatus.Expired, ReactionStatus.Cancelled)) {
            require(updated.command == null && !updated.reconcile && updated.receipt == null)
        } else require(updated.command != null)
        if(updated.terminal && updated.command != null) {
            val receipt = MessageReactionClient.decodeReceipt(requireNotNull(updated.command), Json.parseToJsonElement(updated.receipt ?: throw ClientFailure.Protocol()).jsonObject)
            require(receipt.status == updated.status && receipt.reason == updated.reason)
        } else require(updated.receipt == null)
        db.execSQL("UPDATE reaction_operations SET work=? WHERE id=?", arrayOf(Json.encodeToString(updated), updated.intent.operation))
    } }
    private fun reactionSummariesNow(): PersistentList<MessageReactionSummary> = db.rawQuery("""
        SELECT r.room,r.message,r.reaction,COUNT(*),MAX(CASE WHEN r.actor=? THEN 1 ELSE 0 END)
        FROM reaction_versions r JOIN messages m ON m.id=r.message AND m.room=r.room
        WHERE r.present=1 AND m.withdrawn=0 AND NOT EXISTS(SELECT 1 FROM message_tombstones t WHERE t.id=r.message)
          AND r.room NOT IN(SELECT room FROM memberships WHERE member=0)
        GROUP BY r.room,r.message,r.reaction ORDER BY r.message,r.reaction
        """.trimIndent(), arrayOf(account.value)).use { rows ->
        buildList { while(rows.moveToNext()) add(MessageReactionSummary(RoomId(rows.getString(0)), MessageId(rows.getString(1)), rows.getString(2), rows.getInt(3), rows.getInt(4) != 0)) }.toPersistentList()
    }
    private fun changes()=android.database.DatabaseUtils.longForQuery(db,"SELECT total_changes()",null)
    private suspend fun <T> resourceWrite(body: ()->T): T = access {
        // total_changes() belongs to a physical SQLite connection. Keep both reads on the transaction's writer.
        val (result,changed)=transaction { val before=changes();val value=body();value to (changes()!=before) }
        if(changed) resourceChanges.value=resourceChanges.value+1
        result
    }
    override suspend fun resourceReadGeneration() = access { catalog.readGeneration() }
    override suspend fun selectMessageResource(key: ResourceKey) = access { transaction { catalog.selectRead(key) } }
    override suspend fun selectMessageResource(key: ResourceKey,location: MediaMessageLocation) = access { transaction { catalog.selectRead(key,location) } }
    override suspend fun isMessageResourceCurrent(read: MessageResourceRead) = access { transaction { catalog.currentRead(read) } }
    override suspend fun selectAvatarResource(key: ResourceKey) = access { transaction { catalog.selectAvatar(key) } }
    override suspend fun isAvatarResourceCurrent(selection: AvatarResourceSelection) = access { transaction { catalog.currentAvatar(selection) } }
    override suspend fun enqueueSelectedProfileAvatar(intent: ProfileIntent,selection: AvatarResourceSelection,now: Long) = resourceWrite {
        if(!catalog.currentAvatar(selection)) throw ResourceCatalogConflict()
        val request=requireNotNull(intent.serverImport).request
        require(request.source==selection.importSource && request.targetUsage==ResourceUsage.UserAvatar)
        check(profileIntents.statuses().none { !it.intent.locallyTerminal && it.work?.terminal!=true } && ownProfile.works().none { !it.terminal }) { "请先处理尚未确认的资料修改" }
        profileIntents.enqueue(intent,now)
    }
    override suspend fun enqueueSelectedGroupAvatar(authority: GroupAvatarEditAuthority,command: GroupAvatarCommand,
        source: GroupAvatarImportPreparation,selection: AvatarResourceSelection,now: Long) = resourceWrite {
        if(!catalog.currentAvatar(selection)) throw ResourceCatalogConflict()
        require(source.request.source==selection.importSource && source.request.targetUsage==ResourceUsage.GroupAvatar(command.room))
        check(groupAvatarIntents.all().none { it.command.room==command.room && it.pending }) { "请先处理尚未确认的群头像修改" }
        groupAvatarIntents.enqueue(authority,command,null,now,serverImport=source)
    }
    override suspend fun resourceDirectory(query: ResourceCatalogQuery) = access { catalog.directory(query) }
    private data class PreparationPreview(val plan:ResourcePreparationCancellationPlan,val parents:PersistentList<String>,val order:Long)
    private val preparationPreviewSequence=java.util.concurrent.atomic.AtomicLong()
    private val preparationPreviews=java.util.concurrent.ConcurrentHashMap<String,PreparationPreview>()
    override suspend fun planResourcePreparationCancellation(transfer:ResourceTransferId)=access {
        transaction {
            val parents=sendIntents.preparationCancellationParents(transfer) ?: throw ResourceTransferActionUnavailable()
            if(preparationPreviews.size>=16) preparationPreviews.entries.minByOrNull {it.value.order}?.let {preparationPreviews.remove(it.key)}
            val plan=ResourcePreparationCancellationPlan(java.util.UUID.randomUUID().toString().uppercase(),transfer,parents.size)
            preparationPreviews[plan.id]=PreparationPreview(plan,parents.map {it.id}.toPersistentList(),preparationPreviewSequence.incrementAndGet())
            plan
        }
    }
    override suspend fun cancelResourcePreparation(plan:ResourcePreparationCancellationPlan)=resourceWrite {
        val preview=preparationPreviews.remove(plan.id) ?: throw ResourceTransferActionUnavailable()
        if(preview.plan!=plan) throw ResourceTransferActionUnavailable()
        sendIntents.cancelPreparation(plan.transfer,preview.parents)
    }
    private data class UnboundPreview(val plan:ResourceUnboundCancellationPlan,val identity:SqliteResourceTransfers.UnboundIdentity,val order:Long)
    private val unboundPreviews=java.util.concurrent.ConcurrentHashMap<String,UnboundPreview>()
    private val unboundPreviewSequence=java.util.concurrent.atomic.AtomicLong()
    override suspend fun planUnboundResourceCancellation(transfer:ResourceTransferId)=access {
        transaction {
            val identity=transfers().unboundIdentity(transfer) ?: throw ResourceTransferActionUnavailable()
            if(unboundPreviews.size>=16) unboundPreviews.entries.minByOrNull {it.value.order}?.let {unboundPreviews.remove(it.key)}
            val plan=ResourceUnboundCancellationPlan(java.util.UUID.randomUUID().toString().uppercase(),transfer)
            unboundPreviews[plan.id]=UnboundPreview(plan,identity,unboundPreviewSequence.incrementAndGet())
            plan
        }
    }
    override suspend fun cancelUnboundResource(plan:ResourceUnboundCancellationPlan)=resourceWrite {
        val preview=unboundPreviews.remove(plan.id) ?: throw ResourceTransferActionUnavailable()
        if(preview.plan!=plan) throw ResourceTransferActionUnavailable()
        transfers().cancelUnbound(plan.transfer,preview.identity)
    }
    private fun businessOwners()=SqliteResourceBusinessOwners(db,account,device)
    override suspend fun resourceBusinessOwners(query:ResourceBusinessOwnerQuery)=access {transaction {businessOwners().page(query)}}
    override suspend fun resourceHasBusinessOwner(transfer:ResourceTransferId,owner:ResourceBusinessOwner)=access {transaction {businessOwners().contains(transfer,owner)}}
    override suspend fun resourceProfileIntent(transfer:ResourceTransferId,intent:String)=access {transaction {profileOwner(transfer,intent)}}
    private fun profileOwner(transfer:ResourceTransferId,intent:String):ProfileIntentStatus? {
        if(!businessOwners().contains(transfer,ResourceBusinessOwner.Profile(intent))) return null
        return profileIntents.statuses().firstOrNull {it.intent.id==intent}
    }
    private data class ProfileDispositionPreview(val plan:ResourceProfileDispositionPlan,val status:ProfileIntentStatus,val order:Long)
    private val profileDispositionPreviews=java.util.concurrent.ConcurrentHashMap<String,ProfileDispositionPreview>()
    private val profileDispositionSequence=java.util.concurrent.atomic.AtomicLong()
    override suspend fun planResourceProfileDisposition(transfer:ResourceTransferId,intent:String)=access {transaction {
        val status=profileOwner(transfer,intent)?.takeIf {it.sourceRetained && it.work?.terminal!=false} ?: throw ResourceTransferActionUnavailable()
        val effect=if(status.intent.frozen) ResourceProfileDispositionEffect.ReleaseFinishedSource else ResourceProfileDispositionEffect.WithdrawUnsubmittedChange
        val plan=ResourceProfileDispositionPlan(java.util.UUID.randomUUID().toString().uppercase(),transfer,intent,effect)
        if(profileDispositionPreviews.size>=16) profileDispositionPreviews.entries.minByOrNull {it.value.order}?.let {profileDispositionPreviews.remove(it.key)}
        profileDispositionPreviews[plan.id]=ProfileDispositionPreview(plan,status,profileDispositionSequence.incrementAndGet());plan
    }}
    override suspend fun commitResourceProfileDisposition(plan:ResourceProfileDispositionPlan)=resourceWrite {
        val preview=profileDispositionPreviews.remove(plan.id) ?: throw ResourceTransferActionUnavailable()
        if(preview.plan!=plan || profileOwner(plan.transfer,plan.intent)!=preview.status || preview.status.work?.terminal==false) throw ResourceTransferActionUnavailable()
        profileIntents.discard(plan.intent)
    }
    private fun transfers()=SqliteResourceTransfers(db,resources,imports,downloads,sendIntents)
    override suspend fun resourceTransfers(query:ResourceTransferQuery,now:Long):ResourceTransferPage {
        val context=kotlinx.coroutines.currentCoroutineContext()
        return access {transaction {transfers().page(query,now) {context.ensureActive()}}}
    }
    override suspend fun controlResourceTransfer(id:ResourceTransferId,action:ResourceTransferAction,now:Long)=resourceWrite {transfers().control(id,action,now)}
    override suspend fun retryResourceTransfers(ids:PersistentList<ResourceTransferId>,action:ResourceTransferAction,now:Long):ResourceTransferBatchResult {
        require(ids.size in 1..100 && action in setOf(ResourceTransferAction.Retry,ResourceTransferAction.RetryCancellation) && now>=0)
        val results=mutableListOf<ResourceTransferBatchItem>()
        for(id in ids.distinct()) {
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            access {check(db.isOpen)}
            val outcome=try {controlResourceTransfer(id,action,now);ResourceTransferBatchOutcome.Requested}
                catch(error:kotlinx.coroutines.CancellationException) {throw error}
                catch(_:ResourceTransferActionUnavailable) {ResourceTransferBatchOutcome.Skipped}
                catch(_:Exception) {access {check(db.isOpen)};ResourceTransferBatchOutcome.Failed}
            results+=ResourceTransferBatchItem(id,outcome)
        }
        return ResourceTransferBatchResult(action,results.toPersistentList())
    }
    internal suspend fun backgroundDownloadSources()=access {backgroundDownloadSources.sources()}
    internal suspend fun beginBackgroundDownloadSource(mapping:ResourceBackgroundDownloadMapping,rawBudget:Long,policy:ResourceOriginalPolicy)=resourceWrite {backgroundDownloadSources.begin(mapping,rawBudget,policy)}
    internal suspend fun requireBackgroundDownloadSourceActive(mapping:ResourceBackgroundDownloadMapping)=access {backgroundDownloadSources.requireActive(mapping)}
    internal suspend fun beginBackgroundDownloadPublication(mapping:ResourceBackgroundDownloadMapping,id:String,reuse:Boolean,allocated:Long,policy:ResourceOriginalPolicy)=resourceWrite {backgroundDownloadSources.publication(mapping,id,reuse,allocated,policy)}
    internal suspend fun deleteBackgroundDownloadSource(mapping:ResourceBackgroundDownloadMapping,finished:Boolean)=resourceWrite {backgroundDownloadSources.delete(mapping,finished)}
    override suspend fun backgroundDownloadSession()=resourceWrite {downloads.backgroundSession()}
    override suspend fun activeBackgroundDownloads()=access {downloads.backgrounds()}
    override suspend fun installBackgroundDownload(claim:ResourceDownloadClaim,id:String,task:String,target:ResourceBackgroundDownloadTarget,now:Long)=resourceWrite {downloads.installBackground(claim,id,task,target,now)}
    override suspend fun finishBackgroundDownload(mapping:ResourceBackgroundDownloadMapping,result:ResourceBackgroundDownloadResult?,now:Long)=resourceWrite {downloads.finishBackground(mapping,result,now)}
    override suspend fun completeBackgroundDownload(mapping:ResourceBackgroundDownloadMapping,read:MessageResourceRead,now:Long)=resourceWrite {downloads.completeBackground(mapping,read,now)}
    override suspend fun discardReceivedBackgroundDownload(mapping:ResourceBackgroundDownloadMapping,issue:ResourceDownloadIssue,now:Long)=resourceWrite {downloads.discardReceived(mapping,issue,now)}
    override suspend fun failReceivedBackgroundDownload(mapping:ResourceBackgroundDownloadMapping,issue:ResourceDownloadIssue,retryAt:Long?,serverRetryAt:Long,now:Long)=resourceWrite {downloads.failReceived(mapping,issue,retryAt,serverRetryAt,now)}
    override suspend fun downloadNetworkPreferences()=access {downloads.networkPreferences()}
    override suspend fun setDownloadNetworkPreferences(value:ResourceDownloadNetworkPreferences)=resourceWrite {downloads.networkPreferences(value)}
    override suspend fun prepareAutomaticDownloads(now:Long,networkAllowed:Boolean)=resourceWrite {downloads.prepareAutomatic(now,networkAllowed)}
    override suspend fun resourceDownloads()=access {downloads.snapshots()}
    override suspend fun enqueueResourceDownload(key:ResourceKey,source:MessageResourceSource,now:Long)=resourceWrite {downloads.enqueue(key,source,now)}
    override suspend fun controlResourceDownload(id:String,control:ResourceDownloadControl,now:Long)=resourceWrite {downloads.control(id,control,now)}
    override suspend fun recoverResourceDownloads(owner:String,now:Long)=resourceWrite {downloads.recover(owner,now)}
    override suspend fun claimResourceDownload(id:String,owner:String,now:Long)=resourceWrite {downloads.claim(id,owner,now)}
    override suspend fun completeResourceDownload(claim:ResourceDownloadClaim,read:MessageResourceRead,now:Long)=resourceWrite {downloads.complete(claim,read,now)}
    override suspend fun releaseResourceDownload(claim:ResourceDownloadClaim,issue:ResourceDownloadIssue,retryAt:Long?,serverRetryAt:Long,interrupted:Boolean,now:Long)=resourceWrite {downloads.release(claim,issue,retryAt,serverRetryAt,interrupted,now)}
    suspend fun resourceDetails(key:ResourceKey,before:ResourceSourceCursor?=null,limit:Int=30):ResourceDetailSnapshot?=resourceWrite {
        catalog.visibleDescriptor(key)?.let {ResourceDetailSnapshot(it,retention.variants(key),catalog.sources(key,before,limit))}
    }
    override suspend fun resourceSources(key: ResourceKey,before: ResourceSourceCursor?,limit: Int) = access { catalog.sources(key,before,limit) }
    override suspend fun containsResourceSource(key: ResourceKey,source: MessageResourceSource) = access { catalog.contains(key,source) }
    override suspend fun beginResourceDirectoryScan(room: RoomId,query: RoomResourceQuery) = resourceWrite { catalog.begin(room,query) }
    override suspend fun resourceDirectoryScan(room: RoomId,query: RoomResourceQuery) = access { catalog.scan(room,query) }
    override suspend fun applyResourceDirectoryPage(scan: ResourceDirectoryScan,page: RoomResourcePage) = resourceWrite { catalog.apply(scan,page) }
    override suspend fun denyResourceDirectory(scan: ResourceDirectoryScan) = resourceWrite { catalog.deny(scan) }
    override suspend fun indexResourceProjectionBatch(limit: Int) = resourceWrite { catalog.indexBatch(limit) }
    override suspend fun resourceImports() = access { imports.all() }
    override suspend fun prepareResourceImport(id: String,request: ResourceImportRequest,now: Long) = resourceWrite { imports.prepare(id,request,now) }
    override suspend fun recoverResourceImportClaims(owner: String) = resourceWrite { imports.recover(owner) }
    override suspend fun claimResourceImport(id: String,owner: String,now: Long) = resourceWrite { imports.claim(id,owner,now) }
    override suspend fun finishResourceImport(claim: ResourceImportClaim,status: ResourceImportStatus,now: Long) = resourceWrite { imports.finish(claim,status,now) }
    override suspend fun failResourceImport(claim: ResourceImportClaim,issue: ResourceImportIssue,retryAt: Long?,serverRetryAt: Long,cancelled: Boolean) = resourceWrite { imports.fail(claim,issue,retryAt,serverRetryAt,cancelled) }
    override suspend fun cancelResourceImport(id: String) = resourceWrite { imports.cancel(id) }
    override suspend fun controlResourceImport(id: String,paused: Boolean,retry: Boolean) = resourceWrite { imports.control(id,paused,retry) }
    override suspend fun releaseResourceImport(id: String) = resourceWrite { imports.release(id) }
    internal suspend fun backgroundUploadSources()=access {backgroundUploads.sources()}
    internal suspend fun requireBackgroundSourceActive(mapping:ResourceBackgroundUploadMapping)=access {backgroundUploads.requireSourceActive(mapping)}
    internal suspend fun beginBackgroundUploadSource(mapping:ResourceBackgroundUploadMapping,policy:ResourceOriginalPolicy)=resourceWrite {backgroundUploads.beginSource(mapping,policy)}
    internal suspend fun finishBackgroundUploadSource(mapping:ResourceBackgroundUploadMapping,checksum:ResourceChecksum,allocated:Long,policy:ResourceOriginalPolicy)=resourceWrite {backgroundUploads.finishSource(mapping,checksum,allocated,policy)}
    internal suspend fun deleteBackgroundUploadSource(mapping:ResourceBackgroundUploadMapping,finished:Boolean,recoverPreparing:Boolean=false)=resourceWrite {backgroundUploads.deleteSource(mapping,finished,recoverPreparing)}
    override suspend fun backgroundUploadSession()=resourceWrite {backgroundUploads.session()}
    override suspend fun activeBackgroundUploads()=access {transaction {backgroundUploads.active()}}
    override suspend fun installBackgroundUploads(claim:ResourceUploadClaim,tasks:PersistentList<ResourceBackgroundUploadRegistration>,now:Long)=resourceWrite {backgroundUploads.install(claim,tasks,now)}
    override suspend fun completeBackgroundUpload(mapping:ResourceBackgroundUploadMapping,result:ResourceBackgroundUploadResult?,now:Long)=resourceWrite {backgroundUploads.complete(mapping,result,now)}
    override suspend fun recoverResourceUploadClaims(owner: String) = resourceWrite { resources.recoverClaims(owner) }
    override suspend fun claimResourceUpload(id: String,owner: String,now: Long) = resourceWrite { resources.claim(id,owner,now) }
    override suspend fun finishResourceUpload(claim: ResourceUploadClaim,session: ResourceUploadSession?,next: ResourceUploadAction,retryAt: Long,processingPoll: Boolean,preserveBudget: Boolean) = resourceWrite { resources.finish(claim,session,next,retryAt,processingPoll,preserveBudget) }
    override suspend fun failResourceUpload(claim: ResourceUploadClaim,error: ResourceUploadError,retryAt: Long?,serverRetryAt: Long,cancelled: Boolean,session: ResourceUploadSession?) = resourceWrite { resources.fail(claim,error,retryAt,serverRetryAt,cancelled,session) }
    override suspend fun controlResourceUpload(id: String,paused: Boolean,retry: Boolean) = resourceWrite { resources.control(id,paused,retry) }
    override suspend fun resourceAssets() = access { resources.assets() }
    override suspend fun observeResourceVariant(read:MessageResourceRead,target:MediaDownloadTarget)=resourceWrite {retention.observe(read,target)}
    internal suspend fun resourceVariants(key:ResourceKey)=resourceWrite {retention.variants(key)}
    internal suspend fun resourceVariant(key:ResourceVariantKey)=resourceWrite {retention.variant(key)}
    internal suspend fun setVisibleResourceOriginalRetained(key:ResourceKey,retained:Boolean,policy:ResourceOriginalPolicy)=resourceWrite {retention.setVisibleOriginal(key,retained,policy)}
    internal suspend fun resourceCleanupSelection(keys:kotlinx.collections.immutable.PersistentList<ResourceKey>):SqliteResourceRetention.CleanupSelection {
        val context=kotlinx.coroutines.currentCoroutineContext()
        return resourceWrite {retention.cleanupSelection(keys) {context.ensureActive()}}
    }
    internal suspend fun resourceStoragePolicy(defaults:ResourceOriginalPolicy)=resourceWrite {storagePolicy.load(defaults).also(resources::seedDownloadAdmission)}
    internal suspend fun resourceDownloadAdmission(file:String,current:ResourceOriginalPolicy)=access {resources.downloadAdmission(file,current)}
    internal suspend fun setResourceStoragePolicy(value:ResourceOriginalPolicy)=resourceWrite {storagePolicy.save(value)}
    internal suspend fun setResourceRetained(key:ResourceVariantKey,retained:Boolean,policy:ResourceOriginalPolicy)=resourceWrite {retention.set(key,retained,policy)}
    internal suspend fun planUnavailableRetentionRelease(now:()->Long=System::currentTimeMillis):ResourceUnavailableRetentionPlan {
        val context=kotlinx.coroutines.currentCoroutineContext()
        return resourceWrite {retention.plan(now()) {context.ensureActive()}}
    }
    internal suspend fun releaseUnavailableRetention(plan:ResourceUnavailableRetentionPlan,now:()->Long=System::currentTimeMillis):ResourceUnavailableRetentionResult {
        val context=kotlinx.coroutines.currentCoroutineContext()
        return resourceWrite {retention.release(plan,now()) {context.ensureActive()}}
    }
    internal suspend fun resourceBytesRetained(bytes:Long,checksum:ResourceChecksum)=access {resources.retainedBytes(bytes,checksum)}
    internal suspend fun beginResourceDownload(id: String,bytes: Long,checksum: ResourceChecksum,policy: ResourceOriginalPolicy)=resourceWrite { resources.beginDownload(id,bytes,checksum,policy) }
    internal suspend fun publishResourceDownload(id: String,allocated: Long,policy: ResourceOriginalPolicy)=resourceWrite { resources.publishDownload(id,allocated,policy) }
    internal suspend fun recoverResourceDownload(id: String,allocated: Long)=resourceWrite { resources.recoverDownload(id,allocated) }
    internal suspend fun touchResourceDownload(id: String)=resourceWrite { resources.touchDownload(id) }
    internal suspend fun retireResourceCache(id: String)=resourceWrite { resources.retireCache(id) }
    internal suspend fun beginResourceCacheCleanup(expected:ResourceLocalFile)=resourceWrite { resources.beginCacheCleanup(expected) }
    override suspend fun resourceFiles() = access { resources.files() }
    override suspend fun beginResourceImport(asset: ResourceLocalAsset,policy: ResourceOriginalPolicy) = resourceWrite { resources.begin(asset,policy) }
    override suspend fun reserveResourceAllocation(file: String,allocatedBytes: Long,policy: ResourceOriginalPolicy) = resourceWrite { resources.reserve(file,allocatedBytes,policy) }
    override suspend fun publishResourceImport(asset: String,file: String,allocatedBytes: Long) = resourceWrite { resources.publish(asset,file,allocatedBytes) }
    override suspend fun markResourceFile(file: String,state: ResourceFileState) = resourceWrite { resources.markFile(file,state) }
    override suspend fun markResourceAssetUnavailable(asset: String) = resourceWrite { resources.unavailable(asset) }
    override suspend fun releaseResourceSelection(asset: String) = resourceWrite { resources.releaseSelection(asset) }
    override suspend fun resourceOriginal(selection: String?,upload: String?,profile: ProfileOriginalConsumer?) = access { resources.original(selection,upload,profile) }
    override suspend fun retireResourceFiles(excluding: kotlinx.collections.immutable.PersistentSet<String>) = resourceWrite { resources.retire(excluding) }
    override suspend fun deleteResourceFile(file: String) = resourceWrite { resources.delete(file) }
    override suspend fun prepareResourceUpload(id: String,asset: String,request: ResourceUploadRequest) = resourceWrite { resources.prepare(id,asset,request) }
    override suspend fun resourceUploads() = access { resources.uploads() }
    override suspend fun resourceUpload(id: String) = access { resources.upload(id) }
    override suspend fun saveResourceUploadSession(id: String,session: ResourceUploadSession) = resourceWrite { resources.save(id,session) }
    override suspend fun requestResourceUploadCancellation(id: String) = resourceWrite { resources.cancel(id) }
    override suspend fun confirmResourceUploadCancellation(id: String,session: ResourceUploadSession) = resourceWrite { resources.confirmCancel(id,session) }
    override suspend fun releaseResourceUploadSource(id: String) = resourceWrite { resources.release(id) }

    override suspend fun ownProfile() = access { ownProfile.read() }
    override suspend fun ownProfileWorks() = access { ownProfile.works() }
    override suspend fun ownProfileWork(operation:String): OwnProfileWork? = access {
        db.rawQuery("SELECT work FROM own_profile_operations WHERE id=?",arrayOf(operation)).use { rows->
            if(rows.moveToFirst()) Json.decodeFromString<OwnProfileWork>(rows.getString(0)).also {require(it.command.actor==account && it.command.operation==operation)} else null
        }
    }
    override suspend fun saveOwnProfile(profile: ProfileView) = resourceWrite { ownProfile.save(profile) }
    override suspend fun enqueueOwnProfile(command: OwnProfileCommand,replaces: String?) = enqueueOwnProfile(command, replaces, System.currentTimeMillis())
    override suspend fun enqueueOwnProfile(command: OwnProfileCommand, replaces: String?, now: Long) = resourceWrite {
        profileIntents.requireNoWaitingIntent()
        require(replaces==null || profileIntents.forOperation(replaces)==null) { "请通过原资料意图重新应用" }
        ownProfile.enqueue(command,replaces,now=now)
    }
    override suspend fun updateOwnProfile(expected: OwnProfileWork,updated: OwnProfileWork) = resourceWrite { profileClaims.update(expected,updated,System.currentTimeMillis());profileIntents.reconcile() }
    override suspend fun recoverOwnProfileClaimsAfterDrain(owner: String, now: Long) = resourceWrite { profileClaims.recover(owner, now) }
    override suspend fun claimOwnProfile(operation: String, owner: String, now: Long) = resourceWrite { profileClaims.claim(operation, owner, now).also { profileIntents.reconcile() } }
    override suspend fun deferOwnProfile(claim: OwnProfileOperationClaim, until: Long, code: String, attention: Boolean, nextAction: OperationWorkAction) = resourceWrite {
        profileClaims.defer(claim, until, code, attention, nextAction)
    }
    override suspend fun completeOwnProfile(claim: OwnProfileOperationClaim, receipt: OwnProfileResult.Receipt, now: Long) = resourceWrite {
        profileClaims.complete(claim, receipt, now); profileIntents.reconcile()
    }
    override suspend fun retryOwnProfile(operation: String, now: Long) = resourceWrite { profileClaims.retry(operation, now) }
    override suspend fun discardOwnProfileDraft(operation: String) = resourceWrite {
        val intent=profileIntents.forOperation(operation)
        if(intent==null) ownProfile.discard(operation) else profileIntents.discard(intent.id)
    }
    override suspend fun selectConversationResource(key: ResourceKey)=access { transaction {catalog.selectAttachment(key)} }
    override suspend fun isConversationResourceCurrent(selection: MessageAttachmentSelection)=access { transaction {catalog.currentAttachment(selection)} }
    override suspend fun addConversationImport(expected: ConversationDraft,attachment: ConversationImportedAttachment,now: Long)=resourceWrite {conversationDrafts.addImport(expected,attachment,now)}
    override suspend fun removeConversationImport(expected: ConversationDraft,id: String,now: Long)=resourceWrite {conversationDrafts.removeImport(expected,id,now)}
    override suspend fun reorderConversationResources(expected: ConversationDraft,ids: PersistentList<String>,now: Long)=resourceWrite {conversationDrafts.reorderResources(expected,ids,now)}
    private fun directPeerNow(room:RoomId):UserId? {
        if(revoked(room.value) || db.rawQuery("SELECT kind FROM room_kinds WHERE room=?",arrayOf(room.value)).use {it.moveToFirst() && it.getString(0)==RoomKind.Group.name}) return null
        return profilePresentations.peer(room) ?: directWorksNow().firstOrNull {it.room==room && it.status==DirectWorkStatus.Opened}?.command?.target
    }
    private fun sendingPolicyNow(room:RoomId)=ConversationSendingPolicy(directCapabilityNow(room)?.canSend,directPeerNow(room)?.let {profilePresentations.accountKind(room,it)})
    suspend fun conversationSendingPolicy(room:RoomId,viewer:UserId)=access {if(viewer==account) sendingPolicyNow(room) else ConversationSendingPolicy()}
    suspend fun directSendingPeer(room:RoomId,viewer:UserId)=access {if(viewer==account) directPeerNow(room) else null}
    /** Adopt only public classification; names, avatars and display leases remain memory-only. */
    suspend fun adoptDirectAccountKind(room:RoomId,value:ProfileReadResult.Available,expected:ProfileFenceSnapshot)=access {transaction {
        val profile=value.profile;val lease=profile.lease;val keys=persistentListOf(lease.key)
        if(!value.valid() || lease.actor!=account || lease.device!=device || profile.view.user!=directPeerNow(room) || profilePresentations.read(keys)!=expected) return@transaction false
        val floor=expected.floors[lease.key] ?: return@transaction false
        if(profile.view.revision<=floor.securityRevision || profile.view.revision<floor.minimumProfileRevision) return@transaction false
        val kind=profile.view.identity?.kind ?: return@transaction false
        profilePresentations.putAccountKind(room,profile.view.user,profile.view.revision,kind);true
    }}
    private fun directCapabilityNow(room:RoomId)=directSendingCapabilities.available(room)
    override suspend fun directSendingCapability(room:RoomId,viewer:UserId)=access {if(viewer==account) directCapabilityNow(room) else null}
    override suspend fun conversationDraft(room: RoomId) = resourceWrite { conversationDrafts.restore(room) }
    override suspend fun saveConversationText(expected: ConversationDraft,text: String,now: Long) = resourceWrite { conversationDrafts.saveText(expected,text,now) }
    override suspend fun saveConversationContent(expected: ConversationDraft,text: String,rich: MessageRichContent,now: Long) = resourceWrite { conversationDrafts.saveContent(expected,text,rich,now) }
    override suspend fun addConversationAttachment(room: RoomId,attachment: SendAttachment,now: Long) = resourceWrite { conversationDrafts.add(room,attachment,now) }
    override suspend fun removeConversationAttachment(expected: ConversationDraft,asset: String,now: Long) = resourceWrite { conversationDrafts.remove(expected,asset,now) }
    override suspend fun reorderConversationAttachments(expected: ConversationDraft,assets: PersistentList<String>,now: Long) = resourceWrite { conversationDrafts.reorder(expected,assets,now) }
    override suspend fun submitConversationDraft(expected: ConversationDraft,intent: SendIntent,now: Long): SendIntent = try {
        resourceWrite { conversationDrafts.submit(expected,intent,now) }
    } catch(error: kotlinx.coroutines.CancellationException) { throw error }
      catch(error: IllegalArgumentException) { throw ConversationDraftSubmissionRejected(error.message ?: "草稿无法提交") }
      catch(error: IllegalStateException) { throw ConversationDraftSubmissionRejected(error.message ?: "草稿无法提交") }
    override suspend fun sendIntents() = access { sendIntents.statuses() }
    override suspend fun enqueueSendIntent(intent: SendIntent,now: Long) = resourceWrite { sendIntents.enqueue(intent,now) }
    override suspend fun advanceSendIntents(now: Long) = resourceWrite { val before=changes();sendIntents.advance(now);changes()!=before }
    override suspend fun sendPreparationDeadline() = access { sendIntents.deadline() }
    override suspend fun resumeSendIntent(id: String,now: Long) = resourceWrite { sendIntents.resume(id,now) }
    override suspend fun replaceSendIntent(id: String,next: SendIntent,now: Long) = resourceWrite { sendIntents.replace(id,next,now) }
    override suspend fun discardSendIntent(id: String) = resourceWrite { sendIntents.discard(id) }
    override suspend fun profileIntents() = access { profileIntents.statuses() }
    override suspend fun enqueueProfileIntent(intent: ProfileIntent,now: Long) = resourceWrite { profileIntents.enqueue(intent,now) }
    override suspend fun advanceProfileIntents(now: Long) = resourceWrite { val before=changes();profileIntents.advance(now);changes()!=before }
    override suspend fun profilePreparationDeadline() = access { profileIntents.deadline() }
    override suspend fun resumeProfileIntent(id: String,now: Long) = resourceWrite { profileIntents.resume(id,now) }
    override suspend fun replaceProfileIntent(id: String,newId: String,newOperation: String,newUpload: String,revision: Long,now: Long) = resourceWrite { profileIntents.replace(id,newId,newOperation,newUpload,revision,now) }
    override suspend fun discardProfileIntent(id: String) = resourceWrite { profileIntents.discard(id) }
    override suspend fun nameWorks() = access { names.works() }
    override suspend fun nameWork(operation:String): NameWork? = access {
        db.rawQuery("SELECT work FROM name_operations WHERE id=?",arrayOf(operation)).use { rows->
            if(rows.moveToFirst()) Json.decodeFromString<NameWork>(rows.getString(0)).also {require(it.command.actor==account && it.command.operation==operation)} else null
        }
    }
    override suspend fun saveNameSnapshot(snapshot: NameSnapshot) = access { transaction { names.save(snapshot) } }
    override suspend fun enqueueName(command: NameCommand) = enqueueName(command, System.currentTimeMillis())
    override suspend fun enqueueName(command: NameCommand, now: Long) = access { transaction {
        require(now >= 0)
        (command.target as? NameTarget.Group)?.let { check(!revoked(it.room.value)) { "此会话已不可访问" } }
        names.enqueue(command).also { nameClaims.ensure(it, now) }
    } }
    override suspend fun updateName(expected: NameWork,updated: NameWork) = access { transaction { nameClaims.update(expected,updated,System.currentTimeMillis()) } }
    override suspend fun recoverNameClaimsAfterDrain(owner: String, now: Long) = access { transaction { nameClaims.recover(owner, now) } }
    override suspend fun claimName(operation: String, owner: String, now: Long) = access { transaction { nameClaims.claim(operation, owner, now) } }
    override suspend fun deferName(claim: NameOperationClaim, until: Long, code: String, attention: Boolean, nextAction: OperationWorkAction) = access {
        transaction { nameClaims.defer(claim, until, code, attention, nextAction) }
    }
    override suspend fun completeName(claim: NameOperationClaim, receipt: NameResult.Receipt, now: Long) = access { transaction { nameClaims.complete(claim, receipt, now) } }
    override suspend fun retryName(operation: String, now: Long) = access { transaction { nameClaims.retry(operation, now) } }
    override suspend fun cancelOrCloseName(operation: String, now: Long) = access { transaction { nameClaims.cancelOrClose(operation, now) } }
    override suspend fun groupAvatarIntents() = access { groupAvatarIntents.all() }
    override suspend fun groupAvatarIntent(id: String) = access { groupAvatarIntents.find(id) }
    override suspend fun enqueueImportedGroupAvatar(authority: GroupAvatarEditAuthority,command: GroupAvatarCommand,source: GroupAvatarImportPreparation,now: Long) = resourceWrite { groupAvatarIntents.enqueue(authority,command,null,now,serverImport=source) }
    override suspend fun enqueueGroupAvatar(authority: GroupAvatarEditAuthority,command: GroupAvatarCommand,upload: GroupAvatarUploadPreparation?,now: Long) = resourceWrite { groupAvatarIntents.enqueue(authority,command,upload,now) }
    override suspend fun prepareGroupAvatars(now: Long) = resourceWrite { groupAvatarIntents.prepare(now) }
    override suspend fun dueGroupAvatars(now: Long) = access { groupAvatarIntents.due(now) }
    override suspend fun claimGroupAvatar(id: String,now: Long) = resourceWrite { groupAvatarIntents.claim(id,now) }
    override suspend fun finishGroupAvatar(claim: GroupAvatarClaim,response: GroupAvatarCommandResponse,now: Long) = resourceWrite { groupAvatarIntents.finish(claim,response,now) }
    override suspend fun finishGroupAvatarRecovery(claim: GroupAvatarClaim,response: GroupAvatarRecoveryResponse,now: Long) = resourceWrite { groupAvatarIntents.finishRecovery(claim,response,now) }
    override suspend fun failGroupAvatar(claim: GroupAvatarClaim,issue: GroupAvatarIssue,retryAt: Long,attention: Boolean,serverRetryAt: Long) { resourceWrite { groupAvatarIntents.fail(claim,issue,retryAt,attention,serverRetryAt) } }
    override suspend fun retryGroupAvatar(id: String) = resourceWrite { groupAvatarIntents.retry(id) }
    override suspend fun requestGroupAvatarRecovery(id: String,action: GroupAvatarRecoveryAction) = resourceWrite { groupAvatarIntents.requestRecovery(id,action) }
    override suspend fun cancelGroupAvatar(id: String) = resourceWrite { groupAvatarIntents.cancel(id) }
    override suspend fun abandonGroupAvatar(id: String) = resourceWrite { groupAvatarIntents.abandon(id) }
    override suspend fun replaceGroupAvatar(id: String,authority: GroupAvatarEditAuthority,operation: String,upload: String,media: String,now: Long) = resourceWrite { groupAvatarIntents.replace(id,authority,operation,upload,media,now) }
    suspend fun profileFences(keys: PersistentList<ProfileKey>) = access { profilePresentations.read(keys) }
    override suspend fun relationshipWindow(viewer: UserId,request: RelationshipPageRequest,anchor: RelationshipAnchor,precedingCount: Int) = access {
        transaction { relationshipPages.window(viewer,request,anchor,precedingCount) }
    }
    override suspend fun relationshipPage(viewer: UserId,request: RelationshipPageRequest) = access { transaction { relationshipPages.page(viewer,request) } }
    override suspend fun processRelationshipSearchIndex(maximumUsers: Int) = access { transaction { relationshipPages.process(maximumUsers) } }
    suspend fun cachedLocalProfileDisplays(keys: PersistentList<ProfileKey>) = access {
        transaction { localProfileDisplays.load(keys) }
    }
    suspend fun readLocalProfileDisplays(keys: PersistentList<ProfileKey>, expected: ProfileFenceSnapshot) = access {
        require(keys.size <= 128 && keys.distinct().size == keys.size && keys.toSet() == expected.floors.keys)
        transaction { if (profilePresentations.read(keys) == expected) localProfileDisplays.load(keys) else null }
    }
    suspend fun clearLocalProfileDisplays() = access { transaction { localProfileDisplays.clear() }; signalLocalDisplay() }
    /** Accepted presentation facts only. Stale/foreign batches cannot partially change the journal. */
    suspend fun saveLocalProfileDisplays(results: PersistentList<ProfileReadResult>, expected: ProfileFenceSnapshot): Boolean = access {
        require(results.size <= 128 && results.map { it.key }.distinct().size == results.size)
        require(results.all { it.key in expected.floors })
        val saved = try { transaction {
            if (profilePresentations.read(expected.floors.keys.toPersistentList()) != expected) throw LocalDisplayRejected()
            for (result in results) {
                if (result is ProfileReadResult.Available) {
                    val profile = result.profile; val floor = expected.floors.getValue(result.key)
                    if (!result.valid() || profile.lease.actor != account || profile.lease.device != device ||
                        profile.view.revision < floor.minimumProfileRevision || profile.view.state == ProfileState.Active &&
                        (profile.view.revision <= floor.securityRevision || (profile.alias?.revision ?: 0) < floor.aliasRevision ||
                            (profile.groupName?.revision ?: 0) < floor.nicknameRevision)) throw LocalDisplayRejected()
                }
                if (!localProfileDisplays.adopt(result)) throw LocalDisplayRejected()
            }
            true
        } } catch (_: LocalDisplayRejected) { false }
        if (saved && results.any { it !is ProfileReadResult.Retryable }) signalLocalDisplay()
        saved
    }
    private class LocalDisplayRejected : Exception()
    override suspend fun groupAvatarFence(room: RoomId) = access { groupAvatars.fence(room) }
    override suspend fun sendHistory(room: RoomId,viewer: UserId,selection: SendHistorySelection,limit: Int) = access {transaction {outboxEchoes.history(room,viewer,selection,limit)}}
    override suspend fun favoriteMessages(viewer: UserId,selection: FavoriteMessageSelection,limit: Int) = access {transaction {favorites.read(viewer,selection,limit)}}
    override suspend fun messageSources(room: RoomId, viewer: UserId, ids: PersistentSet<MessageId>) = access {
        transaction { timeline.sources(room,viewer,ids) }
    }
    override suspend fun searchMessages(viewer: UserId, request: MessageSearchRequest) = access { transaction {search.search(viewer,request)} }
    override suspend fun processMessageSearchIndex(limit: Int) = access { transaction {search.process(limit)} }
    override suspend fun messageSearchProgress() = access {search.progress()}
    override suspend fun rebuildMessageSearchIndex() = access {transaction {search.rebuild()} }
    override suspend fun conversationTimeline(room: RoomId, viewer: UserId, selection: TimelineSelection, limit: Int) = access {
        transaction { timeline.read(room, viewer, selection, limit) }
    }
    override suspend fun locateTimelineMessage(room: RoomId, viewer: UserId, message: MessageId, before: Int, after: Int) = access {
        transaction { timeline.locate(room, viewer, message, before, after) }
    }
    override suspend fun locateTimelineActivity(room:RoomId,viewer:UserId,source:String,before:Int,after:Int)=access {
        transaction {timeline.locateActivity(room,viewer,source,before,after)}
    }
    private fun decodeTimelineMessage(rows: android.database.Cursor) = Message(
        MessageId(rows.getString(0)), RoomId(rows.getString(1)), UserId(rows.getString(2)), rows.getString(3), rows.getLong(4),
        withdrawn = rows.getInt(5) != 0, revision = rows.getLong(6), roomSequence = rows.getLong(11), timelineSequence = rows.getLong(7),
        forwardedFrom = if(rows.isNull(8)) null else ForwardAttribution(MessageId(rows.getString(8)), UserId(rows.getString(9))),
        redacted = rows.getInt(10) != 0, media = decodeStoredMessageMedia(rows.getString(1),rows.getString(12)),
        rich = storedMessageRich(rows.getString(3),rows.getString(13)))
    /** Compatibility/export snapshot. Interactive app publication must use appSnapshot(). */
    suspend fun snapshot(): ClientSnapshot = access {transaction {snapshotNow(true)}}
    /** Metadata publication without decoding or retaining committed message history. */
    suspend fun appSnapshot(): ClientSnapshot = access {transaction {snapshotNow(false)}}
    suspend fun observedAppSnapshot(): ObservedClientSnapshot = access {
        val snapshot=transaction {snapshotNow(false)}
        ObservedClientSnapshot(snapshot,projectionDiagnostics?.takeConversationCommit())
    }
    internal suspend fun localConversations(before: LocalConversationCursor?, limit: Int) = access {
        check(isReadOnly); transaction { SqliteLocalProjection(db, account).conversations(before, limit) }
    }
    internal suspend fun localMessages(room: RoomId, before: TimelineCursor?, limit: Int) = access {
        check(isReadOnly); transaction { SqliteLocalProjection(db, account).messages(room, before, limit) }
    }
    private fun snapshotNow(includeMessages: Boolean): ClientSnapshot {
        val messages = if(includeMessages) db.rawQuery("SELECT ${SqliteConversationTimeline.COLUMNS} FROM messages ORDER BY sequence,id", null).use { rows ->
            buildList { while (rows.moveToNext()) add(decodeTimelineMessage(rows)) }.toMutableList()
        } else mutableListOf()
        if(includeMessages) db.rawQuery("SELECT command,receipt,echo_created FROM outbox o WHERE NOT EXISTS(SELECT 1 FROM message_tombstones t WHERE t.id=o.echo_message AND t.room=o.room) ORDER BY o.rowid", null).use { rows ->
            while (rows.moveToNext()) {
                val command = MessageSendOperation.parseFrom(rows.getBlob(0))
                if (revoked(command.roomId)) continue
                val receipt = if (rows.isNull(1)) null else MessageSendOperationReceipt.parseFrom(rows.getBlob(1))
                val id = if (receipt?.hasAccepted() == true) receipt.accepted.messageId else command.clientMessageId
                if (messages.none { it.id.value == id }) messages.add(Message(MessageId(id), RoomId(command.roomId), UserId(command.senderUserId), command.text.ifEmpty { if(command.mediaIdsCount>0) "[附件]" else "" },
                    rows.getLong(2), when { receipt == null -> Delivery.Pending; receipt.hasAccepted() -> Delivery.Accepted; else -> Delivery.Failed }, revision = 0, media = MessageMedia(command.mediaIdsList.toPersistentList()),rich=MessageRichContent.fromCommand(command)))
            }
        }
        val rooms = db.rawQuery("SELECT id,title FROM rooms", null).use { rows ->
            buildMap { while (rows.moveToNext()) put(rows.getString(0), rows.getString(1)) }
        }
        val localDirect = directIdentities.all().associateBy { it.room }
        val peers = localDirect.mapValues { it.value.publicIdentity.user } + profilePresentations.peers()
        val grouped = messages.groupBy { it.roomId }
        val summaries = latestVisible.all(cursorNow().generation)
        val messageRooms=if(includeMessages) grouped.keys else db.rawQuery("SELECT DISTINCT room FROM messages UNION SELECT room FROM outbox WHERE room NOT IN (SELECT room FROM memberships WHERE member=0)",null).use {rows->
            buildSet {while(rows.moveToNext()) add(RoomId(rows.getString(0)))}
        }
        val conversationRooms = (rooms.keys.map { RoomId(it) } + messageRooms + localDirect.keys).distinct()
        val unreadCounts = readReceipts.unreadCounts(conversationRooms)
        val conversations = conversationRooms.map { id ->
            val summary = summaries[id]
            val latest = if(includeMessages) grouped[id]?.maxByOrNull {it.createdAt}?.let {it.text to it.createdAt} else if(summary==null) localPreview(id) else null
            val preference = personalStateNow(PersonalTarget.Conversation(id).key)?.target as? PersonalTarget.Conversation
            val kind = db.rawQuery("SELECT kind FROM room_kinds WHERE room=?", arrayOf(id.value)).use { if(it.moveToFirst()) RoomKind.valueOf(it.getString(0)) else RoomKind.Direct }
            Conversation(id, if(kind == RoomKind.Direct) "会话" else rooms[id.value]?.takeIf(String::isNotBlank) ?: "群聊", summary?.previewText ?: latest?.first.orEmpty(),
                updatedAt = (if(summary != null) summary.latest?.createdAt else latest?.second) ?: localDirect[id]?.roomCreatedAt ?: 0,
                unread = unreadCounts[id] ?: 0,
                historyIncomplete = roomCursorNow(id).historyIncomplete,
                kind = kind, peer = peers[id].takeIf { kind == RoomKind.Direct }, pinned = preference?.pinned ?: false, archived = preference?.archived ?: false, muted = (preference?.muteUntil ?: 0) > System.currentTimeMillis())
        }.sortedWith(compareByDescending<Conversation> { it.pinned }.thenByDescending { it.updatedAt }).toPersistentList()
        val contacts = db.rawQuery("SELECT id FROM contacts WHERE state='accepted' ORDER BY id", null).use { rows ->
            buildList { while (rows.moveToNext()) { val id = rows.getString(0); add(Contact(UserId(id), "联系人 ${id.takeLast(6)}", "")) } }.toPersistentList()
        }
        val relationships = db.rawQuery("SELECT id,state,requester,time FROM contacts WHERE state <> 'none' ORDER BY time DESC,id", null).use { rows ->
            buildList { while (rows.moveToNext()) add(Relationship(UserId(rows.getString(0)), RelationshipState.fromWire(rows.getString(1)),
                if(rows.isNull(2)) null else UserId(rows.getString(2)), rows.getLong(3))) }.toPersistentList()
        }
        val blocked = db.rawQuery("SELECT id,time FROM user_blocks WHERE blocked=1 ORDER BY time DESC,id", null).use { rows ->
            buildList { while (rows.moveToNext()) add(UserBlock(UserId(rows.getString(0)), rows.getLong(1))) }.toPersistentList()
        }
        val revokedRooms = db.rawQuery("SELECT room FROM memberships WHERE member=0", null).use { rows ->
            buildList { while (rows.moveToNext()) add(RoomId(rows.getString(0))) }.toPersistentSet()
        }
        val announcements = db.rawQuery("SELECT effect FROM group_announcements WHERE room NOT IN (SELECT room FROM memberships WHERE member=0)", null).use { rows ->
            buildList { while(rows.moveToNext()) { val effect = Json.decodeFromString<GroupMetadataEffect.Announcement>(rows.getString(0)); add(GroupAnnouncement(effect.room, effect.body, effect.revision, effect.updatedAt)) } }.toPersistentList()
        }
        val pins = db.rawQuery("SELECT p.effect FROM group_pins p JOIN messages m ON m.room=p.room AND m.id=p.message WHERE m.withdrawn=0 AND p.room NOT IN (SELECT room FROM memberships WHERE member=0)", null).use { rows ->
            buildList { while(rows.moveToNext()) { val effect = Json.decodeFromString<GroupMetadataEffect.Pin>(rows.getString(0)); if(effect.pinned) add(GroupPin(effect.room, effect.message, effect.sequence)) } }.toPersistentList()
        }
        return ClientSnapshot(sendIntents = sendIntents.statuses(),resourceImports = imports.all(),groupAvatarIntents = groupAvatarIntents.all(),groupAvatarGeneration = groupAvatars.generation(),profileIntents = profileIntents.statuses(),ownProfile = ownProfile.read(),ownProfileOperations = ownProfile.works(),nameOperations = names.works(),nameSnapshots = names.snapshots(),presentationGeneration = profilePresentations.generation(),readCheckpoints = readReceipts.checkpoints(),readOperations = readReceipts.works(),directReads = readReceipts.visible(),forwardOperations = forwardWorksNow(), reactions = reactionSummariesNow(), reactionOperations = reactionWorksNow(), mutationOperations = mutationWorksNow(), personalOperations = personalWorksNow(), personalStates = (personalStatesNow("personal_confirmed") + personalStatesNow("personal_projections")).groupBy { it.target.key }.values.map { values -> values.maxBy { it.revision } }.toPersistentList(), conversations = conversations, contacts = contacts, messages = messages.toPersistentList(), directOperations = directWorksNow(),localDirectMessages = localDirectMessages.all(),
            relationships = relationships, blockedUsers = blocked, socialOperations = socialWorksNow(), socialProposals = socialProposalsNow(), groupCreations = groupWorksNow(), membershipOperations = membershipWorksNow(), capabilityOperations = capabilityWorksNow(), invitationOperations = invitationWorksNow(), moderationOperations = moderationWorksNow(), administrationOperations = administrationWorksNow(), moderationFacts = moderationFactsNow(), rolePolicies = rolePoliciesNow(), memberAccess = memberAccessNow(), groupPolicyStates = policyRecovery.states(), preferences = preferenceSnapshotsNow(), preferenceOperations = preferenceWorksNow(), announcements = announcements, pins = pins, revokedRooms = revokedRooms)
    }
    private fun project(event: String, kind: String, bytes: ByteArray, snapshot: Boolean = false, roomSequence: Long? = null, origin: String = event) {
        val value = Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
        if(snapshot && kind in setOf("message", "message_reaction", "moderation", "group_capability")) throw ClientFailure.Protocol()
        if(kind=="direct_sending_capability") {
            if(roomSequence!=null) throw ClientFailure.Protocol()
            directSendingCapabilities.project(DirectSendingCapability.decode(value));return
        }
        if(kind=="timeline_activity") {
            if(roomSequence!=null) throw ClientFailure.Protocol()
            timelineActivities.project(TimelineActivity.decode(origin,value));return
        }
        if(kind == "room_head") {accountRoomHeads.project(AccountRoomHead.decode(value));return}
        if(kind == "group_capability" && value["room_id"]?.jsonPrimitive?.contentOrNull?.let { revoked(RoomId(it).value) } == true) return
        if(kind == "group_capability" && value["event_type"]?.jsonPrimitive?.content=="group.avatar_changed") {
            groupAvatars.project(GroupAvatarEffect.decode(origin,value,expectedSequence=roomSequence));return
        }
        if(kind in setOf("room","membership") || kind=="group_capability" && value["event_type"]?.jsonPrimitive?.content in setOf("group.member_role_changed","group.role_permissions_changed"))
            value["room_id"]?.jsonPrimitive?.contentOrNull?.let { groupAvatars.invalidate(RoomId(it).value) }
        if(profilePresentations.project(origin,kind,value,roomSequence)) {
            if (!snapshot && kind == "profile_invalidation") directIdentities.pruneSecurity(UserId(value.getValue("user_id").jsonPrimitive.content))
            return
        }
        if(kind in setOf("own_read_watermark","direct_read_receipt")) {
            readReceipts.project(kind,value)
            db.execSQL("INSERT OR REPLACE INTO records VALUES (?,?,?,?)",arrayOf(event,kind,bytes,RoomId(value.required("room_id")).value));return
        }
        val type = value["event_type"]?.jsonPrimitive?.content
        val scopedRoom = value["room_id"]?.jsonPrimitive?.contentOrNull?.let { RoomId(it).value }
        if (kind == "room" || kind == "membership") {
            val room = scopedRoom ?: throw ClientFailure.Protocol()
            val revision = value["membership_revision"]?.jsonPrimitive?.longOrNull ?: throw ClientFailure.Protocol()
            if (revision <= 0 || type !in setOf("room.created", "membership_changed", "group.ownership_transferred", "group.dissolved")) throw ClientFailure.Protocol()
            val action = value["action"]?.jsonPrimitive?.content
            val target = value["target_user_id"]?.jsonPrimitive?.contentOrNull?.let { UserId(it) }
            if (type == "membership_changed" && (target == null || action !in setOf("add", "remove"))) throw ClientFailure.Protocol()
            val own = (kind == "room" && type == "room.created") || type == "group.dissolved" || target == account
            val viewerRevision = if (snapshot) value["viewer_membership_revision"]?.jsonPrimitive?.longOrNull else null
            val ownRevision = viewerRevision ?: revision.takeIf { own }
            val isMember = if (viewerRevision != null) value["viewer_is_member"]?.jsonPrimitive?.booleanOrNull ?: throw ClientFailure.Protocol()
                else type != "group.dissolved" && !(own && action == "remove")
            val source = if (viewerRevision != null) value.required("viewer_membership_source_event_id") else event
            if (ownRevision != null) {
                if (ownRevision <= 0) throw ClientFailure.Protocol()
                val previous = db.rawQuery("SELECT revision,source,member FROM memberships WHERE room=?", arrayOf(room)).use {
                    if (it.moveToFirst()) Triple(it.getLong(0), it.getString(1), it.getInt(2) == 1) else null
                }
                if (previous != null && ownRevision < previous.first) return
                if (previous != null && ownRevision == previous.first && ((previous.second != "state" && source != previous.second) || isMember != previous.third)) throw ClientFailure.Protocol()
                if(previous != null && ownRevision > previous.first && isMember) { purgeMetadata(room);catalog.invalidateRoom(room) }
                db.execSQL("INSERT OR REPLACE INTO memberships VALUES (?,?,?,?)", arrayOf<Any>(room, ownRevision, source, if (isMember) 1 else 0))
                if(isMember && (previous == null || !previous.third || ownRevision > previous.first)) roomDirectory.enqueue(room)
                if (!isMember) {
                    roomDirectory.discard(room)
                    accountRoomHeads.deny(room)
                    catalog.invalidateRoom(room)
                    purgeMetadata(room)
                    db.execSQL("DELETE FROM message_tombstones WHERE room=?", arrayOf(room)); db.execSQL("DELETE FROM messages WHERE room=?", arrayOf(room)); db.execSQL("DELETE FROM rooms WHERE id=?", arrayOf(room))
                    db.execSQL("DELETE FROM direct_sending_capabilities WHERE room=?",arrayOf(room));db.execSQL("DELETE FROM timeline_activities WHERE room=?",arrayOf(room));db.execSQL("DELETE FROM records WHERE room=?", arrayOf(room)); db.execSQL("DELETE FROM conversation_state WHERE room=?", arrayOf(room))
                    return
                }
            }
            if (revoked(room)) return
            if(kind == "membership" && type in setOf("membership_changed","group.ownership_transferred")) {
                MemberAccessEffect.decode(origin,kind,value,RoomId(room),roomSequence).forEach(::projectMemberAccess)
            }
            policyRecovery.observeProfile(RoomId(room),revision,origin.substringBefore('/'))
            val title = value.required("title")
            db.execSQL("INSERT OR REPLACE INTO rooms VALUES (?,?)", arrayOf(room, title))
        } else if (scopedRoom != null && revoked(scopedRoom)) return
        if(kind == "group_capability" && type == "group.role_permissions_changed") {
            projectRolePolicy(RolePolicyEffect.decode(origin,value,RoomId(scopedRoom ?: throw ClientFailure.Protocol()),roomSequence ?: throw ClientFailure.Protocol()))
            return
        }
        if(kind == "group_capability" && type == "group.member_role_changed") {
            MemberAccessEffect.decode(origin,kind,value,RoomId(scopedRoom ?: throw ClientFailure.Protocol()),roomSequence ?: throw ClientFailure.Protocol()).forEach(::projectMemberAccess)
            return
        }
        if(kind == "moderation") {
            val fact = MemberMuteFact.decode(event,value,RoomId(scopedRoom ?: throw ClientFailure.Protocol()),roomSequence ?: throw ClientFailure.Protocol())
            val old = db.rawQuery("SELECT effect FROM moderation_facts WHERE source=?",arrayOf(fact.source)).use { if(it.moveToFirst()) Json.decodeFromString<MemberMuteFact>(it.getString(0)) else null }
            if(old != null && old != fact) throw ClientFailure.Protocol()
            if(old == null) db.execSQL("INSERT INTO moderation_facts VALUES (?,?,?)",arrayOf(fact.source,fact.room.value,Json.encodeToString(fact)))
            return // Keep only the privacy-safe fact; never persist extra audit/report fields.
        }
        if(kind == "group_capability" && type in setOf("group.announcement_changed", "message.pinned_changed")) {
            projectMetadata(GroupMetadataEffect.decode(event, value, RoomId(scopedRoom ?: throw ClientFailure.Protocol()), roomSequence ?: throw ClientFailure.Protocol()))
        }
        if (kind == "direct_room_profile") {
            val descriptor = DirectProfileDescriptor.decode(value)
            directIdentities.validate(descriptor.room, descriptor.peer, descriptor.createdAt)
            profilePresentations.direct(value,account)
            db.execSQL("INSERT OR IGNORE INTO rooms VALUES (?,?)",arrayOf(scopedRoom ?: throw ClientFailure.Protocol(),"会话"))
            return // Discovery strings are not display grants and never enter the raw-record cache.
        }
        if (kind == "relationship") {
            val target = UserId(value.required("target_user_id")).value
            val state = value.required("state")
            val requester = value["requested_by_user_id"]?.jsonPrimitive?.contentOrNull?.let { UserId(it).value }
            val time = value["updated_at_ms"]?.jsonPrimitive?.longOrNull ?: throw ClientFailure.Protocol()
            if (state !in setOf("none", "pending", "accepted") || (state == "pending") != (requester != null) || time < 0) throw ClientFailure.Protocol()
            if (target == account.value || (requester != null && requester != account.value && requester != target)) throw ClientFailure.Protocol()
            db.execSQL("INSERT OR REPLACE INTO contacts VALUES (?,?,?,?)", arrayOf<Any?>(target, state, requester, time))
        }
        PreferenceKind.entries.firstOrNull { it.projection == kind }?.let { preferenceKind ->
            val (snapshotValue, time) = AccountPreferenceClient.projection(account, preferenceKind, value)
            val previous = db.rawQuery("SELECT snapshot,time FROM preference_projections WHERE kind=?", arrayOf(preferenceKind.name)).use {
                if(it.moveToFirst()) Json.decodeFromString<PreferenceSnapshot>(it.getString(0)) to it.getLong(1) else null
            }
            if(previous == null || snapshotValue.revision > previous.first.revision) {
                db.execSQL("INSERT OR REPLACE INTO preference_projections VALUES (?,?,?)", arrayOf<Any>(preferenceKind.name, Json.encodeToString(snapshotValue), time))
            } else if(snapshotValue.revision == previous.first.revision && (snapshotValue != previous.first || time != previous.second)) throw ClientFailure.Protocol()
            savePreferenceNow(snapshotValue)
        }
        if (kind == "user_block") {
            val target = UserId(value.required("target_user_id"))
            val blocked = value["is_blocked"]?.jsonPrimitive?.booleanOrNull ?: throw ClientFailure.Protocol()
            val time = value["updated_at_ms"]?.jsonPrimitive?.longOrNull ?: throw ClientFailure.Protocol()
            if (time < 0 || target == account) throw ClientFailure.Protocol()
            db.execSQL("INSERT OR REPLACE INTO user_blocks VALUES (?,?,?)", arrayOf<Any>(target.value, if(blocked) 1 else 0, time))
        }
        if(kind in setOf("conversation_state", "message_favorite")) {
            val state = PersonalState.projection(kind, value)
            savePersonalStateNow("personal_projections", state)
        }
        if(kind == "message_reaction") {
            projectReaction(ReactionEffect.decode(event, value, roomSequence ?: throw ClientFailure.Protocol()))
        }
        if (kind == "message") {
            val id = MessageId(value.required("message_id")).value; val room = RoomId(value.required("room_id")).value
            fun number(fields: JsonObject, key: String): Long = fields[key]?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
            fun text(fields: JsonObject, key: String): String = fields[key]?.jsonPrimitive?.takeIf { it.isString }?.content ?: throw ClientFailure.Protocol()
            val revision = number(value, "message_revision"); if(revision <= 0) throw ClientFailure.Protocol()
            var priorSourceText: String? = null
            val prior = db.rawQuery("SELECT room,sender,text,time,revision,sequence,withdrawn,forwarded_message,forwarded_sender,(SELECT redacted FROM message_tombstones t WHERE t.id=messages.id),accepted_sequence,media,rich,source_text FROM messages WHERE id=?", arrayOf(id)).use {
                if(it.moveToFirst()) {priorSourceText=if(it.isNull(13)) null else it.getString(13);Message(MessageId(id), RoomId(it.getString(0)), UserId(it.getString(1)), it.getString(2), it.getLong(3), withdrawn = it.getInt(6) != 0, revision = it.getLong(4), roomSequence = it.getLong(10), timelineSequence = it.getLong(5), forwardedFrom = if(it.isNull(7)) null else ForwardAttribution(MessageId(it.getString(7)), UserId(it.getString(8))), redacted = it.getInt(9) != 0, media = decodeStoredMessageMedia(it.getString(0),it.getString(11)),rich=storedMessageRich(it.getString(2),it.getString(12))) } else null
            }
            if(prior != null && prior.roomId.value != room) throw ClientFailure.Protocol()
            val removal = db.rawQuery("SELECT room,revision,redacted FROM message_tombstones WHERE id=?", arrayOf(id)).use {
                if(it.moveToFirst()) { if(it.getString(0) != room) throw ClientFailure.Protocol(); it.getLong(1) to (it.getInt(2) != 0) } else 0L to false
            }
            val tombstone = removal.first
            when(type) {
                "message.accepted" -> {
                    if(tombstone > 0 || prior?.withdrawn == true) {
                        if(revision > maxOf(tombstone,prior?.revision ?: 0)) throw ClientFailure.Protocol()
                        db.execSQL("INSERT OR REPLACE INTO records VALUES (?,?,?,?)",arrayOf(event,kind,bytes,scopedRoom));return
                    }
                    val sender = UserId(value.required("sender_user_id")).value
                    val body = text(value, "text")
                    val media = decodeMessageMedia(RoomId(room),value)
                    val rich = MessageRichContent.decodeProjection(body,value)
                    val acceptedSequence = if(value.containsKey("room_sequence")) number(value,"room_sequence") else roomSequence ?: throw ClientFailure.Protocol()
                    if(acceptedSequence <= 0 || roomSequence != null && roomSequence != acceptedSequence) throw ClientFailure.Protocol()
                    val sequence = if(value.containsKey("timeline_sequence")) number(value, "timeline_sequence") else number(value, "room_sequence")
                    if(prior != null && (prior.timelineSequence != sequence || prior.roomSequence != 0L && prior.roomSequence != acceptedSequence)) throw ClientFailure.Protocol()
                    val time = number(value, "server_created_at_ms")
                    if(prior != null && (prior.sender.value != sender || prior.createdAt != time)) throw ClientFailure.Protocol()
                    if(sequence <= 0 || time < 0 || (body.isEmpty() && media.ids.isEmpty())) throw ClientFailure.Protocol()
                    fun origin(key: String): String? = value[key]?.takeUnless { it is JsonNull }?.let { text(value, key) }
                    val originMessage = origin("forwarded_from_message_id"); val originSender = origin("forwarded_from_user_id")
                    if((originMessage == null) != (originSender == null)) throw ClientFailure.Protocol()
                    val attribution = originMessage?.let { ForwardAttribution(MessageId(it), UserId(requireNotNull(originSender))) }
                    val displayed = body.ifEmpty { "[附件]" }
                    if(prior?.revision == revision) {
                        if(prior.sender.value != sender || prior.text != displayed || priorSourceText != null && priorSourceText != body || prior.createdAt != time || prior.timelineSequence != sequence || prior.forwardedFrom != attribution || prior.media != null && prior.media != media || prior.rich != null && prior.rich != rich) throw ClientFailure.Protocol()
                    } else if(prior == null || revision > prior.revision) db.execSQL("INSERT OR REPLACE INTO messages (id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn,forwarded_message,forwarded_sender,media,rich) VALUES (?,?,?,?,?,?,?,?,0,?,?,?,?)", arrayOf(id, room, sender, displayed, time, revision, sequence, acceptedSequence, attribution?.message?.value, attribution?.sender?.value, media.payload().toString(),rich.payload().toString()))
                    db.execSQL("UPDATE messages SET accepted_sequence=? WHERE id=? AND room=? AND accepted_sequence=0",arrayOf<Any>(acceptedSequence,id,room))
                    db.execSQL("UPDATE messages SET media=? WHERE id=? AND room=? AND revision=? AND media IS NULL AND withdrawn=0",arrayOf(media.payload().toString(),id,room,revision))
                    db.execSQL("UPDATE messages SET rich=? WHERE id=? AND room=? AND revision=? AND rich IS NULL AND withdrawn=0",arrayOf(rich.payload().toString(),id,room,revision))
                    db.execSQL("UPDATE messages SET source_text=? WHERE id=? AND room=? AND revision=? AND source_text IS NULL AND withdrawn=0",arrayOf<Any>(body,id,room,revision))
                }
                "message.edited" -> {
                    if(tombstone > 0 || prior?.withdrawn == true) {
                        if(revision > maxOf(tombstone, prior?.revision ?: 0)) throw ClientFailure.Protocol()
                    } else {
                        val envelope = value["replacement"]?.takeUnless { it is JsonNull }?.jsonObject
                        if(envelope != null) {
                            val replacement = envelope["state"]?.jsonObject ?: throw ClientFailure.Protocol()
                            if(replacement["media_ids"] !is JsonArray || replacement["media_presentations"] !is JsonArray) throw ClientFailure.Protocol()
                            if(number(envelope, "schema_version") != 1L || number(envelope, "accepted_membership_revision") <= 0 ||
                                replacement.required("event_type") != "message.accepted" || MessageId(replacement.required("message_id")).value != id || RoomId(replacement.required("room_id")).value != room || number(replacement, "message_revision") != revision) throw ClientFailure.Protocol()
                            MessageRichContent.decodeProjection(text(replacement,"text"),replacement,complete=true)
                            project(envelope.required("accepted_event_id"), "message", replacement.toString().toByteArray())
                        } else {
                            val body = text(value, "text"); if(body.isEmpty() || prior == null || revision > prior.revision + 1) throw ClientFailure.Protocol()
                            if(revision == prior.revision && (body != prior.text || priorSourceText != null && priorSourceText != body || prior.rich?.entities?.isNotEmpty()==true)) throw ClientFailure.Protocol()
                            db.execSQL("UPDATE messages SET text=?,source_text=?,revision=?,rich=? WHERE id=? AND room=? AND revision<? AND withdrawn=0", arrayOf(body, body, revision, prior.rich?.copy(entities=kotlinx.collections.immutable.persistentListOf())?.payload()?.toString(), id, room, revision))
                        }
                    }
                }
                "message.withdrawn", "message.redacted" -> {
                    if(prior != null && !prior.withdrawn && revision <= prior.revision) throw ClientFailure.Protocol()
                    if(revision == tombstone && removal.second != (type == "message.redacted")) throw ClientFailure.Protocol()
                    val redacted = removal.second || type == "message.redacted"
                    if(revision > tombstone) db.execSQL("INSERT OR REPLACE INTO message_tombstones (id,room,revision,redacted) VALUES (?,?,?,?)", arrayOf<Any>(id,room,revision,if(redacted) 1 else 0))
                    db.execSQL("UPDATE messages SET text=?,source_text='',revision=?,withdrawn=1,forwarded_message=NULL,forwarded_sender=NULL,media='{}',rich='{}' WHERE id=? AND room=? AND revision<?", arrayOf<Any>(if(redacted) "消息已由管理员移除" else "消息已撤回",revision,id,room,revision))
                }
                else -> throw ClientFailure.Protocol()
            }
            catalog.projectMessage(id)
        }
        // Preserve all projection kinds for later materialization, never silently discard their payload.
        db.execSQL("INSERT OR REPLACE INTO records VALUES (?,?,?,?)", arrayOf(event, kind, bytes, scopedRoom))
    }
    private fun projectReaction(effect: ReactionEffect) {
        val key = arrayOf(effect.message.value, effect.actor.value, effect.reaction)
        val priorEffect = db.rawQuery("SELECT effect FROM reaction_effects WHERE source=? AND message=? AND actor=? AND reaction=?", arrayOf(effect.source, *key)).use {
            if(it.moveToFirst()) Json.decodeFromString<ReactionEffect>(it.getString(0)) else null
        }
        if(priorEffect != null) { if(priorEffect != effect) throw ClientFailure.Protocol(); return }
        db.rawQuery("SELECT room FROM messages WHERE id=? UNION SELECT room FROM message_tombstones WHERE id=?", arrayOf(effect.message.value, effect.message.value)).use {
            while(it.moveToNext()) if(it.getString(0) != effect.room.value) throw ClientFailure.Protocol()
        }
        val current = db.rawQuery("SELECT effect FROM reaction_versions WHERE message=? AND actor=? AND reaction=?", key).use {
            if(it.moveToFirst()) Json.decodeFromString<ReactionEffect>(it.getString(0)) else null
        }
        if(current != null && (current.room != effect.room || current.sequence == effect.sequence && current != effect)) throw ClientFailure.Protocol()
        val encoded = Json.encodeToString(effect)
        db.execSQL("INSERT INTO reaction_effects VALUES (?,?,?,?,?,?)", arrayOf(effect.source, *key, effect.room.value, encoded))
        if(current == null || current.sequence < effect.sequence) db.execSQL("INSERT OR REPLACE INTO reaction_versions VALUES (?,?,?,?,?,?)", arrayOf<Any>(*key, effect.room.value, if(effect.present) 1 else 0, encoded))
    }
    private fun projectMetadata(effect: GroupMetadataEffect) {
        val kind = if(effect is GroupMetadataEffect.Announcement) "announcement" else "pin"
        val previous = db.rawQuery("SELECT effect FROM group_metadata_effects WHERE room=? AND source=? AND kind=?", arrayOf(effect.room.value, effect.source, kind)).use {
            if(it.moveToFirst()) Json.decodeFromString<GroupMetadataEffect>(it.getString(0)) else null
        }
        if(previous != null) { if(previous != effect) throw ClientFailure.Protocol(); return }
        db.execSQL("INSERT INTO group_metadata_effects VALUES (?,?,?,?)", arrayOf(effect.room.value, effect.source, kind, Json.encodeToString<GroupMetadataEffect>(effect)))
        when(effect) {
            is GroupMetadataEffect.Announcement -> {
                val current = db.rawQuery("SELECT effect FROM group_announcements WHERE room=?", arrayOf(effect.room.value)).use { if(it.moveToFirst()) Json.decodeFromString<GroupMetadataEffect.Announcement>(it.getString(0)) else null }
                if(current != null) {
                    if(current.revision > effect.revision) return
                    if(current.revision == effect.revision && current != effect) throw ClientFailure.Protocol()
                }
                db.execSQL("INSERT OR REPLACE INTO group_announcements VALUES (?,?)", arrayOf(effect.room.value, Json.encodeToString(effect)))
            }
            is GroupMetadataEffect.Pin -> {
                val current = db.rawQuery("SELECT effect FROM group_pins WHERE room=? AND message=?", arrayOf(effect.room.value, effect.message.value)).use { if(it.moveToFirst()) Json.decodeFromString<GroupMetadataEffect.Pin>(it.getString(0)) else null }
                if(current != null) {
                    if(current.source == effect.source || current.sequence == effect.sequence) { if(current != effect) throw ClientFailure.Protocol(); return }
                    if(current.sequence > effect.sequence) return
                }
                db.execSQL("INSERT OR REPLACE INTO group_pins VALUES (?,?,?)", arrayOf(effect.room.value, effect.message.value, Json.encodeToString(effect)))
            }
        }
    }
    override suspend fun discoverPolicyRecovery(limit: Int) = access { transaction { policyRecovery.discover(limit) } }
    override suspend fun duePolicyRecovery(now: Long,limit: Int) = access { policyRecovery.due(now,limit) }
    override suspend fun requestPolicyRecovery(room: RoomId,resume: Boolean) = access { transaction { policyRecovery.request(room,resume) } }
    override suspend fun completePolicyRecovery(request: PolicyRecoveryRequest,baseline: GroupPolicies) = access { transaction { policyRecovery.complete(request,baseline) } }
    override suspend fun failPolicyRecovery(request: PolicyRecoveryRequest,disposition: PolicyRecoveryDisposition) = access { transaction { policyRecovery.failure(request,disposition) } }
    private fun rolePoliciesNow(): PersistentList<RolePolicyEffect> = db.rawQuery("SELECT effect FROM role_policy_observations WHERE room NOT IN (SELECT room FROM memberships WHERE member=0) ORDER BY room,role",null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<RolePolicyEffect>(rows.getString(0))) }.toPersistentList()
    }
    private fun memberAccessNow(): PersistentList<MemberAccessEffect> = db.rawQuery("SELECT effect FROM member_access_observations WHERE room NOT IN (SELECT room FROM memberships WHERE member=0) ORDER BY room,user",null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<MemberAccessEffect>(rows.getString(0))) }.toPersistentList()
    }
    private fun projectRolePolicy(effect: RolePolicyEffect) {
        val prior = db.rawQuery("SELECT effect FROM role_policy_effects WHERE source=? AND room=?",arrayOf(effect.source,effect.room.value)).use { if(it.moveToFirst()) Json.decodeFromString<RolePolicyEffect>(it.getString(0)) else null }
        if(prior != null) { if(prior != effect) throw ClientFailure.Protocol();return }
        db.execSQL("INSERT INTO role_policy_effects VALUES (?,?,?)",arrayOf(effect.source,effect.room.value,Json.encodeToString(effect)))
        if(!policyRecovery.validateEvent(effect)) return
        val current = db.rawQuery("SELECT effect FROM role_policy_observations WHERE room=? AND role=?",arrayOf(effect.room.value,effect.role.name)).use { if(it.moveToFirst()) Json.decodeFromString<RolePolicyEffect>(it.getString(0)) else null }
        if(current != null) {
            if(current.revision > effect.revision) return
            if(current.revision == effect.revision && current != effect) throw ClientFailure.Protocol()
        }
        db.execSQL("INSERT OR REPLACE INTO role_policy_observations VALUES (?,?,?)",arrayOf(effect.room.value,effect.role.name,Json.encodeToString(effect)))
    }
    private fun projectMemberAccess(effect: MemberAccessEffect) {
        val matches = db.rawQuery("SELECT effect FROM member_access_effects WHERE (source=? AND user=?) OR (room=? AND user=? AND revision=?)",arrayOf(effect.source,effect.user.value,effect.room.value,effect.user.value,effect.revision.toString())).use { rows ->
            buildList { while(rows.moveToNext()) add(Json.decodeFromString<MemberAccessEffect>(rows.getString(0))) }
        }
        if(matches.any { !it.sameMeaning(effect) || (it.sequence != null && effect.sequence != null && it.sequence != effect.sequence) }) throw ClientFailure.Protocol()
        val joined = effect.copy(sequence = matches.firstOrNull()?.sequence ?: effect.sequence)
        db.execSQL("INSERT OR REPLACE INTO member_access_effects VALUES (?,?,?,?,?)",arrayOf<Any>(joined.source,joined.user.value,joined.room.value,joined.revision,Json.encodeToString(joined)))
        val current = db.rawQuery("SELECT effect FROM member_access_observations WHERE room=? AND user=?",arrayOf(effect.room.value,effect.user.value)).use { if(it.moveToFirst()) Json.decodeFromString<MemberAccessEffect>(it.getString(0)) else null }
        if(current != null && current.revision > joined.revision) return
        db.execSQL("INSERT OR REPLACE INTO member_access_observations VALUES (?,?,?)",arrayOf(joined.room.value,joined.user.value,Json.encodeToString(joined)))
    }
    private fun purgeMetadata(room: String) {
        profilePresentations.purge(room)
        groupAvatars.purge(room)
        listOf("group_announcements", "group_pins", "group_metadata_effects", "moderation_facts", "role_policy_effects", "role_policy_observations", "member_access_effects", "member_access_observations", "policy_baselines", "policy_recovery", "policy_denials", "policy_profile_fences").forEach { db.execSQL("DELETE FROM $it WHERE room=?", arrayOf(room)) }
    }
    private fun retainMetadataForSnapshot() {
        db.execSQL("CREATE TEMP TABLE IF NOT EXISTS retained_timeline_activities AS SELECT * FROM timeline_activities WHERE 0")
        db.execSQL("DELETE FROM retained_timeline_activities")
        db.execSQL("INSERT INTO retained_timeline_activities SELECT * FROM timeline_activities")
        db.execSQL("CREATE TEMP TABLE IF NOT EXISTS metadata_grants (room TEXT PRIMARY KEY, revision INTEGER NOT NULL)")
        db.execSQL("DELETE FROM metadata_grants")
        db.execSQL("INSERT INTO metadata_grants SELECT room,revision FROM memberships WHERE member=1")
    }
    private fun finishMetadataSnapshot() {
        directIdentities.pruneSecurity()
        db.rawQuery("SELECT source,room,sequence,kind,time FROM retained_timeline_activities WHERE room IN (SELECT id FROM rooms)",null).use {rows->
            while(rows.moveToNext()) timelineActivities.project(SqliteTimelineActivities.decode(rows))
        }
        db.execSQL("DELETE FROM retained_timeline_activities")
        groupAvatars.finishSnapshot()
        listOf("group_announcements", "group_pins", "group_metadata_effects", "moderation_facts", "role_policy_effects", "role_policy_observations", "member_access_effects", "member_access_observations", "policy_baselines", "policy_recovery").forEach { table ->
            db.execSQL("DELETE FROM $table WHERE room NOT IN (SELECT m.room FROM memberships m JOIN metadata_grants p ON p.room=m.room AND p.revision=m.revision WHERE m.member=1)")
        }
        db.execSQL("DELETE FROM presentation_floors WHERE room <> '' AND room NOT IN (SELECT m.room FROM memberships m JOIN metadata_grants p ON p.room=m.room AND p.revision=m.revision WHERE m.member=1)")
        db.execSQL("DELETE FROM nickname_effects WHERE room NOT IN (SELECT m.room FROM memberships m JOIN metadata_grants p ON p.room=m.room AND p.revision=m.revision WHERE m.member=1)")
        db.execSQL("DELETE FROM metadata_grants")
    }
    private fun revoked(room: String): Boolean = db.rawQuery("SELECT member FROM memberships WHERE room=?", arrayOf(room)).use { it.moveToFirst() && it.getInt(0) == 0 }
    private fun clearProjections() {
        favorites.clearProjections()
        catalog.snapshotChanged()
        groupAvatars.clearEpochs()
        profilePresentations.invalidate() // Global security/alias floors survive a personal snapshot replacement.
        listOf("account_room_heads", "direct_profile_bindings", "direct_account_kinds", "direct_sending_capabilities", "timeline_activities", "records", "reaction_versions", "reaction_effects", "messages", "message_tombstones", "rooms", "memberships", "contacts", "user_blocks", "conversation_state", "room_cursors", "latest_visible", "room_observed_heads", "room_kinds", "preference_projections", "personal_projections", "policy_profile_fences", "policy_denials", "direct_read_projections", "own_read_projections", "read_room_state").forEach { db.execSQL("DELETE FROM $it") }
    }
    private fun localPreview(room: RoomId): Pair<String,Long>? {
        if(revoked(room.value)) return null
        val committed=db.rawQuery("SELECT text,time FROM messages WHERE room=? ORDER BY time DESC,sequence,id LIMIT 1",arrayOf(room.value)).use {
            if(it.moveToFirst()) it.getString(0) to it.getLong(1) else null
        }
        val echo=outboxEchoes.preview(room)?.let {it.text to it.createdAt}
        return if(committed!=null && (echo==null || committed.second>=echo.second)) committed else echo
    }
    private fun JsonObject.required(key: String) = get(key)?.jsonPrimitive?.content?.takeIf { it.isNotBlank() } ?: throw ClientFailure.Protocol()
    override fun close() = synchronized(databaseLifecycle) {
        if (!databaseClosed) {
            databaseClosed = true
            projectionDiagnostics = null
            profileDispositionPreviews.clear(); unboundPreviews.clear(); preparationPreviews.clear()
            try { db.close() } finally { databaseAccess.close() }
        }
    }
}
