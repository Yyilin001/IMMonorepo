package com.xmtx.im

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.ConversationActivityState
import com.xmtx.im.client.RoomId

@Composable internal fun ConversationActivityBanner(state: ConversationActivityState, room: RoomId, active: Boolean, group: Boolean) {
    if (!active || state.room != room || !state.subscribed) return
    val text = when {
        state.typing.isNotEmpty() -> if(group) "${state.typing.size} 人正在输入…" else "对方正在输入…"
        state.online == true && !group -> "对方在线"
        else -> return
    }
    Text(text,Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=6.dp)
        .testTag("conversation-activity").semantics { liveRegion = LiveRegionMode.Polite },
        style=MaterialTheme.typography.labelMedium,color=MaterialTheme.colorScheme.onSurfaceVariant)
}
