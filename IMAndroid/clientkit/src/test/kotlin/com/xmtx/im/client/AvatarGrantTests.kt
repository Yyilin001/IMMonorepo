package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.security.MessageDigest
import kotlin.test.*

internal class AvatarFixture {
    val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");val target=UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    val device=DeviceId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC");val key=ProfileKey(target,ProfileContext.Relationship)
    val media="EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE";val variant="FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
    val bytes="verified avatar bytes".toByteArray();var clock=100L
    val content=AvatarContent(media,variant,1,ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }),bytes.size.toLong())
    fun access(url: String="https://localhost/avatar?signature=private-object-secret")=AvatarAccess(content,ResourceTransferPlan(ResourceTransferMode.Get,url,
        persistentListOf(ResourceTransferHeader("Authorization","Object private-capability",ResourceHeaderKind.ObjectCapability)),persistentMapOf(),null,1700000060000,bytes.size.toLong(),null,null,content.checksum))
    fun available(access: AvatarAccess=access(),deadline: Long=300_000_000_100,download: Long?=60_000_000_100)=ProfileReadResult.Available(
        AuthorizedProfile(ProfileView(target,PublicIdentity(target,PublicHandle("friend_b"),"好友 B",AccountKind.Regular),media,ProfileState.Active,3,5),
            ProfileLease(actor,device,key,3,5,0,ProfileAuthority(7,null,0,0),1700000000000,1700000300000)),deadline,access,download)
    suspend fun scope(value: ProfileReadResult.Available=available()): ProfilePresentationScope {
        val scope=ProfilePresentationScope(actor,device,{ persistentListOf(value) },{clock});scope.interests(persistentListOf(key));scope.refresh();return scope
    }
    fun wire(): JsonObject {
        val original=javaClass.getResourceAsStream("/profile-presentations-swift.txt")!!.bufferedReader().readLines()[1]
        val response=Json.parseToJsonElement(original).jsonObject;val old=response["results"]!!.jsonArray.first().jsonObject.objectValue("presentation").objectValue("_0")
        val view=JsonObject(old.objectValue("view")+("avatar" to buildJsonObject { put("mediaID",wireId(media)) }))
        val background=buildJsonObject { put("id",variant);put("expectedByteCount",content.byteCount);put("checksum",content.checksum.payload());put("issuedAtMilliseconds",1700000000000);put("expiresAtMilliseconds",1700000060000) }
        val plan=buildJsonObject { put("version",1);put("mode","http_get");put("url","https://localhost/avatar?signature=private-object-secret");put("headers",JsonArray(emptyList()));put("formFields",buildJsonObject {});put("expiresAtUnixMilliseconds",1700000060000);put("expectedByteCount",content.byteCount);put("checksum",content.checksum.payload());put("backgroundDownloadAuthorization",background) }
        val avatar=buildJsonObject { put("mediaID",wireId(media));put("variantID",wireId(variant));put("version",1);put("checksum",content.checksum.payload());put("byteCount",content.byteCount);put("plan",plan) }
        val entry=buildJsonObject { put("presentation",buildJsonObject { put("_0",JsonObject(old+("view" to view)));put("avatar",avatar) }) }
        return JsonObject(response+("results" to JsonArray(listOf(entry))))
    }
}

