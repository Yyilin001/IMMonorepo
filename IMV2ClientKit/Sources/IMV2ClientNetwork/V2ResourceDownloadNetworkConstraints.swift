import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum V2NetworkPolicyError: Error, Equatable, Sendable { case unsupportedConstraints }

public struct V2ResourceDownloadNetworkConstraints: Equatable, Sendable {
    public let allowsCellular: Bool
    public let allowsExpensive: Bool
    public let allowsConstrained: Bool
    public static let unrestricted = Self(allowsCellular: true, allowsExpensive: true, allowsConstrained: true)
    public init(allowsCellular: Bool, allowsExpensive: Bool, allowsConstrained: Bool) {
        self.allowsCellular = allowsCellular; self.allowsExpensive = allowsExpensive; self.allowsConstrained = allowsConstrained
    }
    package func intersecting(_ other: Self) -> Self {
        .init(allowsCellular: allowsCellular && other.allowsCellular,
              allowsExpensive: allowsExpensive && other.allowsExpensive,
              allowsConstrained: allowsConstrained && other.allowsConstrained)
    }
    // Request-local metadata for platform streaming adapters; never an HTTP header.
    @TaskLocal package static var transferConstraints: Self?
    package func apply(to request: inout URLRequest) throws {
        #if canImport(Darwin)
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsExpensive
        request.allowsConstrainedNetworkAccess = allowsConstrained
        #else
        // FoundationNetworking cannot enforce cost/cellular constraints. A
        // platform transport must implement them before restricted downloads.
        guard self == .unrestricted else { throw V2NetworkPolicyError.unsupportedConstraints }
        #endif
    }
}
