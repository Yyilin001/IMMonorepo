package com.xmtx.im.client

import kotlin.test.*

class ServerTimeAnchorTests {
    @Test fun `monotonic estimate expires after one hour and reset removes authority`() {
        var clock = 100L
        val anchor = ServerTimeAnchor { clock }
        assertEquals(ServerTimeAnchor.Reason.Unavailable, assertFailsWith<ServerTimeAnchor.Failure> { anchor.now() }.reason)
        anchor.observe(1_000_000)
        clock += 1_234_999_999
        assertEquals(1_001_234, anchor.now())
        assertEquals(4_600_000, anchor.now(100 + 3_600_000_000_000))
        assertFailsWith<ServerTimeAnchor.Failure> { anchor.now(100 + 3_600_000_000_001) }
        assertFailsWith<ServerTimeAnchor.Failure> { anchor.now(99) }
        anchor.observe(2_000_000)
        assertEquals(2_000_000, anchor.now())
        anchor.reset()
        assertFailsWith<ServerTimeAnchor.Failure> { anchor.now() }
    }

    @Test fun `invalid sample cannot replace trusted time and overflow fails closed`() {
        val anchor = ServerTimeAnchor { 0 }
        anchor.observe(1000)
        for (invalid in listOf(0L, -1, Long.MIN_VALUE)) {
            assertEquals(ServerTimeAnchor.Reason.InvalidSample, assertFailsWith<ServerTimeAnchor.Failure> { anchor.observe(invalid) }.reason)
            assertEquals(1000, anchor.now())
        }
        anchor.observe(Long.MAX_VALUE)
        assertEquals(ServerTimeAnchor.Reason.InvalidSample, assertFailsWith<ServerTimeAnchor.Failure> { anchor.now(1_000_000) }.reason)
    }

    @Test fun `elapsed subtraction supports nanoTime wrap and anchors are independent`() {
        val first = ServerTimeAnchor { Long.MAX_VALUE - 10 }
        val second = ServerTimeAnchor { 0 }
        first.observe(1000)
        assertEquals(1001, first.now(Long.MIN_VALUE + 1_000_000))
        assertFailsWith<ServerTimeAnchor.Failure> { second.now() }
    }
}
