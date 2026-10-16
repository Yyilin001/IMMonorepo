/// Classifies logical sends by their original scheduled monotonic time, never
/// by ACK arrival. Queueing, retry and reconnect retain that original time.
public struct V2LoadMessageCohortWindows: Sendable {
    public enum Failure: Error, Equatable { case invalidWindow }
    private struct Window: Sendable {
        let name: String
        let start: UInt64
        let end: UInt64
    }
    private var windows: [Window] = []
    public init() {}
    public mutating func register(name: String, start: UInt64, end: UInt64) throws {
        guard !name.isEmpty, start < end, windows.last.map({ $0.end <= start }) ?? true,
              !windows.contains(where: { $0.name == name }) else { throw Failure.invalidWindow }
        windows.append(Window(name: name, start: start, end: end))
    }
    public func cohort(scheduledAt: UInt64) -> String? {
        var low = 0, high = windows.count
        while low < high {
            let middle = low + (high - low) / 2
            if windows[middle].start <= scheduledAt { low = middle + 1 } else { high = middle }
        }
        guard low > 0, scheduledAt < windows[low - 1].end else { return nil }
        return windows[low - 1].name
    }
}
