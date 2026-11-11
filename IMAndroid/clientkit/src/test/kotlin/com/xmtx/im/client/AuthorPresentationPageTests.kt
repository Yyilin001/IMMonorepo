package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class AuthorPresentationPageTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val user=UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val device=DeviceId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val key=ProfileKey(user,ProfileContext.Relationship)
    private val stream="EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
    private fun grant(revision: Long=2,control: Long=1,deadline: Long=100_000_000_000)=ProfileReadResult.Available(
        AuthorizedProfile(ProfileView(user,PublicIdentity(user,PublicHandle("friend"),"姓名$revision",AccountKind.Regular),null,ProfileState.Active,revision,1),
            ProfileLease(actor,device,key,revision,1,0,ProfileAuthority(control,null,0,0),0,300000)),deadline)
    private fun delta(view: AuthorPresentationView,sequence: Long,value: ProfileReadResult.Available)=
        ReceivedAuthorPresentationDelta(view,sequence,persistentListOf(ReceivedAuthorPresentationEntry.Available(value)))

    @Test fun `push invalidates earlier HTTP and independent HTTP survives stream retirement`()=runTest {
        var now=0L;val gate=CompletableDeferred<Unit>();var calls=0
        val scope=ProfilePresentationScope(actor,device,{calls++;if(calls==1) gate.await();persistentListOf(grant())},{now})
        scope.interests(persistentListOf(key));val read=async {scope.refresh()};runCurrent()
        now=1;val receiver=AuthorPresentationReceiver(actor,device,{now});val view=receiver.begin(stream,persistentListOf())
        val binding=scope.bindAuthor(view);val incoming=delta(view,1,grant(3))
        scope.ingestAuthor(incoming,binding);gate.complete(Unit);read.await()
        assertEquals("姓名3",scope.snapshot().profiles.getValue(key).profile.displayName())
        assertEquals(100_000_000_000,scope.retainedAuthor(incoming,binding)[key])
        scope.unbindAuthor(binding);assertTrue(scope.snapshot().profiles.isEmpty())
        now=2;scope.bindAuthor(receiver.begin(stream,persistentListOf()))
        // Same profile revision is still protected even after retirement.
        scope.refresh();assertTrue(scope.snapshot().profiles.isEmpty())
        scope.close();receiver.close()
        val http=ProfilePresentationScope(actor,device,{persistentListOf(grant())},{now})
        http.interests(persistentListOf(key));http.refresh();val httpBinding=http.bindAuthor(AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf()))
        http.unbindAuthor(httpBinding);assertEquals(1,http.snapshot().profiles.size);http.close()
    }

    @Test fun `expired author denial keeps authority floor and cannot receipt retry or superseded value`()=runTest {
        var now=0L;var result=grant();val scope=ProfilePresentationScope(actor,device,{persistentListOf(result)},{now})
        scope.interests(persistentListOf(key));val view=AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf())
        val binding=scope.bindAuthor(view)
        val denied=ReceivedAuthorPresentationDelta(view,1,persistentListOf(ReceivedAuthorPresentationEntry.Unavailable(ProfileReadResult.Unavailable(key,ProfileAuthority(2,null,0,0)),1_000_000_000)))
        scope.ingestAuthor(denied,binding);assertEquals(1_000_000_000,scope.retainedAuthor(denied,binding)[key])
        now=1_000_000_000;assertTrue(scope.snapshot().unavailable.isEmpty());assertTrue(scope.retainedAuthor(denied,binding).isEmpty())
        result=grant(control=2);scope.refresh();assertTrue(scope.snapshot().profiles.isEmpty())
        result=grant(control=3);scope.refresh();assertEquals(1,scope.snapshot().profiles.size)
        val pushed=delta(view,2,grant(3,3));scope.ingestAuthor(pushed,binding)
        val latest=delta(view,3,grant(4,3));scope.ingestAuthor(latest,binding)
        assertTrue(scope.retainedAuthor(pushed,binding).isEmpty());assertEquals(1,scope.retainedAuthor(latest,binding).size)
        val retry=ReceivedAuthorPresentationDelta(view,4,persistentListOf(ReceivedAuthorPresentationEntry.Retryable(key,now+1_000_000_000)))
        scope.ingestAuthor(retry,binding);assertTrue(scope.retainedAuthor(retry,binding).isEmpty());scope.close()
    }

    private inner class Transport(private val clock: ()->Long): AuthorPresentationSource,AuthorPresentationCommands {
        val receiver=AuthorPresentationReceiver(actor,device,clock)
        val starts=mutableListOf<AuthorPresentationView>();val receipts=mutableListOf<AuthorPresentationReceipt>()
        val interests=mutableListOf<AuthorPresentationInterests>();val ends=mutableListOf<AuthorPresentationStart>()
        val incoming=Channel<ReceivedAuthorPresentationDelta>(Channel.UNLIMITED)
        var endGate: CompletableDeferred<Unit>?=null
        override fun beginAuthorPresentationView(messageRooms: PersistentList<RoomId>)=receiver.begin(stream,messageRooms).also {starts.add(it)}
        override fun endAuthorPresentationView(view: AuthorPresentationView) {receiver.end(view)}
        override suspend fun nextAuthorPresentationDelta(view: AuthorPresentationView)=incoming.receive()
        override suspend fun start(value: AuthorPresentationStart) {}
        override suspend fun end(value: AuthorPresentationStart) {ends.add(value);endGate?.await()}
        override suspend fun interests(value: AuthorPresentationInterests) {interests.add(value)}
        override suspend fun receipt(value: AuthorPresentationReceipt) {receipts.add(value)}
    }

    @Test fun `denial and retry timers use elapsed durations across nanoTime wrap`()=runTest {
        var now=Long.MAX_VALUE-500_000_000
        val scope=ProfilePresentationScope(actor,device,{persistentListOf(ProfileReadResult.Retryable(key))},{now})
        scope.interests(persistentListOf(key));val view=AuthorPresentationReceiver(actor,device,{now}).begin(stream,persistentListOf())
        val binding=scope.bindAuthor(view)
        val denied=ReceivedAuthorPresentationDelta(view,1,persistentListOf(ReceivedAuthorPresentationEntry.Unavailable(ProfileReadResult.Unavailable(key,ProfileAuthority(2,null,0,0)),now+800_000_000)))
        scope.ingestAuthor(denied,binding);assertEquals(800,scope.nextReadDelayMillis())
        assertEquals(now+800_000_000,scope.retainedAuthor(denied,binding)[key])
        scope.ingestAuthor(ReceivedAuthorPresentationDelta(view,2,persistentListOf(ReceivedAuthorPresentationEntry.Retryable(key,now+1_200_000_000))),binding)
        assertEquals(1200,scope.nextReadDelayMillis())
        now+=900_000_000;assertTrue(scope.snapshot().unavailable.isEmpty());assertEquals(300,scope.nextReadDelayMillis())
        now+=400_000_000;assertEquals(0,scope.nextReadDelayMillis());scope.close()
    }

    @Test fun `durable authority change during author merge clears value and receipt before publication`()=runTest {
        var checks=0;var merging=false
        val page=page {
            if(merging) checks++
            ProfileFenceSnapshot(if(merging && checks>=2) "revoked" else "one",persistentMapOf())
        }
        advanceTimeBy(1)
        val receiver=AuthorPresentationReceiver(actor,device,{testScheduler.currentTime*1_000_000})
        val view=receiver.begin(stream,persistentListOf());page.bindAuthor(view)
        merging=true;val incoming=delta(view,1,grant());page.ingestAuthor(incoming)
        assertTrue(page.state.value.display.profiles.isEmpty());assertTrue(page.retainedAuthor(incoming).isEmpty())
        assertTrue(page.authorDemand.value.revision>1);page.close()
    }

    @Test fun `viewport update cannot publish author value while final authority read is suspended`()=runTest {
        val gate=CompletableDeferred<Unit>();var checks=0
        val page=page {checks++;if(checks==2) gate.await();ProfileFenceSnapshot("one",persistentMapOf())}
        advanceTimeBy(1)
        val view=AuthorPresentationReceiver(actor,device,{testScheduler.currentTime*1_000_000}).begin(stream,persistentListOf())
        page.bindAuthor(view);val incoming=delta(view,1,grant())
        val merge=launch {page.ingestAuthor(incoming)};runCurrent()
        page.update(persistentListOf(key),"one",persistentListOf(key))
        assertTrue(page.state.value.display.profiles.isEmpty())
        gate.complete(Unit);merge.join();assertTrue(page.retainedAuthor(incoming).isEmpty());page.close()
    }

    @Test fun `viewport update cannot publish HTTP value before post read authority validation`()=runTest {
        val gate=CompletableDeferred<Unit>();var checks=0;var reads=0
        val page=ProfilePresentationPage(actor,device,{reads++;if(reads>1) awaitCancellation();persistentListOf(grant())},
            {checks++;if(checks==2) gate.await();ProfileFenceSnapshot("one",persistentMapOf())},backgroundScope,{testScheduler.currentTime*1_000_000})
        page.update(persistentListOf(key),"one");advanceTimeBy(41);runCurrent()
        page.update(persistentListOf(key),"one",persistentListOf(key))
        assertTrue(page.state.value.display.profiles.isEmpty())
        gate.complete(Unit);runCurrent();assertTrue(page.state.value.display.profiles.isEmpty());page.close()
    }

    @Test fun `authority read authentication failure cannot resurrect cached HTTP on viewport change`()=runTest {
        var signedOut=false
        val page=ProfilePresentationPage(actor,device,{persistentListOf(grant())},
            {if(signedOut) throw ClientFailure.SignedOut();ProfileFenceSnapshot("one",persistentMapOf())},backgroundScope,{testScheduler.currentTime*1_000_000})
        page.update(persistentListOf(key),"one");advanceTimeBy(41);runCurrent();assertEquals(1,page.state.value.display.profiles.size)
        signedOut=true;page.update(persistentListOf(key),"one",persistentListOf(key));advanceTimeBy(41);runCurrent()
        assertTrue(page.state.value.display.profiles.isEmpty())
        page.update(persistentListOf(key),"one");assertTrue(page.state.value.display.profiles.isEmpty());page.close()
    }
    private fun TestScope.page(fences: suspend (PersistentList<ProfileKey>)->ProfileFenceSnapshot={ProfileFenceSnapshot("one",persistentMapOf())})=
        ProfilePresentationPage(actor,device,{awaitCancellation()},fences,backgroundScope,{testScheduler.currentTime*1_000_000}).also {it.update(persistentListOf(key),"one")}

    @Test fun `coordinator acknowledges installed grant and drains cleanup before renewal`()=runTest {
        val transport=Transport {testScheduler.currentTime*1_000_000};val page=page()
        val coordinator=AuthorPresentationCoordinator(transport,transport,backgroundScope,{testScheduler.currentTime*1_000_000},{4000})
        assertTrue(coordinator.register(page));advanceTimeBy(41);runCurrent()
        val first=transport.starts.single();assertEquals(persistentListOf(key),transport.interests.single().keys)
        transport.incoming.send(delta(first,1,grant(deadline=2_000_000_000)));runCurrent()
        assertEquals("姓名2",page.state.value.display.profiles.getValue(key).profile.displayName())
        assertEquals(1959,transport.receipts.single().minimumRemainingMillis)
        transport.endGate=CompletableDeferred();advanceTimeBy(1100);runCurrent()
        assertEquals(1,transport.ends.size);assertEquals(1,transport.starts.size)
        transport.endGate!!.complete(Unit);advanceTimeBy(41);runCurrent()
        assertEquals(2,transport.starts.size)
        // Renewal transfers ownership without extending the original grant.
        assertEquals(2_000_000_000,page.state.value.display.profiles.getValue(key).deadlineNanos)
        coordinator.close();coordinator.awaitClosed();assertTrue(page.state.value.display.profiles.isEmpty());page.close()
    }

    @Test fun `page removal during suspending authority read never sends receipt`()=runTest {
        val gate=CompletableDeferred<Unit>();var block=false
        val page=page {if(block) gate.await();ProfileFenceSnapshot("one",persistentMapOf())}
        val transport=Transport {testScheduler.currentTime*1_000_000}
        val coordinator=AuthorPresentationCoordinator(transport,transport,backgroundScope,{testScheduler.currentTime*1_000_000})
        coordinator.register(page);advanceTimeBy(41);runCurrent();block=true
        transport.incoming.send(delta(transport.starts.single(),1,grant()));runCurrent()
        coordinator.remove(page);gate.complete(Unit);runCurrent()
        assertTrue(transport.receipts.isEmpty());assertTrue(page.state.value.display.profiles.isEmpty())
        coordinator.close();coordinator.awaitClosed();page.close()
    }
}
