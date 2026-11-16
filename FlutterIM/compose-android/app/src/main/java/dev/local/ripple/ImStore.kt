package dev.local.ripple

import android.app.Application
import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlin.random.Random

/** One writer at a time. Only immutable payloads cross the lock into Compose. */
class ImStore(application: Application) : AndroidViewModel(application) {
    private val disk = Storage(application.getSharedPreferences("ripple", 0))
    private val epoch = System.currentTimeMillis()
    private val history = History(epoch)
    private val cache = MessageCache(40_000, 500)
    private val _notes = MutableStateFlow(disk.notes())
    val notes = _notes.asStateFlow()
    private val rows = Array(ConversationCount) { id ->
        MutableStateFlow(Conversation(id, name(id), sampleTexts[id % sampleTexts.size], epoch - id * 60_000L,
            if (id != 0 && id % 7 == 0) id % 9 + 1 else 0, id < 3))
    }
    private val _total = MutableStateFlow(rows.sumOf { it.value.unread })
    val total = _total.asStateFlow()
    private val all = Projection("", false)
    private val activeFilters = mutableSetOf<Projection>()
    private val sessions = LinkedHashMap<Int, MutableStateFlow<Window>>(24, .75f, true)
    private val requests = mutableMapOf<Int, Job>()
    private val replies = mutableMapOf<Int, MutableSet<Job>>()
    private val _drafts = MutableStateFlow(persistentHashMapOf<Int, String>())
    val drafts = _drafts.asStateFlow()
    private val _backgrounds = MutableStateFlow(persistentHashMapOf<Int, Backdrop>())
    val backgrounds = _backgrounds.asStateFlow()
    private val _prefs = MutableStateFlow(disk.preferences())
    val prefs = _prefs.asStateFlow()
    private val _me = MutableStateFlow(MyProfile())
    val me = _me.asStateFlow()
    private val _recent = MutableStateFlow(listOf("chats","friends","groups").associateWith(disk::recent).toPersistentMap())
    val recent = _recent.asStateFlow()
    private val _runtime = MutableStateFlow(Runtime())
    val runtime = _runtime.asStateFlow()
    private val _stats = MutableStateFlow(Stats())
    val stats = _stats.asStateFlow()
    private val frames = ArrayDeque<Float>()
    private var received = 0L
    private var sent = 0L
    private var revision = 0L
    private var workNs = 0L
    private var publishNs = 0L
    @Volatile private var focus: Int? = null
    private var worker: Job? = null
    private val random = Random(42)
    private var generated = 0

    init {
        all.order.value = buildOrder(all)
        startWorker()
        viewModelScope.launch(Dispatchers.Default) {
            var previous = 0L
            var previousTime = SystemClock.elapsedRealtime()
            while (isActive) {
                delay(500)
                synchronized(this@ImStore) {
                    val now = SystemClock.elapsedRealtime()
                    val speed = ((received - previous) * 1000 / (now - previousTime).coerceAtLeast(1)).toInt()
                    val trend = (_stats.value.samples.takeLast(59) + speed).toPersistentList()
                    val sorted = frames.sorted()
                    _stats.value = Stats(received, sent, cache.size, cache.evictions, speed,
                        workNs / 1e6, publishNs / 1e6, sorted.getOrNull(((sorted.size - 1) * .95).toInt()) ?: 0f,
                        frames.count { it > 16.7f }, frames.size, trend)
                    workNs = 0L
                    publishNs = 0L
                    previous = received
                    previousTime = now
                }
            }
        }
    }

