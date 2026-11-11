package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*

/** Only this Keystore-encrypted journal persists the short-lived delegated plan. Never log its JSON. */
internal data class SystemUploadRecord(val mapping:ResourceBackgroundUploadMapping,val scope:String,val checksum:ResourceChecksum,
    val plan:ResourceTransferPlan?,val boot:Int,val admittedElapsed:Long,val deadlineElapsed:Long,val attempts:Int=0,
    val cancelled:Boolean=false,val result:ResourceBackgroundUploadResult?=null,val exitMarker:String?=null) {
    init {
        require(exitMarker == null || exitMarker.matches(Regex("[0-9a-f]{64}")))
        require(scope.matches(Regex("[0-9a-f]{64}")) && boot>=0 && admittedElapsed>=0 && deadlineElapsed>admittedElapsed && deadlineElapsed-admittedElapsed<=900_000 && attempts in 0..2)
        require((plan==null)==(result!=null))
        plan?.let {require(it.backgroundUpload==mapping.authorization && it.expectedBytes==mapping.expectedBytes && it.range==mapping.range && resourceBackgroundOriginDigest(it.url)==mapping.originDigest)}
        result?.let {require(it.mapping==mapping.id && it.task==mapping.task)}
    }
    fun unknown()=ResourceBackgroundUploadResult(mapping.id,mapping.task,null,1,0,null)
}
internal object ResourceSystemUploadJournal {
    private val mutex=Mutex()
    private fun secrets(context:Context)=KeystoreSecretStore(context.applicationContext,"resource-system-uploads")
    private suspend fun read(context:Context):PersistentList<SystemUploadRecord> {
        val raw=secrets(context).read() ?: return persistentListOf()
        require(raw.toByteArray().size<=8*1024*1024)
        val rows=Json.parseToJsonElement(raw).jsonArray;require(rows.size<=128)
        return rows.map {decode(it.jsonObject)}.toPersistentList().also {require(it.map {r->r.mapping.task}.distinct().size==it.size)}
    }
    private suspend fun save(context:Context,rows:PersistentList<SystemUploadRecord>) {
        require(rows.size<=128);secrets(context).write(JsonArray(rows.map(::encode)).toString())
    }
    suspend fun records(context:Context)=mutex.withLock {read(context)}
    suspend fun install(context:Context,record:SystemUploadRecord)=mutex.withLock {
        val rows=read(context);val old=rows.firstOrNull {it.mapping.task==record.mapping.task}
        if(old!=null) {require(old.mapping==record.mapping && old.scope==record.scope && old.exitMarker==record.exitMarker && old.checksum==record.checksum && (old.plan==null || old.plan==record.plan));return@withLock}
        require(rows.size<128 && rows.none {it.mapping.id==record.mapping.id});save(context,rows.add(record))
    }
    suspend fun start(context:Context,task:String,boot:Int,elapsed:Long,wall:Long):SystemUploadRecord?=mutex.withLock {
        val rows=read(context);val index=rows.indexOfFirst {it.mapping.task==task};if(index<0) return@withLock null
        val row=rows[index];if(row.result!=null) return@withLock null
        if(row.cancelled || (row.exitMarker?.let {FileLocalExitMarker.forIdentifier(context,it).isPending()} == true) || row.attempts>=2 || row.boot!=boot || elapsed !in row.admittedElapsed until row.deadlineElapsed || requireNotNull(row.plan).expiresAt<=wall) {
            save(context,rows.set(index,row.copy(plan=null,result=row.unknown())));return@withLock null
        }
        row.copy(attempts=row.attempts+1).also {save(context,rows.set(index,it))}
    }
    suspend fun cancel(context:Context,mapping:ResourceBackgroundUploadMapping)=mutex.withLock {
        val rows=read(context);val index=rows.indexOfFirst {it.mapping.task==mapping.task};if(index<0) return@withLock
        val row=rows[index];require(row.mapping==mapping);if(!row.cancelled) save(context,rows.set(index,row.copy(cancelled=true)))
    }
    suspend fun finish(context:Context,task:String,result:ResourceBackgroundUploadResult?=null)=mutex.withLock {
        val rows=read(context);val index=rows.indexOfFirst {it.mapping.task==task};if(index<0 || rows[index].result!=null) return@withLock
        val row=rows[index];save(context,rows.set(index,row.copy(plan=null,result=result ?: row.unknown())))
    }
    suspend fun acknowledge(context:Context,mapping:ResourceBackgroundUploadMapping)=mutex.withLock {
        val rows=read(context);val row=rows.firstOrNull {it.mapping.task==mapping.task} ?: return@withLock
        require(row.mapping==mapping && row.result!=null);save(context,rows.remove(row))
    }
    private fun encode(row:SystemUploadRecord)=buildJsonObject {
        row.exitMarker?.let {put("exitMarker",it)}
        put("mapping",row.mapping.payload());put("scope",row.scope);put("checksum",row.checksum.value);put("boot",row.boot)
        put("admitted",row.admittedElapsed);put("deadline",row.deadlineElapsed);put("attempts",row.attempts);put("cancelled",row.cancelled)
        row.plan?.let {p->put("plan",buildJsonObject {
            put("version",1);put("mode",p.mode.wire);put("url",p.url);put("headers",JsonArray(p.headers.map {h->buildJsonObject {put("name",h.name);put("value",h.value);put("kind","content")}}))
            put("formFields",buildJsonObject {});put("expiresAtUnixMilliseconds",p.expiresAt);put("expectedByteCount",p.expectedBytes)
            p.range?.let {put("byteRange",it.payload())};p.part?.let {put("partNumber",it)};p.checksum?.let {put("checksum",it.payload())}
            put("backgroundAuthorization",requireNotNull(p.backgroundUpload).payload())
        })}
        row.result?.let {r->put("result",buildJsonObject {
            r.status?.let {put("status",it)};r.error?.let {put("error",it)};put("sent",r.sentBytes)
            r.originDigest?.let {put("origin",it)};r.retryNotBefore?.let {put("retry",it)};r.observation?.let {put("observation",it.payload())}
        })}
    }
    private fun decode(v:JsonObject):SystemUploadRecord {
        val mapping=ResourceBackgroundUploadMapping.decode(v.getValue("mapping").jsonObject)
        val r=v["result"]?.jsonObject
        return SystemUploadRecord(mapping,v.getValue("scope").jsonPrimitive.content,ResourceChecksum(v.getValue("checksum").jsonPrimitive.content),
            v["plan"]?.jsonObject?.let(ResourceTransferPlan::decode),v.getValue("boot").jsonPrimitive.int,v.getValue("admitted").jsonPrimitive.long,
            v.getValue("deadline").jsonPrimitive.long,v.getValue("attempts").jsonPrimitive.int,v.getValue("cancelled").jsonPrimitive.boolean,
            r?.let {ResourceBackgroundUploadResult(mapping.id,mapping.task,it["status"]?.jsonPrimitive?.int,it["error"]?.jsonPrimitive?.int,
                it.getValue("sent").jsonPrimitive.long,it["origin"]?.jsonPrimitive?.content,it["retry"]?.jsonPrimitive?.long,it["observation"]?.jsonObject?.let(ResourceBackgroundTransferObservation::decode))},
            v["exitMarker"]?.jsonPrimitive?.also {require(it.isString)}?.content)
    }
}
