import Foundation
import IMClientKit

struct AppNetworkConfiguration: Equatable {
    let apiBaseURL: URL
    let imTCPHost: String
    let imTCPPort: UInt16

    static let local = AppNetworkConfiguration(
        apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
        imTCPHost: "127.0.0.1",
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
