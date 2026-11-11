package com.xmtx.im.platform

import android.content.*
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class DocumentTestProvider: ContentProvider() {
    companion object {
        var opened=CountDownLatch(1);var release=CountDownLatch(1)
        fun uri(file: File)=Uri.parse("content://com.xmtx.im.platform.test.documents/${file.name}")
    }
    override fun onCreate()=true
    override fun getType(uri: Uri)=uri.getQueryParameter("mime") ?: "text/plain"
    override fun query(uri: Uri,projection: Array<out String>?,selection: String?,selectionArgs: Array<out String>?,sortOrder: String?): Cursor =
        MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE)).apply { addRow(arrayOf<Any?>("说明.txt",uri.getQueryParameter("size")?.toLong())) }
    override fun insert(uri: Uri,values: ContentValues?): Uri?=null
    override fun update(uri: Uri,values: ContentValues?,selection: String?,selectionArgs: Array<out String>?)=0
    override fun delete(uri: Uri,selection: String?,selectionArgs: Array<out String>?)=0
    override fun openAssetFile(uri: Uri,mode: String): AssetFileDescriptor {
        if(uri.lastPathSegment=="slow") {
            val pipe=ParcelFileDescriptor.createReliablePipe()
            Thread { ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { release.await(10,TimeUnit.SECONDS) } }.start()
            opened.countDown();return AssetFileDescriptor(pipe[0],0,AssetFileDescriptor.UNKNOWN_LENGTH)
        }
        val file=File(requireNotNull(context).filesDir,requireNotNull(uri.lastPathSegment))
        return AssetFileDescriptor(ParcelFileDescriptor.open(file,ParcelFileDescriptor.MODE_READ_ONLY),0,if(uri.getQueryParameter("known")=="true") file.length() else AssetFileDescriptor.UNKNOWN_LENGTH)
    }
}
class DocumentImportTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val room=RoomId(id())
    private fun store()=SqliteClientStore(context,UserId(id()),DeviceId(id()))
    private fun staging(store: SqliteClientStore)=File(context.noBackupFilesDir,"resources-${store.resourceScope}/document-imports")
    private fun source(bytes: Int=256)=File.createTempFile("document-",".txt",context.filesDir).apply { writeBytes(ByteArray(bytes) { (it%251).toByte() }) }
    @Test fun unknownLengthAndDishonestSizeUseActualBytesAndRestoreAfterReopen()=runBlocking {
        val source=source(200000);val store=store();var files=ManagedResourceFiles(context,store)
        try {
            val uri=DocumentTestProvider.uri(source).buildUpon().appendQueryParameter("size","1").build()
            val first=files.importDocument(context.contentResolver,uri,ResourceUsage.Attachment(room));val second=files.importDocument(context.contentResolver,uri,ResourceUsage.Attachment(room))
            assertEquals(200000L,first.byteCount);assertEquals("说明.txt",first.displayName);assertEquals("text/plain",first.contentType)
            assertEquals(ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(source.readBytes()).joinToString("") { "%02x".format(it) }),first.checksum)
            assertEquals(first.file,second.file);assertTrue(staging(store).listFiles()!!.isEmpty());source.delete()
            files.close();files=ManagedResourceFiles(context,store)
            assertEquals(2,files.selected(ResourceUsage.Attachment(room)).size)
            files.withOriginal(selection=first.id) { assertEquals(200000L,it.length()) }
        } finally { files.close();store.close();source.delete() }
    }
    @Test fun sizeLimitsEmptyDocumentsAndInvalidUrisLeaveNoSelectionOrStaging()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store);val source=source(1025);val empty=source(0)
        try {
            for(uri in listOf(DocumentTestProvider.uri(source),DocumentTestProvider.uri(source).buildUpon().appendQueryParameter("known","true").build(),DocumentTestProvider.uri(empty))) {
                assertTrue(runCatching { files.importDocument(context.contentResolver,uri,ResourceUsage.Attachment(room),maximumBytes=1024) }.isFailure)
                assertTrue(store.resourceAssets().isEmpty());assertTrue(staging(store).listFiles()!!.isEmpty())
            }
            assertTrue(runCatching { files.importDocument(context.contentResolver,DocumentTestProvider.uri(source),ResourceUsage.Attachment(room),maximumBytes=50L*1024*1024+1) }.isFailure)
            assertTrue(runCatching { files.importDocument(context.contentResolver,Uri.fromFile(source),ResourceUsage.Attachment(room)) }.isFailure)
        } finally { files.close();store.close();source.delete();empty.delete() }
    }
    @Test fun invalidMimeFallsBackToBinaryAndTemporaryQuotaIsEnforced()=runBlocking {
        val source=source();val store=store();var files=ManagedResourceFiles(context,store,ResourceOriginalPolicy(maximumTemporaryBytes=1))
        try {
            val uri=DocumentTestProvider.uri(source).buildUpon().appendQueryParameter("mime","text/plain; charset=utf8").build()
            assertTrue(runCatching { files.importDocument(context.contentResolver,uri,ResourceUsage.Attachment(room)) }.isFailure)
            assertTrue(store.resourceAssets().isEmpty());assertTrue(staging(store).listFiles()!!.isEmpty());files.close()
            store.setResourceStoragePolicy(ResourceOriginalPolicy())
            files=ManagedResourceFiles(context,store);assertEquals("application/octet-stream",files.importDocument(context.contentResolver,uri,ResourceUsage.Attachment(room)).contentType)
        } finally { files.close();store.close();source.delete() }
    }
    @Test fun cancelledProviderReadDrainsAndReleasesTheFileOwner()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store)
        DocumentTestProvider.opened=CountDownLatch(1);DocumentTestProvider.release=CountDownLatch(1)
        try {
            val work=launch { files.importDocument(context.contentResolver,Uri.parse("content://com.xmtx.im.platform.test.documents/slow"),ResourceUsage.Attachment(room)) }
            assertTrue(withContext(Dispatchers.IO) { DocumentTestProvider.opened.await(5,TimeUnit.SECONDS) })
            work.cancel();DocumentTestProvider.release.countDown();withTimeout(5000) { work.join() };assertTrue(work.isCancelled)
            assertTrue(store.resourceAssets().isEmpty());assertTrue(staging(store).listFiles()!!.isEmpty())
        } finally { DocumentTestProvider.release.countDown();files.close();store.close() }
    }
    @Test fun cancellationAfterPublicationDoesNotResurrectADiscardedSelection()=runBlocking {
        val store=store();val source=source();val files=ManagedResourceFiles(context,store,checkpoint={ if(it==ManagedResourceFiles.PublicationCheckpoint.Published) throw CancellationException("late return") })
        try {
            assertTrue(runCatching { files.importDocument(context.contentResolver,DocumentTestProvider.uri(source),ResourceUsage.Attachment(room)) }.exceptionOrNull() is CancellationException)
            assertTrue(files.selected(ResourceUsage.Attachment(room)).isEmpty());files.cleanup();assertTrue(store.resourceFiles().isEmpty());assertTrue(staging(store).listFiles()!!.isEmpty())
        } finally { files.close();store.close();source.delete() }
    }
    @Test fun privateStagingFromAnInterruptedProcessIsRemovedOnReopen()=runBlocking {
        val store=store();var files=ManagedResourceFiles(context,store)
        try {
            files.selected(ResourceUsage.Attachment(room));files.close()
            val orphan=File(staging(store),id()).apply { writeText("partial provider read") }
            files=ManagedResourceFiles(context,store);assertTrue(files.selected(ResourceUsage.Attachment(room)).isEmpty());assertFalse(orphan.exists())
        } finally { files.close();store.close() }
    }
}