class AvatarGrantTests {
    @Test fun `optional background GET grant binds exact bytes expiry and noncredential headers`() {
        val f=AvatarFixture();val grant=ResourceBackgroundDownloadAuthorization(f.variant,f.content.byteCount,f.content.checksum,1700000000000,1700000060000)
        val plan=f.access().plan!!.copy(headers=persistentListOf(),backgroundDownload=grant)
        assertFails { plan.copy(expectedBytes=plan.expectedBytes+1) };assertFails { plan.copy(expiresAt=plan.expiresAt+1) }
        assertFails { plan.copy(mode=ResourceTransferMode.Put) };assertFails { plan.copy(headers=f.access().plan!!.headers) }
        assertFails { grant.copy(issuedAt=grant.expiresAt) };assertFails { grant.copy(expiresAt=grant.issuedAt+900001) }
    }
    @Test fun `avatar response binds content and maps independent download and display deadlines`() {
        val f=AvatarFixture();fun decode(body: JsonObject=f.wire(),received: Long=100)=ProfilePresentationClient.decode(persistentListOf(f.key),body,f.actor,f.device,100,received).single() as ProfileReadResult.Available
        val value=decode();assertEquals(f.content,value.avatar!!.content);assertEquals(59_000_000_100,value.avatarDownloadDeadlineNanos);assertEquals(299_000_000_100,value.deadlineNanos)
        val late=decode(received=59_000_000_100);assertNull(late.avatar!!.plan);assertNull(late.avatarDownloadDeadlineNanos);assertTrue(late.valid(59_000_000_100))
        for((old,new) in listOf("\"http_get\"" to "\"http_put\"","\"byteCount\":21" to "\"byteCount\":22","1700000060000" to "1700000400000","1700000060000" to "1700000001000")) {
            val raw=f.wire().toString();assertTrue(raw.contains(old));assertFails { decode(Json.parseToJsonElement(raw.replace(old,new)).jsonObject) }
        }
        val body=f.wire();val envelope=body["results"]!!.jsonArray.single().jsonObject.objectValue("presentation")
        val wrong=JsonObject(envelope.objectValue("avatar")+("mediaID" to wireId(f.variant)))
        assertFails { decode(JsonObject(body+("results" to buildJsonArray { add(buildJsonObject { put("presentation",JsonObject(envelope+("avatar" to wrong))) }) }))) }
    }
    @Test fun `grants require live interests and invalidation and have immutable deadlines`()=runTest {
        val f=AvatarFixture();val scope=f.scope();val grant=assertNotNull(scope.avatarReadGrant(f.key));grant.requireValid()
        f.clock=60_000_000_100;grant.requireValid();assertFailsWith<AvatarTargetExpired> { grant.downloadTarget() }
        f.clock=300_000_000_100;assertFailsWith<AvatarAccessFailure> { grant.requireValid() }
        f.clock=100;scope.refresh();val next=scope.avatarReadGrant(f.key)!!;scope.invalidate(f.key);assertFailsWith<AvatarAccessFailure> { next.requireValid() }
        scope.refresh();val removed=scope.avatarReadGrant(f.key)!!;scope.interests(persistentListOf());assertFailsWith<AvatarAccessFailure> { removed.requireValid() }
        scope.interests(persistentListOf(f.key));scope.refresh();val closed=scope.avatarReadGrant(f.key)!!;scope.close();assertFailsWith<AvatarAccessFailure> { closed.requireValid() }
    }
    @Test fun `renewal never extends old pixels and changed content revokes old grant`()=runTest {
        val f=AvatarFixture();var current=f.available(deadline=80_000_000_100)
        val scope=ProfilePresentationScope(f.actor,f.device,{persistentListOf(current)},{f.clock});scope.interests(persistentListOf(f.key));scope.refresh()
        val first=scope.avatarReadGrant(f.key)!!;current=f.available();scope.refresh();first.requireValid()
        f.clock=80_000_000_100;assertFailsWith<AvatarAccessFailure> { first.requireValid() };scope.avatarReadGrant(f.key)!!.requireValid()
        f.clock=100;val second=scope.avatarReadGrant(f.key)!!;current=f.available(f.access().copy(content=f.content.copy(version=2)));scope.refresh()
        assertFailsWith<AvatarAccessFailure> { second.requireValid() };assertEquals(2,scope.avatarReadGrant(f.key)!!.content.version)
        current=f.available();scope.refresh();assertEquals(2,scope.avatarReadGrant(f.key)!!.content.version)
        scope.close()
    }
    @Test fun `additional page authority is checked both before and after validation`()=runTest {
        val f=AvatarFixture();val scope=f.scope();val grant=scope.avatarReadGrant(f.key) { scope.close();true }!!
        assertFailsWith<AvatarAccessFailure> { grant.requireValid() }
        val another=f.scope();val denied=another.avatarReadGrant(f.key) { false }!!;assertFailsWith<AvatarAccessFailure> { denied.requireValid() };another.close()
    }
}
