package com.xmtx.im

import android.os.Bundle
import android.os.Trace
import android.os.SystemClock
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.ReportDrawnWhen
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.lifecycle.lifecycleScope
import com.xmtx.im.client.*
import com.xmtx.im.platform.SqliteClientStore
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first

/** Drives the production list composables and SQLite reads; fixture seeding is outside measurements. */
class ListBenchmarkActivity : ComponentActivity() {
    private var store: SqliteClientStore? = null
    private var page: ConversationTimelineSession? by mutableStateOf(null)
    private var state by mutableStateOf<AppState?>(null)
    private var prepared by mutableStateOf(false)
    private var updating by mutableStateOf(false)
    private var version by mutableIntStateOf(0)
    private var readyVersion by mutableIntStateOf(-1)
    private var trace: String? = null
    private var frameClock: MonotonicFrameClock? = null
    private var streamStatus by mutableStateOf("idle")
    private var streamJob: Job? = null
    private var loadingJob: Job? = null
    private val manual get() = intent.getBooleanExtra("manual", false)
    private var manualResult by mutableStateOf("")
    private var manualProgress by mutableStateOf("")
    private val streamRate get() = intent.getIntExtra("streamRate", 0)
    private val streamSeconds get() = intent.getIntExtra("streamSeconds", 30)
    private lateinit var fixture: ListBenchmarkFixture
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        fixture = ListBenchmarkFixture(this, requireNotNull(intent.getStringExtra("kind")), intent.getIntExtra("count", 0))
        val prepare = intent.getBooleanExtra("prepare", false)
        if (!prepare && !manual) begin("IM.List.load")
        setContent {
            LaunchedEffect(Unit) { frameClock = currentCoroutineContext()[MonotonicFrameClock] }
            val timeline = page?.state?.collectAsState()?.value
            val loaded = state != null && !updating && (fixture.kind == "conversations" || timeline?.let { it.loaded && !it.loading } == true)
            LaunchedEffect(loaded, version) {
                if (loaded) {
                    if (fixture.kind == "messages") check(requireNotNull(timeline).window.available && timeline.window.messages.size == 120)
                    // Publish completion only after the resulting list has passed a frame boundary.
                    withFrameNanos { }; withFrameNanos { }
                    readyVersion = version
                    if (streamStatus == "idle") end()
                }
            }
            ReportDrawnWhen { prepared || readyVersion >= 0 }
            MaterialTheme {
                Column(Modifier.fillMaxSize().systemBarsPadding().semantics { testTagsAsResourceId = true }) {
                    if (manual) {
                        TextButton(onClick = { finish() }) { Text("返回测试设置") }
                        Text("${if (fixture.kind == "messages") "消息" else "会话"}列表 · ${fixture.count} · ${streamRate} msg/s · ${streamSeconds} 秒")
                        if (readyVersion < 0) Text("正在生成并加载测试数据…")
                        if (manualProgress.isNotEmpty()) Text(manualProgress)
                        if (manualResult.isNotEmpty()) Text(manualResult, Modifier.testTag("benchmark-manual-result"))
                    }
                    if (prepare) Text(if (prepared) "prepared" else "preparing", Modifier.testTag("benchmark-status"))
                    else {
                        Row {
                            Text(if (readyVersion == version) "ready:$version" else "loading", Modifier.testTag("benchmark-status"))
                            if (!manual) Button(onClick = ::update, enabled = readyVersion == version && state != null && streamStatus == "idle", modifier = Modifier.testTag("benchmark-update")) { Text("批量更新") }
                        }
                        if (streamRate > 0) Row {
                            Text(streamStatus, Modifier.testTag("benchmark-stream-status"))
                            Button(onClick = ::startStream, enabled = streamStatus == "idle" && readyVersion >= 0,
                                modifier = Modifier.testTag("benchmark-stream")) { Text("持续 $streamRate msg/s") }
                            if (manual && streamStatus in setOf("running", "draining")) TextButton(onClick = { streamJob?.cancel() }) { Text("停止") }
                        }
                        if (manual && streamStatus == "draining") Text("输入结束，等待界面追平；浏览历史时请点击返回最新。")
                        state?.let { app ->
                            val session = SessionUi.SignedIn(fixture.actor)
                            Box(Modifier.weight(1f)) {
                                if (fixture.kind == "conversations") Conversations(app, session, true, { null }, {})
                                else Chat(app, session, fixture.room, { _, _ -> false }, openTimeline = {
                                    ConversationTimelineSession(requireNotNull(store), fixture.room, fixture.actor, lifecycleScope).also { page = it }
                                })
                            }
                        }
                    }
                }
            }
        }
        loadingJob = lifecycleScope.launch {
            previousCleanup?.join()
            if (prepare) { withContext(Dispatchers.IO) { verifyOptimizedRuntime(); fixture.prepare() }; prepared = true }
            else {
                if (manual) { withContext(Dispatchers.IO) { verifyOptimizedRuntime(); fixture.prepare() }; begin("IM.List.load") }
                store = withContext(Dispatchers.IO) { fixture.open() }
                state = AppState(session = SessionUi.SignedIn(fixture.actor), snapshot = requireNotNull(store).appSnapshot())
                check(state!!.snapshot.messages.isEmpty())
                check(state!!.snapshot.conversations.size == if (fixture.kind == "conversations") fixture.count else 1)
            }
        }
    }
    private fun begin(name: String) { check(trace == null); trace = name; Trace.beginAsyncSection(name, 1) }
    private fun end() { trace?.let { Trace.endAsyncSection(it, 1) }; trace = null }
    private fun update() {
        begin("IM.List.update"); updating = true; version++
        lifecycleScope.launch {
            withContext(Dispatchers.IO) { fixture.update() }
            if (fixture.kind == "conversations") state = requireNotNull(state).copy(snapshot = requireNotNull(store).appSnapshot())
            else { requireNotNull(page).refresh(); requireNotNull(page).state.first { it.loaded && !it.loading } }
            updating = false
        }
    }
    private fun startStream() {
        check(streamJob == null)
        val load = StreamLoad(streamRate, streamSeconds)
        val run = UUID.fromString(requireNotNull(intent.getStringExtra("streamRun"))).toString()
        streamStatus = "running"; begin("IM.List.stream")
        streamJob = lifecycleScope.launch { supervisorScope {
            val latest = AtomicReference(StreamLoad.Commit())
            val visible = AtomicInteger(0); val maximumUnpublished = AtomicInteger(0)
            val latencies = mutableListOf<Double>(); var maximumRows = 0; var historical = false
            val producer = async(Dispatchers.IO) {
                fixture.StreamWriter().use { writer ->
                    val result = load.produce(SystemClock::elapsedRealtimeNanos, { deadline ->
                        while (SystemClock.elapsedRealtimeNanos() < deadline) {
                            delay(((deadline - SystemClock.elapsedRealtimeNanos()) / 1_000_000).coerceAtLeast(1))
                        }
                        currentCoroutineContext().ensureActive()
                    }, writer::append, { commit ->
                        latest.set(commit)
                        maximumUnpublished.updateAndGet { maxOf(it, commit.messages - visible.get()) }
                    })
                    result to writer.rowCount()
                }
            }
            try {
                withTimeout((streamSeconds + 60) * 1_000L) {
                    while (!producer.isCompleted || visible.get() < load.expected) {
                        if (producer.isCompleted) { producer.await(); streamStatus = "draining" }
                        val marker = latest.get()
                        if (manual) manualProgress = "已写入 ${marker.messages}/${load.expected}，已发布 ${visible.get()}"
                        if (marker.messages > visible.get()) {
                            var current = true
                            if (fixture.kind == "conversations") {
                                val snapshot = requireNotNull(store).appSnapshot()
                                check(snapshot.conversations.size == fixture.count && snapshot.messages.isEmpty())
                                check(snapshot.conversations.maxOf { it.updatedAt } >= 1_700_000_000_000 + fixture.count + marker.messages)
                                state = requireNotNull(state).copy(snapshot = snapshot)
                            } else {
                                val timeline = requireNotNull(page)
                                timeline.refresh()
                                val window = timeline.state.first { it.loaded && !it.loading }.window
                                maximumRows = maxOf(maximumRows, window.messages.size)
                                check(window.available && window.messages.size == 120)
                                current = window.latest && window.messages.last().roomSequence >= fixture.count + marker.messages
                                if (!current) historical = true
                            }
                            if (current) {
                                withContext(requireNotNull(frameClock)) { withFrameNanos { }; withFrameNanos { } }
                                visible.set(marker.messages)
                                latencies += (SystemClock.elapsedRealtimeNanos() - marker.atNanos) / 1_000_000.0
                            }
                        }
                        delay(100) // One reader; notifications coalesce rather than queue per-message UI work.
                    }
                }
                val (result, rows) = producer.await()
                check(result.committed == load.expected && rows == fixture.count + load.expected)
                check(latencies.isNotEmpty() && visible.get() == load.expected)
                end()
                val sorted = latencies.sorted()
                val report = JSONObject().put("kind", fixture.kind).put("count", fixture.count)
                    .put("mode", intent.getStringExtra("streamMode")).put("rate", streamRate).put("seconds", streamSeconds)
                    .put("expected", load.expected).put("committed", result.committed).put("withinWindow", result.withinWindow)
                    .put("achievedMsgPerSecond", result.withinWindow.toDouble() / streamSeconds)
                    .put("producerElapsedMs", result.elapsedMs).put("maximumProducerBacklog", result.maximumBacklog)
                    .put("maximumProducerLatenessMs", result.maximumLatenessMs).put("maximumUnpublished", maximumUnpublished.get())
                    .put("published", visible.get()).put("publicationSamples", latencies.size)
                    .put("commitToFrameP95Ms", sorted[(kotlin.math.ceil(sorted.size * 0.95).toInt() - 1).coerceAtLeast(0)])
                    .put("commitToFrameMaxMs", sorted.last()).put("maximumWindowRows", maximumRows)
                    .put("historicalWindowObserved", historical).put("finalRowCount", rows)
                    .put("targetMet", result.withinWindow >= kotlin.math.ceil(load.expected * 0.95).toInt())
                withContext(Dispatchers.IO) {
                    val directory = File(externalMediaDirs.first(), "stream-reports").apply { mkdirs() }
                    File(directory, "$run.json").writeText(report.toString())
                }
                streamStatus = "done"
                if (manual) {
                    manualProgress = "已写入 ${result.committed}/${load.expected}，已发布 ${visible.get()}"
                    manualResult = "实际速率：${result.withinWindow / streamSeconds.toDouble()} msg/s\n" +
                        "提交到帧 P95：${report.getDouble("commitToFrameP95Ms").toInt()} ms · 最大积压：${result.maximumBacklog}\n" +
                        "${if (report.getBoolean("targetMet")) "达到目标（95% 容差）" else "未达到目标速率"} · 返回设置可重新测试"
                }
            } catch (error: CancellationException) {
                if (manual) { streamStatus = "stopped"; manualResult = "测试已停止，返回设置可重新测试。" }
                throw error
            } catch (error: Exception) {
                if (!manual) throw error
                streamStatus = "failed"
                manualResult = "测试未完成：${error.javaClass.simpleName}。返回设置可重新测试。"
            } finally { producer.cancelAndJoin(); end() }
        } }
    }
    override fun onDestroy() {
        end()
        val closingPage = page; val closingStore = store
        closingPage?.close()
        val closingStream = streamJob
        closingStream?.cancel()
        val closingLoad = loadingJob
        closingLoad?.cancel()
        // Store close must follow the cancelled page's physical reads, including Activity recreation.
        previousCleanup = CoroutineScope(Dispatchers.IO).launch { closingLoad?.join(); closingStream?.join(); closingPage?.awaitClosed(); closingStore?.close() }
        super.onDestroy()
    }
    companion object { private var previousCleanup: Job? = null }
}
