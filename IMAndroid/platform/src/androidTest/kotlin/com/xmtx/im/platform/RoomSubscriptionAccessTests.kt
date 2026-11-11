package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class RoomSubscriptionAccessTests {
    @Test fun localRevocationQueryTracksCommittedDenialAndAuthorizedRecoveryAcrossRestart() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor = UserId(UUID.randomUUID().toString()); val device = DeviceId(UUID.randomUUID().toString()); val room = RoomId(UUID.randomUUID().toString())
        val file = accountDatabaseFile(context, actor, device); var store = SqliteClientStore(context, actor, device)
        try {
            assertFalse(store.isRoomLocallyRevoked(room)) // Absence is not positive subscription authority.
            store.unavailable(room); assertTrue(store.isRoomLocallyRevoked(room))
            store.close(); store = SqliteClientStore(context, actor, device); assertTrue(store.isRoomLocallyRevoked(room))
            store.acceptState(room, RoomSyncState.newBuilder().setOwnerEpoch(1).setViewerMembershipRevision(1).setHead(3).setUnreadCount(3).build())
            assertFalse(store.isRoomLocallyRevoked(room)); assertEquals(0, store.roomCursor(room).sequence)
        } finally { store.close(); SQLiteDatabase.deleteDatabase(file) }
    }
}
