import Foundation

enum IMRealtimeDeliveryDiagnostics {
    static func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    static func elapsedMilliseconds(from start: Date, to end: Date = Date()) -> Int {
        max(0, Int(end.timeIntervalSince(start) * 1000))
    }

    static func shouldLog(durationMilliseconds: Int, thresholdMilliseconds: Int) -> Bool {
        thresholdMilliseconds > 0 && durationMilliseconds >= thresholdMilliseconds
    }

    static func shouldLogAny(_ durations: [Int], thresholdMilliseconds: Int) -> Bool {
        thresholdMilliseconds > 0 && durations.contains { $0 >= thresholdMilliseconds }
    }
}