    internal class Projection(val query: String, val unread: Boolean, private val ranks: IntArray? = null) {
        fun ordering(c: Conversation): Conversation = ranks?.let { c.copy(pinned = false, order = -it[c.id].toLong()) } ?: c
        internal val order = MutableStateFlow<ConversationOrder?>(null)
        val visible = order.asStateFlow()
        fun matches(c: Conversation) = (!unread || c.unread > 0) && (query.isEmpty() ||
            c.name.contains(query, true) || originalName(c.id).contains(query, true) || numberId(c.id).contains(query))
    }
    private fun buildOrder(filter: Projection): ConversationOrder? {
        var root: ConversationOrder? = null
        for (row in rows) if (filter.matches(row.value)) root = ConversationOrder.add(root, filter.ordering(row.value))
        return root
    }
    @Synchronized internal fun filter(query: String, unread: Boolean, frozen: Boolean): Projection {
        if (query.isBlank() && !unread && !frozen) return all
        val ranks = if (frozen) IntArray(ConversationCount).also { values ->
            val order = checkNotNull(all.order.value)
            for (i in values.indices) values[order[i]] = i
        } else null
        return Projection(query.trim(), unread, ranks).also { it.order.value = buildOrder(it); activeFilters.add(it) }
    }
    @Synchronized internal fun release(p: Projection) { activeFilters.remove(p) }

    private fun replace(old: Conversation, next: Conversation) {
        fun update(p: Projection) {
            val was = p.matches(old)
            val now = p.matches(next)
            val before = p.ordering(old)
            val after = p.ordering(next)
            if (was == now && (!now || (before.pinned == after.pinned && before.order == after.order))) return
            val removed = if (was) p.order.value?.remove(before) else p.order.value
            p.order.value = if (now) ConversationOrder.add(removed, after) else removed
        }
        update(all)
        activeFilters.forEach(::update)
        rows[old.id].value = next
        _total.value += next.unread - old.unread
    }
    fun name(id: Int) = _notes.value[id]?.remark?.takeIf(String::isNotEmpty) ?: originalName(id)
    fun row(id: Int): StateFlow<Conversation> = rows[id]
    @Synchronized fun markRead(id: Int) { val old = rows[id].value; if (old.unread > 0) replace(old, old.copy(unread = 0)) }
    @Synchronized fun readAll() { rows.indices.forEach(::markRead) }
    @Synchronized fun pin(id: Int) { val old = rows[id].value; replace(old, old.copy(pinned = !old.pinned)) }
    @Synchronized fun mute(id: Int) { val old = rows[id].value; replace(old, old.copy(muted = !old.muted)) }
    @Synchronized fun select(id: Int?) { focus = id; if (id != null) markRead(id) }
    @Synchronized fun setNote(id: Int, value: Note) {
        if (value.deleted) replies.remove(id)?.forEach { it.cancel() }
        _notes.value = _notes.value.put(id, value)
        val old = rows[id].value
        replace(old, old.copy(name = name(id)))
        disk.save(id, value)
    }
    fun setProfile(value: MyProfile) { _me.value = value }
    fun setPrefs(value: Preferences) { _prefs.value = value; disk.save(value) }
    fun setBackground(id: Int, value: Backdrop) { _backgrounds.update { it.put(id, value) } }
    fun draft(id: Int, text: String) { _drafts.update { if (text.isEmpty()) it.remove(id) else it.put(id, text.take(2000)) } }
    fun rememberQuery(key: String, text: String?) {
        if (text != null && text.isBlank()) return
        val value = if (text == null) persistentListOf() else
            (listOf(text.trim()) + _recent.value[key].orEmpty().filterNot { it.equals(text.trim(), true) }.take(11)).toPersistentList()
        _recent.value = _recent.value.put(key, value)
        disk.saveRecent(key, value)
    }

    @Synchronized internal fun cachedImages(id: Int) = cache.latest(id, 500).filter { it.image }.toPersistentList()

    @Synchronized fun window(id: Int): StateFlow<Window> {
        sessions[id]?.let { return it }
        val recent = cache.latest(id, 100)
        return MutableStateFlow(Window(messages = recent, lastLive = recent.lastOrNull())).also {
            sessions[id] = it
            if (sessions.size > 20) {
                val evicted = sessions.keys.first()
                requests.remove(evicted)?.cancel()
                sessions.remove(evicted)
            }
            if (it.value.messages.size < 100) load(id)
        }
    }

