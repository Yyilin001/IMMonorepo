package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.KeyStore
import java.util.UUID

class CredentialStoreStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun fixture(body:suspend (String,File,KeystoreCredentialStore)->Unit)=runBlocking {
        val name="credential-state-${UUID.randomUUID()}";val file=File(context.noBackupFilesDir,"$name.enc")
        try {body(name,file,KeystoreCredentialStore(context,name))}
        finally {
            for(suffix in listOf("",".bak",".new")) File(file.path+suffix).delete()
            KeyStore.getInstance("AndroidKeyStore").apply {load(null);deleteEntry("com.xmtx.im.$name.v1")}
        }
    }
    private suspend fun failure(reason:CredentialStoreFailure.Reason,action:suspend ()->Unit) {
        try {action();fail("accepted inaccessible record")} catch(e:CredentialStoreFailure) {assertEquals(reason,e.reason);assertNull(e.cause)}
    }
    @Test fun missingIsDistinctFromMalformedEnvelopeAndAuthenticatedCiphertextFailure()=fixture {name,file,store->
        assertNull(store.read());store.write("fixture record");assertEquals("fixture record",KeystoreCredentialStore(context,name).read())
        val valid=file.readBytes();file.writeBytes(byteArrayOf(1,2))
        failure(CredentialStoreFailure.Reason.Malformed) {store.read()};assertArrayEquals(byteArrayOf(1,2),file.readBytes())
        val damaged=valid.copyOf();damaged[damaged.lastIndex]=(damaged.last().toInt() xor 1).toByte();file.writeBytes(damaged)
        failure(CredentialStoreFailure.Reason.Malformed) {store.read()};assertArrayEquals(damaged,file.readBytes())
    }
    @Test fun missingDeviceKeyNeverReplacesTheRecordOrCreatesANewKey()=fixture {name,file,store->
        store.write("keep this record");val bytes=file.readBytes()
        val keys=KeyStore.getInstance("AndroidKeyStore").apply {load(null)};val alias="com.xmtx.im.$name.v1";keys.deleteEntry(alias)
        failure(CredentialStoreFailure.Reason.PermanentlyInvalidated) {store.read()}
        failure(CredentialStoreFailure.Reason.PermanentlyInvalidated) {store.write("replacement")}
        assertArrayEquals(bytes,file.readBytes());assertFalse(keys.containsAlias(alias))
    }
    @Test fun orphanBackupAndNewFilePreventKeyReplacementDuringWrite()=fixture {name,file,store->
        store.write("keep backup");val bytes=file.readBytes()
        val keys=KeyStore.getInstance("AndroidKeyStore").apply {load(null)};val alias="com.xmtx.im.$name.v1";keys.deleteEntry(alias)
        for(suffix in listOf(".bak",".new")) {
            file.delete();val retained=File(file.path+suffix);retained.writeBytes(bytes)
            failure(CredentialStoreFailure.Reason.PermanentlyInvalidated) {store.write("replacement")}
            assertFalse(file.exists());assertArrayEquals(bytes,retained.readBytes());assertFalse(keys.containsAlias(alias));retained.delete()
        }
    }
    @Test fun restoredAtomicBackupKeepsTheSameCredentialIdentity()=fixture {name,file,store->
        store.write("original");val bytes=file.readBytes();file.renameTo(File(file.path+".bak"))
        assertEquals("original",KeystoreCredentialStore(context,name).read());assertArrayEquals(bytes,file.readBytes())
        store.write("updated");assertEquals("updated",store.read())
    }
    @Test fun explicitDeletionRetiresTheOldKeyAndAllowsAnIndependentNewCredential()=fixture {name,file,store->
        val keys=KeyStore.getInstance("AndroidKeyStore").apply {load(null)};val alias="com.xmtx.im.$name.v1"
        store.write("old credential");val old=file.readBytes();assertTrue(keys.containsAlias(alias))
        File(file.path+".bak").writeBytes(old);File(file.path+".new").writeBytes(old)
        store.delete();assertNull(store.read());assertFalse(keys.containsAlias(alias))
        assertTrue(listOf("",".bak",".new").none {File(file.path+it).exists()})
        store.write("new credential");assertEquals("new credential",KeystoreCredentialStore(context,name).read())
        file.writeBytes(old);failure(CredentialStoreFailure.Reason.Malformed) {store.read()}
        assertArrayEquals(old,file.readBytes())
    }
    @Test fun explicitDeletionOfAMissingKeyRecordAllowsNextLoginToCreateANewKey()=fixture {name,file,store->
        store.write("old credential")
        val keys=KeyStore.getInstance("AndroidKeyStore").apply {load(null)};val alias="com.xmtx.im.$name.v1";keys.deleteEntry(alias)
        failure(CredentialStoreFailure.Reason.PermanentlyInvalidated) {store.read()}
        store.delete();assertFalse(file.exists());assertFalse(keys.containsAlias(alias))
        store.write("new credential");assertEquals("new credential",KeystoreCredentialStore(context,name).read())
    }
}
