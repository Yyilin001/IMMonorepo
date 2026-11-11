package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import android.database.Cursor
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import java.util.UUID

/** Called under the account store transaction. All JSON is rebuilt from known typed fields. */
internal class SqliteResourceFiles(private val db: SQLiteDatabase,private val actor: UserId) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_variants(key TEXT PRIMARY KEY,resource TEXT NOT NULL,descriptor TEXT NOT NULL CHECK(length(descriptor)<=4096),checksum TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(bytes>0))")
        db.execSQL("CREATE INDEX IF NOT EXISTS resource_variant_resource ON resource_variants(resource,key)")
        prepareVariantOrder()
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_retention(key TEXT PRIMARY KEY,checksum TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(bytes>0),intent TEXT UNIQUE NOT NULL,time INTEGER NOT NULL CHECK(time>=0))")
        db.execSQL("CREATE INDEX IF NOT EXISTS resource_retention_bytes ON resource_retention(checksum,bytes)")
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_source_claims (consumer TEXT PRIMARY KEY,asset TEXT NOT NULL)")
        val fileSchema="(id TEXT PRIMARY KEY,bytes INTEGER NOT NULL CHECK(bytes>=0),checksum TEXT NOT NULL,state TEXT NOT NULL,allocated INTEGER NOT NULL CHECK(allocated>=0),kind TEXT NOT NULL DEFAULT 'Original',last_used INTEGER NOT NULL DEFAULT 0)"
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_files $fileSchema")
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_download_admission(file TEXT PRIMARY KEY,cache_bytes INTEGER NOT NULL,temporary_bytes INTEGER NOT NULL,retained_bytes INTEGER NOT NULL)")
        val admissionColumns=db.rawQuery("PRAGMA table_info(resource_download_admission)",null).use {r->buildSet {while(r.moveToNext()) add(r.getString(1))}}
        if("managed_bytes" !in admissionColumns) db.execSQL("ALTER TABLE resource_download_admission ADD COLUMN managed_bytes INTEGER")
        val fileColumns=db.rawQuery("PRAGMA table_info(resource_files)",null).use { rows -> buildSet { while(rows.moveToNext()) add(rows.getString(1)) } }
        if("kind" !in fileColumns) {
            db.execSQL("CREATE TABLE resource_files_migration $fileSchema")
            db.execSQL("INSERT INTO resource_files_migration(id,bytes,checksum,state,allocated) SELECT id,bytes,checksum,state,allocated FROM resource_files")
            db.execSQL("DROP TABLE resource_files");db.execSQL("ALTER TABLE resource_files_migration RENAME TO resource_files")
        }
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_assets (id TEXT PRIMARY KEY,planned_file TEXT NOT NULL,file_id TEXT,metadata TEXT NOT NULL CHECK(length(metadata)<=8192),availability TEXT NOT NULL,selection INTEGER NOT NULL,created INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_uploads (id TEXT PRIMARY KEY,asset TEXT NOT NULL,operation TEXT UNIQUE NOT NULL,media TEXT UNIQUE NOT NULL,request TEXT NOT NULL CHECK(length(request)<=8192),session TEXT CHECK(length(session)<=524288),stage TEXT NOT NULL,cancelled INTEGER NOT NULL DEFAULT 0,released INTEGER NOT NULL DEFAULT 0)")
        val columns=db.rawQuery("PRAGMA table_info(resource_uploads)",null).use { rows -> buildSet { while(rows.moveToNext()) add(rows.getString(1)) } }
        if("execution" !in columns) {
            db.execSQL("ALTER TABLE resource_uploads ADD COLUMN execution TEXT NOT NULL DEFAULT '{}' CHECK(length(execution)<=8192)")
            db.execSQL("UPDATE resource_uploads SET execution='{\"next\":\"Status\"}' WHERE session IS NOT NULL")
            db.execSQL("UPDATE resource_uploads SET execution='{\"next\":\"Cancel\"}' WHERE cancelled=1")
        }
    } }
    init { if (!db.isReadOnly) {
        db.beginTransaction()
        try {
            val columns=db.rawQuery("PRAGMA table_info(resource_uploads)",null).use {rows->buildSet {while(rows.moveToNext()) add(rows.getString(1))}}
            if("created" !in columns) {
                db.execSQL("ALTER TABLE resource_uploads ADD COLUMN created INTEGER NOT NULL DEFAULT 0")
                // Legacy journals did not record job creation; preserve the source timestamp once.
                db.execSQL("UPDATE resource_uploads SET created=COALESCE((SELECT created FROM resource_assets WHERE id=resource_uploads.asset),0)")
            }
            db.execSQL("CREATE INDEX IF NOT EXISTS resource_upload_created ON resource_uploads(created,id)")
            db.setTransactionSuccessful()
        } finally {db.endTransaction()}
    } }
    private fun prepareVariantOrder() {
        // Typed sort columns avoid JSON-extension dependencies on Android 12.
        // Schema changes, backfill and the index commit together; interrupted or
        // invalid legacy data cannot leave apparently migrated default values.
        db.beginTransaction()
        try {
            val columns=db.rawQuery("PRAGMA table_info(resource_variants)",null).use {rows->buildSet {while(rows.moveToNext()) add(rows.getString(1))}}
            val missing=listOf("sort_kind","sort_id","sort_version").any {it !in columns}
            if("sort_kind" !in columns) db.execSQL("ALTER TABLE resource_variants ADD COLUMN sort_kind INTEGER NOT NULL DEFAULT 0")
            if("sort_id" !in columns) db.execSQL("ALTER TABLE resource_variants ADD COLUMN sort_id TEXT NOT NULL DEFAULT ''")
            if("sort_version" !in columns) db.execSQL("ALTER TABLE resource_variants ADD COLUMN sort_version INTEGER NOT NULL DEFAULT 0")
            if(missing) db.rawQuery("SELECT key,descriptor FROM resource_variants ORDER BY key",null).use {rows->
                while(rows.moveToNext()) {
                    val descriptor=ResourceVariantDescriptor.decode(Json.parseToJsonElement(rows.getString(1)).jsonObject)
                    val derived=descriptor.key.rendition as? ResourceRendition.Derived
                    db.execSQL("UPDATE resource_variants SET sort_kind=?,sort_id=?,sort_version=? WHERE key=?",arrayOf(if(derived==null) 0 else 1,derived?.id ?: "",derived?.version ?: 0L,rows.getString(0)))
                }
            }
            db.execSQL("CREATE INDEX IF NOT EXISTS resource_variant_order ON resource_variants(resource,sort_kind,sort_id,sort_version DESC,key)")
            db.setTransactionSuccessful()
        } finally {db.endTransaction()}
    }
    fun retainedBytes(bytes:Long,checksum:ResourceChecksum)=db.rawQuery("SELECT 1 FROM resource_retention WHERE checksum=? AND bytes=? LIMIT 1",arrayOf(checksum.value,bytes.toString())).use {it.moveToFirst()}
    fun seedDownloadAdmission(policy:ResourceOriginalPolicy) {
        // Only legacy pending rows lack admission records; their old implementation had no managed-byte cap.
        db.execSQL("INSERT OR IGNORE INTO resource_download_admission(file,cache_bytes,temporary_bytes,retained_bytes,managed_bytes) SELECT id,?,?,?,NULL FROM resource_files WHERE kind='Cache' AND state='Publishing'",arrayOf(policy.maximumCacheBytes,policy.maximumTemporaryBytes,policy.retainedWarningBytes))
    }
    fun downloadAdmission(file:String,current:ResourceOriginalPolicy)=db.rawQuery("SELECT cache_bytes,temporary_bytes,managed_bytes FROM resource_download_admission WHERE file=?",arrayOf(file)).use {r->
        check(r.moveToFirst()) {"下载缺少持久化容量预留"}
        current.copy(maximumCacheBytes=maxOf(current.maximumCacheBytes,r.getLong(0)),maximumTemporaryBytes=maxOf(current.maximumTemporaryBytes,r.getLong(1)),maximumManagedBytes=if(current.maximumManagedBytes==null || r.isNull(2)) null else maxOf(requireNotNull(current.maximumManagedBytes),r.getLong(2)))
    }
    private fun requireManagedCapacity(records:List<ResourceLocalFile>,addition:Long,policy:ResourceOriginalPolicy) {
        policy.maximumManagedBytes?.let {maximum->requireCapacity(Math.addExact(records.filter {it.state!=ResourceFileState.Missing}.sumCharges(),backgroundSourceReservedBytes(db)),addition,maximum)}
    }
    fun requireRetainedCapacity(policy:ResourceOriginalPolicy) {
        val retained=files().filter {it.kind==ResourceFileKind.Cache && it.retained}
        if(retained.size>policy.maximumRetainedEntries) throw ResourceRetentionCapacityExceeded()
    }
    fun beginDownload(id: String,bytes: Long,checksum: ResourceChecksum,policy: ResourceOriginalPolicy): ResourceLocalFile {
        require(bytes in 0..512L*1024*1024 && UUID.fromString(id).toString().uppercase()==id)
        val records=files();val retained=retainedBytes(bytes,checksum);val cache=records.filter {it.kind==ResourceFileKind.Cache && it.retained==retained}
        check(cache.size<if(retained) policy.maximumRetainedEntries else policy.maximumCacheEntries)
        if(!retained) requireCapacity(cache.sumCharges(),bytes,policy.maximumCacheBytes)
        requireManagedCapacity(records,bytes,policy)
        requireCapacity(Math.addExact(records.filter { it.state==ResourceFileState.Publishing }.sumCharges(),backgroundSourceReservedBytes(db)),bytes,policy.maximumTemporaryBytes)
        db.execSQL("INSERT INTO resource_files(id,bytes,checksum,state,allocated,kind,last_used) VALUES (?,?,?,'Publishing',0,'Cache',?)",arrayOf<Any>(id,bytes,checksum.value,System.currentTimeMillis()))
        db.execSQL("INSERT INTO resource_download_admission(file,cache_bytes,temporary_bytes,retained_bytes,managed_bytes) VALUES(?,?,?,?,?)",arrayOf(id,policy.maximumCacheBytes,policy.maximumTemporaryBytes,policy.retainedWarningBytes,policy.maximumManagedBytes))
        return files().first { it.id==id }
    }
    fun publishDownload(id: String,allocated: Long,policy: ResourceOriginalPolicy) {
        val file=files().first { it.id==id };require(file.kind==ResourceFileKind.Cache && file.state==ResourceFileState.Publishing)
        reserve(id,allocated,policy)
        db.execSQL("UPDATE resource_files SET state='Published',last_used=? WHERE id=?",arrayOf<Any>(System.currentTimeMillis(),id))
        db.execSQL("DELETE FROM resource_download_admission WHERE file=?",arrayOf(id))
    }
    /** Recovery accounts for bytes already on disk; a reduced quota is handled by cache cleanup. */
    fun recoverDownload(id: String,allocated: Long) {
        require(allocated>=0 && files().any { it.id==id && it.kind==ResourceFileKind.Cache && it.state==ResourceFileState.Publishing })
        db.execSQL("UPDATE resource_files SET state='Published',allocated=?,last_used=? WHERE id=?",arrayOf<Any>(allocated,System.currentTimeMillis(),id))
        db.execSQL("DELETE FROM resource_download_admission WHERE file=?",arrayOf(id))
    }
    fun touchDownload(id: String) {
        require(files().any { it.id==id && it.state==ResourceFileState.Published })
        db.execSQL("UPDATE resource_files SET last_used=? WHERE id=?",arrayOf<Any>(System.currentTimeMillis(),id))
    }
    fun retireCache(id: String) {
        require(files().any { it.id==id && it.kind==ResourceFileKind.Cache && (!it.retained || it.state in setOf(ResourceFileState.Invalid,ResourceFileState.Missing)) })
        db.execSQL("UPDATE resource_files SET state='Retiring' WHERE id=?",arrayOf(id))
    }
    /** Recheck protection and the exact previewed incarnation inside the writer transaction. */
    fun beginCacheCleanup(expected:ResourceLocalFile):Boolean {
        val current=files().firstOrNull {it.id==expected.id} ?: return false
        if(current!=expected || current.kind!=ResourceFileKind.Cache || current.retained || current.state==ResourceFileState.Retiring) return false
        db.execSQL("UPDATE resource_files SET state='Retiring' WHERE id=?",arrayOf(current.id))
        return true
    }
    fun assets(): PersistentList<ResourceLocalAsset> = db.rawQuery("SELECT id,planned_file,file_id,metadata,availability,selection,created FROM resource_assets ORDER BY rowid",null).use { rows -> buildList {
        while(rows.moveToNext()) {
            val meta=Json.parseToJsonElement(rows.getString(3)).jsonObject
            add(ResourceLocalAsset(rows.getString(0),rows.getString(1),if(rows.isNull(2)) null else rows.getString(2),meta.text("name"),meta.text("type"),meta.long("bytes"),ResourceChecksum(meta.text("checksum")),
                ResourceUsage.decode(meta.getValue("purpose").jsonObject),meta["dimensions"]?.jsonObject?.let { ResourceDimensions(Math.toIntExact(it.long("width")),Math.toIntExact(it.long("height"))) },
                ResourceAssetAvailability.valueOf(rows.getString(4)),rows.getInt(5)==1,rows.getLong(6)))
        }
    }.toPersistentList() }
    fun files(): PersistentList<ResourceLocalFile> = db.rawQuery("SELECT f.id,f.bytes,f.checksum,f.state,f.allocated,f.kind,f.last_used,EXISTS(SELECT 1 FROM resource_retention r WHERE r.checksum=f.checksum AND r.bytes=f.bytes) FROM resource_files f ORDER BY f.rowid",null).use { rows -> buildList {
        while(rows.moveToNext()) add(ResourceLocalFile(rows.getString(0),rows.getLong(1),ResourceChecksum(rows.getString(2)),ResourceFileState.valueOf(rows.getString(3)),rows.getLong(4),ResourceFileKind.valueOf(rows.getString(5)),rows.getLong(6),rows.getInt(7)==1))
    }.toPersistentList() }
    fun begin(asset: ResourceLocalAsset,policy: ResourceOriginalPolicy): ResourceLocalAsset {
        require(asset.availability==ResourceAssetAvailability.Importing && asset.selectionActive && asset.file==null)
        val old=assets().firstOrNull { it.id==asset.id }
        if(old!=null) { require(old.copy(file=null,availability=ResourceAssetAvailability.Importing)==asset);return old }
        check(assets().count { it.selectionActive }<policy.maximumSelections) { "已选资源过多" }
        val existing=files().firstOrNull { it.id==asset.plannedFile }
        if(existing!=null) {
            require(existing.state==ResourceFileState.Published && existing.byteCount==asset.byteCount && existing.checksum==asset.checksum)
            if(existing.kind==ResourceFileKind.Cache) {
                requireCapacity(files().filter { it.kind==ResourceFileKind.Original }.sumCharges(),existing.chargedBytes,policy.maximumOriginalBytes)
                db.execSQL("UPDATE resource_files SET kind='Original' WHERE id=?",arrayOf(existing.id))
            }
        }
        else {
            val records=files();requireManagedCapacity(records,asset.byteCount,policy);requireCapacity(records.filter { it.kind==ResourceFileKind.Original }.sumCharges(),asset.byteCount,policy.maximumOriginalBytes)
            requireCapacity(Math.addExact(records.filter { it.state==ResourceFileState.Publishing }.sumCharges(),backgroundSourceReservedBytes(db)),asset.byteCount,policy.maximumTemporaryBytes)
            db.execSQL("INSERT INTO resource_files(id,bytes,checksum,state,allocated) VALUES (?,?,?,'Publishing',0)",arrayOf<Any>(asset.plannedFile,asset.byteCount,asset.checksum.value))
        }
        val metadata=buildJsonObject { put("name",asset.displayName);put("type",asset.contentType);put("bytes",asset.byteCount);put("checksum",asset.checksum.value);put("purpose",asset.purpose.payload());asset.dimensions?.let { put("dimensions",it.payload()) } }
        db.execSQL("INSERT INTO resource_assets VALUES (?,?,NULL,?,'Importing',1,?)",arrayOf<Any>(asset.id,asset.plannedFile,metadata.toString(),asset.createdAt))
        return asset
    }
    fun reserve(fileId: String,allocated: Long,policy: ResourceOriginalPolicy) {
        require(allocated>=0);val records=files();val file=records.first { it.id==fileId };require(file.state==ResourceFileState.Publishing)
        if(file.kind==ResourceFileKind.Original || !file.retained) requireCapacity(records.filter {it.id!=fileId && it.kind==file.kind && (file.kind==ResourceFileKind.Original || !it.retained)}.sumCharges(),maxOf(file.byteCount,allocated),if(file.kind==ResourceFileKind.Original) policy.maximumOriginalBytes else policy.maximumCacheBytes)
        if(maxOf(file.byteCount,allocated)>file.chargedBytes) requireManagedCapacity(records,maxOf(file.byteCount,allocated)-file.chargedBytes,policy)
        requireCapacity(Math.addExact(records.filter { it.id!=fileId && it.state==ResourceFileState.Publishing }.sumCharges(),backgroundSourceReservedBytes(db)),maxOf(file.byteCount,allocated),policy.maximumTemporaryBytes)
        db.execSQL("UPDATE resource_files SET allocated=? WHERE id=?",arrayOf<Any>(allocated,fileId))
    }
    fun publish(assetId: String,fileId: String,allocated: Long): ResourceLocalAsset {
        require(allocated>=0)
        val asset=assets().first { it.id==assetId };val file=files().first { it.id==fileId }
        require(asset.plannedFile==fileId && asset.checksum==file.checksum && asset.byteCount==file.byteCount)
        require(asset.availability in setOf(ResourceAssetAvailability.Importing,ResourceAssetAvailability.Local) && file.state in setOf(ResourceFileState.Publishing,ResourceFileState.Published))
        require(allocated==file.allocatedBytes) { "文件发布缺少磁盘额度预留" }
        db.execSQL("UPDATE resource_files SET state='Published',allocated=? WHERE id=?",arrayOf<Any>(allocated,fileId))
        db.execSQL("UPDATE resource_assets SET file_id=?,availability='Local' WHERE id=?",arrayOf(fileId,assetId))
        return assets().first { it.id==assetId }
    }
    fun markFile(id: String,state: ResourceFileState) {
        require(state in setOf(ResourceFileState.Invalid,ResourceFileState.Missing))
        require(files().any { it.id==id })
        db.execSQL("UPDATE resource_files SET state=? WHERE id=?",arrayOf(state.name,id))
        db.execSQL("UPDATE resource_assets SET availability='Unavailable' WHERE file_id=? OR planned_file=?",arrayOf(id,id))
    }
    fun unavailable(id: String) { db.execSQL("UPDATE resource_assets SET availability='Unavailable' WHERE id=?",arrayOf(id)) }
    fun releaseSelection(id: String) { db.execSQL("UPDATE resource_assets SET selection=0 WHERE id=?",arrayOf(id)) }
    fun bindProfile(assetId: String,consumer: ProfileOriginalConsumer,adopting: ProfileOriginalConsumer?=null) {
        val asset=assets().first { it.id==assetId }
        require(asset.availability==ResourceAssetAvailability.Local && asset.purpose==ResourceUsage.UserAvatar)
        require(files().any { it.id==asset.file && it.state==ResourceFileState.Published })
        require(if(adopting==null) asset.selectionActive else claimAsset(adopting)==assetId)
        db.execSQL("INSERT INTO resource_source_claims VALUES (?,?)",arrayOf(consumer.key,assetId));releaseSelection(assetId)
    }
    fun releaseProfile(consumer: ProfileOriginalConsumer) { db.execSQL("DELETE FROM resource_source_claims WHERE consumer=?",arrayOf(consumer.key)) }
    private fun claimAsset(consumer: ProfileOriginalConsumer): String?=db.rawQuery("SELECT asset FROM resource_source_claims WHERE consumer=?",arrayOf(consumer.key)).use { if(it.moveToFirst()) it.getString(0) else null }
    private fun groupAssetId(consumer: GroupAvatarOriginalConsumer): String?=db.rawQuery("SELECT asset FROM resource_source_claims WHERE consumer=?",arrayOf(consumer.key)).use { if(it.moveToFirst()) it.getString(0) else null }
    fun groupOriginal(consumer: GroupAvatarOriginalConsumer): ResourceLocalAsset {
        val asset=assets().first { it.id==groupAssetId(consumer) }
        require(asset.availability==ResourceAssetAvailability.Local && files().any { it.id==asset.file && it.state==ResourceFileState.Published })
        return asset
    }
    fun bindGroup(assetId: String,room: RoomId,consumer: GroupAvatarOriginalConsumer,adopting: GroupAvatarOriginalConsumer?=null) {
        val asset=assets().first { it.id==assetId }
        require(asset.purpose==ResourceUsage.GroupAvatar(room) && asset.availability==ResourceAssetAvailability.Local)
        require(files().any { it.id==asset.file && it.state==ResourceFileState.Published })
        require(if(adopting==null) asset.selectionActive else groupAssetId(adopting)==assetId)
        db.execSQL("INSERT INTO resource_source_claims VALUES (?,?)",arrayOf(consumer.key,assetId));releaseSelection(assetId)
    }
    fun releaseGroup(consumer: GroupAvatarOriginalConsumer) { db.execSQL("DELETE FROM resource_source_claims WHERE consumer=?",arrayOf(consumer.key)) }
    fun bindSend(assetId: String,room: RoomId,consumer: SendOriginalConsumer,adopting: SendOriginalConsumer?=null) {
        val asset=assets().first { it.id==assetId }
        require(consumer.asset==assetId && asset.purpose==ResourceUsage.Attachment(room) && asset.availability==ResourceAssetAvailability.Local)
        require(files().any { it.id==asset.file && it.state==ResourceFileState.Published })
        require(if(adopting==null) asset.selectionActive else sendAsset(adopting)==assetId)
        db.execSQL("INSERT INTO resource_source_claims VALUES (?,?)",arrayOf(consumer.key,assetId));releaseSelection(assetId)
    }
    fun releaseSend(consumer: SendOriginalConsumer) { db.execSQL("DELETE FROM resource_source_claims WHERE consumer=?",arrayOf(consumer.key)) }
    private fun sendAsset(consumer: SendOriginalConsumer): String?=db.rawQuery("SELECT asset FROM resource_source_claims WHERE consumer=?",arrayOf(consumer.key)).use { if(it.moveToFirst()) it.getString(0) else null }
    fun ownsSendSource(consumer:SendOriginalConsumer)=sendAsset(consumer)==consumer.asset
    fun sendOriginal(consumer: SendOriginalConsumer): ResourceLocalAsset {
        val asset=assets().first { it.id==sendAsset(consumer) }
        require(asset.availability==ResourceAssetAvailability.Local && files().any { it.id==asset.file && it.state==ResourceFileState.Published })
        return asset
    }
    fun original(selection: String?,upload: String?,profile: ProfileOriginalConsumer?=null): ResourceLocalAsset {
        require(listOf(selection,upload,profile).count { it!=null }==1)
        val asset=if(selection!=null) assets().first { it.id==selection }.also { require(it.selectionActive) }
            else if(profile!=null) assets().first { it.id==claimAsset(profile) }
            else { val job=uploads().first { it.id==upload };require(!job.sourceReleased);assets().first { it.id==job.asset } }
        require(asset.availability==ResourceAssetAvailability.Local && files().any { it.id==asset.file && it.state==ResourceFileState.Published }) { "资源原文件不可用" }
        return asset
    }
    fun retire(excluding: PersistentSet<String>): PersistentList<ResourceLocalFile> {
        val claims=db.rawQuery("SELECT asset FROM resource_source_claims",null).use { rows -> buildSet { while(rows.moveToNext()) add(rows.getString(0)) } }
        val consumers=uploads().filter { !it.sourceReleased }.map { it.asset }.toSet()+claims
        val used=assets().filter { it.selectionActive || it.id in consumers }.flatMap { listOfNotNull(it.file,it.plannedFile) }.toSet()
        files().filter {it.kind==ResourceFileKind.Original && it.retained && it.id !in used}.forEach {db.execSQL("UPDATE resource_files SET kind='Cache' WHERE id=?",arrayOf(it.id))}
        val candidates=files().filter { it.id !in used && it.id !in excluding && ((it.kind==ResourceFileKind.Original && !it.retained) || it.state in setOf(ResourceFileState.Invalid,ResourceFileState.Missing,ResourceFileState.Retiring)) }
        candidates.forEach { db.execSQL("UPDATE resource_files SET state='Retiring' WHERE id=?",arrayOf(it.id)) }
        return candidates.map { it.copy(state=ResourceFileState.Retiring) }.toPersistentList()
    }
    fun delete(id: String) {
        require(files().first { it.id==id }.state==ResourceFileState.Retiring)
        db.execSQL("UPDATE resource_assets SET availability='Unavailable',file_id=NULL WHERE file_id=? OR planned_file=?",arrayOf(id,id))
        db.execSQL("DELETE FROM resource_files WHERE id=?",arrayOf(id))
        db.execSQL("DELETE FROM resource_download_admission WHERE file=?",arrayOf(id))
        db.execSQL("DELETE FROM resource_assets WHERE selection=0 AND (file_id IS NULL) AND NOT EXISTS(SELECT 1 FROM resource_uploads WHERE asset=resource_assets.id) AND NOT EXISTS(SELECT 1 FROM resource_source_claims WHERE asset=resource_assets.id)")
    }
    private val uploadColumns="id,asset,request,session,stage,cancelled,released,execution"
    private fun decodeUpload(row:Cursor)=ResourceUploadWork(row.getString(0),row.getString(1),ResourceUploadRequest.decode(Json.parseToJsonElement(row.getString(2)).jsonObject),
        if(row.isNull(3)) null else ResourceUploadSession.decode(Json.parseToJsonElement(row.getString(3)).jsonObject),ResourceUploadStage.valueOf(row.getString(4)),row.getInt(5)==1,row.getInt(6)==1,Json.decodeFromString<ResourceUploadExecution>(row.getString(7)))
    fun upload(id:String)=db.rawQuery("SELECT $uploadColumns FROM resource_uploads WHERE id=?",arrayOf(id)).use {if(it.moveToFirst()) decodeUpload(it) else null}
    fun uploads():PersistentList<ResourceUploadWork> = db.rawQuery("SELECT $uploadColumns FROM resource_uploads ORDER BY rowid",null).use {rows->buildList {while(rows.moveToNext()) add(decodeUpload(rows))}.toPersistentList()}
    fun prepare(id: String,assetId: String,request: ResourceUploadRequest,profile: ProfileOriginalConsumer?=null,group: GroupAvatarOriginalConsumer?=null,send: SendOriginalConsumer?=null): ResourceUploadWork {
        require(listOf(profile,group,send).count { it!=null }<=1)
        val work=ResourceUploadWork(id,assetId,request);val old=uploads().firstOrNull { it.id==id }
        if(old!=null) { require(old.asset==assetId && old.request==request);return old }
        val asset=assets().first { it.id==assetId }
        require((when { send!=null -> sendAsset(send)==assetId;profile!=null -> claimAsset(profile)==assetId;group!=null -> groupAssetId(group)==assetId;else -> asset.selectionActive }) && asset.availability==ResourceAssetAvailability.Local)
        require(asset.byteCount==request.byteCount && asset.checksum==request.checksum && asset.contentType==request.contentType && asset.displayName==request.displayName && asset.purpose==request.usage && (request.dimensions==null || request.dimensions==asset.dimensions))
        val imports=db.rawQuery("SELECT status,cancelled,confirmed FROM resource_imports",null).use { rows ->
            var count=0
            while(rows.moveToNext()) {
                val state=if(rows.isNull(0)) null else ResourceImportStatus.decode(Json.parseToJsonElement(rows.getString(0)).jsonObject).state
                if(state==null || !state.terminal || state==ResourceImportState.Ready && rows.getInt(1)==1 && rows.getInt(2)==0) count++
            }
            count
        }
        check(uploads().count { !it.terminal }+imports<32) { "待处理资源任务过多" }
        db.execSQL("INSERT INTO resource_uploads(id,asset,operation,media,request,stage,created) VALUES (?,?,?,?,?,'Prepared',?)",arrayOf(id,assetId,request.operation,request.media,request.payload().toString(),System.currentTimeMillis()))
        releaseSelection(assetId)
        return work
    }
    private fun bound(session: ResourceUploadSession,work: ResourceUploadWork) {
        require(session.media==work.request.media && session.locator.home==work.request.usage.home(actor))
        work.session?.let { require(session.locator==it.locator && session.generation>=it.generation) }
        var total=0L;session.parts.forEach { require(it.byteCount<=work.request.byteCount-total);total+=it.byteCount }
    }
    fun save(id: String,session: ResourceUploadSession,owner: String?=null): ResourceUploadWork {
        val work=uploads().first { it.id==id };require(!work.execution.backgroundPending && work.execution.owner==owner);require(!work.cancellationRequested && work.stage !in setOf(ResourceUploadStage.Cancelled,ResourceUploadStage.Expired,ResourceUploadStage.Rejected));bound(session,work)
        val stage=when {
            session.state==ResourceSessionState.Cancelled -> ResourceUploadStage.Cancelled
            session.state==ResourceSessionState.Expired -> ResourceUploadStage.Expired
            session.state==ResourceSessionState.Failed || session.resourceState in setOf(ResourceState.Rejected,ResourceState.Deleted,ResourceState.DeletionPending) -> ResourceUploadStage.Rejected
            session.resourceState==ResourceState.Ready -> ResourceUploadStage.Ready
            session.state in setOf(ResourceSessionState.Finalizing,ResourceSessionState.Completed) -> ResourceUploadStage.Processing
            else -> ResourceUploadStage.Transferring
        }
        require(work.stage!=ResourceUploadStage.Ready || stage in setOf(ResourceUploadStage.Ready,ResourceUploadStage.Cancelled,ResourceUploadStage.Expired,ResourceUploadStage.Rejected))
        db.execSQL("UPDATE resource_uploads SET session=?,stage=? WHERE id=?",arrayOf(session.payload().toString(),stage.name,id))
        return uploads().first { it.id==id }
    }
    fun cancel(id: String): ResourceUploadWork {
        val work=uploads().first { it.id==id };if(work.terminal || work.cancellationRequested) return work
        db.execSQL("UPDATE resource_uploads SET cancelled=1 WHERE id=?",arrayOf(id))
        putExecution(id,work.execution.copy(next=ResourceUploadAction.Cancel,userPaused=false,attention=false,attempts=0,deadline=null,retryAt=work.execution.serverRetryAt))
        return uploads().first { it.id==id }
    }
    fun confirmCancel(id: String,session: ResourceUploadSession,owner: String?=null): ResourceUploadWork {
        val work=uploads().first { it.id==id };require(!work.execution.backgroundPending && work.execution.owner==owner);require(work.cancellationRequested);bound(session,work)
        require(session.state in setOf(ResourceSessionState.Cancelled,ResourceSessionState.Completed,ResourceSessionState.Expired,ResourceSessionState.Failed))
        db.execSQL("UPDATE resource_uploads SET session=?,stage=? WHERE id=?",arrayOf(session.payload().toString(),if(session.state==ResourceSessionState.Completed) "Ready" else "Cancelled",id))
        return uploads().first { it.id==id }
    }
    internal fun putExecution(id: String,value: ResourceUploadExecution) { db.execSQL("UPDATE resource_uploads SET execution=? WHERE id=?",arrayOf(Json.encodeToString(value),id)) }
    fun recoverClaims(owner: String) {
        require(UUID.fromString(owner).toString().uppercase()==owner)
        uploads().filter { it.execution.owner!=null && it.execution.owner!=owner }.forEach { putExecution(it.id,it.execution.copy(owner=null,token=null)) }
    }
    fun claim(id: String,owner: String,now: Long): ResourceUploadClaim? {
        require(now in 0..Long.MAX_VALUE-60000)
        val work=uploads().firstOrNull { it.id==id } ?: return null;val prior=work.execution
        if(work.terminal || prior.backgroundPending || prior.attention || prior.userPaused || prior.owner!=null || prior.retryAt>now) return null
        val deadline=prior.deadline ?: now+60000
        if(prior.attempts>=5 || now>=deadline) {
            putExecution(id,prior.copy(attention=true,error=ResourceUploadError.BudgetExhausted));db.execSQL("UPDATE resource_uploads SET stage='Paused' WHERE id=?",arrayOf(id));return null
        }
        val token=UUID.randomUUID().toString().uppercase()
        val charged=prior.copy(owner=owner,token=token,attempts=prior.attempts+1,totalAttempts=Math.addExact(prior.totalAttempts,1),deadline=deadline)
        val recovery=if(work.cancellationRequested) ResourceUploadAction.Cancel else if(work.session==null) ResourceUploadAction.Create else ResourceUploadAction.Status
        putExecution(id,charged.copy(next=recovery,error=prior.error ?: ResourceUploadError.OutcomeUnknown))
        return ResourceUploadClaim(work.copy(execution=charged.copy(next=if(work.cancellationRequested) ResourceUploadAction.Cancel else prior.next)),owner,token)
    }
    internal fun owned(claim: ResourceUploadClaim): ResourceUploadWork {
        val current=uploads().first { it.id==claim.work.id }
        require(current.execution.owner==claim.owner && current.execution.token==claim.token && current.request==claim.work.request && current.asset==claim.work.asset)
        return current
    }
    fun finish(claim: ResourceUploadClaim,session: ResourceUploadSession?,next: ResourceUploadAction,retryAt: Long,poll: Boolean,preserve: Boolean) {
        require(retryAt>=0);val current=owned(claim)
        if(current.cancellationRequested && !claim.work.cancellationRequested) { putExecution(current.id,current.execution.copy(owner=null,token=null));return }
        session?.let { if(claim.work.cancellationRequested) confirmCancel(current.id,it,claim.owner) else save(current.id,it,claim.owner) }
        val server=maxOf(current.execution.serverRetryAt,session?.retryNotBefore ?: 0)
        val value=current.execution.copy(next=next,retryAt=maxOf(server,retryAt),serverRetryAt=server,owner=null,token=null,
            attempts=if(preserve) current.execution.attempts else 0,deadline=if(preserve) current.execution.deadline else null,
            polls=if(poll) Math.addExact(current.execution.polls,1) else current.execution.polls,error=if(preserve) claim.work.execution.error else null)
        putExecution(current.id,value)
    }
    fun fail(claim: ResourceUploadClaim,error: ResourceUploadError,retryAt: Long?,serverRetryAt: Long,cancelled: Boolean,session: ResourceUploadSession?) {
        require(serverRetryAt>=0 && (retryAt==null || retryAt>=0));val current=owned(claim);val prior=current.execution
        if(cancelled || current.cancellationRequested && !claim.work.cancellationRequested) { putExecution(current.id,prior.copy(owner=null,token=null));return }
        val updated=session?.let { save(current.id,it,claim.owner) } ?: current
        if(updated.terminal) { putExecution(current.id,prior.copy(owner=null,token=null));return }
        val server=maxOf(prior.serverRetryAt,serverRetryAt)
        putExecution(current.id,prior.copy(owner=null,token=null,error=error,attention=retryAt==null,retryAt=maxOf(server,retryAt ?: Long.MAX_VALUE),serverRetryAt=server))
        db.execSQL("UPDATE resource_uploads SET stage='Paused' WHERE id=?",arrayOf(current.id))
    }
    fun control(id: String,paused: Boolean,retry: Boolean) {
        val current=uploads().first { it.id==id };if(current.terminal) return
        val value=current.execution
        if(retry) { require(value.owner==null && !value.backgroundPending && (value.attention || value.userPaused));putExecution(id,value.copy(userPaused=paused,backgroundAttempts=0,attempts=0,polls=0,deadline=null,attention=false,error=null,retryAt=value.serverRetryAt,
            next=if(current.cancellationRequested) ResourceUploadAction.Cancel else if(current.session==null) ResourceUploadAction.Create else ResourceUploadAction.Status)) }
        else putExecution(id,value.copy(userPaused=paused))
    }
    fun release(id: String) {
        val job=uploads().first { it.id==id };require(job.terminal && !job.execution.backgroundPending && job.execution.owner==null)
        // A ready source remains retained until its business owner explicitly releases it.
        db.execSQL("UPDATE resource_uploads SET released=1 WHERE id=?",arrayOf(id))
        uploads().filter { it.terminal && it.sourceReleased }.dropLast(500).forEach {
            db.execSQL("DELETE FROM resource_uploads WHERE id=? AND NOT EXISTS(SELECT 1 FROM profile_intents WHERE upload_id=resource_uploads.id) AND NOT EXISTS(SELECT 1 FROM group_avatar_intents WHERE upload_id=resource_uploads.id) AND NOT EXISTS(SELECT 1 FROM send_intent_attachments WHERE upload_id=resource_uploads.id)",arrayOf(it.id))
            db.execSQL("DELETE FROM resource_assets WHERE id=? AND selection=0 AND NOT EXISTS(SELECT 1 FROM resource_uploads WHERE asset=resource_assets.id) AND NOT EXISTS(SELECT 1 FROM resource_source_claims WHERE asset=resource_assets.id)",arrayOf(it.asset))
        }
    }
}
private fun JsonObject.text(key: String) = getValue(key).jsonPrimitive.also { require(it.isString) }.content
private fun JsonObject.long(key: String) = getValue(key).jsonPrimitive.also { require(!it.isString) }.long
private fun Iterable<ResourceLocalFile>.sumCharges() = fold(0L) { total,file -> Math.addExact(total,file.chargedBytes) }
private fun requireCapacity(used: Long,addition: Long,maximum: Long) { check(used<=maximum && addition<=maximum-used) { "资源存储空间额度不足" } }
