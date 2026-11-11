package com.xmtx.im

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import org.junit.Assert.*
import java.io.File

internal data class PeerAttachmentFixture(val asset: ResourceLocalAsset,val message: Message,val text: String,val bytes: String)

/** Real peer traffic supplies the source; the App's own model/store are never seeded or mutated by the fixture. */
internal suspend fun sendPeerAttachment(store: SqliteClientStore,socket: RealtimeConnection,api: AuthenticatedTransport,
    http: OkHttpClient,actor: UserId,room: RoomId,run: String): PeerAttachmentFixture=withTimeout(60000) {
    val context=InstrumentationRegistry.getInstrumentation().targetContext
    val resources=AccountResourceActivity(context,store,ResourceUploadClient(api,actor)) {ManagedResourceUploadBytes(it,ResourcePlanUploader(http))}
    try {
        val body="真实界面附件内容 $run";val text="真实附件来源 $run"
        val source=File.createTempFile("ui-resource-",".txt",context.cacheDir)
        val asset=try {source.writeText(body);resources.files.importFile(source,"UI附件-$run.txt","text/plain",ResourceUsage.Attachment(room),4096)} finally {source.delete()}
        val sends=SendIntentService(actor,store);val intent=sends.enqueue(room,text,persistentListOf(SendAttachment(asset.id,asset.id,asset.displayName,asset.contentType,asset.byteCount)))
        coroutineScope {
            val transfer=launch {resources.runForeground()};val preparation=launch {sends.runPreparation()}
            try {while(store.pending().none {it.clientMessageId==intent.operation}) delay(100)}
            finally {preparation.cancelAndJoin();transfer.cancelAndJoin()}
        }
        val outbox=MessageOutbox(socket,store)
        while(store.pending().any {it.clientMessageId==intent.operation}) {outbox.flush();delay(250)}
        var message: Message?=null
        while(message==null) {
            RoomSyncEngine(socket,store).synchronize()
            message=store.snapshot().messages.firstOrNull {it.text==text && it.revision>0};if(message==null) delay(500)
        }
        PeerAttachmentFixture(asset,requireNotNull(message),text,body)
    } finally {resources.close()}
}

