package com.xmtx.im.client

import java.net.URI
import java.net.URLDecoder

/** External entry accepts only the generated invitation URL, never arbitrary navigation or raw codes. */
fun invitationDeepLink(value: String): InvitationSecret? = try {
    require(value.length <= 2048 && value.none { it.isWhitespace() || it.code < 32 })
    val uri = URI(value)
    require(uri.scheme.equals("iim", true) && uri.host == "group-invite")
    require(uri.rawUserInfo == null && uri.port == -1 && uri.rawFragment == null)
    require(uri.rawPath.isNullOrEmpty() || uri.rawPath == "/")
    val parts = requireNotNull(uri.rawQuery).split('&')
    require(parts.size == 1)
    val pair = parts.single().split('=', limit = 2)
    require(pair.size == 2 && URLDecoder.decode(pair[0], "UTF-8") == "token")
    InvitationSecret(URLDecoder.decode(pair[1], "UTF-8"))
} catch (_: Exception) { null }
