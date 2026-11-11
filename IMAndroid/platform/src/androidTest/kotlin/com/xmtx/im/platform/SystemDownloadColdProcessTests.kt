package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.Base64

/** Two explicit host-controlled phases; the original process must die between them. */
class SystemDownloadColdProcessTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    @Test fun prepareQueuedTask()=runBlocking {
        val args=InstrumentationRegistry.getArguments();val endpoint=args.getString("coldURL")
        assumeTrue("Requires controlled HTTPS fixture",endpoint!=null)
        File(context.noBackupFilesDir,"system-download-test-ca.pem").writeBytes(Base64.getDecoder().decode(requireNotNull(args.getString("coldCA"))))
        File(context.noBackupFilesDir,"system-download-worker-pid.txt").delete()
        val f=ResourceSystemDownloadTests().Fixture(endpoint!!)
        try {
            f.schedule()
            File(context.noBackupFilesDir,"system-download-cold-fixture.json").writeText(buildJsonObject {
                put("actor",f.actor.value);put("device",f.device.value);put("mapping",f.mapping.payload())
                put("pid",android.os.Process.myPid());put("job",systemDownloadJobId(f.mapping.task))
            }.toString())
            assertTrue(f.store.resourceDownloads().single().work.backgroundPending)
        } finally {f.closeOwner()}
    }
    @Test fun verifyTaskRanWithoutTheOriginalProcess()=runBlocking {
        val args=InstrumentationRegistry.getArguments()
        assumeTrue("Requires cold-process verification",args.getString("verifyCold")=="true")
        val metadata=Json.parseToJsonElement(File(context.noBackupFilesDir,"system-download-cold-fixture.json").readText()).jsonObject
        assertNotEquals(metadata.getValue("pid").jsonPrimitive.int,File(context.noBackupFilesDir,"system-download-worker-pid.txt").readText().toInt())
        val mapping=ResourceBackgroundDownloadMapping.decode(metadata.getValue("mapping").jsonObject)
        val store=SqliteClientStore(context,UserId(metadata.getValue("actor").jsonPrimitive.content),DeviceId(metadata.getValue("device").jsonPrimitive.content))
        val files=ManagedResourceFiles(context,store);val driver=ResourceSystemDownloadDriver(context,TestResourceDownloadJobService::class.java)
        try {
            val result=driver.completions(mapping.systemSession).single();assertEquals(200,result.status);assertEquals(21L,result.receivedBytes)
            assertEquals(mapping.originDigest,result.originDigest);assertTrue(store.resourceFiles().isEmpty())
            assertEquals(1,driver.reconcile(store,files));assertTrue(store.activeBackgroundDownloads().single().received)
            assertFalse(store.resourceDownloads().single().work.terminal)
            // A newly resolved account target is still required after physical receipt.
            val descriptor=store.resourceDownloads().single().work.descriptor
            val target=MediaDownloadTargetClient(object:AuthenticatedTransport {
                override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("unused")
                override suspend fun mediaTarget(path:String,query:Map<String,String>,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {put("plan",buildJsonObject {
                    put("version",1);put("mode","http_get");put("url",requireNotNull(args.getString("coldURL")))
                    put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()));put("expiresAtUnixMilliseconds",System.currentTimeMillis()+120000)
                    put("expectedByteCount",descriptor.byteCount);put("checksum",descriptor.checksum!!.payload())
                })})
            }).resolve(descriptor.key.media,null,null)
            files.publishBackgroundDownload(mapping,target)
            assertEquals("system-download-bytes",files.withDownloaded(target,cacheOnly=true) {it.readText()})
            assertTrue(store.completeBackgroundDownload(mapping,store.selectMessageResource(descriptor.key)))
            driver.reconcile(store,files);assertEquals(0L,files.storageSnapshot().temporaryReservedBytes)
            assertTrue(driver.completions(mapping.systemSession).isEmpty())
        } finally {
            store.resourceDownloads().firstOrNull()?.work?.let {if(!it.terminal) store.controlResourceDownload(it.id,ResourceDownloadControl.Cancel)}
            driver.cancelAndDrain(mapping);driver.reconcile(store,files);files.close();store.close()
        }
    }
}
