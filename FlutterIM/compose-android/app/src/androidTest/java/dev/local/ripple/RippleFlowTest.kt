package dev.local.ripple

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RippleFlowTest {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()
    private val store get() = ViewModelProvider(ui.activity)[ImStore::class.java]

    private fun tap(text: String) = ui.onNodeWithText(text).performClick()
    private fun action(label: String) = ui.onNodeWithContentDescription(label).performClick()
    private fun visible(text: String) {
        ui.waitUntil(8000) {
            runCatching { ui.onAllNodesWithText(text).onFirst().isDisplayed() }.getOrDefault(false)
        }
    }
    private fun stopTraffic() {
        ui.runOnIdle { store.configure(store.runtime.value.copy(running = false)) }
    }

    @Test fun chatReplyDraftSettingsAndBackStackRestore() {
        stopTraffic()
        tap("林知夏")
        visible("本地会话")
        ui.onNodeWithContentDescription("消息输入框").performTextInput("hello compose")
        action("发送消息")
        visible("收到你的消息了：「hello compose」 ✓")
        ui.onNodeWithContentDescription("消息输入框").performTextInput("my draft")
        action("聊天设置")
        tap("消息免打扰")
        tap("薄荷")
        ui.activityRule.scenario.recreate()
        visible("聊天设置")
        action("返回")
        visible("my draft")
        action("返回")
        tap("林知夏")
        visible("my draft")
        assertTrue(store.row(1).value.muted)
        assertEquals(Backdrop.Mint, store.backgrounds.value[1])
    }

    @Test fun contactSearchRemarksDeletionAndRestore() {
        stopTraffic()
        tap("联系人")
        tap("搜索昵称、备注、标签或账号")
        ui.onNode(hasSetTextAction()).performTextInput("linzhixia")
        visible("林知夏")
        tap("林知夏")
        tap("设置备注与标签")
        ui.onNodeWithText("备注名").performTextInput("夏")
        tap("保存")
        action("资料设置")
        tap("删除联系人")
        tap("删除")
        visible("重新添加联系人")
        tap("重新添加联系人")
        tap("发消息")
        visible("本地会话")
        assertEquals("夏", store.row(1).value.name)
        assertFalse(store.notes.value[1]!!.deleted)
        ui.runOnIdle { store.setNote(1, Note()) }
    }

    @Test fun failedPageCanRetryAndMergeOverlappingResponse() {
        stopTraffic()
        ui.runOnIdle { store.configure(store.runtime.value.copy(failNext = true)) }
        tap("Flutter 技术交流")
        visible("历史记录加载失败 · 重试加载")
        ui.runOnIdle { store.configure(store.runtime.value.copy(network = Network.Overlap)) }
        tap("历史记录加载失败 · 重试加载")
        ui.waitUntil(5000) { store.window(2).value.messages.size == 100 }
        action("查看历史记录")
        ui.waitUntil(5000) { store.window(2).value.messages.size >= 200 }
        val messages = store.window(2).value.messages
        assertEquals(messages.map { it.seq }.distinct().sorted(), messages.map { it.seq })
    }

    @Test fun photoConfirmationGalleryAndDraftOnAndroid12() {
        stopTraffic()
        tap("林知夏")
        ui.onNodeWithContentDescription("消息输入框").performTextInput("keep this draft")
        ui.onNodeWithContentDescription("消息输入框").assertTextEquals("keep this draft")
        ui.onNodeWithContentDescription("添加附件").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnClick)
        visible("相册")
        val fixture = File.createTempFile("ripple-fixture-", ".png", ui.activity.cacheDir)
        val bitmap = Bitmap.createBitmap(24, 12, Bitmap.Config.ARGB_8888)
        fixture.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val result = Instrumentation.ActivityResult(Activity.RESULT_OK, Intent().setData(Uri.fromFile(fixture)))
        val filter = android.content.IntentFilter(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            addDataType("image/*")
        }
        val monitor = instrumentation.addMonitor(filter, result, true)
        try {
            tap("相册")
            visible("发送给 林知夏")
            tap("发送")
            visible("收到你发来的图片了。")
            visible("keep this draft")
            val image = store.window(1).value.messages.last { it.file != null }
            assertTrue(File(image.file!!).isFile)
            assertEquals(2f, image.ratio, .01f)
            ui.onAllNodesWithContentDescription("图片消息").onFirst().performClick()
            ui.onNodeWithContentDescription("关闭图片预览").assertIsDisplayed()
            action("关闭图片预览")
        } finally {
            instrumentation.removeMonitor(monitor)
            fixture.delete()
        }
    }

    @Test fun highRateTrafficPreservesReadingAndFrozenListOrder() {
        stopTraffic()
        val model = store
        tap("Flutter 技术交流")
        action("查看历史记录")
        ui.waitUntil(5000) { model.window(2).value.reading && model.window(2).value.messages.size >= 200 }
        val anchor = model.window(2).value.anchor
        val snapshot = model.window(2).value.messages
        val before = model.stats.value.received
        model.configure(model.runtime.value.copy(rate = 5000, running = true))
        try {
            ui.waitUntil(10000) { model.stats.value.received - before > 2000 }
            assertTrue(model.window(2).value.pending > 0)
            assertEquals(anchor, model.window(2).value.anchor)
            assertTrue(snapshot.last().seq < model.window(2).value.messages.last().seq)
        } finally { model.configure(model.runtime.value.copy(running = false)) }
        ui.onNodeWithText("条新消息", substring = true).performClick()
        ui.waitUntil(5000) { !model.window(2).value.reading && model.window(2).value.pending == 0 }
        val frozen = model.filter("", false, frozen = true)
        try {
            val old = frozen.visible.value!!
            val id = old[20]
            model.send(id, "stable slot")
            assertEquals(id, frozen.visible.value!![20])
            assertEquals(id, old[20])
        } finally { model.release(frozen) }
    }
}