internal fun verifyConversationResourceBackendUi(compose: ComposeContentTestRule,restoration: StateRestorationTester,
    model: ()->AppViewModel,reopen: (String)->Unit,hideKeyboard: ()->Unit,room: RoomId,actor: UserId,peer: Credentials,
    peerApi: AuthenticatedTransport,peerStore: SqliteClientStore,peerSocket: RealtimeConnection,http: OkHttpClient,run: String,phase: (String)->Unit) {
    fun waitFor(body: ()->Boolean)=compose.waitUntil(45000,body)
    fun capture(name: String) {
        if(InstrumentationRegistry.getArguments().getString("captureAppBackend")!="true") return
        compose.waitForIdle();val instrumentation=InstrumentationRegistry.getInstrumentation();val image=requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {instrumentation.targetContext.openFileOutput(name,0).use {image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}} finally {image.recycle()}
    }
    phase("peer uploads and sends a real source attachment")
    val source=runBlocking {sendPeerAttachment(peerStore,peerSocket,peerApi,http,peer.userId,room,run)}
    waitFor {compose.onAllNodesWithText(source.text).fetchSemanticsNodes().isNotEmpty()}
    phase("resource center lists a real attachment, retains it and restores the shared detail stack")
    compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("我的").performClick()
    compose.onNodeWithText("资源中心").performClick()
    waitFor {model().state.value.resourceLibrary.entries.any {it.descriptor.key.media==source.asset.id}}
    compose.onNodeWithTag("resource-library-search").performTextInput(source.asset.displayName);hideKeyboard()
    waitFor {model().state.value.resourceLibrary.let {it.search==source.asset.displayName && !it.loading && it.entries.any {row->row.descriptor.key.media==source.asset.id}}}
    phase("resource selection retains the original before download and repeated retention is unchanged")
    compose.onNodeWithTag("resource-select-mode").performClick();compose.onNodeWithTag("resource-entry-${source.asset.id}").performClick()
    compose.onNodeWithTag("resource-selected-retain").performClick()
    waitFor {model().state.value.resourceLibrary.let {it.selection.retentionResult?.changedCount==1 && it.entries.any {row->row.descriptor.key.media==source.asset.id && row.retained}}}
    compose.onNodeWithTag("resource-entry-${source.asset.id}").performClick();compose.onNodeWithTag("resource-selected-retain").performClick()
    waitFor {model().state.value.resourceLibrary.selection.retentionResult?.unchangedCount==1}
    compose.onNodeWithTag("resource-select-mode").performClick()
    compose.onNodeWithTag("resource-entry-${source.asset.id}").performClick()
    waitFor {model().state.value.resourceDetail?.let {it.original?.retained==true && it.usable}==true}
    assertFalse(model().state.value.resourceDetail!!.original!!.availableLocally)
    restoration.emulateSavedInstanceStateRestore()
    waitFor {model().state.value.resourceDetail?.let {it.original?.retained==true && it.usable}==true}
    compose.onNodeWithText("解除保留本机").assertIsDisplayed();capture("app-backend-resource-detail.png")
    phase("resource detail persists a manual download and the account owner completes it")
    compose.onNodeWithTag("resource-download").performScrollTo().performClick()
    waitFor {model().state.value.resourceDetail?.let {it.queuedDownload!=null && it.usable}==true}
    val downloadId=requireNotNull(model().state.value.resourceDetail?.queuedDownload)
    compose.onNodeWithTag("resource-detail").performScrollToNode(hasTestTag("resource-download-tasks"))
    compose.onNodeWithTag("resource-download-tasks").assertIsEnabled().performClick()
    try {waitFor {model().state.value.resourceDownloads.entries.any {it.work.id==downloadId && it.work.phase==ResourceDownloadPhase.Completed}}}
    catch(error:Throwable) {
        capture("app-backend-resource-download-failure.png")
        val row=model().state.value.resourceDownloads.entries.firstOrNull {it.work.id==downloadId}
        throw AssertionError("Manual download: ${row?.let {"sourceAvailable=${it.sourceAvailable}, phase=${it.work.phase}, control=${it.work.control}, requested=${it.work.requested}, attempts=${it.work.attempts}, issue=${it.work.issue}, claimed=${it.work.owner!=null}"}}",error)
    }
    assertEquals(source.asset.checksum,model().state.value.resourceDownloads.entries.first {it.work.id==downloadId}.work.descriptor.checksum)
    waitFor {model().state.value.resourceDownloads.network!=null}
    compose.onNodeWithTag("download-cellular").assertIsOn().performClick()
    waitFor {model().state.value.resourceDownloads.let {it.working==null && it.network?.allowsCellular==false}}
    compose.onNodeWithTag("download-constrained").assertIsOff().performClick()
    waitFor {model().state.value.resourceDownloads.let {it.working==null && it.network==ResourceDownloadNetworkPreferences(false,true)}}

    restoration.emulateSavedInstanceStateRestore()
    waitFor {model().state.value.resourceDownloads.entries.any {it.work.id==downloadId && it.work.phase==ResourceDownloadPhase.Completed}}
    compose.onNodeWithTag("download-cellular").assertIsOff();compose.onNodeWithTag("download-constrained").assertIsOn()
    capture("app-backend-resource-downloads.png")
    compose.onNodeWithContentDescription("返回").performClick()
    waitFor {model().state.value.resourceDetail?.let {it.usable && it.original?.availableLocally==true}==true}
    compose.onNodeWithTag("resource-open").performScrollTo().performClick()
    waitFor {runCatching {compose.onNodeWithTag("message-file-save").assertIsEnabled();true}.getOrDefault(false)}
    compose.onNodeWithContentDescription("返回").performClick();waitFor {model().state.value.resourceDetail?.usable==true}
    compose.onNodeWithContentDescription("返回").performClick()
    waitFor {model().state.value.resourceLibrary.entries.any {it.descriptor.key.media==source.asset.id && it.retained}}
    phase("unified transfers show the real completed download and restore the shared detail stack")
    compose.onNodeWithTag("resource-transfer-tasks").performClick();compose.onNodeWithTag("transfers-group-Finished").performClick()
    waitFor {model().state.value.resourceTransfers.let {it.available && it.page.entries.any {row->row.id==ResourceTransferId(ResourceTransferKind.Download,downloadId) && row.phase==ResourceTransferPhase.Completed}}}
    val transferTag="transfer-download/$downloadId"
    assertEquals(source.asset.byteCount,model().state.value.resourceTransfers.page.entries.first {it.id.value==downloadId}.confirmedBytes)
    restoration.emulateSavedInstanceStateRestore();compose.onNodeWithTag("resource-transfers").assertIsDisplayed()
    compose.onNodeWithTag("resource-transfers").performScrollToNode(hasTestTag(transferTag))
    compose.onNode(hasText("查看资源") and hasAnyAncestor(hasTestTag(transferTag))).performClick()
    waitFor {model().state.value.resourceDetail?.usable==true};compose.onNodeWithContentDescription("返回").performClick()
    waitFor {model().state.value.resourceTransfers.available};compose.onNodeWithContentDescription("返回").performClick()
    waitFor {model().state.value.resourceLibrary.available && !model().state.value.resourceLibrary.loading}
    phase("selected cleanup protects a retained downloaded resource")
    compose.onNodeWithTag("resource-select-mode").performClick()
    compose.onNodeWithTag("resource-entry-${source.asset.id}").performClick()
    compose.onNodeWithTag("resource-selected-preview").performClick()
    waitFor {model().state.value.resourceLibrary.selection.preview!=null}
    assertEquals(0,model().state.value.resourceLibrary.selection.preview!!.plan.fileCount)
    assertEquals(1,model().state.value.resourceLibrary.selection.preview!!.plan.skippedCount)
    compose.onNodeWithTag("resource-selected-confirm").assertIsNotEnabled()
    compose.onNodeWithTag("resource-selected-dismiss").performClick();compose.onNodeWithTag("resource-select-mode").performClick()
    phase("storage UI measures downloaded retained bytes and persists a cache quota")
    compose.onNodeWithTag("resource-storage-open").performClick()
    waitFor {model().state.value.resourceStorage.snapshot?.retainedAllocatedBytes?.let {it>0}==true}
    compose.onNodeWithTag("storage-cache-limit").performScrollTo().performClick();compose.onNodeWithTag("storage-cache-256").performClick()
    waitFor {model().state.value.resourceStorage.let {!it.working && it.snapshot?.policy?.maximumCacheBytes==256L*1024*1024}}
    compose.onNodeWithTag("storage-managed-limit").performScrollTo().performClick();compose.onNodeWithTag("storage-managed-1024").performClick()
    waitFor {model().state.value.resourceStorage.let {!it.working && it.snapshot?.policy?.maximumManagedBytes==1024L*1024*1024}}
    restoration.emulateSavedInstanceStateRestore();compose.onNodeWithTag("resource-storage").assertIsDisplayed();capture("app-backend-storage.png")
    compose.onNodeWithContentDescription("返回").performClick()
    waitFor {model().state.value.resourceLibrary.entries.any {it.descriptor.key.media==source.asset.id && it.retained}}
    compose.onNodeWithTag("resource-library-retained").performClick()
    waitFor {model().state.value.resourceLibrary.let {it.retainedOnly && !it.loading && it.entries.size==1}}
    capture("app-backend-resource-library.png")
    compose.onNodeWithTag("resource-entry-${source.asset.id}").performClick();waitFor {model().state.value.resourceDetail?.usable==true}
    phase("resource detail source navigation prepares the same room editor")
    compose.onNodeWithTag("resource-source-${source.message.id.value}").performScrollTo().assertIsEnabled().performClick()
    try {waitFor {model().state.value.chatComposer?.let {it.room==room && it.available && !it.loading}==true}}
    catch(error:Throwable) {
        capture("app-backend-resource-source-failure.png")
        val state=model().state.value;val editor=state.chatComposer
        throw AssertionError("Source navigation: detail=${state.resourceDetail?.let {"available=${it.available}, loading=${it.loading}, working=${it.working}"}}, composer=${editor?.let {"matchingRoom=${it.room==room}, available=${it.available}, loading=${it.loading}, feedback=${it.feedback}"}}",error)
    }
    val text="UI 导入发送 $run"
    compose.onNodeWithTag("persistent-message-draft").performTextReplacement(text);hideKeyboard()
    waitFor {model().state.value.chatComposer?.let {it.text==text && !it.saving}==true}
    val composerId=requireNotNull(model().state.value.chatComposer).id
    phase("select through the actual shared Nav3 resource picker")
    compose.onNodeWithContentDescription("添加附件").performClick();compose.onNodeWithText("从聊天附件选择").performClick()
    waitFor {model().state.value.conversationResources?.entries?.any {it.descriptor.key.media==source.asset.id}==true}
    compose.onNodeWithText("我的",useUnmergedTree=true).assertDoesNotExist()
    compose.onNodeWithText("文件",substring=false).performClick()
    compose.onNodeWithTag("conversation-resource-search").performTextInput(source.asset.displayName);hideKeyboard()
    waitFor {model().state.value.conversationResources?.let {it.search==source.asset.displayName && !it.loading}==true}
    restoration.emulateSavedInstanceStateRestore()
    waitFor {compose.onAllNodesWithTag("conversation-resource-${source.asset.id}").fetchSemanticsNodes().isNotEmpty()}
    assertEquals(composerId,model().state.value.chatComposer?.id)
    compose.onNodeWithTag("conversation-resource-${source.asset.id}").performClick()
    waitFor {model().state.value.conversationResources?.selected!=null}
    compose.onNodeWithText("添加到当前聊天草稿？").assertIsDisplayed();capture("app-backend-resource-confirm.png")
    compose.onNodeWithText("添加到草稿").performClick()
    waitFor {model().state.value.conversationResources==null && model().state.value.chatComposer?.draft?.imports?.size==1}
    val chosen=requireNotNull(model().state.value.chatComposer?.draft).imports.single()
    assertEquals(source.message.id,chosen.selection.source.message);assertEquals(ResourceUsage.Attachment(room),chosen.transfer.request.targetUsage)
    assertEquals(composerId,model().state.value.chatComposer?.id);assertTrue(model().state.value.snapshot.resourceImports.none {it.id==chosen.id})
    assertTrue(model().state.value.snapshot.sendIntents.none {it.intent.serverImports.any {dependency->dependency.id==chosen.id}})
    phase("account owner recreation preserves selected source and draft without starting an import")
    reopen(source.text)
    waitFor {model().state.value.chatComposer?.draft?.imports?.singleOrNull()==chosen}
    compose.onNodeWithTag("persistent-message-draft").assertTextContains(text);compose.onNode(hasText(source.asset.displayName) and hasAnyAncestor(hasTestTag("composer-attachments"))).assertExists()
    assertTrue(model().state.value.snapshot.resourceImports.none {it.id==chosen.id});capture("app-backend-resource-draft.png")
    phase("UI send freezes the import and the real peer receives its independent target")
    compose.onNodeWithContentDescription("发送").performClick();hideKeyboard()
    // Keep Compose's test scheduler progressing while account-owned I/O and the peer run.
    // A blocking peer loop can otherwise leave queued UI effects unprocessed for the whole timeout.
    val peerWait=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    val receiving=peerWait.async {withTimeout(60000) {
        var message: Message?=null
        while(message==null) {
            RoomSyncEngine(peerSocket,peerStore).synchronize()
            message=peerStore.snapshot().messages.firstOrNull {it.sender==actor && it.text==text && it.media?.presentations?.size==1}
            if(message==null) delay(500)
        };requireNotNull(message)
    }}
    val received=try {
        compose.waitUntil(65000) {receiving.isCompleted}
        runBlocking {receiving.await()}
    } finally {runBlocking {receiving.cancelAndJoin()};peerWait.cancel()}
    waitFor {model().state.value.snapshot.sendIntents.any {it.intent.text==text && it.phase==SendIntentPhase.Accepted && it.intent.sourcesReleased}}
    val descriptor=requireNotNull(received.media?.presentations).single().descriptor
    assertEquals(chosen.transfer.request.targetMedia,descriptor.key.media);assertNotEquals(source.asset.id,descriptor.key.media)
    assertEquals(source.asset.checksum,descriptor.checksum);assertEquals(source.asset.byteCount,descriptor.byteCount)
    assertEquals(1,runBlocking {peerStore.snapshot().messages.count {it.sender==actor && it.text==text}})
    waitFor {model().state.value.chatComposer?.draft?.empty==true}
    phase("withdrawal while confirmation is open invalidates the old source in the real UI")
    compose.onNodeWithContentDescription("添加附件").performClick();compose.onNodeWithText("从聊天附件选择").performClick()
    waitFor {model().state.value.conversationResources?.entries?.any {it.descriptor.key.media==source.asset.id}==true}
    compose.onNodeWithTag("conversation-resource-${source.asset.id}").performClick();waitFor {model().state.value.conversationResources?.selected!=null};compose.onNodeWithText("添加到草稿").assertIsDisplayed()
    runBlocking {withTimeout(30000) {
        val service=MessageMutationService(peer.userId,MessageMutationClient(peerApi),peerStore)
        val change=service.enqueue(room,source.message.id,source.message.revision,null)
        while(!peerStore.mutationWorks().first {it.command.operation==change.command.operation}.terminal) {service.flush();delay(250)}
        assertEquals(MutationStatus.Committed,peerStore.mutationWorks().first {it.command.operation==change.command.operation}.status)
        RoomSyncEngine(peerSocket,peerStore).synchronize()
    }}
    waitFor {model().state.value.conversationResources?.let {it.selected==null && it.entries.none {row->row.descriptor.key.media==source.asset.id}}==true}
    compose.onNodeWithText("添加到草稿").assertDoesNotExist();compose.onNodeWithTag("conversation-resource-${source.asset.id}").assertDoesNotExist()
    compose.onNodeWithContentDescription("返回").performClick();waitFor {model().state.value.chatComposer?.draft?.empty==true}
    phase("recipient can still authorize and read imported bytes after source withdrawal")
    runBlocking {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val files=ManagedResourceFiles(context,peerStore,download=MediaFileDownloader(http)::download)
        val reader=MessageOriginalFiles(MediaDownloadTargetClient(peerApi),peerStore,files)
        try {assertEquals(source.bytes,reader.withAuthorizedOriginal(descriptor.key,message=MediaMessageLocation(room,received.id)) {_,file->file.readText()})}
        finally {reader.close();files.close()}
    }
    phase("withdrawn source retention is previewed and released through the actual resource UI")
    compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("我的").performClick();compose.onNodeWithText("资源中心").performClick()
    phase("unified transfers show the completed server import without exposing the revoked download name")
    waitFor {model().state.value.resourceLibrary.available && !model().state.value.resourceLibrary.loading}
    compose.onNodeWithTag("resource-transfer-tasks").performClick();compose.onNodeWithTag("transfers-group-Finished").performClick()
    waitFor {model().state.value.resourceTransfers.let {it.available && it.page.entries.any {row->row.id==ResourceTransferId(ResourceTransferKind.ServerImport,chosen.id) && row.phase==ResourceTransferPhase.Completed}}}
    val importedTransfer=model().state.value.resourceTransfers.page.entries.first {it.id==ResourceTransferId(ResourceTransferKind.ServerImport,chosen.id)}
    assertTrue(importedTransfer.hasBusinessOwners);assertNull(importedTransfer.totalBytes)
    val revokedTransfer=model().state.value.resourceTransfers.page.entries.first {it.id==ResourceTransferId(ResourceTransferKind.Download,downloadId)}
    assertNull(revokedTransfer.displayName);assertNull(revokedTransfer.resource)
    compose.onNodeWithTag("resource-transfers").performScrollToNode(hasTestTag("transfer-import/${chosen.id}"))
    capture("app-backend-transfers.png")
    phase("completed transfer opens actual send history rather than an empty pending task list")
    compose.onNode(hasText("查看会话发送记录") and hasAnyAncestor(hasTestTag("transfer-import/${chosen.id}"))).performClick()
    waitFor {compose.onAllNodesWithTag("send-history-list").fetchSemanticsNodes().isNotEmpty()}
    val sentOperation=model().state.value.snapshot.sendIntents.first {it.intent.text==text}.intent.operation
    waitFor {compose.onAllNodesWithTag("send-history-$sentOperation").fetchSemanticsNodes().isNotEmpty()}
    compose.onNodeWithTag("send-history-list").performScrollToNode(hasTestTag("send-history-$sentOperation"))
    compose.onNode(hasText(text) and hasAnyAncestor(hasTestTag("send-history-$sentOperation"))).assertIsDisplayed()
    compose.onNodeWithContentDescription("返回").performClick();waitFor {model().state.value.resourceTransfers.available}
    compose.onNodeWithContentDescription("返回").performClick()
    waitFor {model().state.value.resourceLibrary.available && !model().state.value.resourceLibrary.loading}
    compose.onNodeWithTag("resource-storage-open").performClick()
    waitFor {model().state.value.resourceStorage.snapshot?.policy?.let {it.maximumCacheBytes==256L*1024*1024 && it.maximumManagedBytes==1024L*1024*1024}==true}
    compose.onNodeWithText("下载任务").performScrollTo().performClick()
    waitFor {model().state.value.resourceDownloads.network==ResourceDownloadNetworkPreferences(false,true)}
    compose.onNodeWithTag("download-cellular").assertIsOff();compose.onNodeWithTag("download-constrained").assertIsOn()
    compose.onNodeWithContentDescription("返回").performClick()

    compose.onNodeWithContentDescription("返回").performClick()
    compose.onNodeWithTag("resource-unavailable-retention").performClick()
    waitFor {model().state.value.unavailableRetention.available}
    compose.onNodeWithTag("retention-release-preview").performClick()
    waitFor {model().state.value.unavailableRetention.plan?.count==1}
    compose.onNodeWithText(source.asset.displayName).assertDoesNotExist();capture("app-backend-retention-confirm.png")
    compose.onNodeWithTag("retention-release-confirm").performClick()
    waitFor {model().state.value.unavailableRetention.let {it.plan==null && !it.working && it.feedback?.startsWith("已解除 1 项")==true}}
    compose.onNodeWithTag("retention-release-preview").performClick()
    waitFor {model().state.value.unavailableRetention.feedback=="没有需要解除的失效保留"}
    capture("app-backend-retention-released.png")
    compose.onNodeWithContentDescription("返回").performClick()
    phase("storage cleanup previews and removes the released local cache through the actual UI")
    compose.onNodeWithTag("resource-storage-open").performClick()
    waitFor {model().state.value.resourceStorage.let {!it.working && it.snapshot?.cacheAllocatedBytes?.let {bytes->bytes>0}==true}}
    val cacheBytes=requireNotNull(model().state.value.resourceStorage.snapshot).cacheAllocatedBytes
    compose.onNodeWithTag("storage-cleanup-preview").performScrollTo().performClick()
    waitFor {model().state.value.resourceStorage.cleanupPlan?.fileCount==1}
    assertEquals(cacheBytes,model().state.value.resourceStorage.cleanupPlan!!.estimatedBytes)
    compose.onNodeWithText(source.asset.displayName).assertDoesNotExist();capture("app-backend-cache-cleanup-preview.png")
    compose.onNodeWithTag("storage-cleanup-dismiss").performClick()
    assertEquals(cacheBytes,model().state.value.resourceStorage.snapshot!!.cacheAllocatedBytes)
    compose.onNodeWithTag("storage-cleanup-preview").performScrollTo().performClick();waitFor {model().state.value.resourceStorage.cleanupPlan!=null}
    compose.onNodeWithTag("storage-cleanup-confirm").performClick()
    waitFor {model().state.value.resourceStorage.let {!it.working && it.cleanupResult?.deletedCount==1 && it.snapshot?.cacheAllocatedBytes==0L}}
    assertEquals(0,model().state.value.resourceStorage.cleanupResult!!.failedCount)
    compose.onNodeWithTag("storage-cleanup-result").performScrollTo().assertIsDisplayed();capture("app-backend-cache-cleanup-result.png")
    compose.onNodeWithTag("storage-cleanup-preview").performScrollTo().performClick()
    waitFor {model().state.value.resourceStorage.feedback?.startsWith("没有可清理的缓存")==true}
    compose.onNodeWithContentDescription("返回").performClick()
    phase("selected resource cleanup downloads and deletes only the independent imported target")
    compose.onNodeWithTag("resource-library-search").performTextClearance();hideKeyboard()
    if(model().state.value.resourceLibrary.retainedOnly) compose.onNodeWithTag("resource-library-retained").performClick()
    waitFor {model().state.value.resourceLibrary.let {!it.loading && it.entries.any {row->row.descriptor.key==descriptor.key}}}
    compose.onNodeWithTag("resource-library-list").performScrollToNode(hasTestTag("resource-entry-${descriptor.key.media}"))
    compose.onNodeWithTag("resource-entry-${descriptor.key.media}").performClick();waitFor {model().state.value.resourceDetail?.usable==true}
    compose.onNodeWithTag("resource-download").performScrollTo().performClick()
    waitFor {model().state.value.resourceDetail?.let {it.usable && it.original?.availableLocally==true}==true}
    compose.onNodeWithContentDescription("返回").performClick()
    waitFor {model().state.value.resourceLibrary.let {!it.loading && it.entries.any {row->row.descriptor.key==descriptor.key}}}
    compose.onNodeWithTag("resource-select-mode").performClick()
    compose.onNodeWithTag("resource-library-list").performScrollToNode(hasTestTag("resource-entry-${descriptor.key.media}"))
    compose.onNodeWithTag("resource-entry-${descriptor.key.media}").performClick()
    phase("batch retain protects imported bytes and batch release leaves bytes for explicit cleanup")
    compose.onNodeWithTag("resource-selected-retain").performClick()
    waitFor {model().state.value.resourceLibrary.selection.retentionResult?.changedCount==1}
    compose.onNodeWithTag("resource-retention-result").assertIsDisplayed();capture("app-backend-batch-retain.png")
    compose.onNodeWithTag("resource-entry-${descriptor.key.media}").performClick()
    compose.onNodeWithTag("resource-selected-preview").performClick()
    waitFor {model().state.value.resourceLibrary.selection.preview!=null}
    assertEquals(0,model().state.value.resourceLibrary.selection.preview!!.plan.fileCount)
    assertEquals(1,model().state.value.resourceLibrary.selection.preview!!.plan.skippedCount)
    compose.onNodeWithTag("resource-selected-confirm").assertIsNotEnabled();compose.onNodeWithTag("resource-selected-dismiss").performClick()
    compose.onNodeWithTag("resource-selected-release").performClick()
    waitFor {model().state.value.resourceLibrary.selection.retentionResult?.let {!it.retained && it.changedCount==1}==true}
    compose.onNodeWithTag("resource-entry-${descriptor.key.media}").performClick()
    compose.onNodeWithTag("resource-selected-preview").performClick()
    waitFor {model().state.value.resourceLibrary.selection.preview?.plan?.fileCount==1}
    assertEquals(1,model().state.value.resourceLibrary.selection.preview!!.resourceCount)
    capture("app-backend-selected-cleanup-preview.png")
    compose.onNodeWithTag("resource-selected-dismiss").performClick()
    assertNull(model().state.value.resourceLibrary.selection.result)
    compose.onNodeWithTag("resource-selected-preview").performClick();waitFor {model().state.value.resourceLibrary.selection.preview!=null}
    compose.onNodeWithTag("resource-selected-confirm").performClick()
    waitFor {model().state.value.resourceLibrary.selection.let {!it.working && it.result?.deletedCount==1}}
    assertEquals(0,model().state.value.resourceLibrary.selection.result!!.failedCount)
    compose.onNodeWithTag("resource-selection-result").assertIsDisplayed();capture("app-backend-selected-cleanup-result.png")
    compose.onNodeWithTag("resource-entry-${descriptor.key.media}").performClick();compose.onNodeWithTag("resource-selected-preview").performClick()
    waitFor {model().state.value.resourceLibrary.selection.preview!=null}
    assertEquals(1,model().state.value.resourceLibrary.selection.preview!!.absentResourceCount)
    compose.onNodeWithTag("resource-selected-confirm").assertIsNotEnabled()
    compose.onNodeWithTag("resource-selected-dismiss").performClick();compose.onNodeWithTag("resource-select-mode").performClick()
    compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("消息",useUnmergedTree=true).performClick()
    compose.onNodeWithTag("conversation-list").performScrollToNode(hasText(text));compose.onNodeWithText(text).performClick()
    waitFor {model().state.value.chatComposer?.let {it.room==room && it.available && !it.loading}==true}
}
