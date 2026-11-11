package com.xmtx.im.benchmark

import android.content.ComponentName
import android.content.Intent
import android.os.SystemClock
import androidx.benchmark.macro.*
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import java.io.File
import java.util.UUID

@OptIn(ExperimentalMetricApi::class)
@RunWith(Parameterized::class)
class MessageStreamBenchmark(private val kind: String, private val count: Int, private val mode: String) {
    @get:Rule val benchmark = MacrobenchmarkRule()
    private val args get() = InstrumentationRegistry.getArguments()
    private val rate = args.getString("im.benchmark.messageRate")?.toInt() ?: 1_000
    private val seconds = args.getString("im.benchmark.streamSeconds")?.toInt() ?: 30
    private val iterations = args.getString("im.benchmark.iterations")?.toInt() ?: 5
    private var run = ""
    private fun intent(prepare: Boolean = false) = Intent().setComponent(ComponentName(PACKAGE, "com.xmtx.im.ListBenchmarkActivity"))
        .putExtra("kind", kind).putExtra("count", count).putExtra("prepare", prepare)
        .putExtra("streamRate", rate).putExtra("streamSeconds", seconds).putExtra("streamRun", run).putExtra("streamMode", mode)
    private fun MacrobenchmarkScope.waitFor(tag: String, value: String) {
        check(device.wait(Until.hasObject(By.res(tag).text(value)), (seconds + 90) * 1_000L)) { "Missing $tag=$value" }
    }
    @Test fun sustainedMessages() {
        require(rate in 1..1_000 && seconds in 5..120 && iterations in 1..20)
        benchmark.measureRepeated(PACKAGE,
            metrics = listOf(FrameTimingMetric(), TraceSectionMetric("IM.List.stream", TraceSectionMetric.Mode.Sum)),
            compilationMode = CompilationMode.Full(), iterations = iterations,
            setupBlock = {
                run = UUID.randomUUID().toString()
                killProcess(); startActivityAndWait(intent(true)); waitFor("benchmark-status", "prepared")
                killProcess(); startActivityAndWait(intent()); waitFor("benchmark-status", "ready:0")
            }) {
            val tag = if (kind == "conversations") "conversation-list" else "chat-timeline"
            val bounds = requireNotNull(device.findObject(By.res(tag))).visibleBounds
            requireNotNull(device.findObject(By.res("benchmark-stream"))).click()
            if (mode == "scroll") {
                val until = SystemClock.elapsedRealtime() + seconds * 1_000L
                var swipe = 0
                while (SystemClock.elapsedRealtime() < until) {
                    val top = bounds.top + bounds.height() / 4; val bottom = bounds.bottom - bounds.height() / 4
                    val up = (swipe++ / 3) % 2 == 0
                    check(device.swipe(bounds.centerX(), if (up) bottom else top, bounds.centerX(), if (up) top else bottom, 30))
                }
            }
            check(device.wait(Until.hasObject(By.res("benchmark-stream-status").text(java.util.regex.Pattern.compile("draining|done"))), (seconds + 60) * 1_000L))
            // Browsing may intentionally stop following incoming messages. Return explicitly to drain.
            device.findObject(By.res("chat-return-latest"))?.click()
            waitFor("benchmark-stream-status", "done")
            val text = device.executeShellCommand("cat /sdcard/Android/media/$PACKAGE/stream-reports/$run.json")
            val report = JSONObject(text)
            val output = args.getString("additionalTestOutputDir")?.let(::File)
                ?: InstrumentationRegistry.getInstrumentation().context.externalMediaDirs.first()
            output.mkdirs(); File(output, "stream-$run.json").writeText(text)
            assertEquals(rate * seconds, report.getInt("committed"))
            assertEquals(report.getInt("committed"), report.getInt("published"))
            assertEquals(count + rate * seconds, report.getInt("finalRowCount"))
            assertTrue(report.getInt("publicationSamples") >= if (mode == "follow") 2 else 1)
            if (kind == "messages") assertEquals(120, report.getInt("maximumWindowRows"))
        }
    }
    companion object {
        const val PACKAGE = "com.xmtx.im.android.benchmark"
        @JvmStatic @Parameterized.Parameters(name = "{0}_{1}_{2}") fun datasets(): List<Array<Any>> = listOf(
            "conversations" to 1_000, "conversations" to 10_000, "messages" to 10_000, "messages" to 100_000
        ).flatMap { (kind, count) -> listOf(arrayOf(kind, count, "follow"), arrayOf(kind, count, "scroll")) }
    }
}
