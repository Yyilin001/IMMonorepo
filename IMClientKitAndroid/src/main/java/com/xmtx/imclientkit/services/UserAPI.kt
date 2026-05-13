package com.xmtx.imclientkit.services

import com.xmtx.imclientkit.networking.HTTPRequestSpec

class UserAPI {
    fun me(): HTTPRequestSpec = HTTPRequestSpec(path = "api/me")
}
