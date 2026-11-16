import Foundation
import IMV2SharedRuntime

extension V2MobileClient {
    public static func apple(accountURL: String, gatewayHost: String, gatewayPort: UInt16) throws -> V2MobileClient {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("im-shared-sdk", isDirectory: true)
        return try V2MobileClient(accountURL: accountURL, gatewayHost: gatewayHost, gatewayPort: gatewayPort,
                                  storage: directory, platform: .apple())
    }
}
