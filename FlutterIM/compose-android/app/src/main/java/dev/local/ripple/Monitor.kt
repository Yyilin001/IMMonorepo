package dev.local.ripple

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import java.util.Locale

@Composable fun Monitor(store: ImStore, close: (() -> Unit)?) {
    val r by store.runtime.ui()
    var menu by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().background(Mist)) {
        Header("运行监控") { if (close != null) Action(Icons.Rounded.Close, "关闭运行监控", close) }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Panel {
                Label("目标吞吐量", 17, bold = true)
                listOf(0, 100, 1000, 3000, 5000).chunked(2).forEach { pair ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        pair.forEach { rate -> OutlinedButton({ store.configure(r.copy(rate = rate)) }, Modifier.weight(1f).heightIn(min = 52.dp),
                            colors = ButtonDefaults.outlinedButtonColors(containerColor = if (rate == r.rate) Mint else White)) {
                            Text(when { rate == 0 -> "3 秒/条"; rate >= 1000 -> "${rate / 1000}k / s"; else -> "$rate / s" })
                        } }
                        if (pair.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
                Label(if (r.rate == 0) "每 3 秒生成 1 条消息，适合观察交互。" else "每秒生成 ${number(r.rate)} 条模拟消息。", 14, Muted)
            }
            Panel {
                Label("消息分布", 17, bold = true)
                for (uniform in listOf(false, true)) LinkRow(if (uniform) "全量均匀随机" else "热点模式",
                    if (uniform) "每个会话等概率接收。" else "优先模拟当前会话及前 100 个热点会话。",
                    if (uniform == r.uniform) Icons.Rounded.RadioButtonChecked else Icons.Rounded.RadioButtonUnchecked) {
                    store.configure(r.copy(uniform = uniform))
                }
            }
            Panel {
                Label("历史记录场景", 17, bold = true)
                Box {
                    OutlinedButton({ menu = true }) { Text(r.network.label); Icon(Icons.Rounded.ArrowDropDown, null) }
                    DropdownMenu(menu, { menu = false }) { Network.entries.forEach {
                        DropdownMenuItem({ Text(it.label) }, { store.configure(r.copy(network = it)); menu = false })
                    } }
                }
                OutlinedButton({ store.configure(r.copy(failNext = true)) }, enabled = !r.failNext) {
                    Text(if (r.failNext) "下次请求将失败" else "模拟下次请求失败")
                }
            }
            StatsCard(store)
        }
        Button({ store.configure(r.copy(running = !r.running)) }, Modifier.fillMaxWidth().padding(12.dp).heightIn(min = 50.dp)) {
            Icon(if (r.running) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, null)
            Text(if (r.running) "暂停模拟" else "开始模拟")
        }
    }
}

@Composable private fun StatsCard(store: ImStore) {
    val s by store.stats.ui()
    val total by store.total.ui()
    fun ms(n: Number) = String.format(Locale.US, "%.2f ms", n.toDouble())
    Panel {
        Label("实时统计", 17, bold = true)
        Info("接收速率", "${number(s.perSecond)} / s")
        Canvas(Modifier.fillMaxWidth().height(90.dp).background(Mint)) {
            val samples = s.samples
            val peak = (samples.maxOrNull() ?: 1).coerceAtLeast(1)
            val path = Path()
            samples.forEachIndexed { i, v ->
                val x = size.width * i / (samples.size - 1).coerceAtLeast(1)
                val y = size.height * (1f - v.toFloat() / peak)
                if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            drawPath(path, Green, style = Stroke(2.dp.toPx()))
        }
        Label("最近 30 秒", 13, Muted)
        Info("累计接收", number(s.received)); Info("手动发送", number(s.sent)); Info("未读消息", number(total))
        Info("缓存消息", "${number(s.cached)} / 40k"); Info("已淘汰消息", number(s.evicted))
        Info("单条处理峰值", ms(s.processMs)); Info("状态通知峰值", ms(s.publishMs))
        Info("帧耗时 P95", ms(s.frameP95)); Info("慢帧 / 采样帧", "${s.slowFrames} / ${s.frameCount}")
    }
}

@Composable fun WideHeader(store: ImStore, monitor: () -> Unit) {
    val stats by store.stats.ui()
    Column(Modifier.fillMaxWidth().padding(bottom = 16.dp)) {
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Label("涟漪  /  Local IM", 27, bold = true, modifier = Modifier.weight(1f))
            Label("100% 本地 Mock", 13, Green)
            Action(Icons.Rounded.Tune, "运行监控", monitor)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            val metrics = listOf("会话总量" to "${number(ConversationCount)} 个", "实时接收" to "${number(stats.perSecond)} 条 / 秒",
                "累计接收" to "${number(stats.received)} 条", "渲染 P95" to String.format(Locale.US, "%.1f ms", stats.frameP95))
            metrics.forEach { (label, value) ->
                Box(Modifier.weight(1f)) { Panel { Label(label, 13, Muted); Label(value, 20, bold = true) } }
            }
        }
    }
}
