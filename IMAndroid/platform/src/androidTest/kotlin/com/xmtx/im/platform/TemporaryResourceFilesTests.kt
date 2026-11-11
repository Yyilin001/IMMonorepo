package com.xmtx.im.platform

import android.net.Uri
import android.provider.OpenableColumns
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest

class TemporaryResourceFilesTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun source()=File.createTempFile("presentation-source-",".txt",context.filesDir).apply { writeText("临时文件内容".repeat(10000)) }
    private fun read(file: File,deadline: Long=System.nanoTime()+60_000_000_000)=AuthorizedOriginalRead(MessageResourceRead(
        ResourceDescriptor(ResourceKey(ResourceHome.Room(RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),1,"项目说明.txt","text/plain",file.length(),ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }),ResourceState.Ready),MessageResourceSource(RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),MessageId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"),0,1),"A".repeat(32)),deadline)
    private fun contents(uri: Uri)=context.contentResolver.openInputStream(uri)!!.bufferedReader().use { it.readText() }
    private fun files()=File(context.cacheDir,"resource-presentations-v1").listFiles().orEmpty()
    @Test fun exactBytesMetadataReadOnlyModeAndClosedUriAreEnforced()=runBlocking {
        val source=source();val owner=TemporaryResourceFiles(context,this,MutableStateFlow(0L)) {true}
        try {
            val lease=owner.prepare(read(source),source);assertEquals(source.readText(),contents(lease.uri));assertEquals("text/plain",context.contentResolver.getType(lease.uri))
            assertTrue(lease.uri.lastPathSegment!!.endsWith(".txt"))
            context.contentResolver.query(lease.uri,arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE),null,null,null)!!.use { assertTrue(it.moveToFirst());assertEquals("项目说明.txt",it.getString(0));assertEquals(source.length(),it.getLong(1)) }
            for(mode in listOf("w","rw","rwt","wa")) assertTrue(runCatching { context.contentResolver.openFileDescriptor(lease.uri,mode)?.close() }.isFailure)
            assertTrue(runCatching { contents(lease.uri.buildUpon().appendQueryParameter("name","other").build()) }.isFailure)
            assertTrue(runCatching { context.contentResolver.delete(lease.uri,null,null) }.isFailure)
            lease.release();assertTrue(runCatching { contents(lease.uri) }.isFailure);assertTrue(files().isEmpty());assertTrue(source.exists())
        } finally { owner.close();source.delete() }
    }
    @Test fun sourceRevocationAndPermitExpiryReleaseRegisteredFiles()=runBlocking {
        val source=source();val changes=MutableStateFlow(0L);var valid=true;val owner=TemporaryResourceFiles(context,this,changes) {valid}
        try {
            val first=owner.prepare(read(source),source);valid=false;changes.value++
            withTimeout(5000) { first.awaitReleased() };assertTrue(runCatching { contents(first.uri) }.isFailure)
            valid=true;val second=owner.prepare(read(source,System.nanoTime()+1_500_000_000),source)
            withTimeout(5000) { second.awaitReleased() };assertTrue(runCatching { contents(second.uri) }.isFailure);assertTrue(files().isEmpty())
        } finally { owner.close();source.delete() }
    }
    @Test fun corruptionAndCancellationNeverPublishAnAccessibleFile()=runBlocking {
        val source=source();var calls=0;var cancel=false;val entered=CompletableDeferred<Unit>();val owner=TemporaryResourceFiles(context,this,MutableStateFlow(0L)) { if(cancel && ++calls==3) { entered.complete(Unit);awaitCancellation() };true }
        try {
            val expected=read(source);source.appendText("corrupted")
            assertTrue(runCatching { owner.prepare(expected,source) }.exceptionOrNull() is MediaReadFailure);assertTrue(files().isEmpty())
            cancel=true;val copy=launch { owner.prepare(read(source),source) };withTimeout(5000) { entered.await() };copy.cancelAndJoin();assertTrue(files().isEmpty())
        } finally { owner.close();source.delete() }
    }
    @Test fun quotaAndStartupCleanupPreserveLiveLeasesButRemoveOrphans()=runBlocking {
        val source=source();val owner=TemporaryResourceFiles(context,this,MutableStateFlow(0L)) {true}
        try {
            val active=(0..3).map { owner.prepare(read(source),source) }
            assertTrue(runCatching { owner.prepare(read(source),source) }.isFailure)
            val orphan=File(context.cacheDir,"resource-presentations-v1/orphan.bin").apply { writeText("orphan") }
            TemporaryResourceFiles.cleanup(context);assertFalse(orphan.exists());assertEquals(4,files().size)
            active.forEach { assertEquals(source.readText(),contents(it.uri)) }
            owner.close();assertTrue(files().isEmpty());active.forEach { assertTrue(runCatching { contents(it.uri) }.isFailure) }
            assertTrue(runCatching { owner.prepare(read(source),source) }.isFailure)
        } finally { owner.close();source.delete() }
    }
    @Test fun accountCloseWaitsForCancelledPreparationBeforeRemovingItsFile()=runBlocking {
        val source=source();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var checks=0
        val owner=TemporaryResourceFiles(context,this,MutableStateFlow(0L)) { if(++checks==3) { entered.complete(Unit);withContext(NonCancellable) { release.await() } };true }
        try {
            val copy=launch { owner.prepare(read(source),source) };withTimeout(5000) { entered.await() }
            val close=async { owner.close() };delay(30);assertFalse(close.isCompleted)
            release.complete(Unit);withTimeout(5000) { close.await();copy.join() };assertTrue(files().isEmpty())
        } finally { release.complete(Unit);owner.close();source.delete() }
    }
}
