package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import org.junit.Assert.*
import java.util.UUID

internal data class MixedDraftBackendPreparation(val intent: SendIntent,val next: ConversationDraft,val photoImport: String,val extraChecksum: ResourceChecksum)

/** Actual source synchronization, draft selection, freeze and post-send replay checks stay together. */
internal suspend fun prepareMixedDraftBackend(store: SqliteClientStore,socket: EnvelopeTransport,files: ManagedResourceFiles,sends: SendIntentService,
    room: RoomId,photo: String,file: String,run: String): MixedDraftBackendPreparation {
    fun freshId()=UUID.randomUUID().toString().uppercase()
    withTimeout(15000) {while(true) {
        RoomSyncEngine(socket,store).synchronize()
        val visible=store.resourceDirectory(ResourceCatalogQuery(room=room)).entries.map {it.descriptor.key.media}.toSet()
        if(photo in visible && file in visible) break
        delay(100)
    }}
    val selectionService=ConversationResourceSelectionService(store)
    val importedPhoto=selectionService.prepare(room,selectionService.select(ResourceKey(ResourceHome.Room(room),photo)))
    val importedFile=selectionService.prepare(room,selectionService.select(ResourceKey(ResourceHome.Room(room),file)))
    val extraFile=java.io.File.createTempFile("mixed-import-",".txt",InstrumentationRegistry.getInstrumentation().targetContext.cacheDir)
    val extra=try {extraFile.writeText("mixed local $run");files.importFile(extraFile,"mixed.txt","text/plain",ResourceUsage.Attachment(room),4096)} finally {extraFile.delete()}
    val local=SendAttachment(freshId(),extra.id,extra.displayName,extra.contentType,extra.byteCount)
    var mixedDraft=store.addConversationAttachment(room,local,System.currentTimeMillis())
    mixedDraft=selectionService.add(mixedDraft,importedFile);mixedDraft=selectionService.add(mixedDraft,importedPhoto)
    mixedDraft=store.saveConversationText(mixedDraft,"mixed imported $run",System.currentTimeMillis())
    mixedDraft=store.reorderConversationResources(mixedDraft,persistentListOf(importedPhoto.id,local.id,importedFile.id),System.currentTimeMillis())
    assertTrue(store.resourceImports().isEmpty())
    val mixed=store.submitConversationDraft(mixedDraft,sends.prepareDraft(mixedDraft),System.currentTimeMillis())
    assertTrue(store.conversationDraft(room).empty)
    val afterMixed=store.saveConversationText(store.conversationDraft(room),"第三条草稿 $run",System.currentTimeMillis())
    store.submitConversationDraft(mixedDraft,mixed,System.currentTimeMillis())
    assertEquals(afterMixed,store.conversationDraft(room))
    return MixedDraftBackendPreparation(mixed,afterMixed,importedPhoto.id,extra.checksum)
}
