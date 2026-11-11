package com.xmtx.im

import android.text.format.Formatter
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*

@Composable internal fun ResourceLibraryScreen(state:ResourceLibraryState,active:Boolean,demo:Boolean,
    query:(String,ResourceCategory,Boolean)->Unit,page:(Boolean)->Unit,reload:()->Unit,open:(ResourceKey)->Unit,downloads:()->Unit={},retentionRelease:()->Unit={},storage:()->Unit={},transfers:()->Unit={},
    toggleSelection:()->Unit={},select:(ResourceKey)->Unit={},selectPage:()->Unit={},previewSelection:()->Unit={},confirmSelection:()->Unit={},dismissSelection:()->Unit={},retainSelection:(Boolean)->Unit={}) {
    val context=LocalContext.current
    val foreground=rememberReadForeground();val selection=state.selection;val selected=selection.selected
    val allowed=active && foreground && state.available && !demo && !selection.working && selection.preview==null
    var text by rememberSaveable {mutableStateOf(state.search)}
    var category by rememberSaveable {mutableStateOf(state.category)}
    var retained by rememberSaveable {mutableStateOf(state.retainedOnly)}
    LaunchedEffect(text,category,retained,allowed) {if(allowed) query(text,category,retained)}
    Column(Modifier.fillMaxSize().padding(horizontal=16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(text,{if(it.toByteArray(Charsets.UTF_8).size<=255) text=it},label={Text("搜索资源名称")},enabled=allowed,singleLine=true,modifier=Modifier.fillMaxWidth().testTag("resource-library-search"))
        Row(Modifier.horizontalScroll(rememberScrollState()),horizontalArrangement=Arrangement.spacedBy(8.dp)) {ResourceCategory.entries.forEach {value->
            FilterChip(selected=category==value,onClick={category=value},enabled=allowed,label={Text(when(value) {ResourceCategory.All->"全部";ResourceCategory.Image->"图片";ResourceCategory.Video->"视频";ResourceCategory.Audio->"音频";ResourceCategory.File->"文件"})})
        }}
        FlowRow(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            FilterChip(retained,{retained=!retained},enabled=allowed,label={Text("仅保留本机")},modifier=Modifier.testTag("resource-library-retained"))
            TextButton(transfers,enabled=allowed,modifier=Modifier.testTag("resource-transfer-tasks")) {Text("传输任务")}
            TextButton(downloads,enabled=allowed) {Text("下载任务")}
        }
        Text(if(demo) "登录后可查看已同步的聊天资源" else "已同步且当前可访问的聊天资源",style=MaterialTheme.typography.bodySmall)
        Row {
            TextButton(storage,enabled=allowed,modifier=Modifier.testTag("resource-storage-open")) {Text("存储管理")}
            TextButton(retentionRelease,enabled=allowed,modifier=Modifier.testTag("resource-unavailable-retention")) {Text("失效资源保留")}
        }
        Row(Modifier.horizontalScroll(rememberScrollState()),horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            TextButton(toggleSelection,enabled=allowed && !state.loading,modifier=Modifier.testTag("resource-select-mode")) {Text(if(selected==null) "多选" else "完成选择")}
            if(selected!=null) {
                TextButton(selectPage,enabled=allowed && !state.loading,modifier=Modifier.testTag("resource-select-page")) {Text("选择本页")}
                TextButton(previewSelection,enabled=allowed && !state.loading && selected.isNotEmpty(),modifier=Modifier.testTag("resource-selected-preview")) {Text("检查所选缓存（${selected.size}/100）")}
            }
        }
        if(selected!=null) Row(Modifier.horizontalScroll(rememberScrollState()),horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            TextButton({retainSelection(true)},enabled=allowed && !state.loading && selected.isNotEmpty(),modifier=Modifier.testTag("resource-selected-retain")) {Text("保留本机")}
            TextButton({retainSelection(false)},enabled=allowed && !state.loading && selected.isNotEmpty(),modifier=Modifier.testTag("resource-selected-release")) {Text("解除保留")}
        }
        if(state.loading || selection.working) LinearProgressIndicator(Modifier.fillMaxWidth())
        selection.feedback?.let {Text(it,modifier=Modifier.testTag("resource-selection-feedback"))}
        selection.result?.let {Text("已清理 ${it.deletedCount} 个本机文件，释放 ${Formatter.formatShortFileSize(context,it.releasedBytes)}；跳过 ${it.skippedCount} 个，失败 ${it.failedCount} 个",modifier=Modifier.testTag("resource-selection-result"))}
        selection.retentionResult?.let {result->
            Text("${if(result.retained) "保留本机" else "解除保留"}：已更新 ${result.changedCount} 项，跳过 ${result.skippedCount} 项，失败 ${result.failedKeys.size} 项。\n无需变更 ${result.unchangedCount} 项，当前不可访问 ${result.unavailableCount} 项。"+
                (if(result.limitReachedCount>0) "\n${result.limitReachedCount} 项达到保留数量上限，可释放其他保留后重试。" else "")+
                (if(result.failedKeys.isNotEmpty()) "\n失败项仍被选中，可重试。" else ""),modifier=Modifier.testTag("resource-retention-result"))
        }
        if(state.indexing) Text("正在整理本机资源目录",style=MaterialTheme.typography.bodySmall)
        state.feedback?.let {Text(it,color=MaterialTheme.colorScheme.error)}
        LazyColumn(Modifier.weight(1f).testTag("resource-library-list"),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            if(selected!=null) item {Text("保留不会自动下载；解除保留不立即删除文件。当前不可访问的保留项请到“失效资源保留”中处理。",style=MaterialTheme.typography.bodySmall)}
            if(!state.loading && state.entries.isEmpty()) item {Text(if(retained) "暂无保留的资源" else "暂无匹配的资源",Modifier.padding(vertical=24.dp))}
            items(state.entries,key={"${it.descriptor.key.home}/${it.descriptor.key.media}"}) {entry->
                val key=entry.descriptor.key
                OutlinedCard(onClick={if(selected==null) open(key) else select(key)},enabled=allowed && !state.loading && (selected==null || key in selected || selected.size<100),modifier=Modifier.fillMaxWidth().testTag("resource-entry-${key.media}").semantics {if(selected!=null) this.selected=key in selected}) {
                    Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
                        Text(entry.descriptor.displayName,style=MaterialTheme.typography.titleMedium)
                        if(selected!=null) Checkbox(checked=key in selected,onCheckedChange=null)
                        Text("${Formatter.formatShortFileSize(context,entry.descriptor.byteCount)} · ${entry.referenceCount} 个来源",style=MaterialTheme.typography.bodySmall)
                        if(entry.retained) Text("保留本机",style=MaterialTheme.typography.labelMedium)
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
            TextButton({page(false)},enabled=allowed && !state.loading && state.positions.size>1) {Text("上一页")}
            TextButton(reload,enabled=allowed && !state.loading) {Text("刷新 · 第 ${state.positions.size} 页")}
            TextButton({page(true)},enabled=allowed && !state.loading && state.next!=null) {Text("下一页")}
        }
    }
    if(active && foreground && !demo && state.available) selection.preview?.let {preview->
        AlertDialog(onDismissRequest=dismissSelection,title={Text("清理所选本机缓存？")},text={
            Column(Modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Text("所选资源：${preview.resourceCount} 个\n可清理文件：${preview.plan.fileCount} 个\n预计释放：${Formatter.formatShortFileSize(context,preview.plan.estimatedBytes)}\n未下载资源：${preview.absentResourceCount} 个\n当前不可访问资源：${preview.unavailableResourceCount} 个\n受保护文件：${preview.plan.skippedCount} 个",modifier=Modifier.testTag("resource-selected-summary"))
                Text("仅清理所选资源对应的已下载缓存，不删除消息或云端资源。多个来源可能共用同一文件，清理后都可能需要重新下载。保留本机、待发送原件和使用中的文件会跳过。预览有效期 30 秒，执行前再次核对，最终释放量以实际结果为准。")
            }
        },confirmButton={TextButton(confirmSelection,enabled=!selection.working && preview.plan.fileCount>0,modifier=Modifier.testTag("resource-selected-confirm")) {Text("清理所选缓存")}},
            dismissButton={TextButton(dismissSelection,enabled=!selection.working,modifier=Modifier.testTag("resource-selected-dismiss")) {Text("取消")}})
    }
}

@Composable internal fun ResourceDetailScreen(state:ResourceDetailState,active:Boolean,retain:(Boolean)->Unit,reload:()->Unit,
    page:(Boolean)->Unit,source:(MessageResourceSource)->Unit,open:(MessageResourceSource)->Unit,download:()->Unit={},downloads:()->Unit={}) {
    val context=LocalContext.current;val foreground=rememberReadForeground();val allowed=active && foreground && state.usable
    val snapshot=state.snapshot;val original=state.original
    LazyColumn(Modifier.fillMaxSize().padding(horizontal=20.dp).testTag("resource-detail"),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        if(state.loading || state.working) item {LinearProgressIndicator(Modifier.fillMaxWidth())}
        item(key="download-tasks") {TextButton(downloads,enabled=active && foreground && state.available,modifier=Modifier.testTag("resource-download-tasks")) {Text("查看下载任务")}}
        if(snapshot!=null) {
            item {Text(snapshot.descriptor.displayName,style=MaterialTheme.typography.headlineSmall,modifier=Modifier.padding(top=16.dp))}
            item {Text(Formatter.formatShortFileSize(context,snapshot.descriptor.byteCount));Text(snapshot.descriptor.contentType,style=MaterialTheme.typography.bodySmall)}
            item {Text(when {original==null->"原件尚不可用";original.availableLocally && original.retained->"已下载并保留本机";original.availableLocally->"已下载";original.retained->"已保留，等待下载";else->"尚未下载"},modifier=Modifier.testTag("resource-local-status"))}
            if(original!=null && !original.availableLocally) item {Button(download,enabled=allowed,modifier=Modifier.fillMaxWidth().testTag("resource-download")) {Text("下载文件")}}
            if(original!=null) item {OutlinedButton({retain(!original.retained)},enabled=allowed,modifier=Modifier.fillMaxWidth().testTag("resource-retain")) {Text(if(original.retained) "解除保留本机" else "保留本机")}}
            snapshot.sources.sources.firstOrNull()?.let {first->item {Button({open(first)},enabled=allowed && original!=null,modifier=Modifier.fillMaxWidth().testTag("resource-open")) {Text("查看与分享文件")}}}
            item {Text("查看和分享前会验证当前访问权限。保留本机可防止自动清理，但不会获得永久访问权限；尚未下载的文件仍需联网获取。",style=MaterialTheme.typography.bodySmall)}
            item {Text("来源消息",style=MaterialTheme.typography.titleMedium)}
            items(snapshot.sources.sources,key={"${it.room.value}/${it.message.value}/${it.ordinal}"}) {entry->
                OutlinedButton({source(entry)},enabled=allowed,modifier=Modifier.fillMaxWidth().testTag("resource-source-${entry.message.value}")) {Text("在会话中查看")}
            }
            if(snapshot.sources.nextCursor!=null) item {TextButton({page(true)},enabled=allowed) {Text("更多来源")}}
            if(state.before!=null) item {TextButton({page(false)},enabled=allowed) {Text("返回最初来源")}}
        } else if(!state.loading) item {Text("资源不可用",Modifier.padding(top=24.dp),style=MaterialTheme.typography.titleLarge)}
        (state.readFailure ?: state.feedback)?.let {item {Text(it,modifier=Modifier.testTag("resource-detail-feedback"))}}
        item {TextButton(reload,enabled=active && state.available && !state.loading && !state.working) {Text("重新读取")}}
    }
}
