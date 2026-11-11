package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class DatabaseIdentityStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val user = UserId(UUID.randomUUID().toString())
    private val device = DeviceId(UUID.randomUUID().toString())
    private val file get() = accountDatabaseFile(context, user, device)

    @Test fun reopeningAndConcurrentOwnersRetainIdentityWhileAnotherDeviceHasItsOwn() = runBlocking {
        val other = DeviceId(UUID.randomUUID().toString())
        try {
            val original = SqliteClientStore(context, user, device).use { it.databaseIdentity }
            val reopened = (1..4).map { async(Dispatchers.IO) {
                SqliteClientStore(context, user, device).use { it.databaseIdentity }
            } }.awaitAll()
            assertTrue(reopened.all { it == original })
            SqliteClientStore(context, user, other).use { assertNotEquals(original, it.databaseIdentity) }
        } finally { SQLiteDatabase.deleteDatabase(file); SQLiteDatabase.deleteDatabase(accountDatabaseFile(context, user, other)) }
    }

    @Test fun trustedDatabaseWithoutTheNewTableMigratesOnceAndPreservesExistingRows() = runBlocking {
        val bootstrap = LocalStoreBootstrapper(context)
        try {
            bootstrap.open(user, device).close()
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use {
                it.execSQL("DROP TABLE im_database_identity")
                it.execSQL("CREATE TABLE migration_fixture(value TEXT NOT NULL)")
                it.execSQL("INSERT INTO migration_fixture VALUES('retained')")
            }
            val identity = bootstrap.open(user, device).use { it.databaseIdentity }
            bootstrap.open(user, device).use { assertEquals(identity, it.databaseIdentity) }
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
                db.rawQuery("SELECT value FROM migration_fixture", null).use { assertTrue(it.moveToFirst()); assertEquals("retained", it.getString(0)) }
            }
        } finally { SQLiteDatabase.deleteDatabase(file) }
    }

    @Test fun malformedExistingIdentityIsPreservedAndNeverSilentlyReplaced() = runBlocking {
        val bootstrap = LocalStoreBootstrapper(context)
        try {
            bootstrap.open(user, device).close()
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use {
                it.execSQL("CREATE TABLE preserved_fixture(value TEXT NOT NULL)")
                it.execSQL("INSERT INTO preserved_fixture VALUES('original record')")
            }
            for (value in listOf("not-a-uuid", "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")) {
                SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use {
                    it.enableWriteAheadLogging()
                    it.execSQL("UPDATE im_database_identity SET identity=?", arrayOf(value))
                }
                try { bootstrap.open(user, device).close(); fail("malformed identity accepted") }
                catch (error: LocalStoreFailure) { assertEquals(LocalStoreFailure.Reason.StoreUnavailable, error.reason) }
                // A failed writable open can change SQLite's header transaction counter. Check
                // retained application data; exact archive bytes are covered by recovery tests.
                SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS).use { db ->
                    db.rawQuery("SELECT identity FROM im_database_identity", null).use {
                        assertTrue(it.moveToFirst()); assertEquals(value, it.getString(0)); assertFalse(it.moveToNext())
                    }
                    db.rawQuery("SELECT value FROM preserved_fixture", null).use {
                        assertTrue(it.moveToFirst()); assertEquals("original record", it.getString(0)); assertFalse(it.moveToNext())
                    }
                }
                // The real failed constructor still permits explicit archival recovery.
                bootstrap.previewRecovery(user, device)
            }
        } finally { SQLiteDatabase.deleteDatabase(file) }
    }
}
