package dev.local.ripple

import java.util.TreeMap
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList

/** Owned by the store lock. Both indexes point to the same immutable message. */
internal class MessageCache(private val totalLimit: Int, private val chatLimit: Int) {
    private val global = LinkedHashMap<Pair<Int, Int>, Unit>()
    private val chats = HashMap<Int, TreeMap<Int, Message>>()
    val size get() = global.size
    var evictions = 0L
        private set

    fun add(id: Int, message: Message) {
        val bucket = chats.getOrPut(id) { TreeMap() }
        bucket[message.seq] = message
        global[id to message.seq] = Unit
        if (bucket.size > chatLimit) evict(id to bucket.firstKey())
        if (global.size > totalLimit) evict(global.keys.first())
    }

    private fun evict(key: Pair<Int, Int>) {
        remove(key.first, key.second)
        evictions++
    }

    fun remove(id: Int, seq: Int) {
        global.remove(id to seq)
        chats[id]?.let {
            it.remove(seq)
            if (it.isEmpty()) chats.remove(id)
        }
    }

    fun get(id: Int, seq: Int) = chats[id]?.get(seq)
    fun latest(id: Int, limit: Int) = chats[id]?.descendingMap()?.values?.take(limit)?.asReversed().orEmpty().toPersistentList()
}

internal data class Page(val records: PersistentList<Message>, val more: Boolean, val gap: Boolean)

internal class History(private val epoch: Long) {
    private val archive = MessageCache(100_000, 5_000)
    private val last = IntArray(ConversationCount) { seedCount(it) }
    private val deleted = HashMap<Int, MutableSet<Int>>()
    fun last(id: Int) = last[id]
    fun lastVisible(id: Int): Int {
        var seq = last[id]
        while (seq > 0 && isDeleted(id, seq)) seq--
        return seq
    }
    fun add(id: Int, message: Message) {
        last[id] = message.seq
        archive.add(id, message)
    }
    fun delete(id: Int, seq: Int) {
        deleted.getOrPut(id) { HashSet() }.add(seq)
        archive.remove(id, seq)
    }
    fun isDeleted(id: Int, seq: Int) = deleted[id]?.contains(seq) == true

    private fun record(id: Int, seq: Int): Message? {
        if (seq > seedCount(id)) return archive.get(id, seq)
        val image = seq % 7 == 0
        return Message(seq, if (seq % 3 == 1) null else senderAt(id, seq),
            "历史 #$seq · ${sampleTexts[(id + seq) % sampleTexts.size]}",
            epoch - (seedCount(id) - seq + 1) * 60_000L, image,
            ratio = when ((seq / 7 + id) % 3) { 1 -> 0.75f; 2 -> 1f; else -> 1.33f })
    }

    fun page(id: Int, cursor: Int, newer: Boolean, limit: Int, overlap: Boolean = false): Page {
        val result = ArrayList<Message>()
        val step = if (newer) 1 else -1
        var seq = cursor + step
        var gap = false
        while (seq in 1..last[id] && result.size < limit) {
            if (!isDeleted(id, seq)) {
                val message = record(id, seq)
                if (message == null) { gap = true; break }
                result.add(message)
            }
            seq += step
        }
        if (overlap && result.isNotEmpty()) {
            result.add(result.first())
            result.shuffle(kotlin.random.Random(cursor))
        }
        return Page(result.toPersistentList(), !gap && seq in 1..last[id], gap)
    }
}
