package com.xmtx.imappandroid.di

import com.xmtx.imclientkit.networking.NetworkEnvironment
import org.junit.Assert.assertThrows
import org.junit.Test

class AndroidNetworkConfigurationPolicyTests {
    @Test
    fun releaseAcceptsRealHttpsAndPublicTCPGateway() {
        AndroidNetworkConfigurationPolicy.validateRelease(
            environment = NetworkEnvironment(
                apiBaseUrl = "https://chat.prod-domain.com",
                imTcpHost = "tcp.prod-domain.com",
                imTcpPort = 9000,
            ),
            tcpRequiresTlsTermination = true,
        )
    }

    @Test
    fun releaseRejectsLocalApiURL() {
        assertThrows(IllegalArgumentException::class.java) {
            AndroidNetworkConfigurationPolicy.validateRelease(
                environment = NetworkEnvironment(
                    apiBaseUrl = "http://10.0.2.2:8080",
                    imTcpHost = "tcp.prod-domain.com",
                    imTcpPort = 9000,
                ),
                tcpRequiresTlsTermination = true,
            )
        }
    }

    @Test
    fun releaseRejectsPlaceholderHost() {
        assertThrows(IllegalArgumentException::class.java) {
            AndroidNetworkConfigurationPolicy.validateRelease(
                environment = NetworkEnvironment(
                    apiBaseUrl = "https://im.example.com",
                    imTcpHost = "tcp.prod-domain.com",
                    imTcpPort = 9000,
                ),
                tcpRequiresTlsTermination = true,
            )
        }
    }

    @Test
    fun releaseRejectsRawTCPIPAddress() {
        assertThrows(IllegalArgumentException::class.java) {
            AndroidNetworkConfigurationPolicy.validateRelease(
                environment = NetworkEnvironment(
                    apiBaseUrl = "https://chat.prod-domain.com",
                    imTcpHost = "47.106.103.10",
                    imTcpPort = 9000,
                ),
                tcpRequiresTlsTermination = true,
            )
        }
    }

    @Test
    fun releaseRejectsUnexpectedPortsAndMissingTLSTermination() {
        assertThrows(IllegalArgumentException::class.java) {
            AndroidNetworkConfigurationPolicy.validateRelease(
                environment = NetworkEnvironment(
                    apiBaseUrl = "https://chat.prod-domain.com:8443",
                    imTcpHost = "tcp.prod-domain.com",
                    imTcpPort = 9000,
                ),
                tcpRequiresTlsTermination = true,
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            AndroidNetworkConfigurationPolicy.validateRelease(
                environment = NetworkEnvironment(
                    apiBaseUrl = "https://chat.prod-domain.com",
                    imTcpHost = "tcp.prod-domain.com",
                    imTcpPort = 9443,
                ),
                tcpRequiresTlsTermination = true,
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            AndroidNetworkConfigurationPolicy.validateRelease(
                environment = NetworkEnvironment(
                    apiBaseUrl = "https://chat.prod-domain.com",
                    imTcpHost = "tcp.prod-domain.com",
                    imTcpPort = 9000,
                ),
                tcpRequiresTlsTermination = false,
            )
        }
    }
}
