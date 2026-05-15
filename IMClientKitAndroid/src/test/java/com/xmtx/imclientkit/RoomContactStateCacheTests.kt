package com.xmtx.imclientkit

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.features.contacts.ContactRequestResponseBody
import com.xmtx.imclientkit.features.contacts.ContactRequestStatus
import com.xmtx.imclientkit.features.contacts.ContactResponseBody
import com.xmtx.imclientkit.features.contacts.ContactState
import com.xmtx.imclientkit.persistence.imcache.IMCacheDatabase
import com.xmtx.imclientkit.persistence.imcache.RoomContactStateCache
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class RoomContactStateCacheTests {
    private lateinit var database: IMCacheDatabase
    private lateinit var cache: RoomContactStateCache

    @Before
    fun setUp() {
        database = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            IMCacheDatabase::class.java,
        ).allowMainThreadQueries().build()
        cache = RoomContactStateCache.create(database)
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun savesAndRestoresContactSnapshot() = runTest {
        cache.saveSnapshot(
            "user-1",
            ContactState(
                contacts = listOf(contact("user-2")),
                incomingRequests = listOf(request("request-1", requesterID = "user-2", addresseeID = "user-1")),
            ),
        )

        val restored = cache.loadSnapshot("user-1")

        assertEquals("user-2", restored?.contacts?.first()?.id)
        assertEquals("request-1", restored?.incomingRequests?.first()?.id)
    }

    @Test
    fun clearRemovesOnlyRequestedUser() = runTest {
        cache.saveSnapshot("user-1", ContactState(contacts = listOf(contact("user-2"))))
        cache.saveSnapshot("user-3", ContactState(contacts = listOf(contact("user-4"))))

        cache.clear("user-1")

        assertNull(cache.loadSnapshot("user-1"))
        assertEquals("user-4", cache.loadSnapshot("user-3")?.contacts?.first()?.id)
    }

    private fun contact(id: String) = ContactResponseBody(
        id = id,
        email = "$id@example.com",
        displayName = id,
        remark = null,
    )

    private fun request(
        id: String,
        requesterID: String,
        addresseeID: String,
    ) = ContactRequestResponseBody(
        id = id,
        requester = AuthUser(requesterID, "$requesterID@example.com"),
        addressee = AuthUser(addresseeID, "$addresseeID@example.com"),
        status = ContactRequestStatus.pending,
        message = "hi",
        requesterRemark = null,
        addresseeRemark = null,
        createdAt = "2026-05-16T00:00:00Z",
    )
}
