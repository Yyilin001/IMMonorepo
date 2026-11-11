package com.xmtx.im.platform

import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.UUID

class LocalExitMarkerStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun fixture(test: suspend (String, FileLocalExitMarker) -> Unit) = runBlocking {
        val scope = "exit-${UUID.randomUUID()}"; val marker = FileLocalExitMarker(context, scope)
        try { test(scope, marker) } finally { for (suffix in listOf("", ".bak", ".new")) File(marker.path.path + suffix).delete() }
    }
    @Test fun committedPendingAndClearedRecordsSurviveIndependentStoreOwners() = fixture { scope, marker ->
        assertFalse(marker.isPending()); marker.markPending()
        assertTrue(FileLocalExitMarker(context, scope).isPending())
        assertEquals("{\"version\":1,\"pending\":true}", marker.path.readText())
        assertFalse(marker.path.name.contains(scope)); assertEquals(context.noBackupFilesDir, marker.path.parentFile)
        FileLocalExitMarker(context, scope).clearPending()
        assertFalse(FileLocalExitMarker(context, scope).isPending())
    }
    @Test fun malformedRecordsAndInterruptedWritesCannotBecomeNotPending() = fixture { _, marker ->
        for (value in listOf("", "{}", "{\"version\":2,\"pending\":false}", "{\"version\":1,\"pending\":\"false\"}", "x".repeat(512))) {
            marker.path.writeText(value)
            try { marker.isPending(); fail("malformed record accepted") } catch (e: LocalExitFailure) { assertEquals(LocalExitFailure.Reason.Malformed, e.reason) }
            assertEquals(value, marker.path.readText())
        }
        marker.markPending(); assertTrue(marker.isPending())
        File(marker.path.path + ".new").writeText("interrupted")
        try { marker.isPending(); fail("incomplete write ignored") } catch (_: LocalExitFailure) {}
        marker.markPending(); assertTrue(marker.isPending()); assertFalse(File(marker.path.path + ".new").exists())
    }
    @Test fun atomicBackupRestoresPendingAndSymlinkNeverFollowsAnotherFile() = fixture { _, marker ->
        marker.markPending(); val bytes = marker.path.readBytes()
        assertTrue(marker.path.renameTo(File(marker.path.path + ".bak")))
        assertTrue(marker.isPending()); assertArrayEquals(bytes, marker.path.readBytes())
        val outside = File(context.cacheDir, "exit-outside-${UUID.randomUUID()}").apply { writeText("retain") }
        try {
            marker.path.delete(); Os.symlink(outside.path, marker.path.path)
            try { marker.markPending(); fail("symlink overwritten") } catch (_: LocalExitFailure) {}
            try { marker.isPending(); fail("symlink followed") } catch (_: LocalExitFailure) {}
            assertEquals("retain", outside.readText())
        } finally { marker.path.delete(); outside.delete() }
    }
    @Test fun durableExitPreventsCredentialAccessWhenCredentialStorageIsUnavailable() = fixture { scope, marker ->
        val secret = object : SecretStore {
            override suspend fun read(): String? = throw IOException("unavailable fixture")
            override suspend fun write(value: String) = throw IOException("unavailable fixture")
            override suspend fun delete() = throw IOException("unavailable fixture")
        }
        var calls = 0
        val api = object : AccountTransport {
            override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject { calls++; error("network reached") }
        }
        val auth = AuthSession(secret, api, marker)
        auth.prepareLocalExit()
        try { auth.logout(); fail("unavailable credentials deleted") } catch (_: IOException) {}
        val reopened = AuthSession(secret, api, FileLocalExitMarker(context, scope))
        assertTrue(reopened.hasCleanup()); assertNull(reopened.current())
        try { reopened.localAccountIdentity(); fail("restored identity") } catch (_: ClientFailure.SignedOut) {}
        assertEquals(0, calls); assertTrue(marker.isPending())
    }
}
