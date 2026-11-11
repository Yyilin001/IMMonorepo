package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/** One owner task, independent cancellable waiters. The owner must cancel/drain when retiring.
 * Scheduling/admission context is inherited explicitly; the initiating waiter's Job is not.
 */
class SharedOperation<T>(context: CoroutineContext = EmptyCoroutineContext, operation: suspend CoroutineScope.() -> T) {
    private val owner = SupervisorJob()
    private val task = CoroutineScope(context.minusKey(Job) + owner).async(block = operation)
    init { task.invokeOnCompletion { owner.complete() } }
    internal val isCompleted: Boolean get() = task.isCompleted
    suspend fun await(): T = task.await()
    fun cancel() { task.cancel() }
    suspend fun cancelAndDrain() { task.cancel(); withContext(NonCancellable) { task.join() } }
    suspend fun result(): Result<T> = withContext(NonCancellable) { runCatching { task.await() } }
}
