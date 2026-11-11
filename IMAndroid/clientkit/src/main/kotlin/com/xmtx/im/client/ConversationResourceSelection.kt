package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.*
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.*
import kotlinx.serialization.json.*
import java.util.UUID

/** Frozen metadata for a chosen message. It grants neither byte access nor future import permission. */
@Serializable data class MessageAttachmentSelection(
    @Serializable(with=AttachmentDescriptorSerializer::class) val descriptor: ResourceDescriptor,val source: MessageResourceSource) {
    init {require(eligible(descriptor) && descriptor.key.home==ResourceHome.Room(source.room))}
    val key get()=descriptor.key
    val importSource get()=ResourceImportSource.Message(source.room,source.message,key.media)
    companion object {fun eligible(value: ResourceDescriptor)=value.state==ResourceState.Ready && value.byteCount<=50L*1024*1024}
}
internal object AttachmentDescriptorSerializer: KSerializer<ResourceDescriptor> {
    override val descriptor=buildClassSerialDescriptor("AttachmentDescriptor")
    override fun serialize(encoder: Encoder,value: ResourceDescriptor)=(encoder as JsonEncoder).encodeJsonElement(value.payload())
    override fun deserialize(decoder: Decoder)=ResourceDescriptor.decode((decoder as JsonDecoder).decodeJsonElement().jsonObject)
}
@Serializable data class ConversationImportedAttachment(val transfer: SendImportedAttachment,val selection: MessageAttachmentSelection) {
    init {require(transfer.request.source==selection.importSource)}
    val id get()=transfer.id
}
internal object ConversationImportsSerializer: ForwardListSerializer<ConversationImportedAttachment>(ConversationImportedAttachment.serializer())
interface ConversationImportDraftStore {
    suspend fun selectConversationResource(key: ResourceKey): MessageAttachmentSelection
    suspend fun isConversationResourceCurrent(selection: MessageAttachmentSelection): Boolean
    suspend fun addConversationImport(expected: ConversationDraft,attachment: ConversationImportedAttachment,now: Long): ConversationDraft
    suspend fun removeConversationImport(expected: ConversationDraft,id: String,now: Long): ConversationDraft
    suspend fun reorderConversationResources(expected: ConversationDraft,ids: PersistentList<String>,now: Long): ConversationDraft
}
class ConversationResourceSelectionService(private val store: ConversationImportDraftStore,private val now: ()->Long=System::currentTimeMillis) {
    suspend fun select(key: ResourceKey)=store.selectConversationResource(key)
    suspend fun isCurrent(selection: MessageAttachmentSelection)=store.isConversationResourceCurrent(selection)
    fun prepare(room: RoomId,selection: MessageAttachmentSelection)=ConversationImportedAttachment(
        SendImportedAttachment(id(),ResourceImportRequest(id(),selection.importSource,ResourceUsage.Attachment(room),id())),selection)
    /** Retain the prepared value for retry after an uncertain local write. No transfer starts here. */
    suspend fun add(expected: ConversationDraft,attachment: ConversationImportedAttachment)=store.addConversationImport(expected,attachment,now())
    private fun id()=UUID.randomUUID().toString().uppercase()
}
