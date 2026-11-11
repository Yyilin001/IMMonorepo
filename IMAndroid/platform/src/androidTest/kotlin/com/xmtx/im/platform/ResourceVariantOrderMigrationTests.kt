package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ResourceVariantOrderMigrationTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val key=ResourceKey(ResourceHome.Room(RoomId(id())),id())
    private val first="11111111-1111-1111-1111-111111111111";private val second="99999999-9999-9999-9999-999999999999"
    private fun variant(rendition:ResourceRendition)=ResourceVariantDescriptor(ResourceVariantKey(key,rendition),ResourceChecksum("a".repeat(64)),8)
    private fun legacy(db:SQLiteDatabase) {db.execSQL("CREATE TABLE resource_variants(key TEXT PRIMARY KEY,resource TEXT NOT NULL,descriptor TEXT NOT NULL,checksum TEXT NOT NULL,bytes INTEGER NOT NULL)")}
    private fun insert(db:SQLiteDatabase,value:ResourceVariantDescriptor) {db.execSQL("INSERT INTO resource_variants VALUES(?,?,?,?,?)",arrayOf(value.key.payload().toString(),key.payload().toString(),value.payload().toString(),value.checksum.value,value.byteCount))}
    private fun ordered(db:SQLiteDatabase)=db.rawQuery("SELECT descriptor FROM resource_variants WHERE resource=? ORDER BY sort_kind,sort_id,sort_version DESC,key LIMIT 128",arrayOf(key.payload().toString())).use {rows->buildList {while(rows.moveToNext()) add(ResourceVariantDescriptor.decode(Json.parseToJsonElement(rows.getString(0)).jsonObject))}}
    @Test fun legacyRowsKeepTheirIdentityAndRetentionWhileOrderingOriginalThenNewestVersions() {
        SQLiteDatabase.create(null).use {db->
            legacy(db)
            val expected=listOf(variant(ResourceRendition.Original),variant(ResourceRendition.Derived(first,10)),variant(ResourceRendition.Derived(first,2)),variant(ResourceRendition.Derived(first,1)),variant(ResourceRendition.Derived(second,100)))
            expected.reversed().forEach {insert(db,it)}
            db.execSQL("CREATE TABLE resource_retention(key TEXT PRIMARY KEY,checksum TEXT NOT NULL,bytes INTEGER NOT NULL,intent TEXT UNIQUE NOT NULL,time INTEGER NOT NULL)")
            val retained=expected[2];val intent=id()
            db.execSQL("INSERT INTO resource_retention VALUES(?,?,?,?,?)",arrayOf(retained.key.payload().toString(),retained.checksum.value,8,intent,1))
            SqliteResourceFiles(db,actor);assertEquals(expected,ordered(db));SqliteResourceFiles(db,actor);assertEquals(expected,ordered(db))
            db.rawQuery("SELECT key,intent FROM resource_retention",null).use {assertTrue(it.moveToFirst());assertEquals(retained.key.payload().toString(),it.getString(0));assertEquals(intent,it.getString(1));assertFalse(it.moveToNext())}
            val plan=db.rawQuery("EXPLAIN QUERY PLAN SELECT descriptor FROM resource_variants WHERE resource=? ORDER BY sort_kind,sort_id,sort_version DESC,key LIMIT 128",arrayOf(key.payload().toString())).use {rows->buildList {while(rows.moveToNext()) add(rows.getString(3))}}
            assertTrue(plan.any {it.contains("resource_variant_order")});assertTrue(plan.none {it.contains("TEMP B-TREE")})
        }
    }
    @Test fun failedBackfillRollsBackSchemaAndCanBeRetriedAfterFixingTheFixture() {
        SQLiteDatabase.create(null).use {db->
            legacy(db);val valid=variant(ResourceRendition.Derived(first,12));insert(db,valid)
            db.execSQL("INSERT INTO resource_variants VALUES('z-broken',?,'not-json',?,8)",arrayOf(key.payload().toString(),valid.checksum.value))
            assertTrue(runCatching {SqliteResourceFiles(db,actor)}.isFailure)
            val columns=db.rawQuery("PRAGMA table_info(resource_variants)",null).use {rows->buildList {while(rows.moveToNext()) add(rows.getString(1))}}
            assertFalse("sort_kind" in columns);assertFalse("sort_id" in columns);assertFalse("sort_version" in columns)
            db.execSQL("DELETE FROM resource_variants WHERE key='z-broken'")
            SqliteResourceFiles(db,actor);assertEquals(listOf(valid),ordered(db))
        }
    }
}
