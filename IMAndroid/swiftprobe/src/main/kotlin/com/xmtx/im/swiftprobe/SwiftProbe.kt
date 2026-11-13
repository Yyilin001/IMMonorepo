package com.xmtx.im.swiftprobe

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject

object NativeProbe {
    init { System.loadLibrary("IMSwiftProbe") }
    external fun start(input: ByteArray): Long
    external fun poll(handle: Long): ByteArray?
    external fun cancel(handle: Long)
    external fun release(handle: Long): Int
    external fun active(): Int
}

object SwiftProbe {
    suspend fun execute(input: JSONObject): JSONObject = withContext(Dispatchers.Default) {
        val handle = NativeProbe.start(input.toString().toByteArray(Charsets.UTF_8))
        check(handle != 0L) { "Native request rejected" }
        try {
            awaitResult(handle)
        } finally {
            // Kotlin cancellation explicitly reaches the owned Swift Task. Wait
            // for the terminal network/stream cleanup before releasing identity.
            withContext(NonCancellable) {
                NativeProbe.cancel(handle)
                withTimeout(5_000) { awaitResult(handle) }
                check(NativeProbe.release(handle) == 1) { "Released a running Swift task" }
            }
        }
    }

    private suspend fun awaitResult(handle: Long): JSONObject {
        while (true) {
            NativeProbe.poll(handle)?.let { return JSONObject(it.toString(Charsets.UTF_8)) }
            delay(10)
        }
    }
}
