package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.toPersistentList

internal suspend fun SyncStore.testSnapshotProgress(manifest:SnapshotManifest):SnapshotImportProgress {
    var progress=SnapshotImportProgress.initial(manifest)
    while(progress.nextPage<manifest.pageCount) {
        val page=page(progress.nextPage) ?: break
        progress=SnapshotImportValidation.advance(manifest,progress,page).progress
    }
    return progress
}
internal suspend fun SyncStore.testSnapshotItems(manifest:SnapshotManifest):kotlinx.collections.immutable.PersistentList<SnapshotItem> {
    var progress=SnapshotImportProgress.initial(manifest)
    val items=mutableListOf<SnapshotItem>()
    while(progress.nextPage<manifest.pageCount) {
        val imported=SnapshotImportValidation.advance(manifest,progress,requireNotNull(page(progress.nextPage)))
        progress=imported.progress;items+=imported.items
    }
    SnapshotImportValidation.validateComplete(manifest,progress)
    return items.toPersistentList()
}
