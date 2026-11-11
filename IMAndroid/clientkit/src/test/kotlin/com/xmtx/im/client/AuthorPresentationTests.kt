package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import kotlin.test.*

class AuthorPresentationTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val device=DeviceId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val stream="EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
    private val view="FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
    private val room=RoomId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
    private val lines get()=javaClass.getResourceAsStream("/author-presentation-swift.jsonl")!!.bufferedReader().readLines()
    private fun raw(index: Int=0)=Json.parseToJsonElement(lines[index]).jsonObject
    private fun bytes(value: JsonObject)=value.toString().toByteArray()
    private fun delta(index: Int=0)=AuthorPresentationDelta.decode(bytes(raw(index)))
    private fun payload(owner: AuthorPresentationView,index: Int=0,sequence: Long=1,padding: Int=0)=bytes(JsonObject(raw(index)+mapOf(
        "viewID" to JsonPrimitive(owner.start.view),"sequence" to JsonPrimitive(sequence),"ignored" to JsonPrimitive("x".repeat(padding)))))

    @Test fun `actual Swift deltas preserve four complete contexts and private name precedence`() {
        val value=delta();assertEquals(stream,value.stream);assertEquals(view,value.view);assertEquals(4,value.entries.size)
        assertEquals(listOf(ProfileContext.Relationship,ProfileContext.DirectConversation,ProfileContext.Room(room),ProfileContext.GroupJoinReview(room)),value.entries.map {it.key.context})
        assertTrue(value.entries.all {(it as AuthorPresentationEntry.Available).profile.displayName()=="私人备注"})
        assertEquals("群内昵称",(value.entries[2] as AuthorPresentationEntry.Available).profile.displayName(false))
        assertIs<AuthorPresentationEntry.Retryable>(delta(1).entries[0]);assertIs<AuthorPresentationEntry.Unavailable>(delta(1).entries[1])
        for((index,name) in listOf("资料暂不可用","已注销用户","受限用户").withIndex()) assertEquals(name,(delta(index+2).entries.single() as AuthorPresentationEntry.Available).profile.displayName())
        val earlier=value.entries;val changed=earlier.removeAt(0);assertEquals(4,earlier.size);assertEquals(3,changed.size)
        val input=bytes(raw());val decoded=AuthorPresentationDelta.decode(input);input.fill(0);assertEquals(value,decoded)
    }
    @Test fun `untrusted payload recipient timing ordering and retry contract are validated before use`() {
        for((field,value) in listOf("sequence" to JsonPrimitive(0),"sequence" to JsonPrimitive("1"),"sequence" to Json.parseToJsonElement(ULong.MAX_VALUE.toString()),
            "serverViewAgeMilliseconds" to JsonPrimitive(-1),"serverViewAgeMilliseconds" to JsonPrimitive(30000),
            "streamID" to JsonPrimitive("bad"),"actorUserID" to wireId(device.value),"deviceID" to wireId(actor.value),"retryAfterMilliseconds" to JsonPrimitive(1000))) {
            assertFailsWith<ClientFailure.Protocol>(field) {AuthorPresentationDelta.decode(bytes(JsonObject(raw()+mapOf(field to value))))}
        }
        assertFails {AuthorPresentationDelta.decode(bytes(JsonObject(raw()-"serverViewAgeMilliseconds")))}
        for(retry in listOf<JsonElement>(JsonNull,JsonPrimitive(0),JsonPrimitive(99),JsonPrimitive(60001)))
            assertFails {AuthorPresentationDelta.decode(bytes(JsonObject(raw(1)+mapOf("retryAfterMilliseconds" to retry))))}
        assertFails {AuthorPresentationDelta.decode(bytes(JsonObject(raw()+mapOf("unknown" to JsonPrimitive("x".repeat(32768))))))}
        assertFails {AuthorPresentationDelta.decode(byteArrayOf(0xc3.toByte(),0x28))}
    }
    @Test fun `entry count duplicates and independent context identities are enforced without HTTP batching limits`() {
        val original=raw(1);val batch=original.objectValue("batch")
        val entry=(batch.getValue("results") as JsonArray).first()
        fun withEntries(entries: List<JsonElement>)=bytes(JsonObject(original+mapOf("batch" to JsonObject(batch+mapOf("results" to JsonArray(entries))))))
        assertFails {AuthorPresentationDelta.decode(withEntries(emptyList()))}
        assertFails {AuthorPresentationDelta.decode(withEntries(listOf(entry,entry)))}
        val many=(1..17).map {i->Json.parseToJsonElement(entry.toString().replace(actor.value,"00000000-0000-0000-0000-${i.toString().padStart(12,'0')}").replace("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","00000000-0000-0000-0000-${i.toString().padStart(12,'0')}"))}
        assertFails {AuthorPresentationDelta.decode(withEntries(many))}
        // Unlike one HTTPS read, a delta may carry more than eight independently authorized contexts.
        val directs=(1..16).map {i->buildJsonObject {put("retryable",buildJsonObject {put("_0",ProfileKey(UserId("00000000-0000-0000-0000-${i.toString().padStart(12,'0')}"),ProfileContext.DirectConversation).payload())})}}
        assertEquals(16,AuthorPresentationDelta.decode(withEntries(directs)).entries.size)
    }
    @Test fun `receiver deducts causal transit time and keeps denial and retry deadlines independent`() {
        var now=1_000_000L;val receiver=AuthorPresentationReceiver(actor,device,{now})
        val current=receiver.begin(stream,persistentListOf(room));now+=1_000_000_000
        val received=receiver.receive(payload(current,1),current)!!
        val profile=(received.entries[2] as ReceivedAuthorPresentationEntry.Available).value
        assertEquals(current.startedNanos+299_200_000_000,profile.deadlineNanos)
        assertEquals(current.startedNanos+30_000_000_000,(received.entries[1] as ReceivedAuthorPresentationEntry.Unavailable).untilNanos)
        assertEquals(now+1_000_000_000,(received.entries[0] as ReceivedAuthorPresentationEntry.Retryable).notBeforeNanos)
        assertNull(receiver.receive(payload(current,1),current))
        now+=1_000_000_000
        assertEquals(current.startedNanos+299_200_000_000,profile.deadlineNanos)
        assertNotNull(receiver.receive(payload(current,1,2),current))
    }
    @Test fun `expired transit cannot become a retry grant and out of order deltas cannot renew`() {
        var now=0L;val receiver=AuthorPresentationReceiver(actor,device,{now});val current=receiver.begin(stream,persistentListOf())
        now=1_000_000_000
        val short=payload(current).decodeToString().replace("1700000300000","1700000001500").toByteArray()
        assertTrue(receiver.receive(short,current)!!.entries.isEmpty())
        assertNull(receiver.receive(payload(current),current))
        assertNotNull(receiver.receive(payload(current,sequence=3),current));assertNull(receiver.receive(payload(current,sequence=2),current))
    }
    @Test fun `wrong recipient or stream is rejected while old view and elapsed local view are inert`() {
        var now=0L;val receiver=AuthorPresentationReceiver(actor,device,{now});val first=receiver.begin(stream,persistentListOf(room));now=1_000_000_000
        assertFailsWith<ClientFailure.Protocol> {receiver.receive(payload(first).decodeToString().replace(stream,view).toByteArray(),first)}
        val second=receiver.begin(stream,persistentListOf());receiver.end(first);now+=1_000_000_000
        assertNull(receiver.receive(byteArrayOf(0),first));assertNotNull(receiver.receive(payload(second),second))
        now=second.renewByNanos;assertNull(receiver.receive(payload(second,sequence=2),second))
        receiver.close();assertFails {receiver.begin(stream,persistentListOf())}
    }
    @Test fun `server monotonic age cannot run ahead and long clock wrap still preserves a short lease`() {
        var now=Long.MAX_VALUE-100_000_000;val receiver=AuthorPresentationReceiver(actor,device,{now});val current=receiver.begin(stream,persistentListOf())
        assertFailsWith<ClientFailure.Protocol> {receiver.receive(payload(current),current)}
        now+=1_000_000_000
        val result=receiver.receive(payload(current),current)!!
        assertTrue((result.entries[0] as ReceivedAuthorPresentationEntry.Available).value.valid(now))
    }
    @Test fun `avatar content survives expired download permission but display lease never grows`() {
        var now=0L;val receiver=AuthorPresentationReceiver(actor,device,{now});val current=receiver.begin(stream,persistentListOf());now=1_000_000_000
        val base=delta();val profile=(base.entries[0] as AuthorPresentationEntry.Available).profile
        val media="11111111-1111-1111-1111-111111111111";val variant="22222222-2222-2222-2222-222222222222"
        val checksum=ResourceChecksum("a".repeat(64))
        val plan=ResourceTransferPlan(ResourceTransferMode.Get,"https://example.test/object",persistentListOf(),persistentMapOf(),null,base.serverNowMillis+500,12,null,null,checksum)
        val avatar=AvatarAccess(AvatarContent(media,variant,1,checksum,12),plan)
        val value=base.copy(view=current.start.view,entries=persistentListOf(AuthorPresentationEntry.Available(profile.copy(view=profile.view.copy(avatarMediaId=media)),avatar)))
        val result=(receiver.receive(value,current)!!.entries.single() as ReceivedAuthorPresentationEntry.Available).value
        assertEquals(avatar.content,result.avatar!!.content);assertNull(result.avatar!!.plan);assertNull(result.avatarDownloadDeadlineNanos)
        assertEquals(299_200_000_000,result.deadlineNanos)
    }
    @Test fun `inbox requires exact confirmation and old replies cannot reactivate replaced pages`() {
        var now=0L;val inbox=AuthorPresentationInbox(stream,actor,device,{now});val first=inbox.begin(persistentListOf());now=1_000_000_000
        inbox.accept(payload(first));assertNull(inbox.next(first))
        assertFails {inbox.confirm(first,first.start.copy(view=stream))}
        inbox.confirm(first,first.start);inbox.accept(payload(first));assertEquals(1,inbox.queuedFrames)
        val second=inbox.begin(persistentListOf(room));now+=1_000_000_000
        inbox.confirm(first,first.start);inbox.accept(payload(second));assertNull(inbox.next(second))
        inbox.confirm(second,second.start);inbox.accept(payload(first));assertNull(inbox.next(second))
        inbox.accept(payload(second));assertNotNull(inbox.next(second));inbox.end(first)
        inbox.accept(payload(second,sequence=2));assertNotNull(inbox.next(second));inbox.end(second);assertFails {inbox.next(second)}
    }
    @Test fun `inbox drops only oldest supplements under byte and frame pressure without renewing queued leases`() {
        var now=0L;val inbox=AuthorPresentationInbox(stream,actor,device,{now});val current=inbox.begin(persistentListOf());inbox.confirm(current,current.start);now=1_000_000_000
        repeat(12) {inbox.accept(payload(current,sequence=it+1L))}
        assertEquals(8,inbox.queuedFrames);assertEquals(5,inbox.next(current)!!.sequence)
        inbox.end(current);val next=inbox.begin(persistentListOf());inbox.confirm(next,next.start);now+=1_000_000_000
        repeat(5) {inbox.accept(payload(next,sequence=it+1L,padding=20000))}
        assertTrue(inbox.queuedBytes<=65536);assertTrue(inbox.queuedFrames in 1..2)
        now+=5_000_000_000
        val received=inbox.next(next)!!
        assertTrue(received.sequence>1);assertEquals(next.startedNanos+299_200_000_000,(received.entries[0] as ReceivedAuthorPresentationEntry.Available).value.deadlineNanos)
        inbox.close();assertEquals(0,inbox.queuedBytes);assertEquals(0,inbox.queuedFrames)
    }
    @Test fun `inbox validates recipient even when no view is listening`() {
        val inbox=AuthorPresentationInbox(stream,actor,device)
        assertFails {inbox.accept(bytes(JsonObject(raw()+mapOf("streamID" to JsonPrimitive(view)))))}
        inbox.accept(bytes(raw()));assertEquals(0,inbox.queuedBytes)
    }
    @Test fun `control values bound full immutable interests and exact retained keys`() {
        val keys=delta().entries.map {it.key}.toPersistentList()
        val start=AuthorPresentationStart(stream,view,persistentListOf(room));assertFails {start.copy(messageRooms=persistentListOf(room,room))}
        assertFails {AuthorPresentationStart(stream,view,persistentListOf(RoomId("not-uuid")))}
        assertFails {AuthorPresentationInterests(stream,view,0,keys)};assertFails {AuthorPresentationInterests(stream,view,1,keys.add(keys[0]))}
        assertFails {AuthorPresentationReceipt(stream,view,1,persistentListOf(),0)};assertFails {AuthorPresentationReceipt(stream,view,1,keys,300001)}
        val old=AuthorPresentationInterests(stream,view,1,keys);val next=old.copy(sequence=2,keys=persistentListOf());assertEquals(4,old.keys.size);assertTrue(next.keys.isEmpty())
    }
}
