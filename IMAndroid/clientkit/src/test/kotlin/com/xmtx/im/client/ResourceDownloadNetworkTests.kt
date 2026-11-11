package com.xmtx.im.client

import kotlin.test.*
import kotlinx.collections.immutable.*

class ResourceDownloadNetworkTests {
    @Test fun `automatic policy is opt in validates bounds and includes animated image content`() {
        val defaults=ResourceAutomaticDownloadPolicy();assertTrue(defaults.categories.isEmpty());assertEquals(10L*1024*1024,defaults.maximumByteCount)
        assertFalse(defaults.allows("image/png",1))
        val images=ResourceAutomaticDownloadPolicy(persistentSetOf(ResourceCategory.Image),100)
        assertTrue(images.allows("image/gif",100));assertFalse(images.allows("image/png",101));assertFalse(images.allows("text/plain",1))
        assertFailsWith<IllegalArgumentException> {ResourceAutomaticDownloadPolicy(persistentSetOf(ResourceCategory.All))}
        assertFailsWith<IllegalArgumentException> {ResourceAutomaticDownloadPolicy(maximumByteCount=0)}
        assertFailsWith<IllegalArgumentException> {ResourceAutomaticDownloadPolicy(maximumByteCount=512L*1024*1024+1)}
    }
    @Test fun `manual defaults allow cellular and expensive but respect constrained networks`() {
        val policy=ResourceDownloadNetworkPreferences().constraints()
        assertTrue(policy.allows(ResourceDownloadNetworkState(true,true,false)))
        assertFalse(policy.allows(ResourceDownloadNetworkState(false,true,true)))
        assertTrue(policy.allows(ResourceDownloadNetworkState(false,false,false)))
        assertTrue(ResourceDownloadNetworkPreferences(allowsConstrained=true).constraints().allows(ResourceDownloadNetworkState(true,true,true)))
    }
    @Test fun `automatic constraints cannot inherit manual cellular expensive or constrained permission`() {
        val constraints=ResourceDownloadNetworkPreferences(true,true).constraints(automatic=true)
        assertEquals(ResourceDownloadNetworkConstraints(false,false,false),constraints)
        assertFalse(constraints.allows(ResourceDownloadNetworkState(false,true,false)))
        assertFalse(constraints.allows(ResourceDownloadNetworkState(true,false,false)))
        assertTrue(constraints.allows(ResourceDownloadNetworkState(false,false,false)))
    }
    @Test fun `disabling cellular rejects unknown underlying transport and intersection cannot widen policy`() {
        val constrained=ResourceDownloadNetworkPreferences(false,false).constraints()
        assertFalse(constrained.allows(ResourceDownloadNetworkState(null,false,false)))
        val open=ResourceDownloadNetworkConstraints(true,true,true)
        assertEquals(constrained,open.intersecting(constrained));assertEquals(constrained,constrained.intersecting(open))
        assertTrue(constrained.allows(ResourceDownloadNetworkState(false,true,false)))
    }
}
