package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.concurrent.atomic.AtomicBoolean

/** Application-owned loop, independent of signed-in account workers. Cancellation retains work. */
class CredentialRevocationRunner(private val queue: CredentialRevocationQueue,
    private val transport: AccountTransport, private val now: () -> Long = System::currentTimeMillis) {
    private val running = AtomicBoolean(false)
    suspend fun run(): Unit {
        currentCoroutineContext().ensureActive()
        check(running.compareAndSet(false, true)) { "Credential revocation runner already active" }
        try {
            while (true) {
                currentCoroutineContext().ensureActive()
                val revision = queue.changes.value
                flushOnce()
                val next = queue.jobs().filter { it.pause == null }.minOfOrNull { it.nextAttemptAt }
                if (next == null) queue.changes.first { it != revision }
                else {
                    val clock = now()
                    if (next <= clock) continue
                    val wait = if (clock < 0 && next > Long.MAX_VALUE + clock) Long.MAX_VALUE else next - clock
                    withTimeoutOrNull(wait) { queue.changes.first { it != revision } }
                }
            }
        } finally { running.set(false) }
    }

    internal suspend fun flushOnce() {
        for (job in queue.due(now())) {
            currentCoroutineContext().ensureActive()
            var failure: Exception? = null
            try {
                // No access token, device authorization header or AuthSession dependency.
                transport.post("/v2/device-credentials/revoke", buildJsonObject {
                    put("credential", job.intent.credential); put("operationID", job.intent.operation)
                }, accessToken = null, expectedStatus = 204)
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) { failure = error }
            currentCoroutineContext().ensureActive()
            if (failure == null || failure is ClientFailure.Http && failure.status == 410) {
                queue.complete(job); continue
            }
            val error = failure
            val pause = when (error) {
                is ClientFailure.Protocol -> CredentialRevocationJob.Pause.InvalidResponse
                is ClientFailure.Http -> when (error.status) {
                    401 -> CredentialRevocationJob.Pause.InvalidCredential
                    409 -> CredentialRevocationJob.Pause.OperationConflict
                    408, 429 -> null
                    in 500..Int.MAX_VALUE -> null
                    else -> CredentialRevocationJob.Pause.InvalidRequest
                }
                else -> null
            }
            val backoff = ((1L shl (job.attempts.coerceAtMost(8).toInt() + 1)) * 1000).coerceAtMost(300_000)
            val retryAfter = (error as? ClientFailure.Http)?.takeIf { it.status == 429 }?.retryAfter
                ?.takeIf { it.matches(Regex("[0-9]+")) }?.toLongOrNull()?.coerceIn(0, 86_400)?.times(1000) ?: 0
            val delay = maxOf(backoff, retryAfter); val clock = now()
            val retry = if (pause != null) clock else if (clock > Long.MAX_VALUE - delay) Long.MAX_VALUE else clock + delay
            queue.recordFailure(job, retry, pause)
        }
    }
}
