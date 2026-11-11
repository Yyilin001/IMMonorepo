package com.xmtx.im

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.AvatarPresentationBytes
import kotlinx.coroutines.*
import kotlin.math.max

/** Mutable decoding belongs only to this rendering boundary, never an application snapshot. */
@Composable internal fun Avatar(name: String,size: Int=48,image: AvatarPresentationBytes?=null) {
    val foreground=rememberReadForeground()
    val permitted=image?.takeIf { foreground && it.valid() }
    val pixels=with(LocalDensity.current) { size.dp.roundToPx().coerceIn(1,512) }
    val decoded by produceState<Pair<AvatarPresentationBytes,ImageBitmap>?>(null,permitted,pixels) {
        value=null
        if(permitted!=null) {
            val bitmap=decodeAvatar(permitted,pixels)
            if(bitmap!=null && permitted.valid()) value=permitted to bitmap
            awaitPresentationExpiry(permitted.deadlineNanos)
            value=null
        }
    }
    val visible=decoded?.takeIf { it.first===permitted && permitted?.valid()==true }?.second
    Box(Modifier.clearAndSetSemantics { testTag=if(visible==null) "avatar-placeholder" else "avatar-image" }.size(size.dp)
        .clip(RoundedCornerShape((size/3).dp)).background(MaterialTheme.colorScheme.primaryContainer),contentAlignment=Alignment.Center) {
        if(visible!=null) Image(visible,null,Modifier.fillMaxSize(),contentScale=ContentScale.Crop)
        else Text(name.take(1).uppercase(),style=if(size>50) MaterialTheme.typography.headlineSmall else MaterialTheme.typography.titleLarge,
            color=MaterialTheme.colorScheme.primary,fontWeight=FontWeight.Medium)
    }
}

private suspend fun decodeAvatar(source: AvatarPresentationBytes,pixels: Int): ImageBitmap? {
    var bitmap: Bitmap?=null
    try {
        withContext(Dispatchers.Default) {
            val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }
            source.encoded.newInput().use { BitmapFactory.decodeStream(it,null,bounds) }
            if(bounds.outWidth !in 1..16384 || bounds.outHeight !in 1..16384 || bounds.outWidth>40_000_000/bounds.outHeight) return@withContext
            var sample=1
            while((max(bounds.outWidth,bounds.outHeight)+sample-1)/sample>pixels) sample*=2
            currentCoroutineContext().ensureActive()
            bitmap=source.encoded.newInput().use { BitmapFactory.decodeStream(it,null,BitmapFactory.Options().apply { inSampleSize=sample;inPreferredConfig=Bitmap.Config.ARGB_8888 }) }
        }
        currentCoroutineContext().ensureActive()
        if(!source.valid()) { bitmap?.recycle();return null }
        return bitmap?.asImageBitmap()
    } catch(error: CancellationException) { bitmap?.recycle();throw error }
    catch(_: Exception) { bitmap?.recycle();return null }
}

/** Authorization expires on the monotonic clock, independently of Compose's animation/test clock. */
internal suspend fun awaitPresentationExpiry(deadlineNanos: Long)=withContext(Dispatchers.Default) {
    while(true) {
        val remaining=deadlineNanos-System.nanoTime()
        if(remaining<=0) break
        delay((remaining+999999)/1000000)
    }
}