    @Synchronized fun load(id: Int, newer: Boolean = false) {
        val flow = sessions[id] ?: return
        val w = flow.value
        if (w.loading || (if (newer) !w.newer else !w.more || w.messages.size >= 2000)) return
        val cursor = if (newer) w.messages.lastOrNull()?.seq ?: 0 else w.messages.firstOrNull()?.seq ?: (history.last(id) + 1)
        val mode = runtime.value
        if (mode.failNext) _runtime.value = mode.copy(failNext = false)
        val limit = if (newer) 30 else if (w.messages.size in 1..99) 100 - w.messages.size else 100
        val page = history.page(id, cursor, newer, limit, mode.network == Network.Overlap)
        flow.value = w.copy(loading = true, error = "")
        requests[id] = viewModelScope.launch(Dispatchers.Default) {
            delay(if (mode.network == Network.Slow) 1500 else 100)
            synchronized(this@ImStore) {
                if (!isActive || sessions[id] !== flow) return@synchronized
                val current = flow.value
                if (mode.network == Network.Offline || mode.failNext) {
                    flow.value = current.copy(loading = false, error = "历史记录加载失败", failedNewer = newer)
                } else {
                    val merged = (current.messages + page.records).filterNot { history.isDeleted(id, it.seq) }
                        .distinctBy { it.seq }.sortedBy { it.seq }
                    val result = (if (newer) merged.takeLast(2000) else merged.take(2000)).toPersistentList()
                    flow.value = current.copy(messages = result, loading = false,
                        more = if (newer) current.more || merged.size > 2000 else page.more,
                        newer = if (newer) page.more || page.gap || (result.lastOrNull()?.seq ?: 0) < history.lastVisible(id) else current.newer || merged.size > 2000,
                        gap = current.gap || page.gap)
                }
                requests.remove(id)
            }
        }
    }

    @Synchronized fun position(id: Int, anchor: Int, offset: Int, reading: Boolean) {
        val flow = sessions[id] ?: return
        val w = flow.value
        flow.value = w.copy(anchor = anchor, offset = offset, reading = reading || w.newer,
            pending = if (reading || w.newer) w.pending else 0)
    }
    @Synchronized fun latest(id: Int) {
        val flow = sessions[id] ?: return
        val w = flow.value
        requests.remove(id)?.cancel()
        if (!w.newer) {
            flow.value = w.copy(reading = false, pending = 0, anchor = 0, offset = 0, loading = false, error = "")
        } else {
            val page = history.page(id, history.last(id) + 1, false, w.messages.size.coerceIn(100, 2000))
            val retained = page.records.asReversed().toPersistentList()
            val recent = if (retained.isEmpty() && w.lastLive != null) persistentListOf(w.lastLive) else retained
            flow.value = Window(messages = recent, more = page.more, gap = page.gap, lastLive = w.lastLive)
        }
    }
    @Synchronized fun deleteMessage(id: Int, message: Message) {
        if (history.isDeleted(id, message.seq)) return
        history.delete(id, message.seq)
        cache.remove(id, message.seq)
        val flow = sessions[id]
        val archived = history.page(id, history.last(id) + 1, false, 1).records.firstOrNull()
        val remaining = flow?.value?.messages?.remove(message)
        val next = listOfNotNull(archived, remaining?.lastOrNull(), flow?.value?.lastLive?.takeUnless { it.seq == message.seq }).maxByOrNull { it.seq }
        if (flow != null && remaining != null) flow.value = flow.value.copy(messages = remaining,
            lastLive = next?.takeIf { it.seq > seedCount(id) })
        val old = rows[id].value
        if (next == null || next.seq < message.seq)
            replace(old, old.copy(preview = next?.preview ?: "暂无消息", time = next?.time ?: old.time))
    }

