import Foundation
import Vapor

struct IMHotConversationConfiguration: Sendable {
    let messagesPerSecondLimit: Int

    var isEnabled: Bool {
        messagesPerSecondLimit > 0
    }

    static func load(from environment: Environment) -> IMHotConversationConfiguration {
        IMHotConversationConfiguration(
            messagesPerSecondLimit: max(0, Environment.get("IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT").flatMap(Int.init(_:)) ?? 0)
        )
    }
}

actor HotConversationLimiter {
    private struct Window {
        var second: Int
        var count: Int
    }

    private var windows: [UUID: Window] = [:]

    func reserve(conversationID: UUID, limit: Int, now: Date = Date()) throws {
        guard limit > 0 else {
            return
        }

        let second = Int(now.timeIntervalSince1970)
        var window = windows[conversationID] ?? Window(second: second, count: 0)
        if window.second != second {
            window = Window(second: second, count: 0)
            prune(before: second - 1)
        }

        guard window.count < limit else {
            windows[conversationID] = window
            throw HotConversationLimiterError.rateLimited
        }

        window.count += 1
        windows[conversationID] = window
    }

    func currentWindowCount(for conversationID: UUID, now: Date = Date()) -> Int {
        let second = Int(now.timeIntervalSince1970)
        guard let window = windows[conversationID], window.second == second else {
            return 0
        }
        return window.count
    }

    func trackedWindowCount() -> Int {
        windows.count
    }

    private func prune(before second: Int) {
        windows = windows.filter { $0.value.second >= second }
    }
}

enum HotConversationLimiterError: Error {
    case rateLimited
}

actor HotConversationMetrics {
    struct Snapshot: Sendable {
        var rejectedMessages: Int = 0
        var trackedWindows: Int = 0
    }

    private var snapshot = Snapshot()

    func recordRejectedMessage() {
        snapshot.rejectedMessages += 1
    }

    func recordTrackedWindows(_ count: Int) {
        snapshot.trackedWindows = count
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}

private struct IMHotConversationConfigurationStorageKey: StorageKey {
    typealias Value = IMHotConversationConfiguration
}

private struct HotConversationLimiterStorageKey: StorageKey {
    typealias Value = HotConversationLimiter
}

private struct HotConversationMetricsStorageKey: StorageKey {
    typealias Value = HotConversationMetrics
}

extension Application {
    var hotConversationConfiguration: IMHotConversationConfiguration {
        get {
            if let configuration = storage[IMHotConversationConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMHotConversationConfiguration.load(from: environment)
            storage[IMHotConversationConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMHotConversationConfigurationStorageKey.self] = newValue }
    }

    var hotConversationLimiter: HotConversationLimiter {
        get {
            if let limiter = storage[HotConversationLimiterStorageKey.self] {
                return limiter
            }
            let limiter = HotConversationLimiter()
            storage[HotConversationLimiterStorageKey.self] = limiter
            return limiter
        }
        set { storage[HotConversationLimiterStorageKey.self] = newValue }
    }

    var hotConversationMetrics: HotConversationMetrics {
        get {
            if let metrics = storage[HotConversationMetricsStorageKey.self] {
                return metrics
            }
            let metrics = HotConversationMetrics()
            storage[HotConversationMetricsStorageKey.self] = metrics
            return metrics
        }
        set { storage[HotConversationMetricsStorageKey.self] = newValue }
    }
}
