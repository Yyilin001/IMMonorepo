package com.xmtx.im

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import com.xmtx.im.platform.SqliteClientStore
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Only compiled into the separate benchmark APK. No account, network or production data. */
internal class ListBenchmarkFixture(private val context: Context, val kind: String, val count: Int) {
    init {
        require(context.packageName == "com.xmtx.im.android.benchmark")
        require(kind in setOf("conversations", "messages"))
        require(count in if (kind == "conversations") setOf(1_000, 10_000) else setOf(10_000, 100_000))
    }
    val actor = UserId(UUID(1, 1).toString())
    private val device = DeviceId(UUID(2, 2).toString())
    val room = RoomId(UUID(3, 1).toString())
    private fun room(n: Int) = RoomId(UUID(3, n.toLong()).toString())
    private fun message(n: Int) = MessageId(UUID(4, n.toLong()).toString())
    private val file: File get() {
        val digest = MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") { "%02x".format(it) }
        return File(context.noBackupFilesDir, "im-$digest.db")
    }
    fun open() = SqliteClientStore(context, actor, device)
    fun prepare() {
        SQLiteDatabase.deleteDatabase(file)
        open().close()
        database { db ->
            val rooms = if (kind == "conversations") count else 1
            val messages = if (kind == "messages") count else rooms
            db.compileStatement("INSERT INTO rooms(id,title) VALUES (?,?)").use { insert ->
                repeat(rooms) { i -> insert.bindString(1, room(i + 1).value); insert.bindString(2, "性能会话 ${i + 1}"); insert.executeInsert() }
            }
            db.compileStatement("INSERT INTO room_kinds(room,kind) VALUES (?,'Group')").use { insert ->
                repeat(rooms) { i -> insert.bindString(1, room(i + 1).value); insert.executeInsert() }
            }
            db.compileStatement("INSERT INTO room_cursors(room,sequence,incomplete,owner,membership,unread) VALUES (?,?,0,0,1,?)").use { insert ->
                repeat(rooms) { i -> insert.bindString(1, room(i + 1).value); insert.bindLong(2, if (kind == "messages") count.toLong() else 1); insert.bindLong(3, (i % 99).toLong()); insert.executeInsert() }
            }
            db.compileStatement("INSERT INTO messages(id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn) VALUES (?,?,?,?,?,1,?,?,0)").use { insert ->
                repeat(messages) { i ->
                    val n = i + 1
                    insert.bindString(1, message(n).value); insert.bindString(2, if (kind == "messages") room.value else room(n).value)
                    insert.bindString(3, if (n % 3 == 0) UserId(UUID(1, 2).toString()).value else actor.value)
                    insert.bindString(4, "消息 $n " + "中文与 English 混排，覆盖不同气泡高度。".repeat(n % 4 + 1))
                    insert.bindLong(5, 1_700_000_000_000 + n.toLong()); insert.bindLong(6, if (kind == "messages") n.toLong() else 1); insert.bindLong(7, if (kind == "messages") n.toLong() else 1)
                    insert.executeInsert()
                }
            }
            check(db.rawQuery("SELECT count(*) FROM messages", null).use { it.moveToFirst(); it.getInt(0) } == messages)
            check(db.rawQuery("SELECT count(*) FROM rooms", null).use { it.moveToFirst(); it.getInt(0) } == rooms)
        }
    }
    fun update() = database { db ->
        if (kind == "conversations") {
            repeat(20) { i ->
                db.execSQL("UPDATE messages SET text=?,time=time+100000,revision=revision+1 WHERE room=?", arrayOf("批量更新 ${i + 1}", room(i + 1).value))
                db.execSQL("UPDATE room_cursors SET unread=unread+1 WHERE room=?", arrayOf(room(i + 1).value))
            }
        } else {
            val last = db.rawQuery("SELECT max(sequence) FROM messages WHERE room=?", arrayOf(room.value)).use { it.moveToFirst(); it.getInt(0) }
            repeat(20) { i ->
                val n = last + i + 1
                db.execSQL("INSERT INTO messages(id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn) VALUES (?,?,?,?,?,1,?,?,0)",
                    arrayOf(message(n).value, room.value, actor.value, "增量消息 $n", 1_700_000_000_000 + n.toLong(), n, n))
            }
            db.execSQL("UPDATE room_cursors SET sequence=? WHERE room=?", arrayOf(last + 20, room.value))
        }
    }
    /** One physical writer for a paced run. The UI uses the production store's separate WAL reader. */
    inner class StreamWriter : java.io.Closeable {
        private val db = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE)
        private val insert = db.compileStatement("INSERT INTO messages(id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn) VALUES (?,?,?,?,?,1,?,?,0)")
        private val cursor = db.compileStatement("UPDATE room_cursors SET sequence=?,unread=unread+1 WHERE room=?")
        fun append(offset: Int, size: Int) {
            db.beginTransaction()
            try {
                repeat(size) { i ->
                    val ordinal = offset + i
                    val sequence = if (kind == "messages") count + ordinal + 1 else 2 + ordinal / count
                    val target = if (kind == "messages") room else room(ordinal % count + 1)
                    insert.bindString(1, message(count + ordinal + 1).value); insert.bindString(2, target.value)
                    insert.bindString(3, actor.value); insert.bindString(4, "持续消息 ${ordinal + 1} " + "中文 English 正文。".repeat(ordinal % 4 + 1))
                    insert.bindLong(5, 1_700_000_000_000 + count + ordinal.toLong() + 1)
                    insert.bindLong(6, sequence.toLong()); insert.bindLong(7, sequence.toLong()); insert.executeInsert()
                    cursor.bindLong(1, sequence.toLong()); cursor.bindString(2, target.value); cursor.executeUpdateDelete()
                }
                db.setTransactionSuccessful()
            } finally { db.endTransaction() }
        }
        fun rowCount() = db.rawQuery("SELECT count(*) FROM messages", null).use { it.moveToFirst(); it.getInt(0) }
        override fun close() { insert.close(); cursor.close(); db.close() }
    }
    private fun database(body: (SQLiteDatabase) -> Unit) {
        SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
            db.beginTransaction()
            try { body(db); db.setTransactionSuccessful() } finally { db.endTransaction() }
        }
    }
}
