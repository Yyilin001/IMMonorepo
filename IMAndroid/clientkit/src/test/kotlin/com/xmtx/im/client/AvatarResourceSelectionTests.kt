package com.xmtx.im.client

import kotlinx.coroutines.test.runTest
import kotlin.test.*

class AvatarResourceSelectionTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val media="CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    private val baseline=ProfileView(actor,PublicIdentity(actor,PublicHandle("resource_owner"),"本人",AccountKind.Regular),null,ProfileState.Active,7,8)
    private val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),media),1,"原图.png","image/png",100,ResourceChecksum("a".repeat(64)),ResourceState.Ready,20,20)
    private val selection=AvatarResourceSelection(descriptor,MessageResourceSource(room,MessageId(actor.value),0,4))
    @Test fun `only ready original JPEG and PNG images from the same room are selectable`() {
        assertTrue(AvatarResourceSelection.eligible(descriptor.copy(contentType="image/jpeg",byteCount=50L*1024*1024)))
        assertFalse(AvatarResourceSelection.eligible(descriptor.copy(byteCount=50L*1024*1024+1)))
        assertFalse(AvatarResourceSelection.eligible(descriptor.copy(contentType="image/gif")))
        assertFalse(AvatarResourceSelection.eligible(descriptor.copy(state=ResourceState.Pending)))
        assertFails { selection.copy(descriptor=descriptor.copy(key=ResourceKey(ResourceHome.Account(actor),media))) }
        assertFails { selection.copy(source=selection.source.copy(room=RoomId(actor.value))) }
        assertEquals(ResourceImportSource.Message(room,selection.source.message,media),selection.importSource)
    }
    @Test fun `submission freezes baseline and creates distinct identities through the atomic store boundary`()=runTest {
        val submitted=mutableListOf<ProfileIntent>();val time=1700000000000L
        val store=object: AvatarResourceSelectionStore {
            override suspend fun selectAvatarResource(key: ResourceKey)=selection.also { assertEquals(selection.key,key) }
            override suspend fun isAvatarResourceCurrent(selection: AvatarResourceSelection)=true
            override suspend fun enqueueSelectedProfileAvatar(intent: ProfileIntent,selection: AvatarResourceSelection,now: Long): ProfileIntent {
                assertEquals(this@AvatarResourceSelectionTests.selection,selection);assertEquals(time,now);submitted.add(intent);return intent
            }
        }
        val service=AvatarResourceSelectionService(actor,store) { time }
        assertEquals(selection,service.select(selection.key));assertTrue(service.isCurrent(selection))
        repeat(2) { service.submit(baseline,selection) }
        val identities=submitted.flatMap { intent ->
            val imported=intent.serverImport!!
            assertEquals(7L,intent.revision);assertEquals(time+86400000,intent.deadline);assertFalse(intent.frozen)
            assertNull(intent.upload);assertEquals(selection.importSource,imported.request.source)
            assertEquals(ResourceUsage.UserAvatar,imported.request.targetUsage)
            listOf(intent.id,intent.operation,imported.id,imported.request.operation,imported.request.targetMedia)
        }
        assertEquals(10,identities.toSet().size);assertFalse(identities.contains(media))
        assertFails { service.submit(baseline.copy(user=UserId(room.value),identity=null,state=ProfileState.Hidden),selection) }
        assertEquals(2,submitted.size)
    }
}
