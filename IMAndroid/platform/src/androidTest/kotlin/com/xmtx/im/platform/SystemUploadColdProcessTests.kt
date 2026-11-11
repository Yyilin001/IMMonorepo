package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.Base64

/** Run the two phases in different instrumentation processes, with the host killing only the test package between them. */
class SystemUploadColdProcessTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    @Test fun prepareQueuedTask()=runBlocking {
        val args=InstrumentationRegistry.getArguments();val endpoint=args.getString("coldURL")
        assumeTrue("Requires explicit controlled HTTPS cold-process fixture",endpoint!=null)
        File(context.noBackupFilesDir,"system-upload-test-ca.pem").writeBytes(Base64.getDecoder().decode(requireNotNull(args.getString("coldCA"))))
        val f=ResourceSystemUploadTests().Fixture(endpoint!!)
        try {
            val claim=f.prepare();val registration=f.registrations(claim).single()
            val mapping=f.store.installBackgroundUploads(claim,persistentListOf(registration)).single()
            ResourceSystemUploadDriver(context,TestResourceUploadJobService::class.java).schedule(f.store,f.files,mapping,registration.target)
            val metadata=buildJsonObject {
                put("actor",f.actor.value);put("device",f.device.value);put("mapping",mapping.payload());put("pid",android.os.Process.myPid());put("job",systemUploadJobId(mapping.task))
            }
            File(context.noBackupFilesDir,"system-upload-cold-fixture.json").writeText(metadata.toString())
            assertTrue(f.store.resourceUploads().single().execution.backgroundPending)
        } finally {f.close()}
    }
    @Test fun verifyTaskRanWithoutTheOriginalProcess()=runBlocking {
        assumeTrue("Requires explicit cold-process verification",InstrumentationRegistry.getArguments().getString("verifyCold")=="true")
        val metadata=Json.parseToJsonElement(File(context.noBackupFilesDir,"system-upload-cold-fixture.json").readText()).jsonObject
        val oldPid=metadata.getValue("pid").jsonPrimitive.int
        val workerPid=File(context.noBackupFilesDir,"system-upload-worker-pid.txt").readText().toInt()
        assertNotEquals(oldPid,workerPid)
        val mapping=ResourceBackgroundUploadMapping.decode(metadata.getValue("mapping").jsonObject)
        val store=SqliteClientStore(context,UserId(metadata.getValue("actor").jsonPrimitive.content),DeviceId(metadata.getValue("device").jsonPrimitive.content))
        val files=ManagedResourceFiles(context,store);val driver=ResourceSystemUploadDriver(context,TestResourceUploadJobService::class.java)
        try {
            val result=driver.completions(mapping.systemSession).single();assertEquals(204,result.status);assertEquals(10L,result.sentBytes)
            assertEquals(mapping.originDigest,result.originDigest)
            assertTrue(store.resourceUploads().single().execution.backgroundPending)
            assertEquals(1,driver.reconcile(store,files));assertEquals(0L,files.storageSnapshot().temporaryReservedBytes)
            assertEquals(ResourceUploadAction.Finalize,store.resourceUploads().single().execution.next);assertFalse(store.resourceUploads().single().terminal)
            assertTrue(driver.completions(mapping.systemSession).isEmpty())
        } finally {driver.cancelAndDrain(mapping);files.close();store.close()}
    }
}
