import Foundation

public protocol V2RuntimeEnvironment: Sendable {
    func value(for key: String) -> String?
}
