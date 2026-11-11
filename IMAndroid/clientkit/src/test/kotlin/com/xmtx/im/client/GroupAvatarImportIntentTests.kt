package com.xmtx.im.client

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.util.UUID
import kotlin.test.*

class GroupAvatarImportIntentTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id());private val room=RoomId(id())
    private val source=GroupAvatarImportPreparation(id(),ResourceImportRequest(id(),ResourceImportSource.Message(room,MessageId(id()),id()),ResourceUsage.GroupAvatar(room),id()))
    private val command=GroupAvatarCommand(id(),room,0,GroupAvatarMutation.Set(source.request.targetMedia))
    @Test fun importedIntentRoundTripsFrozenSourceAndRetainsOwnershipByDefault() {
        val intent=GroupAvatarIntent(actor,device,command,100,serverImport=source)
        assertFalse(intent.sourceReleased);assertNull(intent.upload);assertNull(intent.asset)
        assertEquals(intent,Json.decodeFromString<GroupAvatarIntent>(Json.encodeToString(intent)))
        assertEquals(source,intent.copy(stage=GroupAvatarStage.NeedsAttention).serverImport)
    }
    @Test fun uploadImportRemoveAndTargetIdentitiesCannotBeMixed() {
        assertFailsWith<IllegalArgumentException> {GroupAvatarIntent(actor,device,command,100,upload=id(),asset=id(),serverImport=source)}
        assertFailsWith<IllegalArgumentException> {GroupAvatarIntent(actor,device,command.copy(mutation=GroupAvatarMutation.Remove),100,serverImport=source)}
        assertFailsWith<IllegalArgumentException> {GroupAvatarIntent(actor,device,command.copy(room=RoomId(id())),100,serverImport=source)}
        assertFailsWith<IllegalArgumentException> {GroupAvatarIntent(actor,device,command.copy(mutation=GroupAvatarMutation.Set(id())),100,serverImport=source)}
        assertFailsWith<IllegalArgumentException> {GroupAvatarImportPreparation(id(),source.request.copy(targetUsage=ResourceUsage.UserAvatar))}
    }
    @Test fun existingUploadAndRemovalPayloadsKeepTheirOriginalOwnershipDefaults() {
        for(intent in listOf(GroupAvatarIntent(actor,device,command,100,id(),id()),GroupAvatarIntent(actor,device,command.copy(mutation=GroupAvatarMutation.Remove),100))) {
            val legacy=JsonObject(Json.encodeToJsonElement(intent).jsonObject.filterKeys {it!="serverImport"})
            assertEquals(intent,Json.decodeFromJsonElement<GroupAvatarIntent>(legacy));assertNull(intent.serverImport)
            assertEquals(intent.upload==null,intent.sourceReleased)
        }
    }
}
