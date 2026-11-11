package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.Serializable

@Serializable data class ConversationDraft(val room: RoomId,val revision: Long=0,val text: String="",
    @Serializable(with=SendAttachmentsSerializer::class) val attachments: PersistentList<SendAttachment> = persistentListOf(),val updatedAt: Long=0,val rich: MessageRichContent=MessageRichContent.Empty,
    @Serializable(with=ConversationImportsSerializer::class) val imports: PersistentList<ConversationImportedAttachment> = persistentListOf(),
    @Serializable(with=SendAttachmentOrderSerializer::class) val attachmentOrder: PersistentList<String> = (attachments.map {it.id}+imports.map {it.id}).toPersistentList()) {
    init {
        rich.validate(text)
        uuidId(room.value);require(revision>=0 && updatedAt>=0 && text.toByteArray(Charsets.UTF_8).size<=65536)
        val ids=attachments.map {it.id}+imports.map {it.id}
        require(ids.size<=10 && ids.distinct().size==ids.size && attachments.map {it.asset}.distinct().size==attachments.size)
        require((attachments.map {it.asset}+imports.map {it.id}).distinct().size==ids.size)
        require(imports.all {it.transfer.request.targetUsage==ResourceUsage.Attachment(room)})
        require(imports.map {it.transfer.request.operation}.distinct().size==imports.size)
        val media=attachments.map {it.id}+imports.map {it.transfer.request.targetMedia}
        require(media.distinct().size==media.size)
        require(attachmentOrder.size==ids.size && attachmentOrder.toSet()==ids.toSet())
    }
    val empty get()=text.isEmpty() && attachmentOrder.isEmpty() && rich==MessageRichContent.Empty
    val sendImports get()=imports.map {it.transfer}.toPersistentList()
    val sendText get()=if(rich.entities.isEmpty()) text.trim() else text
}
class ConversationDraftConflict: IllegalStateException("草稿已变化，请重新读取后再操作")
class ConversationDraftSubmissionRejected(message: String): IllegalStateException(message)
interface ConversationDraftStore {
    suspend fun conversationDraft(room: RoomId): ConversationDraft
    /** A changed plain-text body clears old formatting ranges, retaining explicit mentions and reply. */
    suspend fun saveConversationText(expected: ConversationDraft,text: String,now: Long): ConversationDraft
    /** Atomically replace exact text and rich fields against the entire expected draft revision. */
    suspend fun saveConversationContent(expected: ConversationDraft,text: String,rich: MessageRichContent,now: Long): ConversationDraft
    suspend fun addConversationAttachment(room: RoomId,attachment: SendAttachment,now: Long): ConversationDraft
    suspend fun removeConversationAttachment(expected: ConversationDraft,asset: String,now: Long): ConversationDraft
    suspend fun reorderConversationAttachments(expected: ConversationDraft,assets: PersistentList<String>,now: Long): ConversationDraft
    /** Saves the fixed send and consumes only this draft revision in one transaction. Repeating it is safe. */
    suspend fun submitConversationDraft(expected: ConversationDraft,intent: SendIntent,now: Long): SendIntent
}
