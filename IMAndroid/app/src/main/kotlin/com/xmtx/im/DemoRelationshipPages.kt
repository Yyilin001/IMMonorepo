package com.xmtx.im

import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import java.text.Normalizer
import java.util.Locale

/** In-memory demo only; real relationships always use the account's indexed store. */
internal class DemoRelationshipPages(private val contacts: PersistentList<Contact>,
    private val relationships: PersistentList<Relationship>? = null): RelationshipWindowStore {
    private val order = compareByDescending<Relationship> { it.updatedAt }.thenBy { it.target.value }
    override suspend fun processRelationshipSearchIndex(maximumUsers: Int) = true
    private fun matching(viewer: UserId, request: RelationshipPageRequest): List<Relationship> {
        val query = request.query.trim()
        if (query.toByteArray().size > 100) throw RelationshipPageFailure.InvalidQuery()
        fun normalize(value: String) = Normalizer.normalize(value, Normalizer.Form.NFKC).lowercase(Locale.ROOT)
        val known = contacts.associateBy { it.id }
        val rows = relationships ?: contacts.map { Relationship(it.id, RelationshipState.Accepted, null, 0) }
        return rows.filter { row ->
            val scope = when (request.scope) {
                RelationshipPageScope.Accepted -> row.state == RelationshipState.Accepted
                RelationshipPageScope.Incoming -> row.state == RelationshipState.Pending && row.requestedBy != viewer
                RelationshipPageScope.Outgoing -> row.state == RelationshipState.Pending && row.requestedBy == viewer
            }
            scope && (query.isEmpty() || known[row.target]?.let {
                normalize(it.name).contains(normalize(query)) || normalize(it.handle).contains(normalize(query))
            } == true)
        }.sortedWith(order)
    }
    private fun after(row: Relationship, target: UserId, time: Long) = row.updatedAt < time || row.updatedAt == time && row.target.value > target.value
    private fun page(rows: List<Relationship>, more: Boolean, request: RelationshipPageRequest): RelationshipPage =
        RelationshipPage(rows.toPersistentList(), if (more) rows.last().let { RelationshipCursor(it.target, it.updatedAt, "demo", request.scope, request.query.trim()) } else null)
    override suspend fun relationshipPage(viewer: UserId, request: RelationshipPageRequest): RelationshipPage {
        val cursor = request.cursor
        if (cursor != null && (cursor.owner != "demo" || cursor.scope != request.scope || cursor.query != request.query.trim())) throw RelationshipPageFailure.InvalidContinuation()
        val rows = matching(viewer, request).filter { cursor == null || after(it, cursor.target, cursor.updatedAt) }.take(request.limit + 1)
        return page(rows.take(request.limit), rows.size > request.limit, request)
    }
    override suspend fun relationshipWindow(viewer: UserId, request: RelationshipPageRequest, anchor: RelationshipAnchor, precedingCount: Int): RelationshipWindow {
        require(request.cursor == null && precedingCount in 0 until request.limit)
        val all = matching(viewer, request)
        val current = all.firstOrNull { it.target == anchor.target }?.let { RelationshipAnchor(it.target, it.updatedAt) } ?: anchor
        val before = all.filter { !after(it, current.target, current.updatedAt) && it.target != current.target }.asReversed()
        val later = all.filter { after(it, current.target, current.updatedAt) || it.target == current.target }
        var n = minOf(precedingCount, before.size)
        val m = minOf(request.limit - n, later.size)
        n = minOf(request.limit - m, before.size)
        val rows = before.take(n).asReversed() + later.take(m)
        val resolved = (later.firstOrNull() ?: before.firstOrNull())?.let { RelationshipAnchor(it.target, it.updatedAt) }
        return RelationshipWindow(page(rows, later.size > m, request), resolved, before.size > n)
    }
}
