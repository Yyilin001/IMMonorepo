import Foundation
import IMClientKit

struct AppNetworkConfiguration: Equatable {
    let apiBaseURL: URL
    let imTCPHost: String
    let imTCPPort: UInt16

    static let local = AppNetworkConfiguration(
        apiBaseURL: URL(string: "http://120.25.106.200:8080")!,
        imTCPHost: "120.25.106.200",
        imTCPPort: 9000
    )

    static let preview = local

    func makeNetworkEnvironment() -> NetworkEnvironment {
        NetworkEnvironment(baseURL: apiBaseURL)
    }

    func makeIMTCPConfiguration() -> IMTCPClientConfiguration {
        IMTCPClientConfiguration(
            host: imTCPHost,
            port: imTCPPort
        )
    }
}
