package com.xmtx.im

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import java.util.UUID

/** A desktop entry for manual runs; automated Macrobenchmarks still launch their explicit fixture. */
class BenchmarkLauncherActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            var dataset by rememberSaveable { mutableIntStateOf(2) }
            var rate by rememberSaveable { mutableStateOf("1000") }
            var seconds by rememberSaveable { mutableStateOf("30") }
            val valid = rate.toIntOrNull() in 1..1000 && seconds.toIntOrNull() in 5..120
            MaterialTheme {
                Column(Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("列表性能测试", style = MaterialTheme.typography.headlineMedium)
                    Text("选择数据规模后进入列表，再点击持续接收。可手动滚动；浏览历史后点击返回最新，查看最终结果。")
                    listOf("会话列表 · 1,000 个会话", "会话列表 · 10,000 个会话",
                        "消息列表 · 10,000 条历史", "消息列表 · 100,000 条历史").forEachIndexed { index, label ->
                        Row(Modifier.fillMaxWidth().clickable { dataset = index }) {
                            RadioButton(selected = dataset == index, onClick = { dataset = index })
                            Text(label, Modifier.padding(top = 12.dp))
                        }
                    }
                    OutlinedTextField(rate, { rate = it }, label = { Text("消息速率（1–1000 msg/s）") },
                        singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(seconds, { seconds = it }, label = { Text("持续时间（5–120 秒）") },
                        singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.fillMaxWidth())
                    Button(enabled = valid, onClick = {
                        startActivity(Intent(this@BenchmarkLauncherActivity, ListBenchmarkActivity::class.java)
                            .putExtra("kind", if (dataset < 2) "conversations" else "messages")
                            .putExtra("count", when (dataset) { 0 -> 1000; 3 -> 100000; else -> 10000 })
                            .putExtra("manual", true).putExtra("streamRate", rate.toInt())
                            .putExtra("streamSeconds", seconds.toInt()).putExtra("streamMode", "manual")
                            .putExtra("streamRun", UUID.randomUUID().toString()))
                    }, modifier = Modifier.fillMaxWidth()) { Text("生成数据并进入列表") }
                    Text("每次进入都会重新生成隔离测试数据，无需登录。此页面提供吞吐和发布延迟；完整帧耗时与 Perfetto 报告请运行自动化性能测试。",
                        style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}
