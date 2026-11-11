package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*

@Composable
internal fun TimelineActivityRow(activity:TimelineActivity) {
    val text=when(activity.kind) {
        TimelineActivityKind.DirectMessageRestricted->"当前无法向此会话发送消息"
        TimelineActivityKind.SystemAccountReadOnly->"此系统账号仅用于发送通知"
    }
    Text(text,Modifier.fillMaxWidth().heightIn(min=44.dp).padding(horizontal=24.dp,vertical=12.dp)
        .testTag("chat-activity-${activity.sourceEvent}").semantics {contentDescription="系统提示"},
        style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant,textAlign=TextAlign.Center)
}
