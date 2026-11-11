package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Only invoked inside the owning store's transaction. Persists text facts, never a presentation. */
internal class SqliteLocalProfileDisplays(private val db: SQLiteDatabase, private val actor: UserId) {
    init { if (!db.isReadOnly) {
        db.execSQL("""CREATE TABLE IF NOT EXISTS local_profile_displays (
            key TEXT PRIMARY KEY,user TEXT NOT NULL,value TEXT,revision INTEGER,authority TEXT,updated INTEGER NOT NULL,
            CHECK(revision IS NULL OR (typeof(revision)='integer' AND revision>0)))""")
        db.execSQL("CREATE INDEX IF NOT EXISTS local_profile_displays_user ON local_profile_displays(user)")
        for (operation in listOf("INSERT", "UPDATE")) db.execSQL("""
            CREATE TRIGGER IF NOT EXISTS local_profile_security_${operation.lowercase()} AFTER $operation ON presentation_floors
            WHEN NEW.kind='security' AND NEW.room=''
            BEGIN DELETE FROM local_profile_displays WHERE user=NEW.user AND value IS NOT NULL AND revision<=NEW.revision; END
        """.trimIndent())
    } }
    @Serializable private data class Fact(val user: String, val handle: String, val name: String, val kind: String,
        val profile: Long, val visibility: Long, val context: Long = 0, val observed: Long = 0,
        val aliasName: String? = null, val aliasRevision: Long? = null,
        val groupName: String? = null, val groupRevision: Long? = null) {
        fun identity() = PublicIdentity(UserId(user), PublicHandle(handle).also { require(it.value == handle) }, name, AccountKind.valueOf(kind))
        fun alias(actor: UserId) = aliasRevision?.let { ProfileAlias(actor, UserId(user), aliasName, it) }
        fun basic(actor: UserId): LocalProfileBasics {
            require(aliasName == null || aliasRevision != null)
            return LocalProfileBasics(identity(), profile, visibility, alias(actor))
        }
        fun record(key: ProfileKey, actor: UserId): LocalProfileDisplay {
            require(key.user == UserId(user) && (groupName == null || groupRevision != null))
            val group = groupRevision?.let { ProfileGroupName((key.context as ProfileContext.Room).room, key.user, groupName, it) }
            return LocalProfileDisplay(key, basic(actor).identity, profile, visibility, context, alias(actor), group, observed)
        }
    }
    @Serializable private data class Version(val control: Long, val room: String?, val membership: Long, val permission: Long) {
        fun value() = ProfileAuthority(control, room?.let { RoomId(it) }, membership, permission)
    }
    private data class Row(val user: UserId, val fact: Fact?, val revision: Long?, val authority: ProfileAuthority?)
    private fun fact(value: LocalProfileBasics) = Fact(value.identity.user.value, value.identity.handle.value,
        value.identity.displayName, value.identity.kind.name, value.profileRevision, value.visibilityRevision,
        aliasName = value.alias?.name, aliasRevision = value.alias?.revision)
    private fun fact(value: LocalProfileDisplay) = fact(LocalProfileBasics.merge(value)).copy(context = value.contextRevision,
        observed = value.observedAt, groupName = value.groupName?.name, groupRevision = value.groupName?.revision)
    private fun key(key: ProfileKey): String = when (val scope = key.context) {
        ProfileContext.Relationship -> "relationship|${key.user.value}"
        ProfileContext.DirectConversation -> "direct|${key.user.value}"
        is ProfileContext.Room -> "room|${scope.room.value}|${key.user.value}"
        is ProfileContext.GroupJoinReview -> "review|${scope.room.value}|${key.user.value}"
    }
    private fun row(key: String): Row? = db.rawQuery("SELECT user,value,revision,authority FROM local_profile_displays WHERE key=?", arrayOf(key)).use {
        if (!it.moveToFirst()) null else Row(UserId(it.getString(0)), if (it.isNull(1)) null else Json.decodeFromString(Fact.serializer(), it.getString(1)),
            if (it.isNull(2)) null else it.getLong(2), if (it.isNull(3)) null else Json.decodeFromString(Version.serializer(), it.getString(3)).value()).also { row ->
            require(row.fact == null || row.fact.user == row.user.value && row.fact.profile == row.revision)
        }
    }
    private fun put(key: String, user: UserId, value: Fact?, revision: Long?, authority: ProfileAuthority?) {
        val version = authority?.let { Json.encodeToString(Version.serializer(), Version(it.control, it.room?.value, it.membership, it.permission)) }
        db.execSQL("INSERT OR REPLACE INTO local_profile_displays VALUES (?,?,?,?,?,(SELECT COALESCE(MAX(updated),0)+1 FROM local_profile_displays))",
            arrayOf<Any?>(key, user.value, value?.let { Json.encodeToString(Fact.serializer(), it) }, revision, version))
    }
    /** False rejects an obsolete result without erasing a newer accepted fact or denial. */
    fun adopt(result: ProfileReadResult): Boolean {
        if (result is ProfileReadResult.Retryable) return true
        val key = result.key; val raw = key(key); val old = row(raw)
        require(old == null || old.user == key.user)
        val incoming = when (result) {
            is ProfileReadResult.Available -> result.profile.lease.authority
            is ProfileReadResult.Unavailable -> result.authority
            else -> error("unreachable")
        }
        val previous = old?.authority
        if (result is ProfileReadResult.Unavailable) {
            if (previous != null && previous.isAtLeast(incoming) && previous != incoming) return false
            put(raw, key.user, null, null, previous?.merged(incoming) ?: incoming)
            return true
        }
        result as ProfileReadResult.Available
        if (previous != null && (!incoming.isAtLeast(previous) || old.fact == null && incoming == previous)) return false
        val profile = result.profile
        val value = LocalProfileDisplay.from(profile)
        val basicKey = "basic|${key.user.value}"
        val globalKey = "global|${key.user.value}"
        val oldBasic = row(basicKey)?.fact?.basic(actor)
        val global = row(globalKey)
        if (global?.revision?.let { profile.view.revision <= it } == true)
            return value == null && profile.view.revision == global.revision
        if (value == null) {
            if (oldBasic != null && profile.view.revision < oldBasic.profileRevision) return false
            db.execSQL("DELETE FROM local_profile_displays WHERE user=?", arrayOf(key.user.value))
            put(globalKey, key.user, null, profile.view.revision, null)
        } else {
            old?.fact?.record(key, actor)?.let { if (!value.supersedes(it)) return false }
            val basic = LocalProfileBasics.merge(value, oldBasic)
            put(basicKey, key.user, fact(basic), basic.profileRevision, null)
            put(raw, key.user, fact(value), value.profileRevision, incoming)
            db.execSQL("DELETE FROM local_profile_displays WHERE key=?", arrayOf(globalKey))
        }
        // Denials are never evicted to make room for positive cache entries.
        db.execSQL("DELETE FROM local_profile_displays WHERE key IN (SELECT key FROM local_profile_displays WHERE value IS NOT NULL ORDER BY updated DESC LIMIT -1 OFFSET 4000)")
        return true
    }
    fun load(keys: PersistentList<ProfileKey>): LocalProfileDisplaySnapshot {
        require(keys.size <= 128)
        if (keys.isEmpty()) return LocalProfileDisplaySnapshot()
        // Old read-only stores can still show text without creating/migrating this optional cache.
        val exists = db.rawQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name='local_profile_displays'", null).use { it.moveToFirst() }
        if (!exists) return LocalProfileDisplaySnapshot()
        val requested = keys.associateBy(::key); val users = keys.map { it.user.value }.distinct()
        var records = persistentMapOf<ProfileKey, LocalProfileDisplay>(); var basics = persistentMapOf<UserId, LocalProfileBasics>()
        var denied = persistentSetOf<ProfileKey>(); var global = persistentSetOf<UserId>()
        db.rawQuery("""SELECT d.key,d.user,d.value,d.revision,f.revision FROM local_profile_displays d
            LEFT JOIN presentation_floors f ON f.kind='security' AND f.room='' AND f.user=d.user
            WHERE d.user IN (${users.joinToString(",") { "?" }})""", users.toTypedArray()).use { rows ->
            while (rows.moveToNext()) {
                val raw = rows.getString(0); val user = UserId(rows.getString(1))
                val revision = if (rows.isNull(3)) null else rows.getLong(3)
                val floor = if (rows.isNull(4)) 0 else rows.getLong(4).also { require(it > 0 && rows.getType(4) == android.database.Cursor.FIELD_TYPE_INTEGER) }
                if (!rows.isNull(2) && (revision == null || revision <= floor)) continue
                when {
                    raw == "global|${user.value}" -> { require(rows.isNull(2)); global = global.add(user) }
                    raw == "basic|${user.value}" -> {
                        val value = Json.decodeFromString(Fact.serializer(), rows.getString(2)).basic(actor)
                        require(value.identity.user == user && value.profileRevision == revision)
                        basics = basics.put(user, value)
                    }
                    raw in requested -> {
                        val key = requested.getValue(raw); require(key.user == user)
                        if (rows.isNull(2)) denied = denied.add(key)
                        else {
                            val value = Json.decodeFromString(Fact.serializer(), rows.getString(2)).record(key, actor)
                            require(value.profileRevision == revision); records = records.put(key, value)
                        }
                    }
                }
            }
        }
        for (record in records.values) basics = basics.put(record.key.user, LocalProfileBasics.merge(record, basics[record.key.user]))
        return LocalProfileDisplaySnapshot(records, basics, denied, global)
    }
    fun clear() { db.execSQL("DELETE FROM local_profile_displays") }
}
