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
import com.xmtx.im.platform.NormalizedPhoto
import kotlinx.coroutines.*

/** Only small encoded immutable pixels cross the controller boundary; bitmaps remain presentation-local. */
@Composable internal fun DraftThumbnail(asset: String,photo: NormalizedPhoto?,enabled: Boolean) {
    val foreground=rememberReadForeground();val permitted=photo?.takeIf { enabled && foreground }
    val decoded by produceState<Pair<NormalizedPhoto,ImageBitmap>?>(null,permitted) {
        value=null
        if(permitted!=null) decodeLocalPhoto(permitted,256,512*1024)?.let { value=permitted to it }
    }
    val shown=decoded?.takeIf { it.first===permitted }?.second
    Box(Modifier.size(72.dp).testTag(if(shown==null) "draft-thumbnail-placeholder-$asset" else "draft-thumbnail-$asset"),contentAlignment=Alignment.Center) {
        if(shown!=null) Image(shown,null,Modifier.fillMaxSize(),contentScale=ContentScale.Crop)
        else Icon(Icons.Outlined.Image,null,Modifier.size(32.dp))
    }
}
internal suspend fun decodeLocalPhoto(photo: NormalizedPhoto,maximumSide: Int,maximumBytes: Int): ImageBitmap? {
    var bitmap:Bitmap?=null
    try {
        withContext(Dispatchers.Default) {
            if(photo.byteCount>maximumBytes || photo.dimensions.width !in 1..maximumSide || photo.dimensions.height !in 1..maximumSide) return@withContext
            val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }
            photo.data.newInput().use { BitmapFactory.decodeStream(it,null,bounds) }
            if(bounds.outWidth!=photo.dimensions.width || bounds.outHeight!=photo.dimensions.height) return@withContext
            currentCoroutineContext().ensureActive()
            bitmap=photo.data.newInput().use { BitmapFactory.decodeStream(it,null,BitmapFactory.Options().apply { inScaled=false;inPreferredConfig=Bitmap.Config.ARGB_8888 }) }
        }
        currentCoroutineContext().ensureActive();return bitmap?.asImageBitmap()
    } catch(error: CancellationException) { bitmap?.recycle();throw error }
    catch(_: Exception) { bitmap?.recycle();return null }
}
