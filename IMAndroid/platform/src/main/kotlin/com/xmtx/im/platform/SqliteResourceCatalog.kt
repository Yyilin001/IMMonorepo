package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.toPersistentList
import kotlinx.serialization.json.*
import java.util.UUID

/** All methods run under the account store's mutex, with mutations inside its transaction. No JSON1 dependency. */
internal class SqliteResourceCatalog(private val db: SQLiteDatabase) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_catalog_state(id INTEGER PRIMARY KEY CHECK(id=1),generation TEXT NOT NULL,epoch TEXT NOT NULL)")
        db.execSQL("INSERT OR IGNORE INTO resource_catalog_state VALUES(1,hex(randomblob(16)),hex(randomblob(16)))")
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_catalog_rooms(room TEXT PRIMARY KEY,epoch TEXT NOT NULL,denied INTEGER NOT NULL DEFAULT 0)")
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_catalog_entries(home_kind TEXT NOT NULL,home TEXT NOT NULL,media TEXT NOT NULL,descriptor TEXT NOT NULL,revision INTEGER NOT NULL,name TEXT NOT NULL,kind TEXT NOT NULL,indexed_at INTEGER NOT NULL,PRIMARY KEY(home_kind,home,media))")
        val columns=db.rawQuery("PRAGMA table_info(resource_catalog_entries)",null).use {rows->buildSet {while(rows.moveToNext()) add(rows.getString(1))}}
        if("original_variant" !in columns) db.execSQL("ALTER TABLE resource_catalog_entries ADD COLUMN original_variant TEXT")
        if("automatic_admitted" !in columns) db.execSQL("ALTER TABLE resource_catalog_entries ADD COLUMN automatic_admitted INTEGER NOT NULL DEFAULT 0 CHECK(automatic_admitted IN (0,1))")
        if("download_bytes" !in columns) db.execSQL("ALTER TABLE resource_catalog_entries ADD COLUMN download_bytes INTEGER")
        if("download_checksum" !in columns) db.execSQL("ALTER TABLE resource_catalog_entries ADD COLUMN download_checksum TEXT")
        if("download_ready" !in columns) db.execSQL("ALTER TABLE resource_catalog_entries ADD COLUMN download_ready INTEGER")
        while(true) {
            val pending=db.rawQuery("SELECT descriptor FROM resource_catalog_entries WHERE download_bytes IS NULL LIMIT 100",null).use {rows->buildList {while(rows.moveToNext()) add(decode(rows.getString(0)))}}
            if(pending.isEmpty()) break
            pending.forEach(::updateDownloadMetadata)
        }
        // Canonical typed keys avoid JSON1 and are independent of SQL string concatenation rules.
        while(true) {
            val pending=db.rawQuery("SELECT descriptor FROM resource_catalog_entries WHERE original_variant IS NULL LIMIT 100",null).use {rows->buildList {while(rows.moveToNext()) add(decode(rows.getString(0)))}}
            if(pending.isEmpty()) break
            for(value in pending) {val key=home(value.key);db.execSQL("UPDATE resource_catalog_entries SET original_variant=? WHERE home_kind=? AND home=? AND media=?",arrayOf(ResourceVariantKey(value.key).payload().toString(),key[0],key[1],key[2]))}
        }
        db.execSQL("CREATE INDEX IF NOT EXISTS resource_catalog_order ON resource_catalog_entries(indexed_at DESC,home_kind DESC,home DESC,media DESC)")
        db.execSQL("CREATE INDEX IF NOT EXISTS resource_catalog_kind ON resource_catalog_entries(kind,indexed_at DESC,home_kind DESC,home DESC,media DESC)")
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_catalog_sources(message TEXT NOT NULL,ordinal INTEGER NOT NULL,room TEXT NOT NULL,media TEXT NOT NULL,revision INTEGER NOT NULL,epoch TEXT NOT NULL,room_epoch TEXT NOT NULL,revoked INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(message,ordinal))")
        db.execSQL("CREATE INDEX IF NOT EXISTS resource_catalog_source_key ON resource_catalog_sources(room,media,message,ordinal)")
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_message_media(message TEXT NOT NULL,ordinal INTEGER NOT NULL,room TEXT NOT NULL,media TEXT NOT NULL,revision INTEGER NOT NULL,epoch TEXT NOT NULL,PRIMARY KEY(message,ordinal))")
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_catalog_jobs(message TEXT PRIMARY KEY,room TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_catalog_scans(room TEXT NOT NULL,filter TEXT NOT NULL,id TEXT NOT NULL UNIQUE,query TEXT NOT NULL,has_page INTEGER NOT NULL,upper_sequence INTEGER,last_position TEXT,generation TEXT NOT NULL,PRIMARY KEY(room,filter))")
        for(table in listOf("memberships","user_blocks","message_tombstones")) for(operation in listOf("INSERT","UPDATE","DELETE")) {
            db.execSQL("CREATE TRIGGER IF NOT EXISTS catalog_${table}_${operation.lowercase()} AFTER $operation ON $table BEGIN UPDATE resource_catalog_state SET generation=hex(randomblob(16)) WHERE id=1; END")
        }
        db.execSQL("CREATE TRIGGER IF NOT EXISTS catalog_message_update AFTER UPDATE OF revision,withdrawn,media ON messages WHEN NEW.revision<>OLD.revision OR NEW.withdrawn<>OLD.withdrawn OR NEW.media IS NOT OLD.media BEGIN UPDATE resource_catalog_state SET generation=hex(randomblob(16)) WHERE id=1; END")
        db.execSQL("CREATE TRIGGER IF NOT EXISTS catalog_message_insert AFTER INSERT ON messages BEGIN UPDATE resource_catalog_state SET generation=hex(randomblob(16)) WHERE id=1; END")
        db.execSQL("CREATE TRIGGER IF NOT EXISTS catalog_message_delete AFTER DELETE ON messages BEGIN DELETE FROM resource_message_media WHERE message=OLD.id; DELETE FROM resource_catalog_jobs WHERE message=OLD.id; UPDATE resource_catalog_state SET generation=hex(randomblob(16)) WHERE id=1; END")
    } }
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_read_generation(id INTEGER PRIMARY KEY CHECK(id=1),token TEXT NOT NULL)")
        db.execSQL("INSERT OR IGNORE INTO resource_read_generation VALUES(1,hex(randomblob(16)))")
        for(table in listOf("resource_catalog_entries","resource_catalog_sources")) for(operation in listOf("INSERT","UPDATE","DELETE")) {
            val trigger="read_${table}_${operation.lowercase()}"
            // Automatic-admission bookkeeping is not a change to resource read authority.
            val condition=if(table=="resource_catalog_entries" && operation=="UPDATE") {
                db.execSQL("DROP TRIGGER IF EXISTS $trigger")
                " WHEN NEW.descriptor IS NOT OLD.descriptor OR NEW.home_kind IS NOT OLD.home_kind OR NEW.home IS NOT OLD.home OR NEW.media IS NOT OLD.media"
            } else ""
            db.execSQL("CREATE TRIGGER IF NOT EXISTS $trigger AFTER $operation ON $table$condition BEGIN UPDATE resource_read_generation SET token=hex(randomblob(16)) WHERE id=1; END")
        }
        db.execSQL("CREATE TRIGGER IF NOT EXISTS resource_read_access AFTER UPDATE OF generation ON resource_catalog_state WHEN NEW.generation<>OLD.generation BEGIN UPDATE resource_read_generation SET token=hex(randomblob(16)) WHERE id=1; END")
    } }
    fun readGeneration()=db.rawQuery("SELECT token FROM resource_read_generation WHERE id=1",null).use { check(it.moveToFirst());it.getString(0) }
    private fun state(column: String)=db.rawQuery("SELECT $column FROM resource_catalog_state WHERE id=1",null).use { check(it.moveToFirst());it.getString(0) }
    private fun roomEpoch(room: String): String {
        db.execSQL("INSERT OR IGNORE INTO resource_catalog_rooms VALUES(?,hex(randomblob(16)),0)",arrayOf(room))
        return db.rawQuery("SELECT epoch FROM resource_catalog_rooms WHERE room=?",arrayOf(room)).use { check(it.moveToFirst());it.getString(0) }
    }
    private fun generationChanged()=db.execSQL("UPDATE resource_catalog_state SET generation=hex(randomblob(16)) WHERE id=1")
    fun invalidateRoom(room: String) {
        roomEpoch(room)
        db.execSQL("UPDATE resource_catalog_rooms SET epoch=hex(randomblob(16)),denied=1 WHERE room=?",arrayOf(room));generationChanged()
    }
    fun authorizedRoom(room: String) {
        roomEpoch(room)
        db.execSQL("UPDATE resource_catalog_rooms SET denied=0 WHERE room=? AND denied<>0",arrayOf(room))
        if(db.compileStatement("SELECT changes()").use { it.simpleQueryForLong() }>0) generationChanged()
    }
    fun snapshotChanged() { db.execSQL("UPDATE resource_catalog_state SET epoch=hex(randomblob(16)),generation=hex(randomblob(16)) WHERE id=1") }
    fun enqueueExisting() { db.execSQL("INSERT OR IGNORE INTO resource_catalog_jobs SELECT id,room FROM messages") }
    fun indexBatch(limit: Int): Boolean {
        require(limit in 1..100)
        val ids=db.rawQuery("SELECT message FROM resource_catalog_jobs ORDER BY message LIMIT ?",arrayOf(limit.toString())).use { rows -> buildList { while(rows.moveToNext()) add(rows.getString(0)) } }
        ids.forEach(::projectMessage)
        return db.rawQuery("SELECT 1 FROM resource_catalog_jobs LIMIT 1",null).use { it.moveToFirst() }
    }
    fun projectMessage(id: String) {
        db.execSQL("DELETE FROM resource_message_media WHERE message=?",arrayOf(id))
        db.rawQuery("SELECT room,revision,time,withdrawn,media FROM messages WHERE id=?",arrayOf(id)).use { row ->
            if(row.moveToFirst()) {
                val room=RoomId(row.getString(0));val revision=row.getLong(1)
                val authorized=db.rawQuery("SELECT 1 FROM room_cursors c JOIN memberships m ON m.room=c.room WHERE c.room=? AND m.member=1 AND m.revision=c.membership",arrayOf(room.value)).use { it.moveToFirst() }
                if(!authorized) { db.execSQL("DELETE FROM resource_catalog_jobs WHERE message=?",arrayOf(id));return }
                val media=decodeStoredMessageMedia(room.value,row.getString(4))
                if(media==null && row.getInt(3)==0) { db.execSQL("DELETE FROM resource_catalog_jobs WHERE message=?",arrayOf(id));return }
                if(row.getInt(3)==0 && media!=null) {
                    media.ids.forEachIndexed { ordinal,item -> db.execSQL("INSERT INTO resource_message_media VALUES(?,?,?,?,?,?)",arrayOf(id,ordinal,room.value,item,revision,roomEpoch(room.value))) }
                    media.presentations?.forEachIndexed { ordinal,item -> index(item.descriptor,MessageResourceSource(room,MessageId(id),ordinal,revision),row.getLong(2)) }
                }
                // Unknown current media cannot validate any older source.
                db.execSQL("UPDATE resource_catalog_sources SET revoked=1,revision=MAX(revision,?) WHERE message=? AND room=? AND revision<=? AND NOT EXISTS(SELECT 1 FROM resource_message_media p WHERE p.message=resource_catalog_sources.message AND p.ordinal=resource_catalog_sources.ordinal AND p.media=resource_catalog_sources.media)",arrayOf(revision,id,room.value,revision))
            }
        }
        db.execSQL("DELETE FROM resource_catalog_jobs WHERE message=?",arrayOf(id))
    }
    private fun index(descriptor: ResourceDescriptor,source: MessageResourceSource,indexedAt: Long) {
        require(descriptor.key.home==ResourceHome.Room(source.room) && indexedAt>=0)
        val room=source.room.value;val message=source.message.value
        if(db.rawQuery("SELECT 1 FROM memberships WHERE room=? AND member=0 UNION ALL SELECT 1 FROM message_tombstones WHERE id=? AND room=?",arrayOf(room,message,room)).use { it.moveToFirst() }) return
        db.rawQuery("SELECT room,revision,withdrawn,media FROM messages WHERE id=?",arrayOf(message)).use { rows -> if(rows.moveToFirst()) {
            if(rows.getString(0)!=room) throw ResourceCatalogConflict()
            if(rows.getInt(2)!=0) return
            if(rows.getLong(1)>=source.revision && decodeStoredMessageMedia(room,rows.getString(3))?.ids?.getOrNull(source.ordinal)!=descriptor.key.media) return
        } }
        db.rawQuery("SELECT room,media,revision,revoked FROM resource_catalog_sources WHERE message=? AND ordinal=?",arrayOf(message,source.ordinal.toString())).use { rows -> if(rows.moveToFirst()) {
            if(rows.getString(0)!=room) throw ResourceCatalogConflict()
            if(rows.getLong(2)>source.revision || rows.getLong(2)==source.revision && rows.getInt(3)!=0) return
            if(rows.getLong(2)==source.revision && rows.getString(1)!=descriptor.key.media) throw ResourceCatalogConflict()
        } }
        val key=home(descriptor.key)
        val old=db.rawQuery("SELECT descriptor FROM resource_catalog_entries WHERE home_kind=? AND home=? AND media=?",key).use { if(it.moveToFirst()) decode(it.getString(0)) else null }
        if(old!=null) {
            if(old.revision==descriptor.revision && old!=descriptor || old.byteCount!=descriptor.byteCount || old.checksum!=null && old.checksum!=descriptor.checksum) throw ResourceCatalogConflict()
        }
        if(old==null) db.execSQL("INSERT INTO resource_catalog_entries(home_kind,home,media,descriptor,revision,name,kind,indexed_at,original_variant) VALUES(?,?,?,?,?,?,?,?,?)",arrayOf(key[0],key[1],key[2],descriptor.payload().toString(),descriptor.revision,descriptor.displayName,MessageMediaKind.forContentType(descriptor.contentType).wire,indexedAt,ResourceVariantKey(descriptor.key).payload().toString()))
        else if(descriptor.revision>old.revision) db.execSQL("UPDATE resource_catalog_entries SET descriptor=?,revision=?,name=?,kind=? WHERE home_kind=? AND home=? AND media=?",arrayOf(descriptor.payload().toString(),descriptor.revision,descriptor.displayName,MessageMediaKind.forContentType(descriptor.contentType).wire,key[0],key[1],key[2]))
        if(old==null || descriptor.revision>old.revision) updateDownloadMetadata(descriptor)
        db.execSQL("INSERT OR REPLACE INTO resource_catalog_sources VALUES(?,?,?,?,?,?,?,0)",arrayOf(message,source.ordinal,room,descriptor.key.media,source.revision,state("epoch"),roomEpoch(room)))
    }
    private fun decode(value: String)=ResourceDescriptor.decode(Json.parseToJsonElement(value).jsonObject)
    private fun home(key: ResourceKey): Array<String> = when(val scope=key.home) {
        is ResourceHome.Room->arrayOf("room",scope.room.value,key.media)
        is ResourceHome.Account->arrayOf("account",scope.user.value,key.media)
    }
    // A source is descriptive evidence only. Current messages override old snapshot/room epochs,
    // but a withdrawal, unknown newer media set, membership denial, or directory denial always wins.
    private val visible="""
        r.revoked=0 AND NOT EXISTS(SELECT 1 FROM resource_catalog_rooms d WHERE d.room=r.room AND d.denied=1)
        AND NOT EXISTS(SELECT 1 FROM memberships m WHERE m.room=r.room AND m.member=0)
        AND NOT EXISTS(SELECT 1 FROM message_tombstones t WHERE t.id=r.message AND t.room=r.room)
        AND ((r.epoch=(SELECT epoch FROM resource_catalog_state WHERE id=1) AND r.room_epoch=(SELECT epoch FROM resource_catalog_rooms WHERE room=r.room))
            OR EXISTS(SELECT 1 FROM messages m JOIN resource_message_media p ON p.message=m.id WHERE m.id=r.message AND m.room=r.room AND m.withdrawn=0 AND m.revision>=r.revision AND p.ordinal=r.ordinal AND p.media=r.media AND p.revision=m.revision AND m.media IS NOT NULL AND p.epoch=(SELECT epoch FROM resource_catalog_rooms WHERE room=r.room)))
        AND NOT EXISTS(SELECT 1 FROM messages m WHERE m.id=r.message AND (m.room<>r.room OR m.withdrawn=1 OR (m.revision>=r.revision AND NOT EXISTS(SELECT 1 FROM resource_message_media p WHERE p.message=m.id AND p.ordinal=r.ordinal AND p.media=r.media AND p.revision=m.revision AND m.media IS NOT NULL))))
    """.trimIndent()
    private fun updateDownloadMetadata(value:ResourceDescriptor) {
        val key=home(value.key)
        db.execSQL("UPDATE resource_catalog_entries SET download_bytes=?,download_checksum=?,download_ready=? WHERE home_kind=? AND home=? AND media=?",
            arrayOf(value.byteCount,value.checksum?.value,if(value.state==ResourceState.Ready) 1 else 0,key[0],key[1],key[2]))
    }
    fun automaticCandidates(policy:ResourceAutomaticDownloadPolicy,limit:Int):List<MessageResourceRead> {
        require(limit in 1..2);if(policy.categories.isEmpty()) return emptyList()
        val kinds=policy.categories.flatMap {if(it==ResourceCategory.Image) listOf("image","animated_image") else listOf(it.wire)}.sorted()
        val args=(listOf(policy.maximumByteCount.toString())+kinds+limit.toString()).toTypedArray()
        val found=db.rawQuery("SELECT e.descriptor FROM resource_catalog_entries e WHERE e.home_kind='room' AND e.automatic_admitted=0 AND e.download_ready=1 AND e.download_checksum IS NOT NULL AND e.download_bytes BETWEEN 1 AND ? AND e.kind IN ("+kinds.joinToString(",") {"?"}+") AND EXISTS(SELECT 1 FROM resource_catalog_sources r WHERE r.room=e.home AND r.media=e.media AND $visible) AND NOT EXISTS(SELECT 1 FROM resource_files f WHERE f.state='Published' AND f.bytes=e.download_bytes AND f.checksum=e.download_checksum) AND NOT EXISTS(SELECT 1 FROM resource_downloads j WHERE j.media=e.media OR (j.bytes=e.download_bytes AND j.checksum=e.download_checksum)) ORDER BY e.indexed_at DESC,e.media LIMIT ?",args).use {rows->buildList {while(rows.moveToNext()) add(decode(rows.getString(0)))}}
        return found.map {selectRead(it.key)}
    }
    fun markAutomaticAdmitted(key:ResourceKey) {
        db.execSQL("UPDATE resource_catalog_entries SET automatic_admitted=1 WHERE home_kind=? AND home=? AND media=?",home(key))
    }
    fun directory(query: ResourceCatalogQuery): ResourceCatalogPage {
        val retained="EXISTS(SELECT 1 FROM resource_retention p WHERE p.key=e.original_variant)"
        val args=mutableListOf<String>();val predicates=mutableListOf("e.home_kind='room'","EXISTS(SELECT 1 FROM resource_catalog_sources r WHERE r.room=e.home AND r.media=e.media AND $visible)")
        if(query.retainedOnly) predicates.add(retained)
        query.room?.let { predicates.add("e.home=?");args.add(it.value) }
        when(query.category) {
            ResourceCategory.All->Unit
            ResourceCategory.Image->predicates.add("e.kind IN ('image','animated_image')")
            else->{ predicates.add("e.kind=?");args.add(query.category.wire) }
        }
        if(query.search.isNotEmpty()) { predicates.add("e.name LIKE ? ESCAPE '\\'");args.add("%"+query.search.replace("\\","\\\\").replace("%","\\%").replace("_","\\_")+"%") }
        query.before?.let { cursor ->
            val key=home(cursor.key);predicates.add("(e.indexed_at,e.home_kind,e.home,e.media)<(?,?,?,?)");args.add(cursor.indexedAt.toString());args.addAll(key)
        }
        args.add((query.limit+1).toString())
        val found=db.rawQuery("SELECT e.descriptor,e.indexed_at,(SELECT COUNT(*) FROM resource_catalog_sources r WHERE r.room=e.home AND r.media=e.media AND $visible),$retained FROM resource_catalog_entries e WHERE ${predicates.joinToString(" AND ")} ORDER BY e.indexed_at DESC,e.home_kind DESC,e.home DESC,e.media DESC LIMIT ?",args.toTypedArray()).use { rows -> buildList {
            while(rows.moveToNext()) add(ResourceCatalogEntry(decode(rows.getString(0)),rows.getLong(1),rows.getInt(2),rows.getInt(3)==1))
        } }
        val entries=found.take(query.limit).toPersistentList()
        val pending=db.rawQuery("SELECT 1 FROM resource_catalog_jobs"+(if(query.room!=null) " WHERE room=?" else "")+" LIMIT 1",query.room?.let { arrayOf(it.value) }).use { it.moveToFirst() }
        return ResourceCatalogPage(entries,if(found.size>query.limit) entries.last().let { ResourceCatalogCursor(it.indexedAt,it.descriptor.key) } else null,pending)
    }
    fun visibleDescriptor(key:ResourceKey)=detail(key)
    private fun detail(key: ResourceKey): ResourceDescriptor? {
        val home=home(key)
        return db.rawQuery("SELECT e.descriptor FROM resource_catalog_entries e WHERE e.home_kind=? AND e.home=? AND e.media=? AND EXISTS(SELECT 1 FROM resource_catalog_sources r WHERE e.home_kind='room' AND r.room=e.home AND r.media=e.media AND $visible)",home).use { if(it.moveToFirst()) decode(it.getString(0)) else null }
    }
    fun selectRead(key: ResourceKey,location: MediaMessageLocation?=null): MessageResourceRead {
        val descriptor=detail(key) ?: throw ResourceCatalogConflict()
        val source=if(location==null) sources(key,null,1).sources.firstOrNull() else {
            require(key.home==ResourceHome.Room(location.room))
            db.rawQuery("SELECT r.ordinal,r.revision FROM resource_catalog_sources r WHERE r.room=? AND r.media=? AND r.message=? AND $visible ORDER BY r.ordinal LIMIT 1",arrayOf(location.room.value,key.media,location.message.value)).use {
                if(it.moveToFirst()) MessageResourceSource(location.room,location.message,it.getInt(0),it.getLong(1)) else null
            }
        }
        if(source==null) throw ResourceCatalogConflict()
        return MessageResourceRead(descriptor,source,readGeneration())
    }
    fun currentRead(read: MessageResourceRead)=read.generation==readGeneration() && detail(read.descriptor.key)==read.descriptor && contains(read.descriptor.key,read.source)
    fun selectAttachment(key: ResourceKey): MessageAttachmentSelection {
        val value=selectRead(key)
        if(!MessageAttachmentSelection.eligible(value.descriptor)) throw ResourceCatalogConflict()
        return MessageAttachmentSelection(value.descriptor,value.source)
    }
    fun currentAttachment(selection: MessageAttachmentSelection)=detail(selection.key)==selection.descriptor && contains(selection.key,selection.source)
    fun selectAvatar(key: ResourceKey): AvatarResourceSelection {
        val descriptor=detail(key) ?: throw ResourceCatalogConflict()
        val source=sources(key,null,1).sources.firstOrNull() ?: throw ResourceCatalogConflict()
        if(!AvatarResourceSelection.eligible(descriptor)) throw ResourceCatalogConflict()
        return AvatarResourceSelection(descriptor,source)
    }
    fun currentAvatar(selection: AvatarResourceSelection)=detail(selection.key)==selection.descriptor && contains(selection.key,selection.source)
    fun sources(key: ResourceKey,before: ResourceSourceCursor?,limit: Int): ResourceSourcePage {
        require(limit in 1..100)
        if(key.home !is ResourceHome.Room) return ResourceSourcePage(emptyList<MessageResourceSource>().toPersistentList(),null)
        val args=mutableListOf((key.home as ResourceHome.Room).room.value,key.media)
        val cursor=if(before==null) "" else " AND (r.message,r.ordinal)<(?,?)".also { args.add(before.message.value);args.add(before.ordinal.toString()) }
        args.add((limit+1).toString())
        val found=db.rawQuery("SELECT r.room,r.message,r.ordinal,r.revision FROM resource_catalog_sources r WHERE r.room=? AND r.media=? AND $visible$cursor ORDER BY r.message DESC,r.ordinal DESC LIMIT ?",args.toTypedArray()).use { rows -> buildList {
            while(rows.moveToNext()) add(MessageResourceSource(RoomId(rows.getString(0)),MessageId(rows.getString(1)),rows.getInt(2),rows.getLong(3)))
        } }
        val items=found.take(limit).toPersistentList()
        return ResourceSourcePage(items,if(found.size>limit) items.last().let { ResourceSourceCursor(it.message,it.ordinal) } else null)
    }
    fun contains(key: ResourceKey,source: MessageResourceSource): Boolean {
        if(key.home!=ResourceHome.Room(source.room)) return false
        return db.rawQuery("SELECT 1 FROM resource_catalog_sources r WHERE r.room=? AND r.media=? AND r.message=? AND r.ordinal=? AND r.revision=? AND $visible",arrayOf(source.room.value,key.media,source.message.value,source.ordinal.toString(),source.revision.toString())).use { it.moveToFirst() }
    }
    private fun filter(query: RoomResourceQuery)="${query.category.wire}/${query.before ?: -1}/${query.after ?: -1}"
    fun begin(room: RoomId,query: RoomResourceQuery): ResourceDirectoryScan {
        require(query.cursor==null)
        val scan=ResourceDirectoryScan(UUID.randomUUID().toString().uppercase(),room,query,generation=state("generation"))
        roomEpoch(room.value)
        db.execSQL("INSERT OR REPLACE INTO resource_catalog_scans VALUES(?,?,?,?,0,NULL,NULL,?)",arrayOf(room.value,filter(query),scan.id,query.payload().toString(),scan.generation))
        return scan
    }
    fun scan(room: RoomId,query: RoomResourceQuery): ResourceDirectoryScan? {
        return db.rawQuery("SELECT id,query,has_page,upper_sequence,last_position,generation FROM resource_catalog_scans WHERE room=? AND filter=? AND generation=(SELECT generation FROM resource_catalog_state WHERE id=1)",arrayOf(room.value,filter(query))).use { rows ->
            if(!rows.moveToFirst()) null else ResourceDirectoryScan(rows.getString(0),room,RoomResourceQuery.decode(Json.parseToJsonElement(rows.getString(1)).jsonObject),rows.getInt(2)!=0,
                if(rows.isNull(3)) null else rows.getLong(3),rows.getString(4)?.let { RoomResourcePosition.decode(Json.parseToJsonElement(it).jsonObject) },rows.getString(5))
        }
    }
    fun apply(scan: ResourceDirectoryScan,page: RoomResourcePage): ResourceDirectoryScan {
        if(scan.finished || scan(scan.room,scan.query)!=scan) throw ResourceCatalogConflict()
        page.boundTo(scan.room,scan.query)
        val last=scan.lastPosition
        if(scan.snapshotUpper!=null && scan.snapshotUpper!=page.snapshotUpper || last!=null && page.items.firstOrNull()?.position?.let { it>=last }==true) throw ResourceCatalogConflict()
        db.execSQL("UPDATE resource_catalog_rooms SET denied=0 WHERE room=?",arrayOf(scan.room.value))
        page.items.forEach { item -> index(item.descriptor,MessageResourceSource(scan.room,item.message,item.position.ordinal,item.messageRevision),item.createdAt) }
        val next=scan.copy(query=scan.query.copy(cursor=page.nextCursor),hasPage=true,snapshotUpper=page.snapshotUpper,lastPosition=page.items.lastOrNull()?.position ?: scan.lastPosition)
        db.execSQL("UPDATE resource_catalog_scans SET query=?,has_page=1,upper_sequence=?,last_position=? WHERE id=?",arrayOf(next.query.payload().toString(),page.snapshotUpper,next.lastPosition?.payload()?.toString(),scan.id))
        return next
    }
    fun deny(scan: ResourceDirectoryScan) {
        if(scan(scan.room,scan.query)!=scan) throw ResourceCatalogConflict()
        invalidateRoom(scan.room.value)
    }
}
