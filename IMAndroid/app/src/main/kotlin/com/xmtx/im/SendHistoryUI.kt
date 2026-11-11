package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.launch

@Composable internal fun SendHistoryScreen(app: AppState,room: RoomId,active: Boolean,
    open: (RoomId)->SendHistorySession?,openMessage: (MessageId)->Unit,openPreparing: ()->Unit,resume: (String)->Unit={},replaceText: (String)->Unit={},abandonText: (String)->Unit={}) {
    val session=app.session as? SessionUi.SignedIn
    val resumed=rememberReadForeground()
    val allowed=active && resumed && session!=null && !session.demo && room !in app.snapshot.revokedRooms
    val currentOpen by rememberUpdatedState(open)
    var page by remember(session,room) {mutableStateOf<SendHistorySession?>(null)}
    DisposableEffect(session,room,allowed) {
        val opened=if(allowed) currentOpen(room)?.let {if(it.viewer==session?.user && it.room==room) it else {it.close();null}} else null
        page=opened;opened?.latest()
        onDispose {opened?.close();if(page===opened) page=null}
    }
    val result=page?.state?.collectAsState()?.value
    val values=if(allowed) result?.page?.items ?: persistentListOf() else persistentListOf()
    val list=rememberLazyListState();val scope=rememberCoroutineScope()
    LaunchedEffect(result?.selection) {list.scrollToItem(0)}
    Column(Modifier.fillMaxSize()) {
        if(result?.loading==true) LinearProgressIndicator(Modifier.fillMaxWidth())
        if(allowed) Row(Modifier.padding(horizontal=12.dp)) {
            TextButton({page?.previous()},enabled=result?.page?.previous!=null && result.loading!=true) {Text("上一页")}
            TextButton({page?.latest();scope.launch {list.scrollToItem(0)}},enabled=page!=null && result?.loading!=true) {Text("刷新记录")}
            TextButton({page?.next()},enabled=result?.page?.next!=null && result.loading!=true) {Text("下一页")}
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("send-history-list"),state=list,contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
            if(allowed) item {Text("此设备保存的发送记录",style=MaterialTheme.typography.bodySmall);TextButton(openPreparing) {Text("查看附件准备任务")}}
            result?.feedback?.let {feedback->item {Text(feedback);TextButton({page?.refresh()},enabled=allowed) {Text("重试读取记录")}}}
            if(allowed && page==null) item {Text("本地发送记录暂不可读取，请重新打开页面。")}
            if(allowed && result?.loaded==true && values.isEmpty()) item {Text("暂无发送记录")}
            if(room in app.snapshot.revokedRooms) item {Text("此会话当前不可访问")}
            items(values,key={it.operation}) {item->
                Card(Modifier.fillMaxWidth().testTag("send-history-${item.operation}")) {Column(Modifier.padding(16.dp)) {
                    Text(item.text,maxLines=3,overflow=TextOverflow.Ellipsis)
                    Text(when(item.status) {
                        SendRecordStatus.Pending->"等待发送"
                        SendRecordStatus.Confirming->"正在确认原消息的发送结果"
                        SendRecordStatus.WaitingForNetwork->"等待网络连接后继续"
                        SendRecordStatus.WaitingForAuthentication->"等待登录恢复后继续"
                        SendRecordStatus.NeedsAttention->"原消息结果未知，确认已暂停"
                        SendRecordStatus.ExpiredUnsubmitted->"尚未提交，已超过发送期限"
                        SendRecordStatus.Closed->"服务器已确认这条消息未发送"
                        SendRecordStatus.Rejected->"这条消息未能发送"
                        SendRecordStatus.AcceptedAwaitingProjection->"服务器已受理，等待消息同步"
                        SendRecordStatus.Accepted->"服务器已受理"
                    },style=MaterialTheme.typography.bodySmall)
                    if(item.status==SendRecordStatus.NeedsAttention) TextButton({resume(item.operation)},enabled=allowed) {Text("继续确认")}
                    if(item.canReplaceText) TextButton({replaceText(item.operation)},enabled=allowed) {Text("重新发送")}
                    if(item.canAbandonText) TextButton({abandonText(item.operation)},enabled=allowed) {Text("放弃发送")}
                    if(item.replacement!=null) Text("已创建新的发送记录",style=MaterialTheme.typography.bodySmall)
                    if(item.abandoned) Text("已放弃发送",style=MaterialTheme.typography.bodySmall)
                    item.message?.let {message->TextButton({openMessage(message)},enabled=allowed) {Text("打开消息")}}
                }}
            }
        }
    }
}
