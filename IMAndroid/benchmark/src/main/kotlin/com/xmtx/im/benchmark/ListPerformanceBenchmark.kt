package com.xmtx.im.benchmark

import android.content.ComponentName
import android.content.Intent
import androidx.benchmark.macro.*
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

@OptIn(ExperimentalMetricApi::class)
@RunWith(Parameterized::class)
class ListPerformanceBenchmark(private val kind: String, private val count: Int) {
    @get:Rule val benchmark = MacrobenchmarkRule()
    private val iterations = InstrumentationRegistry.getArguments().getString("im.benchmark.iterations")?.toInt() ?: 5
    private val listTag get() = if (kind == "conversations") "conversation-list" else "chat-timeline"
    private fun intent(prepare: Boolean = false) = Intent().setComponent(ComponentName(PACKAGE, "com.xmtx.im.ListBenchmarkActivity"))
        .putExtra("kind", kind).putExtra("count", count).putExtra("prepare", prepare)
    private fun MacrobenchmarkScope.waitStatus(value: String) {
        check(device.wait(Until.hasObject(By.res("benchmark-status").text(value)), 90_000)) { "$kind/$count did not reach $value" }
    }
    private fun MacrobenchmarkScope.prepare() {
        killProcess()
        startActivityAndWait(intent(true))
        waitStatus("prepared")
        killProcess()
    }
    private fun MacrobenchmarkScope.open() { startActivityAndWait(intent()); waitStatus("ready:0") }

    private fun MacrobenchmarkScope.list(): UiObject2 = requireNotNull(device.wait(Until.findObject(By.res(listTag)), 10_000)).apply {
        setGestureMargin(device.displayWidth / 5)
    }
    private fun MacrobenchmarkScope.visibleRows(selector: BySelector): List<String> {
        repeat(5) {
            device.waitForIdle()
            try { return list().findObjects(selector).map { it.text } }
            catch (_: StaleObjectException) { /* Compose replaced nodes during the accessibility read. */ }
        }
        error("List did not produce a stable accessibility snapshot")
    }

    @Test fun coldLoad() {
        require(iterations in 1..20)
        benchmark.measureRepeated(PACKAGE,
            metrics = listOf(StartupTimingMetric(), TraceSectionMetric("IM.List.load", TraceSectionMetric.Mode.Sum)),
            compilationMode = CompilationMode.Full(), iterations = iterations, startupMode = StartupMode.COLD,
            setupBlock = { prepare() }) {
            open()
            assertNotNull(device.findObject(By.res(listTag)))
        }
    }
    @Test fun scrollAndPage() {
        benchmark.measureRepeated(PACKAGE, metrics = listOf(FrameTimingMetric()),
            compilationMode = CompilationMode.Full(), iterations = iterations,
            setupBlock = { prepare(); open() }) {
            // Chat starts at the newest message; conversations start at the first row.
            val gesture = if (kind == "conversations") Direction.UP else Direction.DOWN
            val row = By.textStartsWith(if (kind == "conversations") "性能会话 " else "消息 ")
            val before = visibleRows(row)
            assertTrue("Visible fixture rows are required", before.isNotEmpty())
            repeat(4) { list().swipe(gesture, 0.8f, 2_000); device.waitForIdle() }
            val after = visibleRows(row)
            assertTrue("Visible rows after scrolling are required", after.isNotEmpty())
            assertNotEquals("Gestures must move real list rows", before, after)
            if (kind == "messages") {
                // Exercise the real bounded history replacement, not an in-memory 100k-row list.
                val older = device.wait(Until.findObject(By.res("chat-older-messages")), 10_000)
                requireNotNull(older).click()
                check(device.wait(Until.hasObject(By.res("chat-newer-messages")), 10_000))
            }
            repeat(3) { list().swipe(if (gesture == Direction.UP) Direction.DOWN else Direction.UP, 0.8f, 2_000); device.waitForIdle() }
        }
    }
    @Test fun batchUpdate() {
        benchmark.measureRepeated(PACKAGE,
            metrics = listOf(FrameTimingMetric(), TraceSectionMetric("IM.List.update", TraceSectionMetric.Mode.Sum)),
            compilationMode = CompilationMode.Full(), iterations = iterations,
            setupBlock = { prepare(); open() }) {
            requireNotNull(device.findObject(By.res("benchmark-update"))).click()
            waitStatus("ready:1")
            val changed = if (kind == "conversations") By.textStartsWith("批量更新") else By.textStartsWith("增量消息")
            check(device.wait(Until.hasObject(changed), 10_000)) { "Update did not reach a visible production row" }
        }
    }
    companion object {
        const val PACKAGE = "com.xmtx.im.android.benchmark"
        @JvmStatic @Parameterized.Parameters(name = "{0}_{1}") fun datasets(): List<Array<Any>> = listOf(
            arrayOf("conversations", 1_000), arrayOf("conversations", 10_000),
            arrayOf("messages", 10_000), arrayOf("messages", 100_000))
    }
}
