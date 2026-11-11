package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentSet
import kotlinx.collections.immutable.persistentSetOf
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import java.util.concurrent.atomic.AtomicBoolean

/** Finite visibility categories; no table names, row IDs or account identities enter diagnostics. */
enum class ProjectionScope {
    Conversations,ConversationDetails,Contacts,Privacy,Presentations,GroupNicknames,ContactAliases,
    ConversationTimeline,ConversationMetadata,Resources
}
/** Commit duration covers setTransactionSuccessful/endTransaction, not a pure fsync measurement.
 * Snapshot publication means publishing the immutable application value, not rendering a GPU frame.
 */
data class ProjectionMetric(val phase:Phase,val elapsedNanos:Long,val scopes:PersistentSet<ProjectionScope>) {
    enum class Phase { Commit,CommitToConversationSnapshot }
    init {require(elapsedNanos>=0 && scopes.isNotEmpty())}
}
/** One-shot, account-owned measurement kept outside immutable UI models. */
class ConversationCommitMeasurement(private val committedAt:Long,private val diagnostics:NetworkDiagnostics,
    private val nanoTime:()->Long=System::nanoTime) {
    private val consumed=AtomicBoolean()
    suspend fun didPublishSnapshot() {
        if(!currentCoroutineContext().isActive) return
        if(consumed.compareAndSet(false,true)) diagnostics.record(ProjectionMetric(ProjectionMetric.Phase.CommitToConversationSnapshot,
            (nanoTime()-committedAt).coerceAtLeast(0),persistentSetOf(ProjectionScope.Conversations)))
    }
    companion object {
        fun earliest(first:ConversationCommitMeasurement?,second:ConversationCommitMeasurement?):ConversationCommitMeasurement? {
            val a=first?.takeUnless {it.consumed.get()};val b=second?.takeUnless {it.consumed.get()}
            return when {a==null->b;b==null->a;a.committedAt<=b.committedAt->a;else->b}
        }
    }
}
/** Only the snapshot enters application state; the measurement belongs to the publication operation. */
data class ObservedClientSnapshot(val snapshot:ClientSnapshot,val conversationCommit:ConversationCommitMeasurement?)
