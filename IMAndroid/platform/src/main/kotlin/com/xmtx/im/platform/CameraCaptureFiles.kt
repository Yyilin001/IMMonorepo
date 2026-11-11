package com.xmtx.im.platform

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.UUID

/** A page-owned camera result. Neither this handle nor its URI belongs in saved/UI state. */
interface CameraPhoto : AutoCloseable {
    val uri: Uri
    suspend fun prepare(): NormalizedPhoto
    override fun close()
}

class CameraCaptureProvider : FileProvider()

/** Private staging for ACTION_IMAGE_CAPTURE; it never publishes a photo to shared media storage. */
object CameraCaptureFiles {
    private const val directory="camera-captures-v1"
    private const val reserve=16L*1024*1024
    private val lock=Any()
    private val live=mutableSetOf<String>()
    private val filename=Regex("capture-[0-9a-f-]{36}\\.jpg")
    private fun root(context: Context)=File(context.cacheDir,directory)
    private fun uri(context: Context,file: File)=FileProvider.getUriForFile(context,"${context.packageName}.camera",file)

    /** Call on application start as well as before capture. A previous process cannot restore a lease. */
    suspend fun cleanup(context: Context)=withContext(Dispatchers.IO) { synchronized(lock) { cleanupLocked(context.applicationContext) } }
    private fun cleanupLocked(context: Context) {
        root(context).listFiles()?.filter { filename.matches(it.name) && it.absolutePath !in live }?.forEach { file ->
            context.revokeUriPermission(uri(context,file),Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if(!file.delete() && file.exists()) throw IOException("无法清理临时照片")
        }
    }

    suspend fun create(context: Context): CameraPhoto {
        var result: CameraPhoto?=null
        try { return withContext(Dispatchers.IO) { synchronized(lock) {
        val app=context.applicationContext;cleanupLocked(app);val folder=root(app)
        check(live.none { File(it).parentFile==folder }) { "已有照片正在拍摄或处理" }
        if(!folder.isDirectory && !folder.mkdirs()) throw IOException("无法创建临时照片")
        if(folder.usableSpace<PhotoPreparation.maximumInputBytes+reserve) throw IOException("存储空间不足，请清理后再拍照")
        val file=File(folder,"capture-${UUID.randomUUID()}.jpg")
        check(file.createNewFile())
        try {
            val content=uri(app,file);live.add(file.absolutePath)
            object: CameraPhoto {
                override val uri=content
                private var released=false
                override suspend fun prepare(): NormalizedPhoto {
                    try {
                        withContext(Dispatchers.IO) { synchronized(lock) {
                            check(!released)
                            if(file.length()>PhotoPreparation.maximumInputBytes) throw PhotoPreparationFailure(PhotoPreparationFailure.Reason.TooLarge)
                            if(file.length()==0L) throw PhotoPreparationFailure(PhotoPreparationFailure.Reason.Unreadable)
                        } }
                        return PhotoPreparation().prepare(app.contentResolver,content)
                    } finally { close() }
                }
                override fun close()=synchronized(lock) {
                    if(!released) {
                        released=true;live.remove(file.absolutePath)
                        try { app.revokeUriPermission(content,Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
                        finally { file.delete() } // Startup/next capture retries an unsuccessful unlink.
                    }
                }
            }.also { result=it }
        } catch(error: Throwable) { live.remove(file.absolutePath);file.delete();throw error }
        } } } catch(error: Throwable) { result?.close();throw error }
    }
}
