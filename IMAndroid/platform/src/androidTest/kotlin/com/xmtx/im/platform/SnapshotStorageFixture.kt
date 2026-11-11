package com.xmtx.im.platform

import com.xmtx.im.client.SnapshotItem
import com.xmtx.imclientkit.generated.im.realtime.v2.SnapshotManifest
import kotlinx.collections.immutable.PersistentList

/** Projection-only fixtures explicitly stage their synthetic manifest before local activation.
 * Network ACK/recovery ordering is exercised by SyncEngine and the recovery integration tests.
 */
internal suspend fun SqliteClientStore.activateFixture(manifest: SnapshotManifest,items: PersistentList<SnapshotItem>) {
    stage(manifest);activate(manifest,items)
}
