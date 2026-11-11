package com.xmtx.im.client

import kotlinx.collections.immutable.*

/** Direction is relative to the store's authenticated account. */
enum class RelationshipPageScope { Accepted, Incoming, Outgoing }
data class RelationshipCursor(val target:UserId,val updatedAt:Long,val owner:String,val scope:RelationshipPageScope,val query:String)
data class RelationshipPageRequest(val query:String="",val scope:RelationshipPageScope=RelationshipPageScope.Accepted,
    val cursor:RelationshipCursor?=null,val limit:Int=50) {
    init {require(limit in 1..500)}
}
data class RelationshipPage(val relationships:PersistentList<Relationship> = persistentListOf(),val next:RelationshipCursor?=null)
interface RelationshipPageStore {
    suspend fun relationshipPage(viewer:UserId,request:RelationshipPageRequest):RelationshipPage
    /** Returns true when all known local profile changes have been indexed. No network access. */
    suspend fun processRelationshipSearchIndex(maximumUsers:Int=64):Boolean
}
sealed class RelationshipPageFailure:Exception() {
    class Building:RelationshipPageFailure()
    class InvalidContinuation:RelationshipPageFailure()
    class InvalidQuery:RelationshipPageFailure()
}

/** Stable local position only, not a continuation capability or profile-display permission. */
data class RelationshipAnchor(val target:UserId,val updatedAt:Long) {init {require(updatedAt>=0)}}
data class RelationshipWindow(val page:RelationshipPage,val anchor:RelationshipAnchor?,val hasEarlier:Boolean)
data class RelationshipViewport(val anchor:RelationshipAnchor,val offset:Int=0) {init {require(offset>=0)}}
data class RelationshipNavigation(val revision:Long,val target:UserId?,val offset:Int=0)
interface RelationshipWindowStore:RelationshipPageStore {
    /** request.cursor must be null. Re-resolve a surviving anchor in the current filtered order. */
    suspend fun relationshipWindow(viewer:UserId,request:RelationshipPageRequest,anchor:RelationshipAnchor,
        precedingCount:Int=minOf(50,request.limit-1)):RelationshipWindow
}
