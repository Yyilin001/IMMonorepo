package com.xmtx.im.client

import kotlin.test.*

class InvitationDeepLinkTests {
    private val secret = InvitationSecret("A".repeat(43))
    @Test fun generatedIosCompatibleLinksAndEncodedTokensAreAccepted() {
        assertEquals(secret, invitationDeepLink(invitationURL(secret)))
        assertEquals(secret, invitationDeepLink("IIM://group-invite/?%74oken=${"%41".repeat(43)}"))
    }
    @Test fun externalEntryRejectsAmbiguousAndUnrelatedInputs() {
        val token = secret.rawValue
        listOf(token, "https://group-invite?token=$token", "iim://other?token=$token",
            "iim://group-invite.evil?token=$token", "iim://user@group-invite?token=$token",
            "iim://group-invite:80?token=$token", "iim://group-invite/path?token=$token",
            "iim://group-invite?token=$token#fragment", "iim://group-invite?token=$token&token=$token",
            "iim://group-invite?token=$token&next=chat", "iim://group-invite?token=bad",
            "iim://group-invite?token=%zz", "iim://group-invite?token=${"%41".repeat(2048)}",
            "iim://group-invite?token=%00$token", " iim://group-invite?token=$token",
            "iim://group-invite?TOKEN=$token", "iim://group-invite?token", "iim://group-invite")
            .forEach { assertNull(invitationDeepLink(it)) }
    }
}
