import Foundation
import Network

public struct V2ResourceAutomaticNetworkConditions: Equatable, Sendable {
    public let available: Bool
    public let cellular: Bool
    public let expensive: Bool
    public let constrained: Bool
    public init(available: Bool, cellular: Bool = false, expensive: Bool = false, constrained: Bool = false) {
        self.available = available; self.cellular = cellular; self.expensive = expensive; self.constrained = constrained
    }
    public var permitsAutomaticDownload: Bool { available && !cellular && !expensive && !constrained }
    public static let unavailable = Self(available: false)
    public static let unrestricted = Self(available: true)
}

/// A fresh subscription belongs to each account recovery activity. The queue
/// is only the Network.framework callback bridge; business work stays in actors.
public struct V2ResourceAutomaticNetworkSource: Sendable {
    let initial: V2ResourceAutomaticNetworkConditions
    let updates: @Sendable () -> AsyncStream<V2ResourceAutomaticNetworkConditions>
    public init(initial: V2ResourceAutomaticNetworkConditions = .unavailable,
                updates: @escaping @Sendable () -> AsyncStream<V2ResourceAutomaticNetworkConditions>) {
        self.initial = initial; self.updates = updates
    }
    public static var system: Self {
        .init {
            AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let monitor = NWPathMonitor()
                monitor.pathUpdateHandler = { path in
                    continuation.yield(.init(available: path.status == .satisfied, cellular: path.usesInterfaceType(.cellular),
                        expensive: path.isExpensive, constrained: path.isConstrained))
                }
                continuation.onTermination = { _ in monitor.cancel() }
                monitor.start(queue: DispatchQueue(label: "im.resource.network-path"))
            }
        }
    }
    public static var unrestricted: Self { .init(initial: .unrestricted) { AsyncStream { _ in } } }
}
