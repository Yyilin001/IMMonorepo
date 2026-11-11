package com.xmtx.im

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material3.Icon
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.MessagePreviewBytes
import kotlinx.coroutines.*
import kotlin.math.max

/** Decode only bounded verified derived images; mutable bitmaps never enter a ViewModel snapshot. */
@Composable internal fun MessageImagePreview(image: MessagePreviewBytes?,modifier: Modifier=Modifier,contentScale: ContentScale=ContentScale.Crop) {
    val foreground=rememberReadForeground()
    val permitted=image?.takeIf { foreground && it.valid() }
    val decoded by produceState<Pair<MessagePreviewBytes,ImageBitmap>?>(null,permitted) {
        value=null
        if(permitted!=null) {
            val bitmap=decodeMessagePreview(permitted)
            if(bitmap!=null && permitted.valid()) value=permitted to bitmap
            awaitPresentationExpiry(permitted.deadlineNanos)
            value=null
        }
    }
    val shown=decoded?.takeIf { it.first===permitted && permitted?.valid()==true }?.second
    Box(modifier.fillMaxWidth().height(112.dp).testTag(if(shown==null) "message-preview-placeholder" else "message-preview-image"),contentAlignment=Alignment.Center) {
        if(shown!=null) Image(shown,null,Modifier.fillMaxSize(),contentScale=contentScale)
        else Icon(Icons.Outlined.Image,null,Modifier.size(40.dp))
    }
}
private suspend fun decodeMessagePreview(source: MessagePreviewBytes): ImageBitmap? {
    var bitmap: Bitmap?=null
    try {
        withContext(Dispatchers.Default) {
            val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }
            source.encoded.newInput().use { BitmapFactory.decodeStream(it,null,bounds) }
            if(bounds.outWidth !in 1..1280 || bounds.outHeight !in 1..1280) return@withContext
            var sample=1;while((max(bounds.outWidth,bounds.outHeight)+sample-1)/sample>512) sample*=2
            currentCoroutineContext().ensureActive()
            bitmap=source.encoded.newInput().use { BitmapFactory.decodeStream(it,null,BitmapFactory.Options().apply { inSampleSize=sample;inPreferredConfig=Bitmap.Config.ARGB_8888 }) }
        }
        currentCoroutineContext().ensureActive()
        if(!source.valid()) { bitmap?.recycle();return null }
        return bitmap?.asImageBitmap()
    } catch(error: CancellationException) { bitmap?.recycle();throw error }
    catch(_: Exception) { bitmap?.recycle();return null }
}
