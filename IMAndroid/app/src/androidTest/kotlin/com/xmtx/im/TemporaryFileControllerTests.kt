package com.xmtx.im

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest

class TemporaryFileControllerTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private suspend fun until(test: ()->Boolean)=withTimeout(5000) { while(!test()) delay(10) }
    private suspend fun fixture(body: suspend CoroutineScope.(MessageFileController,TemporaryResourceFiles,()->TemporaryResourceLease?)->Unit)=coroutineScope {
        val source=File.createTempFile("temporary-controller-",".txt",context.filesDir).apply { writeText("文件内容") }
        val read=fileTestRead().let { it.copy(descriptor=it.descriptor.copy(byteCount=source.length(),checksum=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(source.readBytes()).joinToString("") { "%02x".format(it) }))) }
        val changes=MutableStateFlow(0L);val files=TemporaryResourceFiles(context,this,changes) {true};var lease:TemporaryResourceLease?=null
        val controller=MessageFileController(fileTestSelection(),this,changes,{read},{_,_->},{true},{},prepare={ files.prepare(AuthorizedOriginalRead(it.read,System.nanoTime()+60_000_000_000),source).also {lease=it} })
        try { controller.foreground(true);until {controller.state.available};body(controller,files,{lease}) }
        finally { controller.close();controller.awaitClosed();files.close();source.delete() }
    }
    @Test fun directOpenSurvivesBackgroundButReturningReleasesTheReadGrant()=runBlocking { fixture { controller,_,lease ->
        controller.present(TemporaryFileMode.Open);until {controller.state.action!=null};val action=controller.state.action!!
        assertNull(controller.begin());assertTrue(controller.claimPresentation(action.id));assertFalse(controller.claimPresentation(action.id))
        controller.presentationLaunched(action.id);controller.foreground(false);assertTrue(lease()!!.active)
        controller.presentationReturned(action.id);until {!controller.state.opening};assertFalse(lease()!!.active)
    } }
    @Test fun launchedShareOutlivesRouteAndPickerResultUntilAccountOwnerCloses()=runBlocking { fixture { controller,files,lease ->
        controller.present(TemporaryFileMode.Share);until {controller.state.action!=null};val action=controller.state.action!!
        assertTrue(controller.claimPresentation(action.id));controller.presentationLaunched(action.id);controller.presentationReturned(action.id)
        until {!controller.state.opening};controller.close();controller.awaitClosed();assertTrue(lease()!!.active)
        assertEquals("文件内容",context.contentResolver.openInputStream(lease()!!.uri)!!.bufferedReader().use {it.readText()})
        files.close();assertFalse(lease()!!.active)
    } }
    @Test fun failedLaunchAndBackgroundBeforeClaimReleaseEveryPreparedFile()=runBlocking { fixture { controller,_,lease ->
        controller.present(TemporaryFileMode.Share);until {controller.state.action!=null};val first=controller.state.action!!
        assertTrue(controller.claimPresentation(first.id));controller.presentationFailed(first.id);until {!controller.state.opening};assertFalse(lease()!!.active);assertTrue(controller.state.feedback!!.contains("分享"))
        controller.present(TemporaryFileMode.Open);until {controller.state.action!=null};controller.foreground(false)
        until {!controller.state.opening};assertFalse(lease()!!.active)
    } }
    @Test fun staleReturnDoesNotCloseANewerViewerAndAccountExpiryClearsPendingAction()=runBlocking { fixture { controller,files,lease ->
        controller.present(TemporaryFileMode.Open);until {controller.state.action!=null};val action=controller.state.action!!
        controller.presentationReturned("old-request");assertTrue(controller.state.opening);assertNotNull(controller.state.action)
        files.close();until {!controller.state.opening};assertFalse(lease()!!.active);assertNull(controller.state.action);assertTrue(controller.state.feedback!!.contains("失效"))
        assertFalse(controller.claimPresentation(action.id))
    } }
}
