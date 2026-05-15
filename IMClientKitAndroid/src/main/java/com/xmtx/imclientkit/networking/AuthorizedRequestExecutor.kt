package com.xmtx.imclientkit.networking

import com.xmtx.imclientkit.persistence.TokenStore

internal class AuthorizedRequestExecutor(
    private val httpExecutor: HTTPExecutor,
    private val tokenStore: TokenStore,
    private val refreshAccessToken: suspend () -> String,
    private val clearSession: suspend () -> Unit,
) {
    internal suspend inline fun <reified Response : Any> execute(spec: HTTPRequestSpec): Response {
        val accessToken = tokenStore.load()?.accessToken ?: throw APIError.AuthenticationExpired
        return try {
            httpExecutor.execute(spec, accessToken)
        } catch (error: APIError.AuthenticationExpired) {
            val refreshedToken = try {
                refreshAccessToken()
            } catch (_: Throwable) {
                clearSession()
                throw APIError.AuthenticationExpired
            }
            try {
                httpExecutor.execute(spec, refreshedToken)
            } catch (retryError: APIError.AuthenticationExpired) {
                clearSession()
                throw retryError
            }
        }
    }
}
