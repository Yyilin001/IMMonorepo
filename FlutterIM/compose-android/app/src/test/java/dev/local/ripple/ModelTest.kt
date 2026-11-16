package dev.local.ripple

import org.junit.Assert.*
import org.junit.Test
import kotlin.random.Random

class ModelTest {
    @Test fun orderSharesImmutableSnapshotsAcrossRepinsAndReorders() {
        val count = 256
        val rows = Array(count) { Conversation(it, originalName(it), "", 0, 0, it < 3) }
        var root: ConversationOrder? = null
        rows.forEach { root = ConversationOrder.add(root, it) }
        val initial = root!!
        val random = Random(12)
        repeat(4000) { step ->
            val id = random.nextInt(count)
            val old = rows[id]
            val next = old.copy(order = step + 1L, pinned = if (step % 7 == 0) !old.pinned else old.pinned)
            rows[id] = next
            root = ConversationOrder.add(root!!.remove(old), next)
        }
        val sorted = rows.sortedWith(compareByDescending<Conversation> { it.pinned }.thenByDescending { it.order }.thenBy { it.id })
        assertEquals(count, root!!.size)
        assertEquals(sorted.map { it.id }, rows.indices.map { root!![it] })
        assertEquals(rows.indices.toList(), rows.indices.map { initial[it] })
    }

    @Test fun exclusivePagesAndDeletionSurviveLiveWrites() {
        val h = History(1_000_000)
        val first = h.page(2, 12001, false, 100)
        assertEquals(100, first.records.size)
        h.add(2, Message(12001, null, "new", 10))
        h.delete(2, 11900)
        val older = h.page(2, first.records.last().seq, false, 100, true)
        assertEquals((11800..11899).toList(), older.records.map { it.seq }.distinct().sorted())
        assertEquals(12000, first.records.first().seq)
        assertEquals(listOf(12000, 12001), h.page(2, 11999, true, 30).records.map { it.seq })
        assertFalse(h.page(1, 9, false, 100).more)
        assertTrue(h.page(7, 1, false, 100).records.isEmpty())
    }

    @Test fun evictionEnforcesBothBoundsAndDoesNotMutateEarlierSnapshots() {
        val cache = MessageCache(3, 2)
        fun insert(id: Int, seq: Int) = cache.add(id, Message(seq, id, "m$seq", seq.toLong()))
        insert(0, 1); insert(0, 2)
        val before = cache.latest(0, 100)
        insert(0, 3); insert(1, 1); insert(2, 1)
        assertEquals(listOf(1, 2), before.map { it.seq })
        assertEquals(listOf(3), cache.latest(0, 100).map { it.seq })
        assertEquals(2L, cache.evictions)
        assertEquals(3, cache.size)
    }
}
