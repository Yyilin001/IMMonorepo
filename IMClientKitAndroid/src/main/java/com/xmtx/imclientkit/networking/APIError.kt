package com.xmtx.imclientkit.networking

sealed class APIError(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class Network(cause: Throwable) : APIError(cause.message ?: "Network request failed.", cause)
    class Decoding(cause: Throwable) : APIError(cause.message ?: "Response decoding failed.", cause)
    class Server(val statusCode: Int, val serverMessage: String) : APIError(serverMessage)
    class UnexpectedStatus(val statusCode: Int, val responseText: String) :
        APIError("Unexpected HTTP status $statusCode.")

    object AuthenticationExpired : APIError("Authentication expired.")
}
