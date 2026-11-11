package com.xmtx.im

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import com.xmtx.im.client.*
import kotlinx.coroutines.flow.first

/** Saved state is a local row identity/time and pixel offset, never a name, lease or database cursor. */
@Stable internal class ContactListPosition(initial:RelationshipViewport?=null) {
    var viewport by mutableStateOf(initial)
    companion object {
        val Saver=listSaver<ContactListPosition,Any>(save={listOf(it.viewport?.anchor?.target?.value.orEmpty(),it.viewport?.anchor?.updatedAt ?: 0L,it.viewport?.offset ?: 0)},
            restore={ContactListPosition((it[0] as String).takeIf(String::isNotEmpty)?.let {id->RelationshipViewport(RelationshipAnchor(UserId(id),it[1] as Long),it[2] as Int)})})
    }
}

@Composable internal fun rememberContactListPosition(session:SessionUi.SignedIn,query:String,list:LazyListState,
    page:RelationshipPageSession?,value:RelationshipPageState,active:Boolean,headerCount:Int=3):ContactListPosition {
    val position=rememberSaveable(session.user,session.databaseIdentity,query,saver=ContactListPosition.Saver) {ContactListPosition()}
    var consumed by remember(page) {mutableStateOf<Long?>(null)}
    val current by rememberUpdatedState(value);val enabled by rememberUpdatedState(active)
    LaunchedEffect(page,list,position,headerCount) {
        snapshotFlow {Triple(list.firstVisibleItemIndex,list.firstVisibleItemScrollOffset,list.isScrollInProgress) to (current.navigation?.revision to consumed)}.collect {(sample,progress)->
            val navigation=progress.first
            if(!enabled || navigation==null || consumed!=navigation || current.page.relationships.isEmpty()) return@collect
            val row=if(sample.first<headerCount) null else list.layoutInfo.visibleItemsInfo.firstOrNull {it.index==sample.first}?.key?.let {key->current.page.relationships.firstOrNull {it.target.value==key}}
            if(sample.first>=headerCount && row==null) return@collect
            position.viewport=row?.let {RelationshipViewport(RelationshipAnchor(it.target,it.updatedAt),sample.second)}
            page?.observeViewport(row?.target,sample.second,sample.third)
        }
    }
    LaunchedEffect(page,value.navigation,active,headerCount) {
        if(!active) return@LaunchedEffect
        val navigation=value.navigation ?: return@LaunchedEffect
        if(consumed==navigation.revision) return@LaunchedEffect
        val rows=value.page.relationships
        if(rows.isNotEmpty()) {
            snapshotFlow {list.layoutInfo.totalItemsCount}.first {it==rows.size+headerCount}
            val index=navigation.target?.let {id->rows.indexOfFirst {it.target==id}}?.takeIf {it>=0}
            list.scrollToItem(index?.plus(headerCount) ?: 0,if(index!=null) navigation.offset else 0)
        } else position.viewport=null
        consumed=navigation.revision
    }
    return position
}
