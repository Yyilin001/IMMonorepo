package com.xmtx.imappandroid.di

import com.xmtx.imclientkit.networking.NetworkEnvironment
import java.net.URI

internal object AndroidNetworkConfigurationPolicy {
    private val placeholderHosts = setOf("im.example.com", "example.com", "example.net", "example.org")
    private val placeholderSuffixes = listOf(".example.com", ".example.net", ".example.org", ".test", ".invalid", ".localhost")
    private val localHosts = setOf("localhost", "::1", "ip6-localhost")
    private val stalePublicIPs = setOf("47.106.103.10", "120.25.106.200")

    fun validateRelease(
        environment: NetworkEnvironment,
        tcpRequiresTlsTermination: Boolean,
    ) {
        val apiURI = runCatching { URI(environment.apiBaseUrl) }
            .getOrElse { throw IllegalArgumentException("Release builds require a valid IM_API_BASE_URL.") }
        require(apiURI.scheme == "https") {
            "Release builds require an HTTPS IM_API_BASE_URL."
        }
        require(apiURI.host != null) {
            "Release builds require IM_API_BASE_URL to include a host."
        }
        require(apiURI.port == -1 || apiURI.port == 443) {
            "Release builds require IM_API_BASE_URL to use the default HTTPS port 443."
        }
        validatePublicDNSHost(apiURI.host, "IM_API_BASE_URL")

        validatePublicDNSHost(environment.imTcpHost, "IM_TCP_HOST")
        require(environment.imTcpPort == 9000) {
            "Release builds require IM_TCP_PORT=9000."
        }
        require(tcpRequiresTlsTermination) {
            "Release builds require IM_TCP_REQUIRES_TLS_TERMINATION=true for the public TCP gateway."
        }
    }

    private fun validatePublicDNSHost(host: String, key: String) {
        val normalized = host.trim().trim('[', ']').lowercase()
        require(normalized.isNotEmpty()) {
            "Release builds require $key to be set."
        }
        require(normalized !in localHosts && !normalized.endsWith(".local")) {
            "Release builds require $key to use a real public DNS host, not localhost."
        }
        require(normalized !in stalePublicIPs) {
            "Release builds require $key to not point at a stale temporary server."
        }
        require(!isIPLiteral(normalized)) {
            "Release builds require $key to use a real public DNS host, not a raw IP address."
        }
        require(normalized.contains(".")) {
            "Release builds require $key to use a real public DNS host."
        }
        require(normalized !in placeholderHosts && placeholderSuffixes.none { normalized.endsWith(it) }) {
            "Release builds require $key to use a real public DNS host, not a placeholder domain."
        }
    }

    private fun isIPLiteral(host: String): Boolean =
        host.contains(":") || isIPv4Literal(host)

    private fun isIPv4Literal(host: String): Boolean {
        val parts = host.split(".")
        if (parts.size != 4) return false
        return parts.all { part ->
            part.isNotEmpty() && part.all(Char::isDigit) && part.toIntOrNull()?.let { it in 0..255 } == true
        }
    }
}
