package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.toPersistentList
import java.util.UUID

/** Called only inside the account/device store's serialized transaction or read snapshot. */
internal class SqliteRoomDirectory(private val db: SQLiteDatabase) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS directory_scan (id INTEGER PRIMARY KEY CHECK(id=1),scope TEXT NOT NULL,round TEXT NOT NULL,cursor TEXT NOT NULL,topology TEXT,complete INTEGER NOT NULL CHECK(complete IN(0,1)),served INTEGER NOT NULL DEFAULT 0 CHECK(served>=0))")
        db.execSQL("CREATE TABLE IF NOT EXISTS directory_work (room TEXT PRIMARY KEY,revision TEXT NOT NULL,ready_at INTEGER NOT NULL DEFAULT 0 CHECK(ready_at>=0),served INTEGER NOT NULL DEFAULT 0 CHECK(served>=0),membership INTEGER NOT NULL DEFAULT 0 CHECK(membership>=0),owner INTEGER NOT NULL DEFAULT 0 CHECK(owner>=0))")
        val columns=db.rawQuery("PRAGMA table_info(directory_work)",null).use {rows -> buildSet {while(rows.moveToNext()) add(rows.getString(1))}}
        if("summary" !in columns) db.execSQL("ALTER TABLE directory_work ADD COLUMN summary INTEGER NOT NULL DEFAULT 1 CHECK(summary IN(0,1))")
        if("target_head" !in columns) db.execSQL("ALTER TABLE directory_work ADD COLUMN target_head INTEGER NOT NULL DEFAULT 0 CHECK(target_head>=0)")
        if("priority" !in columns) db.execSQL("ALTER TABLE directory_work ADD COLUMN priority INTEGER NOT NULL DEFAULT 0 CHECK(priority BETWEEN 0 AND 2)")
        if("enqueued" !in columns) db.execSQL("ALTER TABLE directory_work ADD COLUMN enqueued INTEGER NOT NULL DEFAULT 0 CHECK(typeof(enqueued)='integer' AND enqueued>=0)")
        db.execSQL("CREATE INDEX IF NOT EXISTS directory_work_priority ON directory_work(priority DESC,served,enqueued,room)")
        db.execSQL("CREATE INDEX IF NOT EXISTS directory_work_due ON directory_work(ready_at,served,room)")
        db.execSQL("CREATE TABLE IF NOT EXISTS directory_seen (cursor TEXT PRIMARY KEY)")
    } }
    private fun id()=UUID.randomUUID().toString()
    fun begin(): String {
        val scope=id()
        db.execSQL("INSERT OR IGNORE INTO directory_scan(id,scope,round,cursor,complete) VALUES (1,?,?,'',0)",arrayOf(scope,id()))
        db.execSQL("UPDATE directory_scan SET scope=? WHERE id=1",arrayOf(scope))
        return scope
    }
    fun scan(scope: String,generation: Long): RoomDirectoryScan = db.rawQuery("SELECT scope,round,cursor,topology,complete FROM directory_scan WHERE id=1",null).use {
        if(!it.moveToFirst() || it.getString(0) != scope) throw RoomDirectoryFailure(RoomDirectoryFailure.Reason.StaleScope)
        RoomDirectoryScan(scope,it.getString(1),it.getString(2),if(it.isNull(3)) null else it.getString(3),it.getInt(4)==1,generation)
    }
    fun restart(scope: String,generation: Long) {scan(scope,generation);reset()}
    fun reset() {
        db.execSQL("UPDATE directory_scan SET round=?,cursor='',topology=NULL,complete=0 WHERE id=1",arrayOf(id()))
        db.execSQL("DELETE FROM directory_seen")
    }
    fun commit(request: RoomDirectoryScan,page: RoomDirectoryPage,generation: Long) {
        page.validate()
        val current=scan(request.scope,generation)
        if(page.next.isNotEmpty() && page.next == current.cursor) throw ClientFailure.Protocol()
        if(current != request || current.complete)
            throw RoomDirectoryFailure(RoomDirectoryFailure.Reason.StalePage)
        if(current.topology != null && current.topology != page.topology) throw RoomDirectoryFailure(RoomDirectoryFailure.Reason.TopologyChanged)
        if(page.next.isNotEmpty() && db.rawQuery("SELECT 1 FROM directory_seen WHERE cursor=?",arrayOf(page.next)).use {it.moveToFirst()}) throw ClientFailure.Protocol()
        db.execSQL("INSERT INTO directory_seen VALUES (?)",arrayOf(current.cursor))
        for(entry in page.entries) {
            enqueue(entry.room.value,priority=0)
            db.execSQL("UPDATE directory_work SET membership=MAX(membership,?),owner=MAX(owner,?) WHERE room=?",arrayOf<Any>(entry.membership,entry.owner,entry.room.value))
            // Discovery controls kind only; authorization still requires RoomSyncState or membership facts.
            db.execSQL("INSERT OR REPLACE INTO room_kinds VALUES (?,?)",arrayOf(entry.room.value,entry.kind.name))
        }
        db.execSQL("UPDATE directory_scan SET cursor=?,topology=?,complete=? WHERE id=1",arrayOf<Any>(page.next,page.topology,if(page.next.isEmpty())1 else 0))
    }
    fun enqueue(room: String,priority: Int=1) {
        require(priority in 0..2)
        // A genuine new grant invalidates an in-flight completion without bypassing retry/fairness.
        db.execSQL("INSERT OR IGNORE INTO directory_work(room,revision,enqueued) VALUES (?,?,(SELECT COALESCE(MAX(enqueued),0)+1 FROM directory_work))",arrayOf(room,id()))
        db.execSQL("UPDATE directory_work SET revision=?,summary=1,priority=MAX(priority,?) WHERE room=?",arrayOf<Any>(id(),priority,room))
    }
    fun ensureSummary(room: String) {
        val pending=db.rawQuery("SELECT summary FROM directory_work WHERE room=?",arrayOf(room)).use {it.moveToFirst() && it.getInt(0)==1}
        if(pending) db.execSQL("UPDATE directory_work SET priority=2 WHERE room=? AND priority<2",arrayOf(room))
        else enqueue(room,priority=2)
    }
    fun discard(room: String) {db.execSQL("DELETE FROM directory_work WHERE room=?",arrayOf(room))}
    fun work(scope: String,generation: Long,now: Long,limit: Int,oldestFirst: Boolean): kotlinx.collections.immutable.PersistentList<RoomDirectoryWork> {
        scan(scope,generation);require(now >= 0 && limit in 1..16)
        val order=if(oldestFirst) "served,enqueued,room" else "priority DESC,served,enqueued,room"
        return db.rawQuery("SELECT room,revision,membership,owner,summary,target_head FROM directory_work WHERE ready_at<=? ORDER BY $order LIMIT ?",arrayOf(now.toString(),limit.toString())).use {rows ->
            buildList {while(rows.moveToNext()) add(RoomDirectoryWork(RoomId(rows.getString(0)),rows.getString(1),rows.getLong(2),rows.getLong(3),rows.getInt(4)==1,rows.getLong(5)))}.toPersistentList()
        }
    }
    fun finish(scope: String,generation: Long,work: RoomDirectoryWork,retryAt: Long?) {
        scan(scope,generation)
        if(retryAt != null) require(retryAt>=0)
        if(db.rawQuery("SELECT 1 FROM directory_work WHERE room=?",arrayOf(work.room.value)).use {!it.moveToFirst()}) return
        val served=db.rawQuery("SELECT served FROM directory_scan WHERE id=1",null).use {it.moveToFirst();it.getLong(0)}
        if(served == Long.MAX_VALUE) throw ClientFailure.Protocol()
        db.execSQL("UPDATE directory_scan SET served=served+1 WHERE id=1")
        if(retryAt == null) db.execSQL("DELETE FROM directory_work WHERE room=? AND revision=?",arrayOf(work.room.value,work.revision))
        // An updated request survives, but the room was served. Preserve fairness and server cooldown across revisions.
        db.execSQL("UPDATE directory_work SET ready_at=MAX(ready_at,?),served=? WHERE room=?",arrayOf<Any>(retryAt ?: 0,served+1,work.room.value))
    }
    fun progress(scope: String,generation: Long): RoomDirectoryProgress {
        val scan=scan(scope,generation)
        return db.rawQuery("SELECT COUNT(*),MIN(ready_at) FROM directory_work",null).use {
            it.moveToFirst();RoomDirectoryProgress(scan.complete,it.getInt(0),if(it.isNull(1)) null else it.getLong(1))
        }
    }
    fun candidate(scope: String,cursor: SyncCursor,hasHeads: Boolean): RoomRecoveryCandidate? {
        val scan=scan(scope,cursor.generation);val progress=progress(scope,cursor.generation)
        if(!progress.complete || progress.pendingRooms != 0 || hasHeads || cursor.pendingReceipt != null || cursor.generation <= 0) return null
        return RoomRecoveryCandidate(scope,scan.round,cursor.generation,cursor.sequence)
    }
    fun verify(candidate: RoomRecoveryCandidate,cursor: SyncCursor,personal: SyncCursor,hasHeads: Boolean): Boolean {
        if(cursor != personal) return false
        val current=candidate(candidate.scope,cursor,hasHeads) ?: return false
        return current.round == candidate.round && current.generation == candidate.generation && current.minimumSequence >= candidate.minimumSequence
    }
}
