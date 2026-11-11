package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.*
import java.util.UUID

class ConversationImportDraftTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val room=RoomId(id())
    private fun imported(target: RoomId=room): ConversationImportedAttachment {
        val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(RoomId(id())),id()),2,"文件.pdf","application/pdf",100,ResourceChecksum("a".repeat(64)),ResourceState.Ready)
        val selection=MessageAttachmentSelection(descriptor,MessageResourceSource((descriptor.key.home as ResourceHome.Room).room,MessageId(id()),1,3))
        return ConversationImportedAttachment(SendImportedAttachment(id(),ResourceImportRequest(id(),selection.importSource,ResourceUsage.Attachment(target),id())),selection)
    }
    @Test fun `mixed draft round trips immutable sources and exact order without transfer capabilities`() {
        val local=SendAttachment(id(),id(),"local.txt","text/plain",5);val remote=imported()
        val draft=ConversationDraft(room,attachments=persistentListOf(local),imports=persistentListOf(remote),attachmentOrder=persistentListOf(remote.id,local.id))
        val encoded=Json.encodeToString(draft);assertEquals(draft,Json.decodeFromString<ConversationDraft>(encoded))
        assertEquals(persistentListOf(remote.transfer),draft.sendImports);assertFalse(draft.empty)
        assertFalse(encoded.contains("download"));assertFalse(encoded.contains("http"));assertFalse(encoded.contains("filePath"))
        val another=imported();val next=draft.copy(imports=draft.imports.add(another),attachmentOrder=draft.attachmentOrder.add(another.id))
        assertEquals(1,draft.imports.size);assertEquals(2,next.imports.size)
        // Invalid permutations must be rejected by construction, not repaired silently.
    }
    @Test fun `old local draft json derives its order and preserves empty behavior`() {
        val local=SendAttachment(id(),id(),"old.txt","text/plain",5)
        val draft=ConversationDraft(room,attachments=persistentListOf(local))
        val encoded=Json.encodeToString(draft);assertFalse(encoded.contains("attachmentOrder"));assertFalse(encoded.contains("imports"))
        assertEquals(persistentListOf(local.id),Json.decodeFromString<ConversationDraft>(encoded).attachmentOrder)
        assertTrue(ConversationDraft(room).empty)
    }
    @Test fun `source target identity order and combined capacity are validated`() {
        val remote=imported();val valid=ConversationDraft(room,imports=persistentListOf(remote))
        assertFails {valid.copy(attachmentOrder=persistentListOf(id()))}
        assertFails {valid.copy(room=RoomId(id()))}
        assertFails {remote.copy(selection=remote.selection.copy(source=remote.selection.source.copy(message=MessageId(id()))))}
        assertFails {remote.selection.copy(descriptor=remote.selection.descriptor.copy(state=ResourceState.Pending))}
        assertFails {remote.selection.copy(descriptor=remote.selection.descriptor.copy(byteCount=50L*1024*1024+1))}
        val local=SendAttachment(id(),remote.id,"local.txt","text/plain",1)
        assertFails {ConversationDraft(room,attachments=persistentListOf(local),imports=persistentListOf(remote))}
        val many=(1..11).map {imported()}.toPersistentList();assertFails {ConversationDraft(room,imports=many)}
    }
}
