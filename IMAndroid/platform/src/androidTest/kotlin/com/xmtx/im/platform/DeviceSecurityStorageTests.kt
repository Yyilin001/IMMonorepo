package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class DeviceSecurityStorageTests {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun command(): DeviceRevocationCommand {
        val lines = InstrumentationRegistry.getInstrumentation().context.assets.open("device-revocation-swift.txt").bufferedReader().readLines()
        return DeviceRevocationCommand.decode(Json.parseToJsonElement(lines[2]).jsonObject)
    }
    @Test fun frozenSecurityJournalSurvivesKeystoreReopenWithoutPlaintextAndLosesSubmitAuthority() = runBlocking {
        val command = command(); val name = "test-device-security-${UUID.randomUUID()}"; val secrets = KeystoreSecretStore(context, name)
        try {
            val journal = DeviceRevocationJournal(secrets, command.baseline.actor, command.baseline.current)
            journal.write(persistentListOf(DeviceRevocationWork(command, roundEndsAt = 61000, nextActionAt = 1000)))
            val bytes = File(context.noBackupFilesDir, "$name.enc").readBytes()
            assertFalse(bytes.toString(Charsets.UTF_8).contains(command.operation)); assertFalse(bytes.toString(Charsets.UTF_8).contains("targetDeviceIDs"))
            val reopened = DeviceRevocationJournal(KeystoreSecretStore(context, name), command.baseline.actor, command.baseline.current)
            assertEquals(command, reopened.read().single().command)
            val transport = object : AuthenticatedTransport {
                override suspend fun request(path: String, payload: JsonObject?, query: Pair<String,String>?, maximumBytes: Long): EdgeResponse {
                    assertTrue(path.endsWith("operations/recover")); assertEquals(command.recovery(), payload)
                    return EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) })
                }
            }
            DeviceRevocationService(command.baseline.actor, command.baseline.current, DeviceSessionClient(transport, command.baseline.current), reopened, { 1000 }, { 0 }).flush()
            assertTrue(reopened.read().single().unknown); assertEquals(1, reopened.read().single().attempts)
            try { reopened.compareAndSet(persistentListOf(), persistentListOf()); fail("stale activation overwrote journal") } catch(_: IllegalStateException) { }
        } finally { secrets.delete() }
    }
    @Test fun corruptCiphertextCannotBecomeAnEmptyOrReplacementJournal() = runBlocking {
        val command = command(); val name = "test-device-corrupt-${UUID.randomUUID()}"; val secrets = KeystoreSecretStore(context, name)
        try {
            DeviceRevocationJournal(secrets, command.baseline.actor, command.baseline.current).write(persistentListOf(DeviceRevocationWork(command, roundEndsAt = 61000, nextActionAt = 1000)))
            val file = File(context.noBackupFilesDir, "$name.enc"); val bytes = file.readBytes(); bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte(); file.writeBytes(bytes)
            try { DeviceRevocationJournal(KeystoreSecretStore(context, name), command.baseline.actor, command.baseline.current).read(); fail("corrupt journal accepted") } catch(_: javax.crypto.AEADBadTagException) { }
            assertArrayEquals(bytes, file.readBytes())
        } finally { secrets.delete() }
    }
}
