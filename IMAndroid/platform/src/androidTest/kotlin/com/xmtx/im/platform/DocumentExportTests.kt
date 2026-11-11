package com.xmtx.im.platform

import android.content.*
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest

class ExportTestProvider: ContentProvider() {
    override fun onCreate()=true
    override fun getType(uri: Uri)="application/octet-stream"
    override fun query(uri: Uri,p: Array<out String>?,s: String?,a: Array<out String>?,o: String?): Cursor?=null
    override fun insert(uri: Uri,values: ContentValues?): Uri?=null
    override fun update(uri: Uri,values: ContentValues?,s: String?,a: Array<out String>?)=0
    private fun file(uri: Uri): File { val name=requireNotNull(uri.lastPathSegment);require(name.startsWith("export-") && !name.contains('/'));return File(requireNotNull(context).filesDir,name) }
    override fun delete(uri: Uri,s: String?,a: Array<out String>?)=if(file(uri).delete()) 1 else 0
    override fun openFile(uri: Uri,mode: String): ParcelFileDescriptor=ParcelFileDescriptor.open(file(uri),ParcelFileDescriptor.parseMode(mode))
}
class DocumentExportTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun source()=File.createTempFile("source-",".bin",context.filesDir).apply { writeBytes(ByteArray(200000) { (it%251).toByte() }) }
    private fun destination()=File.createTempFile("export-",".bin",context.filesDir)
    private fun uri(file: File)=Uri.parse("content://com.xmtx.im.platform.test.exports/${file.name}")
    private fun descriptor(file: File)=ResourceDescriptor(ResourceKey(ResourceHome.Room(RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),1,"数据.bin","application/octet-stream",file.length(),ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }),ResourceState.Ready)
    @Test fun streamPreservesExactOriginalAndDoesNotRemoveSuccessfulDestination()=runBlocking {
        val source=source();val out=destination();var checked=0
        try { DocumentExport.copy(context.contentResolver,uri(out),source,descriptor(source),System.nanoTime()+60_000_000_000) { checked++ };assertArrayEquals(source.readBytes(),out.readBytes());assertTrue(checked>3) }
        finally { source.delete();out.delete() }
    }
    @Test fun corruptLengthAndChecksumCannotBeReportedAsSaved()=runBlocking {
        val source=source()
        try {
            for(descriptor in listOf(descriptor(source).copy(byteCount=1),descriptor(source).copy(byteCount=300000),descriptor(source).copy(checksum=ResourceChecksum("0".repeat(64))))) {
                val out=destination()
                try { val failure=runCatching { DocumentExport.copy(context.contentResolver,uri(out),source,descriptor,System.nanoTime()+60_000_000_000) {} }.exceptionOrNull();assertTrue(failure is MediaReadFailure);assertTrue(DocumentExport.discard(context,uri(out)));assertFalse(out.exists()) }
                finally { out.delete() }
            }
        } finally { source.delete() }
    }
    @Test fun staleAndExpiredAuthorityNeverOpenDestinationAndNonContentUrisAreRejected()=runBlocking {
        val source=source();val out=destination().apply { writeText("untouched") }
        try {
            for(mode in 0..2) {
                assertTrue(runCatching { DocumentExport.copy(context.contentResolver,if(mode==2) Uri.fromFile(out) else uri(out),source,descriptor(source),System.nanoTime()+if(mode==0) -1 else 60_000_000_000) { if(mode==1) throw MediaReadFailure(MediaReadFailureReason.SourceChanged) } }.isFailure)
                assertEquals("untouched",out.readText())
            }
        } finally { source.delete();out.delete() }
    }
    @Test fun cancellationBetweenChunksStopsWritingAndAllowsPartialCleanup()=runBlocking {
        val source=source();val out=destination();val entered=CompletableDeferred<Unit>();var checks=0
        try {
            val task=launch { DocumentExport.copy(context.contentResolver,uri(out),source,descriptor(source),System.nanoTime()+60_000_000_000) { if(++checks==4) { entered.complete(Unit);awaitCancellation() } } }
            withTimeout(5000) { entered.await() };task.cancelAndJoin();assertTrue(out.length() in 1..<source.length());assertTrue(DocumentExport.discard(context,uri(out)));assertFalse(out.exists())
        } finally { source.delete();out.delete() }
    }
}