    @Synchronized fun send(id: Int, text: String, imageFile: String? = null, ratio: Float = 1f) {
        if ((text.isBlank() && imageFile == null) || notes.value[id]?.deleted == true) return
        latest(id)
        receive(id, null, text.trim(), imageFile != null, imageFile, ratio)
        if (imageFile == null) draft(id, "")
        val reply = if (imageFile != null) "收到你发来的图片了。" else "收到你的消息了：「${text.trim().take(32)}${if (text.trim().length > 32) "…" else ""}」 ✓"
        val job = viewModelScope.launch(Dispatchers.Default, start = CoroutineStart.LAZY) {
            delay(650)
            synchronized(this@ImStore) {
                if (isActive) receive(id, senderAt(id, history.last(id)), reply, false)
                replies[id]?.remove(coroutineContext[Job])
                if (replies[id]?.isEmpty() == true) replies.remove(id)
            }
        }
        replies.getOrPut(id) { mutableSetOf() }.add(job)
        job.start()
    }
    private fun receive(id: Int, sender: Int?, text: String, image: Boolean, file: String? = null, ratio: Float = 1.33f) {
        if (notes.value[id]?.deleted == true) return
        val start = System.nanoTime()
        val m = Message(history.last(id) + 1, sender, text, System.currentTimeMillis(), image, file, ratio)
        history.add(id, m)
        cache.add(id, m)
        if (sender == null) sent++ else received++
        val stored = System.nanoTime()
        val old = rows[id].value
        replace(old, old.copy(preview = m.preview, time = m.time, order = ++revision,
            unread = old.unread + if (sender != null && focus != id) 1 else 0))
        // Inspect without changing the LRU order; only opening a chat promotes its session.
        val flow = sessionById(id)
        if (flow != null) {
            val w = flow.value
            val full = w.reading && (w.newer || w.messages.size >= 2000)
            val cap = w.messages.size.coerceIn(200, 2000)
            val next = when {
                full -> w.messages
                !w.reading && w.messages.size >= cap -> w.messages.removeAt(0).add(m)
                else -> w.messages.add(m)
            }
            flow.value = w.copy(messages = next, newer = full, lastLive = m,
                more = w.more || (!w.reading && w.messages.size >= cap),
                pending = w.pending + if (w.reading) 1 else 0)
        }
        workNs = maxOf(workNs, stored - start)
        publishNs = maxOf(publishNs, System.nanoTime() - stored)
    }

    private fun sessionById(id: Int) = if (sessions.containsKey(id)) sessions.entries.firstOrNull { it.key == id }?.value else null

    @Synchronized fun configure(value: Runtime) {
        val previous = _runtime.value
        _runtime.value = value
        if (previous.running != value.running || previous.rate != value.rate) {
            worker?.cancel()
            if (value.running) startWorker()
        }
    }
    private fun startWorker() {
        worker = viewModelScope.launch(Dispatchers.Default) {
            val rate = runtime.value.rate
            val interval = if (rate == 0) 3_000_000_000L else 1_000_000_000L / rate
            var deadline = System.nanoTime() + interval
            while (isActive) {
                val remaining = deadline - System.nanoTime()
                if (remaining > 0) { delay((remaining + 999_999) / 1_000_000); continue }
                synchronized(this@ImStore) {
                    if (!isActive) return@synchronized
                    val chance = random.nextFloat()
                    val selected = focus
                    val target = when {
                        runtime.value.uniform -> random.nextInt(ConversationCount)
                        chance < .1f && selected != null -> selected
                        chance < .3f -> random.nextInt(100)
                        else -> random.nextInt(ConversationCount)
                    }
                    receive(target, senderAt(target, generated), sampleTexts.random(random), generated++ % 7 == 0)
                }
                deadline = if (rate == 0) System.nanoTime() + interval else maxOf(deadline + interval, System.nanoTime() - 16_000_000)
            }
        }
    }
    @Synchronized fun frame(ms: Float) {
        if (frames.size >= 180) frames.removeFirst()
        frames.addLast(ms)
    }
}
