package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*

/** Dedicated encrypted security metadata; never stored with ordinary message projections. */
data class DeviceRevocationWork(val command: DeviceRevocationCommand, val receipt: DeviceRevocationReceipt? = null,
    val unknown: Boolean = false, val needsAttention: Boolean = false, val attempts: Int = 0,
    val roundEndsAt: Long, val nextActionAt: Long)
class DeviceRevocationJournal(private val secrets: SecretStore, private val actor: UserId, private val device: DeviceId) {
    private val mutex = Mutex()
    suspend fun read(): PersistentList<DeviceRevocationWork> = mutex.withLock { readValue() }
    suspend fun write(works: PersistentList<DeviceRevocationWork>) = mutex.withLock { writeValue(works) }
    suspend fun compareAndSet(expected: PersistentList<DeviceRevocationWork>, updated: PersistentList<DeviceRevocationWork>) = mutex.withLock {
        check(readValue() == expected) { "Security journal changed; reopen activation" }; writeValue(updated)
    }
    private suspend fun readValue(): PersistentList<DeviceRevocationWork> {
        val raw = secrets.read() ?: return persistentListOf()
        require(raw.toByteArray().size <= 524288)
        return Json.parseToJsonElement(raw).jsonArray.map { item ->
            val value = item.jsonObject; val command = DeviceRevocationCommand.decode(value.getValue("command").jsonObject)
            DeviceRevocationWork(command, value["receipt"]?.takeUnless { it is JsonNull }?.let { DeviceRevocationReceipt.decode(command, it.jsonObject) },
                value.getValue("unknown").jsonPrimitive.boolean, value.getValue("needsAttention").jsonPrimitive.boolean,
                value.getValue("attempts").jsonPrimitive.int, value.number("roundEndsAt"), value.number("nextActionAt"))
        }.toPersistentList().also(::validate)
    }
    private suspend fun writeValue(works: PersistentList<DeviceRevocationWork>) {
        validate(works)
        val value = JsonArray(works.map { work -> buildJsonObject {
            put("command", work.command.payload()); work.receipt?.let { put("receipt", Json.parseToJsonElement(it.wire)) }
            put("unknown", work.unknown); put("needsAttention", work.needsAttention); put("attempts", work.attempts)
            put("roundEndsAt", work.roundEndsAt); put("nextActionAt", work.nextActionAt)
        } }).toString()
        require(value.toByteArray().size <= 524288); secrets.write(value)
    }
    private fun validate(works: PersistentList<DeviceRevocationWork>) {
        require(works.size <= 16 && works.count { it.receipt == null } <= 8 && works.map { it.command.operation }.distinct().size == works.size)
        works.forEach {
            require(it.command.baseline.actor == actor && it.command.baseline.current == device && it.attempts in 0..5)
            require(it.roundEndsAt > 0 && it.nextActionAt > 0)
            it.receipt?.let { receipt -> require(DeviceRevocationReceipt.decode(it.command, Json.parseToJsonElement(receipt.wire).jsonObject) == receipt && it.unknown) }
        }
    }
}
/** One activation owns submit permission. Reopening the journal restores only confirmation authority. */
class DeviceRevocationService(private val actor: UserId, private val device: DeviceId, private val client: DeviceSessionClient,
    private val journal: DeviceRevocationJournal, private val now: () -> Long = System::currentTimeMillis,
    private val monotonic: () -> Long = System::nanoTime) {
    private val mutex = Mutex()
    @Volatile private var closed = false
    private var observed: Pair<DeviceRevocationBaseline, Long>? = null
    private val submitDeadlines = mutableMapOf<String, Long>()
    private val roundDeadlines = mutableMapOf<String, Long>()
    fun close() { closed = true }
    private fun active() { check(!closed) { "Device management activation closed" } }
    suspend fun works() = mutex.withLock { active(); journal.read() }
    suspend fun baseline(): DeviceRevocationBaseline = mutex.withLock {
        active(); observed = null
        val baseline = client.baseline(); currentCoroutineContext().ensureActive(); active()
        require(baseline.actor == actor && baseline.current == device)
        val remaining = (baseline.expiresAt - now()).coerceAtMost(120000); require(remaining > 0)
        observed = baseline to (monotonic() + remaining * 1000000); baseline
    }
    suspend fun enqueue(command: DeviceRevocationCommand) = mutex.withLock {
        active(); val baseline = requireNotNull(observed)
        require(command.baseline == baseline.first && monotonic() < baseline.second && now() < command.deadline)
        require(command.baseline.actor == actor && command.baseline.current == device && command.targets.isNotEmpty())
        val records = journal.read(); active(); records.firstOrNull { it.command.operation == command.operation }?.let { require(it.command == command); return@withLock it }
        require(records.count { it.receipt == null } < 8)
        require(records.none { it.receipt == null && it.command.targets.any(command.targets::contains) }) { "设备已有待确认操作" }
        val work = DeviceRevocationWork(command, roundEndsAt = Math.addExact(now(), 60000), nextActionAt = now())
        val retained = records.filter { it.receipt == null } + records.filter { it.receipt != null }.takeLast(8)
        journal.compareAndSet(records, (retained + work).toPersistentList()); active()
        submitDeadlines[command.operation] = baseline.second; roundDeadlines[command.operation] = monotonic() + 60000000000
        observed = null; work
    }
    suspend fun resume(operation: String) = mutex.withLock {
        active(); val records = journal.read(); val index = records.indexOfFirst { it.command.operation == operation }; require(index >= 0)
        val work = records[index]; require(work.receipt == null)
        active(); journal.compareAndSet(records, records.set(index, work.copy(needsAttention = false, attempts = 0, roundEndsAt = Math.addExact(now(), 60000), nextActionAt = maxOf(now(), work.nextActionAt))))
        submitDeadlines.remove(operation); roundDeadlines[operation] = monotonic() + 60000000000
    }
    suspend fun flush() = mutex.withLock {
        active()
        var records = journal.read()
        suspend fun save(next: PersistentList<DeviceRevocationWork>) {
            currentCoroutineContext().ensureActive(); active(); journal.compareAndSet(records, next); records = next
        }
        for(index in records.indices) {
            active(); val saved = records[index]; if(saved.receipt != null || saved.needsAttention) continue
            val id = saved.command.operation
            val end = roundDeadlines.getOrPut(id) { monotonic() + (saved.roundEndsAt - now()).coerceIn(0,60000) * 1000000 }
            if(saved.attempts >= 5 || now() >= saved.roundEndsAt || monotonic() >= end) {
                save(records.set(index, saved.copy(needsAttention = true))); continue
            }
            if(saved.nextActionAt > now()) continue
            val submitEnd = submitDeadlines[id]
            val canSubmit = !saved.unknown && submitEnd != null && monotonic() < submitEnd && now() < saved.command.deadline
            // Durable uncertainty BEFORE any physical request, including recovery.
            val work = saved.copy(unknown = true, attempts = saved.attempts + 1)
            save(records.set(index, work))
            active()
            val budget = minOf(15000, (end - monotonic()) / 1000000,
                if(canSubmit) minOf((submitEnd!! - monotonic()) / 1000000, saved.command.deadline - now()) else 15000)
            var delay = 1000L shl work.attempts
            val next = try {
                require(budget > 0)
                val result = withTimeout(budget) { client.execute(work.command, recover = !canSubmit) }
                currentCoroutineContext().ensureActive(); active()
                when(result) {
                    is DeviceRevocationResult.Receipt -> work.copy(receipt = result.receipt, needsAttention = false)
                    DeviceRevocationResult.Conflict -> work.copy(needsAttention = true)
                    DeviceRevocationResult.Unresolved -> work.copy(nextActionAt = Math.addExact(now(), delay))
                }
            } catch(e: TimeoutCancellationException) { work.copy(nextActionAt = Math.addExact(now(), delay)) }
            catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                if(e is DeviceBackpressure) delay = maxOf(delay, e.delayMilliseconds)
                if(e is ClientFailure.SignedOut || e is ClientFailure.Http && e.status in setOf(401,403)) throw e
                work.copy(nextActionAt = Math.addExact(now(), delay), needsAttention = e is IllegalArgumentException || e is ClientFailure.Protocol)
            }
            active()
            val updated = if(next.receipt == null && (next.attempts >= 5 || now() >= next.roundEndsAt || monotonic() >= end)) next.copy(needsAttention = true) else next
            save(records.set(index, updated))
            if(updated.receipt != null) { submitDeadlines.remove(id); observed = null }
        }
    }
}
