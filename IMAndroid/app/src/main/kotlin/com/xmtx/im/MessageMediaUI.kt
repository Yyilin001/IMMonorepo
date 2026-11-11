package com.xmtx.im

import android.text.format.Formatter
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.platform.testTag
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.shape.RoundedCornerShape

/** Metadata remains readable without downloading or treating a projection as byte authorization. */
internal fun chatImageRequests(message: Message): PersistentList<ChatImageRequest> {
    if(message.withdrawn || message.redacted || message.delivery!=Delivery.Accepted) return persistentListOf()
    return message.media?.presentations.orEmpty().filter { it.kind==MessageMediaKind.Image || it.kind==MessageMediaKind.AnimatedImage }
        .map { ChatImageRequest(MessageImageSelection(MediaMessageLocation(message.roomId,message.id),it.media),message.revision,it.descriptor) }.toPersistentList()
}

@Composable internal fun MessageBubbleContent(message: Message,chatImages: ChatImagesState?=null,showImagePreviews: Boolean=false,
    retryImage: (ChatImageRequest)->Unit={},richActive: Boolean=true,viewer: UserId?=null,replySource: Message?=null,jumpReply: (()->Unit)?=null,openFile: ((String)->Unit)?=null,openPlayback: ((String)->Unit)?=null,openImage: ((String)->Unit)?=null) {
    val context=LocalContext.current
    Column(Modifier.padding(14.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        MessageReplyReference(message,replySource,richActive,jumpReply)
        if(message.text.isNotEmpty()) RichMessageText(message,richActive)
        message.rich?.takeUnless {message.withdrawn || message.redacted}?.let {rich->mentionedSummary(rich,viewer).takeIf {it.isNotEmpty()}?.let {Text(it,style=MaterialTheme.typography.labelSmall)}}
        val media=message.media?.takeUnless { message.withdrawn || message.redacted }
        if(media!=null && media.ids.isNotEmpty()) {
            val presentations=media.presentations
            if(presentations==null) Text("${media.ids.size} 个附件 · 等待同步详情",style=MaterialTheme.typography.bodySmall)
            else presentations.forEach { item ->
                val (label,icon)=when(item.kind) {
                    MessageMediaKind.Image->"图片" to Icons.Outlined.Image
                    MessageMediaKind.AnimatedImage->"动图" to Icons.Outlined.Image
                    MessageMediaKind.Video->"视频" to Icons.Outlined.Videocam
                    MessageMediaKind.Audio->"音频" to Icons.Outlined.Audiotrack
                    MessageMediaKind.File->"文件" to Icons.Outlined.InsertDriveFile
                }
                val image=item.kind in setOf(MessageMediaKind.Image,MessageMediaKind.AnimatedImage)
                val request=if(image) ChatImageRequest(MessageImageSelection(MediaMessageLocation(message.roomId,message.id),item.media),message.revision,item.descriptor) else null
                Column(verticalArrangement=Arrangement.spacedBy(6.dp)) {
                    Column(Modifier.semantics(mergeDescendants=true) {}.then(if(image && openImage!=null) Modifier.clickable(role=Role.Button,onClickLabel="查看图片") { openImage(item.media) }.testTag("message-image-open-${item.media}") else if(item.kind in setOf(MessageMediaKind.Audio,MessageMediaKind.Video) && openPlayback!=null && message.delivery==Delivery.Accepted) Modifier.clickable(role=Role.Button,onClickLabel="播放$label") {openPlayback(item.media)}.testTag("message-playback-open-${item.media}") else if(!image && openFile!=null && message.delivery==Delivery.Accepted) Modifier.clickable(role=Role.Button,onClickLabel="查看文件") { openFile(item.media) }.testTag("message-file-open-${item.media}") else Modifier)) {
                        if(image && showImagePreviews && message.delivery==Delivery.Accepted) {
                            val preview=chatImages?.previews?.get(request)?.takeIf { chatImages.available && chatImages.room==message.roomId && it.read.descriptor==item.descriptor && it.read.source.room==message.roomId && it.read.source.message==message.id && it.read.source.revision==message.revision }
                            val ratio=if(item.descriptor.pixelWidth!=null && item.descriptor.pixelHeight!=null) (item.descriptor.pixelWidth!!.toDouble()/item.descriptor.pixelHeight!!).toFloat() else 4f/3f
                            val height=minOf(320f,260f/ratio)
                            MessageImagePreview(preview,Modifier.width((height*ratio).coerceAtLeast(1f).dp).aspectRatio(ratio).clip(RoundedCornerShape(8.dp)),ContentScale.Fit)
                        }
                        Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(10.dp)) {
                            Icon(icon,contentDescription=null,modifier=Modifier.size(24.dp))
                            Column(Modifier.weight(1f,false)) {
                                Text(item.descriptor.displayName,maxLines=2,overflow=TextOverflow.Ellipsis,style=MaterialTheme.typography.bodyMedium)
                                Text("$label · ${Formatter.formatShortFileSize(context,item.byteCount)}",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    if(request!=null && showImagePreviews && chatImages?.available==true) {
                        if(request in chatImages.loading) Text("正在加载缩略图…",style=MaterialTheme.typography.labelSmall)
                        else if(request in chatImages.failed) TextButton(onClick={ retryImage(request) }) { Text("重新加载缩略图") }
                    }
                }
            }
        }
    }
}
