package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class AuthorPresentationCandidateTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val device=DeviceId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val stream="EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
    private fun key(index: Int=1)=ProfileKey(UserId("00000000-0000-0000-0000-${index.toString().padStart(12,'0')}"),ProfileContext.Relationship)
    private fun grant(key: ProfileKey=key(),revision: Long=1,control: Long=1,deadline: Long=100_000_000_000,avatar: AvatarAccess?=null,download: Long?=null)=ProfileReadResult.Available(
        AuthorizedProfile(ProfileView(key.user,PublicIdentity(key.user,PublicHandle("user"),"姓名$revision",AccountKind.Regular),avatar?.content?.media,ProfileState.Active,revision,1),
            ProfileLease(actor,device,key,revision,1,0,ProfileAuthority(control,null,0,0),0,300000)),deadline,avatar,download)
    private fun delta(view: AuthorPresentationView,sequence: Long,value: ProfileReadResult.Available)=ReceivedAuthorPresentationDelta(view,sequence,persistentListOf(ReceivedAuthorPresentationEntry.Available(value)))
    private fun scope(clock: ()->Long,reader: ProfilePresentationReading=ProfilePresentationReading {persistentListOf()})=ProfilePresentationScope(actor,device,reader,clock)

    @Test fun `early delivery has no grant or receipt until visible promotion preserves original deadline`()=runTest {
        var now=0L;val pool=AuthorPresentationCandidates {now};val scope=scope({now})
        val view=AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf());val binding=scope.bindAuthor(view,pool)
        val value=grant();val incoming=delta(view,1,value);scope.ingestAuthor(incoming,binding)
        assertEquals(1,pool.diagnostics().first);assertTrue(scope.snapshot().profiles.isEmpty());assertNull(scope.avatarReadGrant(key()));assertTrue(scope.retainedAuthor(incoming,binding).isEmpty())
        now=4_000_000_000;scope.interests(persistentListOf(key()));assertEquals(persistentSetOf(key()),scope.promoteAuthor())
        assertEquals(value,scope.snapshot().profiles[key()]);assertTrue(scope.retainedAuthor(incoming,binding).isEmpty());assertEquals(0,pool.diagnostics().first)
        scope.close()
    }
    @Test fun `candidate TTL causal view retirement and new page ownership prevent promotion`()=runTest {
        for(mode in listOf("ttl","lease","renew","newPage")) {
            var now=0L;val pool=AuthorPresentationCandidates {now};val scope=scope({now});val receiver=AuthorPresentationReceiver(actor,device,{now})
            val view=receiver.begin(stream,persistentListOf());val binding=scope.bindAuthor(view,pool)
            scope.ingestAuthor(delta(view,1,grant(deadline=if(mode=="lease") 1_000_000_000 else 100_000_000_000)),binding)
            when(mode) {
                "ttl"->now=5_000_000_000
                "lease"->now=1_000_000_000
                "renew"->{now=1;scope.bindAuthor(receiver.begin(stream,persistentListOf()),pool)}
                "newPage"->{val other=scope({now});other.bindAuthor(view,pool);other.interests(persistentListOf(key()));assertTrue(other.promoteAuthor().isEmpty());other.close();scope.unbindAuthor(binding)}
            }
            scope.interests(persistentListOf(key()));assertTrue(scope.promoteAuthor().isEmpty(),mode);assertTrue(scope.snapshot().profiles.isEmpty(),mode);scope.close()
        }
    }
    @Test fun `shared candidate budget counts unique keys and releases individual page ownership`()=runTest {
        var now=0L;val pool=AuthorPresentationCandidates {now};val first=scope({now});val second=scope({now})
        val view=AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf())
        val a=first.bindAuthor(view,pool);val b=second.bindAuthor(view,pool)
        val incoming=delta(view,1,grant());first.ingestAuthor(incoming,a);val one=pool.diagnostics().second
        second.ingestAuthor(incoming,b);assertEquals(1,pool.diagnostics().first);assertEquals(one+64,pool.diagnostics().second)
        first.close();assertEquals(one,pool.diagnostics().second)
        second.interests(persistentListOf(key()));second.promoteAuthor();assertEquals(1,second.snapshot().profiles.size);assertEquals(0,pool.diagnostics().first)
        second.interests(persistentListOf())
        for(index in 2..71) {now++;second.ingestAuthor(delta(view,index.toLong(),grant(key(index))),b)}
        assertEquals(64,pool.diagnostics().first);assertTrue(pool.diagnostics().second<=AuthorPresentationCandidates.MaximumBytes)
        assertNull(pool.peek(key(2),b.id));assertNotNull(pool.peek(key(71),b.id));second.close();assertEquals(0,pool.diagnostics().first)
    }
    @Test fun `capability targets and unredacted header lengths participate in global byte budget`()=runTest {
        var now=0L;val pool=AuthorPresentationCandidates {now};val scope=scope({now})
        val view=AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf());val binding=scope.bindAuthor(view,pool)
        val fixture=AvatarFixture();val access=fixture.access().let {it.copy(plan=it.plan!!.copy(headers=persistentListOf(
            ResourceTransferHeader("X-A","a".repeat(8000),ResourceHeaderKind.ObjectCapability),ResourceTransferHeader("X-B","b".repeat(8000),ResourceHeaderKind.ObjectCapability))))}
        repeat(30) {index->now++;scope.ingestAuthor(delta(view,index+1L,grant(key(index+1),avatar=access,download=60_000_000_000)),binding)}
        assertTrue(pool.diagnostics().first in 1..29);assertTrue(pool.diagnostics().second<=256*1024);scope.close()
    }
    @Test fun `another page cannot replace a newer candidate and closed page version evidence survives`()=runTest {
        var now=0L;val pool=AuthorPresentationCandidates {now};val first=scope({now},{persistentListOf(grant(revision=5,control=5))});val second=scope({now})
        val view=AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf());val a=first.bindAuthor(view,pool);val b=second.bindAuthor(view,pool)
        first.ingestAuthor(delta(view,1,grant(revision=3)),a);second.ingestAuthor(delta(view,2,grant(revision=2)),b)
        assertEquals(3,(pool.peekAny(key())!!.entry as ReceivedAuthorPresentationEntry.Available).value.profile.view.revision)
        assertNull(pool.peek(key(),b.id))
        first.interests(persistentListOf(key()));first.refresh();first.close()
        second.ingestAuthor(delta(view,3,grant(revision=4,control=4)),b);second.interests(persistentListOf(key()))
        assertTrue(second.promoteAuthor().isEmpty());assertTrue(second.snapshot().profiles.isEmpty());second.close()
    }
    @Test fun `staged denial survives eviction and visible interest loss across HTTP and stream`()=runTest {
        var now=0L;var result=grant(control=2);val pool=AuthorPresentationCandidates {now};val scope=scope({now},{persistentListOf(result)})
        val view=AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf());val binding=scope.bindAuthor(view,pool)
        val denial=ReceivedAuthorPresentationDelta(view,1,persistentListOf(ReceivedAuthorPresentationEntry.Unavailable(ProfileReadResult.Unavailable(key(),ProfileAuthority(2,null,0,0)),view.renewByNanos)))
        scope.ingestAuthor(denial,binding);assertTrue(scope.snapshot().unavailable.isEmpty());assertTrue(scope.retainedAuthor(denial,binding).isEmpty())
        now=5_000_000_000;pool.prune();assertEquals(0,pool.diagnostics().first)
        scope.interests(persistentListOf(key()));scope.refresh();assertTrue(scope.snapshot().profiles.isEmpty())
        scope.interests(persistentListOf());scope.interests(persistentListOf(key()));scope.refresh();assertTrue(scope.snapshot().profiles.isEmpty())
        result=grant(control=3);scope.refresh();assertEquals(1,scope.snapshot().profiles.size);scope.close()
    }
    @Test fun `HTTP version evidence acquired before stream binding survives display expiry and is shared`()=runTest {
        var now=0L;val first=scope({now},{persistentListOf(grant(revision=5,control=5,deadline=1))})
        first.interests(persistentListOf(key()));first.refresh();now=2;assertTrue(first.snapshot().profiles.isEmpty())
        val pool=AuthorPresentationCandidates {now};val view=AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf())
        first.bindAuthor(view,pool);first.close()
        val second=scope({now});val binding=second.bindAuthor(view,pool)
        second.ingestAuthor(delta(view,1,grant(revision=4,control=4)),binding);second.interests(persistentListOf(key()))
        assertTrue(second.promoteAuthor().isEmpty());assertTrue(second.snapshot().profiles.isEmpty());second.close()
    }
    @Test fun `unknown alias floors discard old candidates and same nonce may stage a cleared newer alias`()=runTest {
        var now=0L;val pool=AuthorPresentationCandidates {now};val scope=scope({now})
        val view=AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf());val binding=scope.bindAuthor(view,pool)
        fun alias(revision: Long,name: String?)=grant().let {it.copy(profile=it.profile.copy(alias=ProfileAlias(actor,key().user,name,revision)))}
        scope.candidateFence(key(),ProfileFence(aliasRevision=2));scope.ingestAuthor(delta(view,1,alias(1,"旧备注")),binding);assertEquals(0,pool.diagnostics().first)
        scope.ingestAuthor(delta(view,2,alias(2,null)),binding);assertEquals(1,pool.diagnostics().first)
        scope.interests(persistentListOf(key()));scope.promoteAuthor();assertEquals(2,scope.snapshot().profiles.getValue(key()).profile.alias?.revision)
        scope.close()
    }
    @Test fun `promotion strips expired byte targets and rechecks durable floors without extending grants`()=runTest {
        var now=0L;val pool=AuthorPresentationCandidates {now};val scope=scope({now});val fixture=AvatarFixture()
        val view=AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf());val binding=scope.bindAuthor(view,pool)
        scope.ingestAuthor(delta(view,1,grant(avatar=fixture.access(),download=1_000_000_000)),binding)
        now=2_000_000_000;scope.interests(persistentListOf(key()));scope.promoteAuthor()
        val retained=scope.snapshot().profiles.getValue(key());assertNull(retained.avatar?.plan);assertEquals(100_000_000_000,retained.deadlineNanos)
        scope.interests(persistentListOf());scope.ingestAuthor(delta(view,2,grant(revision=2)),binding)
        scope.interests(persistentListOf(key()));scope.fence(key(),ProfileFence(minimumProfileRevision=3));assertTrue(scope.promoteAuthor().isEmpty());assertTrue(scope.snapshot().profiles.isEmpty());scope.close()
    }
    @Test fun `candidate timing uses elapsed durations across nanoTime wrap`()=runTest {
        var now=Long.MAX_VALUE-1000;val pool=AuthorPresentationCandidates {now};val scope=scope({now})
        val view=AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf());val binding=scope.bindAuthor(view,pool)
        scope.ingestAuthor(delta(view,1,grant(deadline=now+10_000_000_000)),binding)
        now+=4_999_999_999;assertEquals(1,pool.diagnostics().first);now++;assertEquals(0,pool.diagnostics().first);scope.close()
    }
    @Test fun `changed promotion fences old HTTP but identical promotion preserves an already running newer read`()=runTest {
        for(identical in listOf(false,true)) {
            var now=0L;val gate=CompletableDeferred<Unit>();var parked=false
            val scope=scope({now},{if(parked) gate.await();persistentListOf(grant(revision=if(parked) 2 else 1))})
            val view=AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf());val binding=scope.bindAuthor(view)
            scope.ingestAuthor(delta(view,1,grant(revision=if(identical) 1 else 3)),binding)
            scope.interests(persistentListOf(key()));if(identical) scope.refresh()
            parked=true;val read=async {scope.refresh()};runCurrent();scope.promoteAuthor();gate.complete(Unit);read.await()
            assertEquals(if(identical) 2 else 3,scope.snapshot().profiles.getValue(key()).profile.view.revision);scope.close()
        }
    }
    @Test fun `crossed candidate and HTTP authority floors remain merged after denial promotion`()=runTest {
        var now=0L;val pool=AuthorPresentationCandidates {now};val room=RoomId(device.value)
        val lookup=ProfileKey(key().user,ProfileContext.DirectConversation)
        fun value(control: Long,membership: Long,permission: Long)=grant().let {v->v.copy(profile=v.profile.copy(lease=v.profile.lease.copy(
            key=lookup,contextRevision=membership,authority=ProfileAuthority(control,room,membership,permission))))}
        val first=scope({now},{persistentListOf(value(5,1,1))});val second=scope({now})
        val view=AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf());first.bindAuthor(view,pool);val binding=second.bindAuthor(view,pool)
        second.ingestAuthor(delta(view,1,value(1,5,5)),binding);first.interests(persistentListOf(lookup));first.refresh()
        second.ingestAuthor(ReceivedAuthorPresentationDelta(view,2,persistentListOf(ReceivedAuthorPresentationEntry.Unavailable(
            ProfileReadResult.Unavailable(lookup,ProfileAuthority(3,room,3,3)),view.renewByNanos))),binding)
        first.close();second.interests(persistentListOf(lookup));second.promoteAuthor();assertTrue(lookup in second.snapshot().unavailable)
        second.ingestAuthor(delta(view,3,value(5,4,5)),binding);assertTrue(second.snapshot().profiles.isEmpty())
        second.ingestAuthor(delta(view,4,value(5,5,6)),binding);assertEquals(1,second.snapshot().profiles.size);second.close()
    }
    @Test fun `room observation starts with no visible authors and page promotes without an HTTP read`()=runTest {
        val receiver=AuthorPresentationReceiver(actor,device,{testScheduler.currentTime*1_000_000});val incoming=Channel<ReceivedAuthorPresentationDelta>(Channel.UNLIMITED)
        val starts=mutableListOf<AuthorPresentationView>();val receipts=mutableListOf<AuthorPresentationReceipt>();var reads=0
        val source=object: AuthorPresentationSource {
            override fun beginAuthorPresentationView(messageRooms: PersistentList<RoomId>)=receiver.begin(stream,messageRooms).also {starts.add(it)}
            override fun endAuthorPresentationView(view: AuthorPresentationView) {receiver.end(view)}
            override suspend fun nextAuthorPresentationDelta(view: AuthorPresentationView)=incoming.receive()
        }
        val commands=object: AuthorPresentationCommands {
            override suspend fun start(value: AuthorPresentationStart) {}
            override suspend fun end(value: AuthorPresentationStart) {}
            override suspend fun interests(value: AuthorPresentationInterests) {}
            override suspend fun receipt(value: AuthorPresentationReceipt) {receipts.add(value)}
        }
        val page=ProfilePresentationPage(actor,device,{reads++;awaitCancellation()},{ProfileFenceSnapshot("one",persistentMapOf())},backgroundScope,{testScheduler.currentTime*1_000_000})
        page.update(persistentListOf(),"one")
        val coordinator=AuthorPresentationCoordinator(source,commands,backgroundScope,{testScheduler.currentTime*1_000_000})
        coordinator.register(page);coordinator.selectMessageRoom(RoomId(device.value));advanceTimeBy(41);runCurrent()
        val view=starts.single();incoming.send(delta(view,1,grant()));runCurrent();assertTrue(page.state.value.display.profiles.isEmpty());assertTrue(receipts.isEmpty())
        page.update(persistentListOf(key()),"one");advanceTimeBy(41);runCurrent()
        assertEquals("姓名1",page.state.value.display.profiles.getValue(key()).profile.displayName());assertEquals(0,reads);assertTrue(receipts.isEmpty())
        coordinator.close();coordinator.awaitClosed();page.close()
    }
}
