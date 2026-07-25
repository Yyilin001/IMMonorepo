import Foundation

/// The application owns the task that calls `run()`. Foreground/background
/// policy can therefore stop heartbeats without changing sync correctness.
public struct V2HeartbeatScheduler: Sendable {
    private let sender: any V2HeartbeatSender
    private let interval: Duration

    public init(sender: any V2HeartbeatSender, interval: Duration) {
        precondition(interval > .zero)
        self.sender = sender
        self.interval = interval
    }

    public func run() async throws {
        while !Task.isCancelled {
            try await sender.sendHeartbeat(clientTime: Date())
            try await Task.sleep(for: interval)
        }
    }
}
