package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.net.URI
import java.util.Locale

enum class ResourceHeaderKind { Content, ObjectCapability }
/** Optional permission for an OS-owned GET; parsing it does not start or persist a background transfer. */
data class ResourceBackgroundDownloadAuthorization(val id: String,val expectedBytes: Long,val checksum: ResourceChecksum,val issuedAt: Long,val expiresAt: Long) {
    init { require(uuidId(id)==id && expectedBytes in 1..512L*1024*1024 && issuedAt>0 && expiresAt>issuedAt && expiresAt-issuedAt<=900_000) }
    fun payload()=buildJsonObject {
        put("id",id);put("expectedByteCount",expectedBytes);put("checksum",checksum.payload())
        put("issuedAtMilliseconds",issuedAt);put("expiresAtMilliseconds",expiresAt)
    }
    companion object { fun decode(value: JsonObject)=ResourceBackgroundDownloadAuthorization(uuidId(value.resourceString("id")),value.resourceNumber("expectedByteCount"),
        ResourceChecksum.decode(value.resourceObject("checksum")),value.resourceNumber("issuedAtMilliseconds"),value.resourceNumber("expiresAtMilliseconds")) }
}
data class ResourceTransferHeader(val name: String,val value: String,val kind: ResourceHeaderKind) {
    init {
        val canonical = name.lowercase(Locale.ROOT)
        require(name.toByteArray().size in 1..128 && name.matches(Regex("[A-Za-z0-9!#\u0024%&'*+.^_`|~\\-]+")))
        require(value.toByteArray().size <= 8192 && value.codePoints().allMatch { it >= 32 && it != 127 })
        require(canonical !in setOf("host","cookie","set-cookie","connection","proxy-connection","proxy-authorization","proxy-authenticate","transfer-encoding","content-length","range","te","trailer","upgrade","keep-alive","expect","referer","origin"))
        require(!canonical.startsWith("sec-") && !canonical.startsWith("proxy-") && !canonical.startsWith("x-forwarded-"))
        require(canonical != "authorization" || kind == ResourceHeaderKind.ObjectCapability)
    }
    override fun toString() = "ResourceTransferHeader(name=$name, value=<redacted>)"
}
/** Authenticated, short-lived memory-only target. Never serialize into journals, saved state, or diagnostics. */
data class ResourceTransferPlan(val mode: ResourceTransferMode,val url: String,val headers: PersistentList<ResourceTransferHeader>,
    val formFields: PersistentMap<String,String>,val formFileField: String?,val expiresAt: Long,val expectedBytes: Long,val range: ResourceRange?,val part: Int?,val checksum: ResourceChecksum?,
    val backgroundDownload: ResourceBackgroundDownloadAuthorization?=null,val backgroundUpload:ResourceBackgroundUploadAuthorization?=null) {
    init {
        val (parsed,strict) = try { url.toHttpUrl() to URI(url) } catch(_: Exception) { throw IllegalArgumentException("资源传输地址无效") }
        require(parsed.isHttps && parsed.username.isEmpty() && parsed.password.isEmpty() && parsed.fragment == null && strict.rawUserInfo == null && strict.rawFragment == null)
        require(url.toByteArray().size <= 8192 && expectedBytes >= 0 && headers.size <= 32 && headers.map { it.name.lowercase(Locale.ROOT) }.distinct().size == headers.size)
        require(headers.sumOf { it.name.toByteArray().size+it.value.toByteArray().size } <= 16384)
        require(formFields.size <= 32 && formFields.all { (k,v) -> formName(k) && v.toByteArray().size <= 8192 && v.codePoints().allMatch { it >= 32 && it != 127 } })
        require(formFields.entries.sumOf { it.key.toByteArray().size+it.value.toByteArray().size } <= 16384)
        when(mode) {
            ResourceTransferMode.Put,ResourceTransferMode.Get -> require(range == null && part == null && formFields.isEmpty() && formFileField == null)
            ResourceTransferMode.FormPost -> require(formFileField != null && formName(formFileField) && formFileField !in formFields && range == null && part == null && headers.none { it.name.equals("content-type",true) })
            ResourceTransferMode.PartPut -> require(range != null && part in 1..10000 && expectedBytes == range.byteCount && formFields.isEmpty() && formFileField == null)
            ResourceTransferMode.RangeGet -> require(range != null && expectedBytes == range.byteCount && part == null && formFields.isEmpty() && formFileField == null)
        }
        backgroundUpload?.let {grant->
            require(backgroundDownload==null && expiresAt==grant.expiresAt && headers.all {it.kind==ResourceHeaderKind.Content && !it.name.equals("authorization",true)})
            when(val scope=grant.scope) {
                is ResourceBackgroundUploadScope.Part->require(mode==ResourceTransferMode.PartPut && part==scope.number && expectedBytes in 1..8L*1024*1024)
                is ResourceBackgroundUploadScope.Whole->require(mode==ResourceTransferMode.Put && expectedBytes==scope.byteCount && checksum==scope.checksum)
            }
        }
        backgroundDownload?.let { require(mode==ResourceTransferMode.Get && expiresAt==it.expiresAt && expectedBytes==it.expectedBytes && checksum==it.checksum &&
            headers.all { header -> header.kind==ResourceHeaderKind.Content && !header.name.equals("authorization",true) }) }
    }
    override fun toString() = "ResourceTransferPlan(mode=$mode, expectedBytes=$expectedBytes, target=<redacted>)"
    companion object {
        private fun formName(value: String) = value.toByteArray().size in 1..128 && value.matches(Regex("[A-Za-z0-9_.\\-]+"))
        fun decode(value: JsonObject): ResourceTransferPlan {
            require(value.resourceNumber("version") == 1L)
            require(value["backgroundDownloadAuthorization"] in listOf(null,JsonNull) || value.resourceString("mode")==ResourceTransferMode.Get.wire)
            val headers = value.resourceArray("headers").also { require(it.size <= 32) }.map { raw -> val fields = raw.jsonObject
                ResourceTransferHeader(fields.resourceString("name"),fields.resourceString("value"),when(fields.resourceString("kind")) {
                    "content" -> ResourceHeaderKind.Content;"object_capability" -> ResourceHeaderKind.ObjectCapability;else -> throw ClientFailure.Protocol()
                })
            }.toPersistentList()
            val form = value.resourceObject("formFields").also { require(it.size <= 32) }.mapValues { it.value.resourceText() }.toPersistentMap()
            return ResourceTransferPlan(ResourceTransferMode.decode(value.resourceString("mode")),value.resourceString("url"),headers,form,value.resourceOptionalString("formFileField"),value.resourceNumber("expiresAtUnixMilliseconds"),
                value.resourceNumber("expectedByteCount"),value.resourceOptionalObject("byteRange")?.let { ResourceRange(it.resourceNumber("lowerBound"),it.resourceNumber("upperBound")) },value.resourceOptionalNumber("partNumber")?.let(Math::toIntExact),value.resourceOptionalObject("checksum")?.let(ResourceChecksum::decode),
                value.resourceOptionalObject("backgroundDownloadAuthorization")?.let(ResourceBackgroundDownloadAuthorization::decode),
                value.resourceOptionalObject("backgroundAuthorization")?.let(ResourceBackgroundUploadAuthorization::decode))
        }
    }
}
