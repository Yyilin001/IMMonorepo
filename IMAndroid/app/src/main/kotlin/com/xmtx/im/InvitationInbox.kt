package com.xmtx.im

import com.xmtx.im.client.InvitationSecret
import com.xmtx.im.client.invitationDeepLink
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

/** Main-thread, memory-only handoff. The observable ticket carries no bearer material. */
internal class InvitationInbox {
    private var secret: InvitationSecret? = null
    private val mutableTicket = MutableStateFlow<String?>(null)
    val ticket = mutableTicket.asStateFlow()

    fun offer(url: String) {
        val incoming = invitationDeepLink(url) ?: return
        if (incoming == secret) return
        secret = incoming
        mutableTicket.value = UUID.randomUUID().toString()
    }

    fun take(ticket: String): InvitationSecret? {
        if (ticket != mutableTicket.value) return null
        val value = secret
        clear()
        return value
    }

    fun clear() { secret = null; mutableTicket.value = null }
}
