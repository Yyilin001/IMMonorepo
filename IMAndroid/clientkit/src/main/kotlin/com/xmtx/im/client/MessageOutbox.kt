package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.security.MessageDigest
import java.util.UUID

/** An account-scoped durable queue. Enqueue and claim metadata must survive process death together. */
interface OutboxStore : SendRecoveryStore {
    suspend fun enqueue(command: MessageSendOperation)
}

/** Frozen text/media/rich-content commands using the iOS domain v3 / operation v1 fingerprint encoding. */
object MessageCommand {
    fun text(account: UserId, room: RoomId, text: String, deadline: Long,
        operation: String = UUID.randomUUID().toString().uppercase(),rich: MessageRichContent=MessageRichContent.Empty): MessageSendOperation {
        require(text.isNotBlank())
        return prepare(account,room,text,persistentListOf(),deadline,operation,rich)
    }
    /** Ordered media identities grant no byte access; the server validates every attachment at binding. */
    fun withMedia(account: UserId,room: RoomId,text: String,media: PersistentList<String>,deadline: Long,
        operation: String=UUID.randomUUID().toString().uppercase(),rich: MessageRichContent=MessageRichContent.Empty): MessageSendOperation {
        require(media.isNotEmpty())
        return prepare(account,room,text,media.map(::uuidId).toPersistentList(),deadline,operation,rich)
    }
    private fun prepare(account: UserId,room: RoomId,text: String,media: PersistentList<String>,deadline: Long,operation: String,rich: MessageRichContent): MessageSendOperation {
        require(text.toByteArray(Charsets.UTF_8).size<=65536 && (text.isNotEmpty() || media.isNotEmpty()) && deadline>0)
        require(media.size<=10 && media.distinct().size==media.size)
        rich.validate(text)
        val operationId = canonicalId(operation)
        val domain = FingerprintEncoder().apply {
            string("im.v2.send-message"); integer(3); string(room.value); string(account.value); string(operationId); string(text)
            integer(media.size.toLong());media.forEach(::string)
            integer(rich.mentions.size.toLong());rich.mentions.forEach { when(it) {is MentionTarget.User->{tag(1);string(it.id.value)};MentionTarget.Everyone->tag(2)} }
            integer(rich.entities.size.toLong());rich.entities.forEach {integer(it.offsetUTF16.toLong());integer(it.lengthUTF16.toLong());string(it.kind.name);optional(it.linkURL)}
            optional(rich.replyTo?.value);tag(0)
        }.digest()
        val fingerprint = FingerprintEncoder().apply {
            string("im.v2.operation"); integer(1); string("sendMessage")
            string("domainFingerprint"); tag(4); bytes(domain)
            string("domainFingerprintVersion"); tag(2); integer(3)
            string("firstSubmissionDeadline"); tag(2); integer(deadline)
            string("identity"); tag(1); string("${account.value}/room/${room.value}/sendMessage/$operationId")
        }.digest()
        return MessageSendOperation.newBuilder().setRoomId(room.value).setSenderUserId(account.value).setClientMessageId(operationId)
            .setText(text).addAllMediaIds(media).setFirstSubmissionDeadlineMs(deadline).setDomainFingerprintVersion(3).setDomainFingerprint(ByteString.copyFrom(domain))
            .setFingerprintVersion(1).setFingerprint(ByteString.copyFrom(fingerprint)).apply {
                rich.mentions.forEach {target->addMentions(MessageSendMention.newBuilder().apply {when(target) {is MentionTarget.User->userId=target.id.value;MentionTarget.Everyone->everyone=true}})}
                rich.entities.forEach {e->addEntities(MessageSendEntity.newBuilder().setOffsetUtf16(e.offsetUTF16).setLengthUtf16(e.lengthUTF16).setKind(e.kind.name).apply {e.linkURL?.let {linkUrl=it}})}
                rich.replyTo?.let {replyToMessageId=it.value}
            }.build()
    }
    private class FingerprintEncoder {
        private val buffer = ByteArrayOutputStream()
        private val output = DataOutputStream(buffer)
        fun tag(value: Int) { output.writeByte(value) }
        fun optional(value: String?) {if(value==null) tag(0) else {tag(1);string(value)}}
        fun integer(value: Long) { output.writeLong(value) }
        fun string(value: String) = bytes(value.toByteArray(Charsets.UTF_8))
        fun bytes(value: ByteArray) { integer(value.size.toLong()); output.write(value) }
        fun digest(): ByteArray = MessageDigest.getInstance("SHA-256").digest(buffer.toByteArray())
    }
}
class MessageOutbox(private val transport: EnvelopeTransport, private val store: OutboxStore,private val admission: AccountRetryAdmission,
    private val now: () -> Long = System::currentTimeMillis) {
    constructor(transport: EnvelopeTransport,store: OutboxStore,now: ()->Long=System::currentTimeMillis):this(transport,store,AccountRetryAdmission(),now)
    private val mutex = Mutex()
    suspend fun send(account: UserId, room: RoomId, text: String,rich: MessageRichContent=MessageRichContent.Empty) {
        store.enqueue(MessageCommand.text(account, room, text, now() + ClientSubmissionWindow.COMMAND_MILLISECONDS,rich=rich))
        flush()
    }
    suspend fun sendMedia(account: UserId,room: RoomId,text: String,media: PersistentList<String>,rich: MessageRichContent=MessageRichContent.Empty) {
        store.enqueue(MessageCommand.withMedia(account,room,text,media,now()+ClientSubmissionWindow.COMMAND_MILLISECONDS,rich=rich))
        flush()
    }
    /** One bounded maintenance turn; completion means durable scheduling, not server acceptance. */
    suspend fun flush() = mutex.withLock {SendRecoveryRunner(transport,store,now,admission=admission).flush()}
}
