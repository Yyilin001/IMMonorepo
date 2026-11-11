package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.util.UUID
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class AccountWorkSchedulerTests {
    private fun TestScope.scheduler(config:AccountWorkScheduler.Configuration=AccountWorkScheduler.Configuration())=
        AccountWorkScheduler(config,{testScheduler.currentTime},StandardTestDispatcher(testScheduler))
    private val ordinary=NetworkWorkContext("account")
    private val up=NetworkWorkContext("objects",NetworkWorkPriority.Recovery,NetworkWorkKind.Upload)
    private val down=NetworkWorkContext("objects",kind=NetworkWorkKind.Download)
    private val auto=down.copy(priority=NetworkWorkPriority.Background)
    private val auth=NetworkWorkContext("authentication",kind=NetworkWorkKind.Authentication)
    private suspend fun rejects(reason:AccountWorkScheduler.Rejection,body:suspend ()->Unit) {
        assertEquals(reason,assertFailsWith<AccountWorkScheduler.AdmissionException> {body()}.reason)
    }
    @Test fun `four byte slots keep directions ordinary and auth independent`()=runTest {
        val s=scheduler();val held=listOf(s.acquire(up),s.acquire(up),s.acquire(down),s.acquire(down))
        val u=async {s.acquire(up)};val d=async {s.acquire(down)};runCurrent()
        val o=s.acquire(ordinary);val a=s.acquire(auth)
        assertEquals(AccountWorkScheduler.Snapshot(6,2,false,2,2,2,0),s.snapshot())
        s.release(held[2]);runCurrent();assertTrue(d.isCompleted);assertFalse(u.isCompleted)
        s.release(held[0]);runCurrent();assertTrue(u.isCompleted)
        (held+listOf(o,a,u.await(),d.await())).forEach {s.release(it)};s.closeAndDrain()
    }
    @Test fun `automatic bytes preserve user reservation and promotion is monotonic`()=runTest {
        val s=scheduler();val first=s.acquire(auto);val queued=async {s.acquire(auto)};runCurrent()
        val user=s.acquire(down);assertEquals(1,s.snapshot().waiting)
        assertNull(scheduler().promoteDownloadPermit(first,NetworkWorkPriority.Critical))
        val promoted=s.promoteDownloadPermit(first,NetworkWorkPriority.Interactive)!!
        assertEquals(first,promoted);assertEquals(NetworkWorkPriority.Interactive,promoted.context.priority)
        assertEquals(NetworkWorkPriority.Interactive,s.promoteDownloadPermit(first,NetworkWorkPriority.Background)!!.context.priority)
        assertEquals(0,s.snapshot().activeBackgroundTransfers)
        s.release(user);runCurrent();assertTrue(queued.isCompleted)
        s.release(first);s.release(queued.await());assertNull(s.promoteDownloadPermit(first,NetworkWorkPriority.Critical));s.closeAndDrain()
    }
    @Test fun `one slot still permits automatic progress`()=runTest {
        val s=scheduler(AccountWorkScheduler.Configuration(byteTransferLimit=1,downloadTransferLimit=1))
        s.release(s.acquire(auto));s.closeAndDrain()
    }
    @Test fun `adoption is idempotent may exceed capacity and does not spend retry quota`()=runTest {
        val s=scheduler();val retry=down.copy(isRetry=true);repeat(5) {s.release(s.acquire(retry))}
        val ids=List(3) {UUID.randomUUID()};val held=ids.map {s.adoptExistingByteTransfer(it,retry)}
        assertEquals(held[0],s.adoptExistingByteTransfer(ids[0],retry))
        rejects(AccountWorkScheduler.Rejection.InvalidAdoption) {s.adoptExistingByteTransfer(ids[0],down)}
        rejects(AccountWorkScheduler.Rejection.InvalidAdoption) {s.adoptExistingByteTransfer(UUID.randomUUID(),ordinary)}
        val next=async {s.acquire(up)};runCurrent();assertFalse(next.isCompleted)
        s.release(held[0]);runCurrent();assertTrue(next.isCompleted)
        (held+next.await()).forEach {s.release(it)};s.closeAndDrain()
    }
    @Test fun `queue capacities are independent and control retains its own backlog`()=runTest {
        val s=scheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1,authenticationLimit=1,byteTransferLimit=1,waiterLimit=1,controlWaiterLimit=1,byteTransferWaiterLimit=1))
        val held=listOf(s.acquire(ordinary),s.acquire(auth),s.acquire(up))
        val queued=listOf(async {s.acquire(ordinary)},async {s.acquire(auth)},async {s.acquire(down)});runCurrent()
        for(context in listOf(ordinary,auth,down)) rejects(AccountWorkScheduler.Rejection.Overloaded) {s.acquire(context)}
        assertEquals(3,s.snapshot().waiting)
        queued.forEach {it.cancel()};runCurrent();held.forEach {s.release(it)};s.closeAndDrain()
    }
    @Test fun `same ordering key is FIFO across kinds despite priority`()=runTest {
        val s=scheduler();val head=s.acquire(ordinary.copy(orderingKey="room"))
        val low=async {s.acquire(auto.copy(orderingKey="room"))};runCurrent()
        val high=async {s.acquire(ordinary.copy(orderingKey="room",priority=NetworkWorkPriority.Critical))};runCurrent()
        s.release(head);runCurrent();assertTrue(low.isCompleted);assertFalse(high.isCompleted)
        s.release(low.await());runCurrent();s.release(high.await());s.closeAndDrain()
    }
    @Test fun `ineligible FIFO head cannot be bypassed by eligible follower`()=runTest {
        val s=scheduler();val occupied=s.acquire(auto)
        val first=async {s.acquire(auto.copy(orderingKey="same"))};runCurrent()
        val next=async {s.acquire(down.copy(orderingKey="same"))};runCurrent()
        assertEquals(2,s.snapshot().waiting);assertEquals(1,s.snapshot().active)
        first.cancelAndJoin();runCurrent();assertTrue(next.isCompleted)
        s.release(occupied);s.release(next.await());s.closeAndDrain()
    }
    @Test fun `weighted wheel gives background bounded opportunity under critical backlog`()=runTest {
        val s=scheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1));var held=s.acquire(ordinary)
        val requests=(0..11).map {i->async {s.acquire(ordinary.copy(priority=if(i==11) NetworkWorkPriority.Background else NetworkWorkPriority.Critical))}.also {runCurrent()}}
        val completed=mutableSetOf<Int>();val order=mutableListOf<NetworkWorkPriority>()
        repeat(12) {
            s.release(held);runCurrent()
            val next=requests.indices.single {it !in completed && requests[it].isCompleted}
            completed+=next;held=requests[next].await();order+=held.context.priority
        }
        assertEquals(NetworkWorkPriority.Background,order[3]);s.release(held);s.closeAndDrain()
    }
    @Test fun `aging selects old byte work but cannot borrow automatic reservation`()=runTest {
        val s=scheduler(AccountWorkScheduler.Configuration(byteTransferLimit=1,byteTransferAgingMillis=100))
        val held=s.acquire(down);val old=async {s.acquire(up)};runCurrent();advanceTimeBy(101)
        val fresh=async {s.acquire(down.copy(priority=NetworkWorkPriority.Critical))};runCurrent()
        s.release(held);runCurrent();assertTrue(old.isCompleted);assertFalse(fresh.isCompleted)
        s.release(old.await());runCurrent();s.release(fresh.await());s.closeAndDrain()
        val t=scheduler(AccountWorkScheduler.Configuration(byteTransferAgingMillis=100));val autoHeld=t.acquire(auto)
        val waiting=async {t.acquire(auto)};runCurrent();advanceTimeBy(101);t.setDegraded(false)
        assertFalse(waiting.isCompleted);waiting.cancelAndJoin();t.release(autoHeld);t.closeAndDrain()
    }
    @Test fun `shared retry quota refills and cancelled queued retries spend nothing`()=runTest {
        val s=scheduler();val retry=ordinary.copy(isRetry=true)
        repeat(5) {s.release(s.acquire(retry))}
        val cancelled=async {s.acquire(retry)};runCurrent();assertEquals(1,s.snapshot().waiting);cancelled.cancelAndJoin()
        val queued=async {s.acquire(retry)};runCurrent();advanceTimeBy(1999);runCurrent();assertFalse(queued.isCompleted)
        // Initial work and authentication do not consume the failed-history quota.
        s.release(s.acquire(ordinary));s.release(s.acquire(auth.copy(isRetry=true)))
        advanceTimeBy(1);runCurrent();assertTrue(queued.isCompleted);s.release(queued.await());s.closeAndDrain()
    }
    @Test fun `cooldown affects new work only in registered service and never shortens`()=runTest {
        val s=scheduler();s.release(s.acquire(ordinary));s.coolDown("account",5000);s.coolDown("account",1000)
        val waiting=async {s.acquire(ordinary)};runCurrent()
        s.release(s.acquire(ordinary.copy(service="independent")));s.release(s.acquire(auth.copy(service="account")))
        advanceTimeBy(2000);runCurrent();assertFalse(waiting.isCompleted)
        advanceTimeBy(3000);runCurrent();assertTrue(waiting.isCompleted);s.release(waiting.await());s.closeAndDrain()
    }
    @Test fun `degradation reduces admissions without cancelling active I O`()=runTest {
        val s=scheduler();val held=List(4) {s.acquire(ordinary)};s.setDegraded(true)
        val queued=async {s.acquire(ordinary.copy(service="other"))};runCurrent();assertFalse(queued.isCompleted)
        s.release(held[0]);runCurrent();assertFalse(queued.isCompleted)
        s.release(held[1]);runCurrent();assertTrue(queued.isCompleted)
        (held+queued.await()).forEach {s.release(it)};s.closeAndDrain()
    }
    @Test fun `deadline removes queue while running slot remains and never transmits late`()=runTest {
        val s=scheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1));val held=s.acquire(ordinary)
        val waiting=async {runCatching {s.acquire(ordinary,20)}};runCurrent();advanceTimeBy(20);runCurrent()
        assertEquals(AccountWorkScheduler.Rejection.DeadlineExceeded,(waiting.await().exceptionOrNull() as AccountWorkScheduler.AdmissionException).reason)
        assertEquals(1,s.snapshot().active);assertEquals(0,s.snapshot().waiting)
        rejects(AccountWorkScheduler.Rejection.DeadlineExceeded) {s.acquire(auth,20)}
        s.release(held);s.closeAndDrain()
    }
    @Test fun `cancel after grant before dispatch returns orphaned permit`()=runTest {
        val s=scheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1));val held=s.acquire(ordinary)
        val waiting=async {s.acquire(ordinary)};runCurrent();s.release(held)
        assertEquals(1,s.snapshot().active)
        waiting.cancel();runCurrent();assertEquals(0,s.snapshot().active);assertEquals(0,s.snapshot().waiting);s.closeAndDrain()
    }
    @Test fun `cancellation and account close await physical I O drain`()=runTest {
        val s=scheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1));val gate=CompletableDeferred<Unit>()
        val running=launch {s.withPermit(ordinary) {withContext(NonCancellable) {gate.await()}}};runCurrent()
        running.cancel();val queued=async {runCatching {s.acquire(ordinary)}};runCurrent()
        val close=launch {s.closeAndDrain()};runCurrent()
        assertEquals(AccountWorkScheduler.Rejection.Closed,(queued.await().exceptionOrNull() as AccountWorkScheduler.AdmissionException).reason)
        assertTrue(s.snapshot().closed);assertEquals(1,s.snapshot().active);assertFalse(close.isCompleted)
        gate.complete(Unit);runCurrent();running.join();close.join();assertEquals(0,s.snapshot().active)
        rejects(AccountWorkScheduler.Rejection.Closed) {s.adoptExistingByteTransfer(UUID.randomUUID(),down)}
    }
    @Test fun `independent account domains reject foreign and duplicate release`()=runTest {
        val a=scheduler();val b=scheduler();val permit=a.acquire(ordinary);val other=b.acquire(ordinary)
        assertFalse(a.release(other));assertTrue(a.release(permit));assertFalse(a.release(permit))
        b.release(other);a.closeAndDrain();b.closeAndDrain()
    }
    @Test fun `service metadata stays bounded while authentication retains admission`()=runTest {
        val s=scheduler();repeat(64) {s.release(s.acquire(ordinary.copy(service="service-$it")))}
        rejects(AccountWorkScheduler.Rejection.Overloaded) {s.acquire(ordinary.copy(service="overflow"))}
        s.release(s.acquire(auth));s.release(s.acquire(ordinary.copy(service="service-0")));s.closeAndDrain()
    }
    @Test fun `shared download demand promotes only its own queued transfer`()=runTest {
        val s=scheduler();val held=s.acquire(auto);val unrelated=async {s.acquire(auto)};runCurrent()
        val demand=ByteTransferDemand(NetworkWorkPriority.Background)
        val shared=async(demand) {s.acquire(auto)};runCurrent();assertEquals(1,demand.observerCount)
        demand.promote(NetworkWorkPriority.Interactive);runCurrent()
        assertTrue(shared.isCompleted);assertFalse(unrelated.isCompleted)
        assertEquals(NetworkWorkPriority.Interactive,shared.await().context.priority);assertEquals(0,demand.observerCount)
        s.release(shared.await());runCurrent();assertFalse(unrelated.isCompleted)
        s.release(held);runCurrent();s.release(unrelated.await());s.closeAndDrain()
    }
    @Test fun `preexisting demand promotion keeps metadata and cancellation removes observation`()=runTest {
        val s=scheduler();val demand=ByteTransferDemand(NetworkWorkPriority.Background)
        demand.promote(NetworkWorkPriority.Interactive);demand.promote(NetworkWorkPriority.Background)
        val work=auto.copy(orderingKey="frozen-task",isRetry=true)
        val held=withContext(demand) {s.acquire(work)}
        assertEquals(work.copy(priority=NetworkWorkPriority.Interactive),held.context)
        val waiting=async(demand) {s.acquire(work)};runCurrent();assertEquals(1,demand.observerCount)
        waiting.cancelAndJoin();assertEquals(0,demand.observerCount)
        demand.promote(NetworkWorkPriority.Critical);runCurrent();assertEquals(1,s.snapshot().active)
        s.release(held);s.closeAndDrain()
    }
    @Test fun `service degradation leaves other services available and byte limits recover`()=runTest {
        val s=scheduler();val held=List(3) {s.acquire(ordinary)};s.setServiceDegraded("account",true)
        val queued=async {s.acquire(ordinary)};runCurrent();assertFalse(queued.isCompleted)
        val other=s.acquire(ordinary.copy(service="other"));s.setServiceDegraded("account",false);runCurrent()
        assertTrue(queued.isCompleted);(held+listOf(other,queued.await())).forEach {s.release(it)}
        val transfer=s.acquire(up);s.setServiceDegraded("objects",true)
        val download=async {s.acquire(down)};runCurrent();assertFalse(download.isCompleted)
        s.release(transfer);runCurrent();s.release(download.await());s.closeAndDrain()
    }

}
