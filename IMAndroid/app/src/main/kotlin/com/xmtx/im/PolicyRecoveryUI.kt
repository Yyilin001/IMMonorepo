package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*

@Composable internal fun PolicyRecoveryPanel(state: GroupPolicyState?,busy: Boolean,showPolicies: Boolean = true,retry: () -> Unit) {
    if(state == null) return
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp),verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(when(state.status) {
            PolicyRecoveryStatus.Unavailable -> "群权限当前不可访问"
            PolicyRecoveryStatus.WaitingForSync -> "等待同步恢复后读取完整权限"
            PolicyRecoveryStatus.Needed -> "完整权限待恢复"
            PolicyRecoveryStatus.Pending -> "完整权限已排队重试"
            PolicyRecoveryStatus.Paused -> "权限恢复已暂停，请重新读取"
            PolicyRecoveryStatus.Ready -> "已保存完整权限"
        },style = MaterialTheme.typography.titleSmall)
        if(showPolicies && state.policies.isNotEmpty()) {
            Text("本机保存的权限仅供查看，操作前需要刷新。",style = MaterialTheme.typography.bodySmall)
            state.policies.forEach { policy -> Text("${policy.role.title}：${policy.permissions.sortedBy { it.ordinal }.joinToString("、") { it.title }.ifEmpty { "无" }}") }
        }
        if(state.status in setOf(PolicyRecoveryStatus.Paused,PolicyRecoveryStatus.Needed)) TextButton(onClick = retry,enabled = !busy) { Text("重新读取完整权限") }
    }
}
