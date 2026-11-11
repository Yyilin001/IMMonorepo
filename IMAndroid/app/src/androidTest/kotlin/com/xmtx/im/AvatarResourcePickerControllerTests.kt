package com.xmtx.im

import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test

class AvatarResourcePickerControllerTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val baseline=ProfileView(actor,PublicIdentity(actor,PublicHandle("avatar_resource"),"本人",AccountKind.Regular),null,ProfileState.Active,1,1)
    private val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"),1,"聊天图片.png","image/png",100,ResourceChecksum("a".repeat(64)),ResourceState.Ready,20,20)
    private val selected=AvatarResourceSelection(descriptor,MessageResourceSource(room,MessageId(actor.value),0,1))
    private val entry=ResourceCatalogEntry(descriptor,1000,1)
    private val page=ResourceCatalogPage(persistentListOf(entry),null,false)
    private fun authority(deadline: Long=System.nanoTime()+300000000000L)=GroupAvatarEditAuthority(
        GroupAvatarPresentation(actor,DeviceId(actor.value),GroupAvatarState(room,null,3),1,null,true,null,1000,301000,1000,deadline,null),
        GroupAvatarFence("A".repeat(32),3,1,true))
    @Test fun groupSelectionUsesPrivateAuthorityAndExpiresWithoutFallingBackToPersonalProfile()=runBlocking {
        var value=authority();var saved:GroupAvatarEditAuthority?=null;var personal=0
        val controller=AvatarResourcePickerController("group",actor,this,MutableStateFlow(0L),{page},{selected},{true},
            {personal++;baseline},{_,_->personal++;"wrong"},{},targetRoom=room,refreshGroup={value},submitGroup={a,_->saved=a;"group-intent"})
        try {
            controller.foreground(true);until {controller.state.groupBaseline!=null && controller.state.entries.isNotEmpty()}
            assertNull(controller.state.baseline);controller.choose(descriptor.key);until {controller.state.selected!=null}
            value=authority(System.nanoTime()+150000000L);controller.refresh();until {controller.state.groupBaseline!=null}
            until {controller.state.groupBaseline==null};controller.confirm();assertNull(saved)
            value=authority();controller.refresh();until {controller.state.groupBaseline!=null};controller.confirm()
            until {controller.state.submitted!=null};assertEquals(value,saved);assertEquals(0,personal);assertNull(controller.state.groupBaseline)
        } finally {controller.close()}
    }
    @Test fun groupRevocationAndBackgroundDiscardLateAuthorityAndCannotConfirm()=runBlocking {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var reads=0;var saves=0
        val controller=AvatarResourcePickerController("group",actor,this,MutableStateFlow(0L),{page},{selected},{true},{baseline},{_,_->"wrong"},{},
            targetRoom=room,refreshGroup={reads++;if(reads==2) {entered.complete(Unit);withContext(NonCancellable) {release.await()}};authority()},submitGroup={_,_->saves++;"saved"})
        try {
            controller.foreground(true);until {controller.state.groupBaseline!=null && controller.state.entries.isNotEmpty()}
            controller.choose(descriptor.key);until {controller.state.selected!=null};controller.invalidateGroupAuthority();entered.await()
            assertNull(controller.state.groupBaseline);controller.confirm();assertEquals(0,saves)
            controller.foreground(false);release.complete(Unit);delay(100);assertNull(controller.state.groupBaseline);assertNull(controller.state.selected)
            controller.foreground(true);until {controller.state.groupBaseline!=null};controller.close();assertNull(controller.state.groupBaseline)
        } finally {release.complete(Unit);controller.close()}
    }
    private suspend fun until(condition: ()->Boolean) { withTimeout(5000) { while(!condition()) delay(10) } }
    private fun preview(token: String)=MessagePreviewBytes(MessageResourceRead(descriptor,selected.source,token),
        ResourceVariantDescriptor(ResourceVariantKey(descriptor.key,ResourceRendition.Derived(actor.value,1)),ResourceChecksum("b".repeat(64)),1),
        com.google.protobuf.ByteString.copyFromUtf8("a"),System.nanoTime()+60000000000)
    @Test fun onlyVisibleRowsLoadAndUnrelatedStoreChangesDoNotRepeatAuthorization()=runBlocking {
        val changes=MutableStateFlow(0L);var token="A".repeat(32);var fetches=0
        val controller=AvatarResourcePickerController("picker",actor,this,changes,{ page },{ selected },{ true },{ baseline },{ _,_->"saved" },{},
            preview={ fetches++;preview(token) },previewGeneration={ token })
        try {
            controller.foreground(true);until { !controller.state.loading };assertEquals(0,fetches)
            controller.visible(persistentListOf(descriptor.key));until { controller.state.previews.isNotEmpty() };assertEquals(1,fetches)
            changes.value++;delay(100);assertEquals(1,fetches)
            token="B".repeat(32);changes.value++;until { controller.state.previews[descriptor.key]?.read?.generation==token };assertEquals(2,fetches)
            controller.reload();until { !controller.state.loading && controller.state.previews.isNotEmpty() };assertEquals(3,fetches)
            controller.visible(persistentListOf());assertTrue(controller.state.previews.isEmpty())
            controller.visible(persistentListOf(descriptor.key));until { controller.state.previews.isNotEmpty() };assertEquals(4,fetches)
            controller.foreground(false);assertTrue(controller.state.previews.isEmpty())
        } finally { controller.close() }
    }
    @Test fun oldPreviewCannotReturnAfterScrollingOffscreenOrChangingAuthorizationGeneration()=runBlocking {
        val changes=MutableStateFlow(0L);var token="A".repeat(32);val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var fetches=0
        val controller=AvatarResourcePickerController("picker",actor,this,changes,{ page },{ selected },{ true },{ baseline },{ _,_->"saved" },{},
            preview={ val value=preview(token);fetches++;if(fetches==1) { entered.complete(Unit);withContext(NonCancellable) { release.await() } };value },previewGeneration={ token })
        try {
            controller.foreground(true);until { !controller.state.loading };controller.visible(persistentListOf(descriptor.key));entered.await()
            controller.visible(persistentListOf());token="B".repeat(32);changes.value++;delay(50);controller.visible(persistentListOf(descriptor.key))
            until { controller.state.previews[descriptor.key]?.read?.generation==token };release.complete(Unit);delay(100)
            assertEquals(token,controller.state.previews[descriptor.key]!!.read.generation)
            controller.close();assertTrue(controller.state.previews.isEmpty())
        } finally { release.complete(Unit);controller.close() }
    }
    @Test fun filteringPaginationAndRevocationFollowCurrentDirectoryGeneration()=runBlocking {
        val changes=MutableStateFlow(0L);val queries=mutableListOf<ResourceCatalogQuery>();var valid=true
        val next=ResourceCatalogCursor(1000,descriptor.key)
        val controller=AvatarResourcePickerController("picker",actor,this,changes,{ query ->
            queries.add(query);page.copy(entries=page.entries.add(entry.copy(descriptor=descriptor.copy(contentType="image/gif"))),nextCursor=if(query.before==null) next else null)
        },{ selected },{ valid },{ baseline },{ _,_->"saved" },{})
        try {
            controller.foreground(true);until { !controller.state.loading && controller.state.entries.isNotEmpty() }
            assertEquals(1,controller.state.entries.size);assertEquals(ResourceCategory.Image,queries.last().category)
            controller.next();until { !controller.state.loading };assertEquals(next,queries.last().before);assertEquals(2,controller.state.pageNumber)
            controller.previous();until { !controller.state.loading };assertNull(queries.last().before)
            controller.search("图片");until { !controller.state.loading };assertEquals("图片",queries.last().search);assertEquals(1,controller.state.pageNumber)
            controller.search("界".repeat(86));assertEquals("图片",controller.state.search)
            controller.choose(descriptor.key);until { controller.state.selected!=null }
            valid=false;changes.value++;until { controller.state.selected==null }
            assertTrue(controller.state.feedback!!.contains("来源已变化"))
        } finally { controller.close() }
    }
    @Test fun lateSearchAndSelectionCannotRestoreBackgroundedPage()=runBlocking {
        val changes=MutableStateFlow(0L);val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var calls=0
        val controller=AvatarResourcePickerController("picker",actor,this,changes,{ query ->
            if(query.search=="旧搜索") { entered.complete(Unit);withContext(NonCancellable) { release.await() } };page
        },{ selected },{ true },{ baseline },{ _,_->"saved" },{ calls++ })
        try {
            controller.foreground(true);until { controller.state.entries.isNotEmpty() }
            controller.search("旧搜索");entered.await();controller.search("新搜索");until { !controller.state.loading }
            release.complete(Unit);delay(50);assertEquals("新搜索",controller.state.search);assertFalse(controller.state.loading)
            controller.foreground(false);assertTrue(controller.state.entries.isEmpty());assertNull(controller.state.baseline)
            val count=calls;changes.value++;delay(50);assertEquals(count,calls)
            controller.foreground(true);until { controller.state.baseline!=null && controller.state.entries.isNotEmpty() }
            controller.close();val closed=calls;changes.value++;delay(50);assertEquals(closed,calls)
        } finally { release.complete(Unit);controller.close() }
    }
    @Test fun cancelledSelectionAndProfileRefreshCannotOverwriteNewForegroundState()=runBlocking {
        val chooseEntered=CompletableDeferred<Unit>();val chooseRelease=CompletableDeferred<Unit>()
        val refreshEntered=CompletableDeferred<Unit>();val refreshRelease=CompletableDeferred<Unit>();var reads=0
        val controller=AvatarResourcePickerController("picker",actor,this,MutableStateFlow(0L),{ page },{
            chooseEntered.complete(Unit);withContext(NonCancellable) { chooseRelease.await() };selected
        },{ true },{
            reads++;if(reads==1) { refreshEntered.complete(Unit);withContext(NonCancellable) { refreshRelease.await() };baseline } else baseline.copy(revision=2)
        },{ _,_->error("must not submit") },{})
        try {
            controller.foreground(true);refreshEntered.await();until { controller.state.entries.isNotEmpty() }
            controller.choose(descriptor.key);chooseEntered.await();controller.foreground(false);controller.foreground(true)
            until { controller.state.baseline?.revision==2L && !controller.state.loadingProfile }
            refreshRelease.complete(Unit);chooseRelease.complete(Unit);delay(100)
            assertEquals(2L,controller.state.baseline!!.revision);assertNull(controller.state.selected);assertFalse(controller.state.selecting);assertFalse(controller.state.loadingProfile)
        } finally { refreshRelease.complete(Unit);chooseRelease.complete(Unit);controller.close() }
    }
    @Test fun confirmationIsExplicitFreezesSelectionAndRejectsDuplicateTaps()=runBlocking {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var submissions=0
        val controller=AvatarResourcePickerController("picker",actor,this,MutableStateFlow(0L),{ page },{ selected },{ true },{ baseline },{ profile,source ->
            assertEquals(baseline,profile);assertEquals(selected,source);submissions++;entered.complete(Unit);release.await();"saved-intent"
        },{})
        try {
            controller.foreground(true);until { controller.state.entries.isNotEmpty() && controller.state.baseline!=null }
            controller.confirm();assertEquals(0,submissions)
            controller.choose(descriptor.key);until { controller.state.selected!=null && !controller.state.selecting };assertEquals(0,submissions)
            controller.confirm();entered.await();controller.confirm();controller.dismiss();controller.next();controller.search("不能更换")
            assertEquals(selected,controller.state.selected);assertEquals("",controller.state.search)
            release.complete(Unit);until { controller.state.submitted!=null && !controller.state.submitting }
            assertEquals(1,submissions);assertEquals("saved-intent",controller.state.submitted);assertNull(controller.state.selected);assertNull(controller.state.baseline)
        } finally { release.complete(Unit);controller.close() }
    }
    @Test fun failedAdmissionRequiresFreshProfileAndSelectionWithoutAutomaticReplay()=runBlocking {
        var submissions=0
        val controller=AvatarResourcePickerController("picker",actor,this,MutableStateFlow(0L),{ page },{ selected },{ true },{ baseline },{ _,_->submissions++;throw ResourceCatalogConflict() },{})
        try {
            controller.foreground(true);until { controller.state.entries.isNotEmpty() && controller.state.baseline!=null }
            controller.choose(descriptor.key);until { controller.state.selected!=null && !controller.state.selecting };controller.confirm()
            until { controller.state.feedback!=null && !controller.state.submitting }
            assertNull(controller.state.selected);assertNull(controller.state.baseline);controller.confirm();assertEquals(1,submissions)
        } finally { controller.close() }
    }
    @Test fun closingDuringAdmissionDropsLatePresentationButDoesNotUndoDurableCommit()=runBlocking {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var committed=false;var publications=0
        val controller=AvatarResourcePickerController("picker",actor,this,MutableStateFlow(0L),{ page },{ selected },{ true },{ baseline },{ _,_->
            entered.complete(Unit);withContext(NonCancellable) { release.await();committed=true };"saved"
        },{ publications++ })
        try {
            controller.foreground(true);until { controller.state.entries.isNotEmpty() && controller.state.baseline!=null }
            controller.choose(descriptor.key);until { controller.state.selected!=null && !controller.state.selecting };controller.confirm();entered.await()
            controller.close();val count=publications;release.complete(Unit);delay(100)
            assertTrue(committed);assertEquals(count,publications);assertNull(controller.state.submitted)
        } finally { release.complete(Unit);controller.close() }
    }
}
