package com.xmtx.im.platform

import android.content.Context
import android.system.Os
import android.system.OsConstants
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.io.*
import java.nio.channels.OverlappingFileLockException
import java.util.UUID

/** Scoped byte inbox. The writer neither opens account SQLite nor grants permission to read a resource. */
internal class ResourceBackgroundDownloadInbox(context:Context,scope:String) {
    private val application=context.applicationContext
    private val owner=File(application.noBackupFilesDir.canonicalFile,"resources-$scope")
    private val root=File(owner,"background-downloads")
    init {require(scope.matches(Regex("[0-9a-f]{64}")))}
    private fun folder(mapping:ResourceBackgroundDownloadMapping)=File(root,mapping.id)
    private fun requireDirectory(file:File) {require(file.canonicalFile==file.absoluteFile && OsConstants.S_ISDIR(Os.lstat(file.path).st_mode))}
    private fun exists(file:File)=try {Os.lstat(file.path);true} catch(e:android.system.ErrnoException) {if(e.errno==OsConstants.ENOENT) false else throw e}
    private fun directory(file:File) {requireDirectory(requireNotNull(file.parentFile));if(!exists(file)) Os.mkdir(file.path,448);requireDirectory(file)}
    private fun sync(file:File) {val fd=Os.open(file.path,OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC,0);try {require(OsConstants.S_ISDIR(Os.fstat(fd).st_mode));Os.fsync(fd)} finally {Os.close(fd)}}
    private fun open(file:File,flags:Int):FileDescriptor {
        requireDirectory(requireNotNull(file.parentFile))
        val fd=Os.open(file.path,flags or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC,384)
        try {require(OsConstants.S_ISREG(Os.fstat(fd).st_mode));return fd} catch(e:Throwable) {Os.close(fd);throw e}
    }
    private fun unlink(file:File) {if(exists(file)) {require(OsConstants.S_ISREG(Os.lstat(file.path).st_mode));Os.remove(file.path)}}
    private data class Permit(val mapping:ResourceBackgroundDownloadMapping,val received:Boolean)
    private fun read(mapping:ResourceBackgroundDownloadMapping):Permit {
        requireDirectory(owner);requireDirectory(root);requireDirectory(folder(mapping))
        val data=FileInputStream(open(File(folder(mapping),"permit"),OsConstants.O_RDONLY)).use {
            require(Os.fstat(it.fd).st_size in 1..8192)
            val buffer=ByteArray(8193);var count=0
            while(count<buffer.size) {val read=it.read(buffer,count,buffer.size-count);if(read<0) break;count+=read}
            require(count in 1..8192);buffer.copyOf(count)
        }
        val value=Json.parseToJsonElement(data.toString(Charsets.UTF_8)).jsonObject
        require(value.getValue("version").jsonPrimitive.int==1)
        return Permit(ResourceBackgroundDownloadMapping.decode(value.getValue("mapping").jsonObject),value.getValue("received").jsonPrimitive.boolean).also {require(it.mapping==mapping)}
    }
    private fun write(permit:Permit) {
        val dir=folder(permit.mapping);requireDirectory(dir)
        val data=buildJsonObject {put("version",1);put("mapping",permit.mapping.payload());put("received",permit.received)}.toString().toByteArray()
        require(data.size<=8192);val temp=File(dir,"permit-new");unlink(temp)
        FileOutputStream(open(temp,OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL)).use {it.write(data);it.fd.sync()}
        Os.rename(temp.path,File(dir,"permit").path);sync(dir)
    }
    /** Only the account file owner may create a permit, after reserving durable capacity. */
    suspend fun prepare(mapping:ResourceBackgroundDownloadMapping)=locked(mapping) {
        requireDirectory(owner);directory(root);directory(folder(mapping));sync(root);sync(owner)
        if(exists(File(folder(mapping),"permit"))) {read(mapping);return@locked}
        // A missing permit never authorizes adopting orphan bytes from an earlier task.
        require(!exists(File(folder(mapping),"data")) && !exists(File(folder(mapping),"incoming")))
        write(Permit(mapping,false))
    }
    /** Redirect-free transport supplies an already checked origin. Exactly the granted bytes may be written. */
    suspend fun receive(mapping:ResourceBackgroundDownloadMapping,origin:String,writer:suspend (OutputStream)->Unit)=locked(mapping,waitForProbe=true) {
        val permit=read(mapping);require(!permit.received && origin==mapping.originDigest)
        val dir=folder(mapping);val part=File(dir,"incoming");val data=File(dir,"data")
        require(!exists(data));unlink(part)
        try {
            FileOutputStream(open(part,OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL)).use {output->
                var count=0L;val maximum=mapping.authorization.expectedBytes
                val bounded=object:OutputStream() {
                    override fun write(value:Int) {require(count<maximum);output.write(value);count++}
                    override fun write(bytes:ByteArray,offset:Int,length:Int) {require(offset>=0 && length>=0 && offset<=bytes.size-length && length<=maximum-count);output.write(bytes,offset,length);count+=length}
                    override fun flush()=output.flush()
                    override fun close() {} // The inbox owns the file descriptor and durability boundary.
                }
                writer(bounded);currentCoroutineContext().ensureActive();require(count==maximum);output.fd.sync()
            }
            Os.rename(part.path,data.path);Os.chmod(data.path,256);sync(dir)
            write(Permit(mapping,true))
        } catch(error:Throwable) {unlink(part);sync(dir);throw error}
    }
    /** Reconcile a crash between durable rename and its permit marker, without accepting another writer. */
    suspend fun hasReceived(mapping:ResourceBackgroundDownloadMapping,waitForProbe:Boolean=false):Boolean=locked(mapping,waitForProbe) {
        val permit=read(mapping);val data=File(folder(mapping),"data")
        if(!exists(data)) {require(!permit.received);return@locked false}
        FileInputStream(open(data,OsConstants.O_RDONLY)).use {require(Os.fstat(it.fd).st_size==mapping.authorization.expectedBytes)}
        if(!permit.received) write(Permit(mapping,true))
        true
    }
    /** The account publisher verifies the full checksum before using this raw file. */
    suspend fun <T> withReceived(mapping:ResourceBackgroundDownloadMapping,block:suspend (File)->T):T=locked(mapping) {
        val permit=read(mapping);val data=File(folder(mapping),"data")
        FileInputStream(open(data,OsConstants.O_RDONLY)).use {require(Os.fstat(it.fd).st_size==mapping.authorization.expectedBytes)}
        if(!permit.received) write(Permit(mapping,true))
        block(data)
    }
    suspend fun discard(mapping:ResourceBackgroundDownloadMapping)=locked(mapping) {
        requireDirectory(owner)
        if(!exists(root)) return@locked
        requireDirectory(root);val dir=folder(mapping);if(!exists(dir)) return@locked
        requireDirectory(dir)
        if(exists(File(dir,"permit"))) read(mapping)
        unlink(File(dir,"permit"));sync(dir) // Revoke before unlinking bytes; late receive never creates directories.
        for(name in listOf("permit-new","incoming","data")) unlink(File(dir,name))
        sync(dir);Os.remove(dir.path);sync(root)
    }
    fun allocated(mapping:ResourceBackgroundDownloadMapping):Long {
        val dir=folder(mapping);if(!exists(dir)) return 0
        requireDirectory(owner);requireDirectory(root);requireDirectory(dir)
        return listOf("incoming","data","permit","permit-new").fold(0L) {sum,name->
            val file=File(dir,name)
            val size=try {val stat=Os.lstat(file.path);require(OsConstants.S_ISREG(stat.st_mode));Math.multiplyExact(stat.st_blocks,512)} catch(e:android.system.ErrnoException) {if(e.errno==OsConstants.ENOENT) 0 else throw e}
            Math.addExact(sum,size)
        }
    }
    private suspend fun <T> locked(mapping:ResourceBackgroundDownloadMapping,waitForProbe:Boolean=false,body:suspend ()->T):T=withContext(Dispatchers.IO) {
        val task=UUID.fromString(mapping.task)
        val position=(task.mostSignificantBits xor task.leastSignificantBits) and Long.MAX_VALUE
        val file=File(application.noBackupFilesDir.canonicalFile,"resource-system-download.lock")
        FileOutputStream(open(file,OsConstants.O_RDWR or OsConstants.O_CREAT)).use {stream->
            fun attempt()=try {stream.channel.tryLock(position.coerceAtMost(Long.MAX_VALUE-1),1,false)} catch(_:OverlappingFileLockException) {null}
            var lock=attempt()
            // A recovery probe can briefly hold the lock when the worker starts. It is not a storage failure.
            // Destruction and ordinary probes still fail immediately if an actual writer owns the file.
            val deadline=android.os.SystemClock.elapsedRealtime()+5000
            while(lock==null && waitForProbe && android.os.SystemClock.elapsedRealtime()<deadline) {delay(10);lock=attempt()}
            check(lock!=null) {"后台下载文件仍在使用"};lock.use {body()}
        }
    }
}
