package com.xmtx.im.client

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.Response
import java.io.Closeable
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardCopyOption.*
import java.security.MessageDigest

enum class MediaFileFailureReason { InvalidRange,VersionChanged,InvalidJournal,DestinationExists,Integrity }
class MediaFileFailure(val reason: MediaFileFailureReason): Exception("Media file $reason")

/** Byte facts only: provider URLs, headers and authorization are never written to disk. */
@Serializable
private data class RangeJournal(val expectedBytes: Long,val checksum: String,val offset: Long,val prefixChecksum: String,val etag: String?)

/** Used serially; its owner drains the physical HTTP callback before closing or checkpointing. */
internal class MediaRangeFile(private val destination: Path,private val target: MediaDownloadTarget,private val checkActive: ()->Unit): Closeable {
    private val partial=destination.resolveSibling(destination.fileName.toString()+".range-part")
    private val journalPath=destination.resolveSibling(destination.fileName.toString()+".range-journal")
    private val temporary=destination.resolveSibling(destination.fileName.toString()+".range-journal-new")
    private val expected=target.plan.expectedBytes
    private val checksum=requireNotNull(target.plan.checksum).value
    private val handle: RandomAccessFile
    private var hash=MessageDigest.getInstance("SHA-256")
    var offset=0L;private set
    var etag: String?=null;private set
    private var checkpointOffset=0L
    private var responseExpected=0L
    private var responseBytes=0L
    private var discardBody=false
    private var discarded=0L
    init {
        Files.createDirectories(destination.parent)
        for(path in listOf(partial,journalPath,temporary)) regularOrAbsent(path)
        if(Files.exists(destination,NOFOLLOW_LINKS)) fail(MediaFileFailureReason.DestinationExists)
        val saved=if(Files.exists(journalPath,NOFOLLOW_LINKS) && Files.size(journalPath)<=4096) runCatching {
            Json.decodeFromString<RangeJournal>(String(Files.readAllBytes(journalPath),Charsets.UTF_8))
        }.getOrNull() else null
        val valid=saved!=null && saved.expectedBytes==expected && saved.checksum==checksum && saved.offset in 0..expected &&
            (saved.etag==null || strongETag(saved.etag)!=null) && Files.exists(partial,NOFOLLOW_LINKS)
        if(!valid) { Files.deleteIfExists(partial);Files.deleteIfExists(journalPath) }
        handle=RandomAccessFile(partial.toFile(),"rw")
        try {
            if(valid) {
                offset=saved!!.offset;etag=saved.etag
                if(handle.length()<offset) reset() else {
                    handle.setLength(offset);handle.seek(0)
                    val buffer=ByteArray(65536)
                    while(true) { checkActive();val n=handle.read(buffer);if(n<0) break;hash.update(buffer,0,n) }
                    if(digest()!=saved.prefixChecksum) reset() else checkpointOffset=offset
                }
            }
            handle.seek(offset)
        } catch(error: Throwable) { handle.close();throw error }
    }
    private fun regularOrAbsent(path: Path) {
        if(Files.exists(path,NOFOLLOW_LINKS) && !Files.isRegularFile(path,NOFOLLOW_LINKS)) fail(MediaFileFailureReason.InvalidJournal)
    }
    private fun digest(): String {
        val bytes=try { (hash.clone() as MessageDigest).digest() } catch(_: CloneNotSupportedException) {
            val replacement=MessageDigest.getInstance("SHA-256")
            Files.newInputStream(partial).use { input -> val buffer=ByteArray(65536);var remaining=offset
                while(remaining>0) { checkActive();val n=input.read(buffer,0,minOf(remaining,buffer.size.toLong()).toInt());if(n<=0) fail(MediaFileFailureReason.InvalidJournal);replacement.update(buffer,0,n);remaining-=n }
            };replacement.digest()
        }
        return bytes.joinToString("") { "%02x".format(it) }
    }
    fun checkpoint() {
        handle.fd.sync()
        val data=Json.encodeToString(RangeJournal(expected,checksum,offset,digest(),etag))
        regularOrAbsent(temporary)
        RandomAccessFile(temporary.toFile(),"rw").use { it.setLength(0);it.write(data.toByteArray(Charsets.UTF_8));it.fd.sync() }
        regularOrAbsent(journalPath)
        Files.move(temporary,journalPath,ATOMIC_MOVE,REPLACE_EXISTING)
        checkpointOffset=offset
    }
    fun reset() {
        handle.setLength(0);handle.seek(0);offset=0;etag=null;hash=MessageDigest.getInstance("SHA-256");checkpointOffset=0;checkpoint()
    }
    fun accept(response: Response,start: Long,end: Long):Long {
        responseBytes=0;discardBody=false;discarded=0
        val incoming=strongETag(response.header("ETag"))
        if(response.header("Content-Encoding")?.let { !it.equals("identity",true) }==true) fail(MediaFileFailureReason.InvalidRange)
        when(response.code) {
            200 -> { if(response.header("Content-Range")!=null) fail(MediaFileFailureReason.InvalidRange);reset();etag=incoming;responseExpected=expected }
            206 -> {
                val range=parseRange(response.header("Content-Range"))
                if(range.first!=start || range.second>end || range.third!=expected || start!=offset) fail(MediaFileFailureReason.InvalidRange)
                if(etag!=null && incoming!=etag) fail(MediaFileFailureReason.VersionChanged)
                etag=incoming;responseExpected=range.second-range.first+1
            }
            416 -> { if(response.header("Content-Range")!="bytes */$expected" || offset!=expected) fail(MediaFileFailureReason.InvalidRange);responseExpected=0;discardBody=true }
            401,403 -> throw MediaReadFailure(MediaReadFailureReason.Denied,response.code)
            else -> throw ClientFailure.Http(response.code,retryAfter=response.header("Retry-After"))
        }
        val length=response.body?.contentLength() ?: 0
        if(length>=0 && (if(discardBody) length>65536 else length!=responseExpected)) fail(MediaFileFailureReason.Integrity)
        return responseExpected
    }
    fun append(buffer: ByteArray,count: Int) {
        checkActive()
        if(discardBody) { discarded+=count;if(discarded>65536) fail(MediaFileFailureReason.Integrity);return }
        if(count>responseExpected-responseBytes || count>expected-offset) fail(MediaFileFailureReason.Integrity)
        handle.write(buffer,0,count);hash.update(buffer,0,count);offset+=count;responseBytes+=count
        if(offset-checkpointOffset>=1024*1024) checkpoint()
    }
    fun finishResponse() { if(responseBytes!=responseExpected) fail(MediaFileFailureReason.Integrity);checkpoint() }
    fun publish() {
        checkActive();target.requireValid()
        if(offset!=expected || digest()!=checksum) { reset();fail(MediaFileFailureReason.Integrity) }
        handle.fd.sync()
        // Same-directory move under the caller's exclusive directory ownership.
        // Do not request ATOMIC_MOVE: its existing-target semantics may replace a file.
        try { Files.move(partial,destination) } catch(_: java.nio.file.FileAlreadyExistsException) { fail(MediaFileFailureReason.DestinationExists) }
        runCatching { Files.deleteIfExists(partial) };runCatching { Files.deleteIfExists(journalPath) }
    }
    override fun close()=handle.close()
    private fun fail(reason: MediaFileFailureReason): Nothing=throw MediaFileFailure(reason)
    private fun parseRange(raw: String?): Triple<Long,Long,Long> {
        if(raw==null || raw.length>128) fail(MediaFileFailureReason.InvalidRange)
        val parts=Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+)").matchEntire(raw)?.groupValues ?: fail(MediaFileFailureReason.InvalidRange)
        val values=parts.drop(1).map { it.toLongOrNull() ?: fail(MediaFileFailureReason.InvalidRange) }
        if(values[1]<values[0] || values[2]<=values[1]) fail(MediaFileFailureReason.InvalidRange)
        return Triple(values[0],values[1],values[2])
    }
    private fun strongETag(raw: String?): String?=raw?.takeIf { value ->
        val bytes=value.toByteArray(Charsets.UTF_8)
        bytes.size in 2..256 && value.first()=='"' && value.last()=='"' && bytes.drop(1).dropLast(1).all { (it.toInt() and 255).let { n -> n==33 || n in 35..126 || n>=128 } }
    }
}
