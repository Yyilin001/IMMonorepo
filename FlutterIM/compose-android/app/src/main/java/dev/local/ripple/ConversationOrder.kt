package dev.local.ripple

import androidx.compose.runtime.Immutable

/** Persistent order-statistic treap. Changing one conversation shares untouched subtrees. */
@Immutable class ConversationOrder private constructor(
    val id: Int, private val pinned: Boolean, private val stamp: Long, private val priority: Int,
    private val left: ConversationOrder?, private val right: ConversationOrder?
) {
    val size: Int = 1 + (left?.size ?: 0) + (right?.size ?: 0)

    operator fun get(index: Int): Int {
        val before = left?.size ?: 0
        return when {
            index < before -> left!![index]
            index == before -> id
            else -> right!![index - before - 1]
        }
    }

    private fun children(l: ConversationOrder? = left, r: ConversationOrder? = right) =
        ConversationOrder(id, pinned, stamp, priority, l, r)

    private fun compare(c: Conversation): Int = when {
        c.pinned != pinned -> pinned.compareTo(c.pinned)
        c.order != stamp -> stamp.compareTo(c.order)
        else -> c.id.compareTo(id)
    }

    private fun insert(c: Conversation): ConversationOrder = when {
        compare(c) < 0 -> {
            val child = add(left, c)
            if (child.priority > priority) child.children(r = children(l = child.right)) else children(l = child)
        }
        compare(c) > 0 -> {
            val child = add(right, c)
            if (child.priority > priority) child.children(l = children(r = child.left)) else children(r = child)
        }
        else -> this
    }

    fun remove(c: Conversation): ConversationOrder? {
        val cmp = compare(c)
        return when {
            cmp < 0 -> children(l = left?.remove(c))
            cmp > 0 -> children(r = right?.remove(c))
            else -> join(left, right)
        }
    }

    companion object {
        private fun join(a: ConversationOrder?, b: ConversationOrder?): ConversationOrder? = when {
            a == null -> b
            b == null -> a
            a.priority > b.priority -> a.children(r = join(a.right, b))
            else -> b.children(l = join(a, b.left))
        }

        fun add(root: ConversationOrder?, c: Conversation): ConversationOrder {
            if (root != null) return root.insert(c)
            var hash = (c.id + 1) * -1640531527
            hash = (hash xor (hash ushr 16)) * -2048144789
            return ConversationOrder(c.id, c.pinned, c.order, hash xor (hash ushr 13), null, null)
        }
    }
}
