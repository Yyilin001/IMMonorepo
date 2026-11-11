package com.xmtx.im.client

import kotlinx.serialization.json.Json
import kotlin.test.*

class ResourceBackgroundJournalContractTests {
    @Test fun `provider retry floors retain delays and saturate without overflow`() {
        assertNull(resourceBackgroundRetryNotBefore(null,1000))
        assertEquals(18000L,resourceBackgroundRetryNotBefore("17",1000))
        assertEquals(86401000L,resourceBackgroundRetryNotBefore("invalid",1000))
        assertEquals(Long.MAX_VALUE,resourceBackgroundRetryNotBefore("17",Long.MAX_VALUE-10))
    }
    @Test fun `legacy execution payloads retain foreground defaults`() {
        val old=Json.decodeFromString<ResourceUploadExecution>("""{"next":"Status","retryAt":125,"serverRetryAt":100}""")
        assertFalse(old.backgroundPending);assertEquals(0,old.backgroundAttempts)
        assertEquals(125L,old.retryAt);assertEquals(100L,old.serverRetryAt)
    }
    @Test fun `origin identity ignores signed path and query but binds scheme host and port`() {
        val origin=resourceBackgroundOriginDigest("https://EXAMPLE.test:443/private?token=secret")
        assertEquals(origin,resourceBackgroundOriginDigest("https://example.test/another?token=different"))
        assertNotEquals(origin,resourceBackgroundOriginDigest("https://example.test:8443/private"))
        assertNotEquals(origin,resourceBackgroundOriginDigest("https://other.test/private"))
        for(url in listOf("http://example.test/","https://@example.test/","https://user:secret@example.test/","https://example.test/#secret","private-secret-invalid")) {
            val error=assertFailsWith<IllegalArgumentException> {resourceBackgroundOriginDigest(url)}
            assertFalse(error.toString().contains("secret"));assertNull(error.cause)
        }
    }
}
