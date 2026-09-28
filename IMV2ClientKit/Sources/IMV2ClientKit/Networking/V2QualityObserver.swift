import Foundation

/// Per-service hysteresis. 429/503 and local processing are not path-quality samples.
public actor V2QualityObserver {
    public enum Sample: Sendable { case success, timeout, transportFailure, serviceCooldown, localProcessing }
    public enum Quality: Sendable, Equatable { case normal, degraded }
    private struct State {
        var samples: [Bool] = []
        var windowStarted: TimeInterval?
        var lastSampleAt: TimeInterval?
        var windowSampleCount = 0
        var badWindows = 0
        var healthyWindows = 0
        var quality: Quality = .normal
    }
    private var services: [String: State] = [:]
    private let serviceLimit: Int
    public init(serviceLimit: Int = 64) { precondition(serviceLimit > 0); self.serviceLimit = serviceLimit }
    public func quality(for service: String) -> Quality { services[service]?.quality ?? .normal }
    /// Monotonic seconds are supplied by the account's clock for deterministic windows.
    @discardableResult public func record(_ sample: Sample, service: String, now: TimeInterval) -> Quality {
        guard now.isFinite, now >= 0, sample == .success || sample == .timeout else { return quality(for: service) }
        guard services[service] != nil || services.count < serviceLimit else { return .normal }
        var state = services[service] ?? State()
        guard state.lastSampleAt.map({ now >= $0 }) ?? true else { return state.quality }
        if let start = state.windowStarted, now - start >= 10 {
            if now - start < 20 && state.windowSampleCount >= 5 && state.samples.count >= 5 {
                let ratio = Double(state.samples.filter { $0 }.count) / Double(state.samples.count)
                if ratio >= 0.3 { state.badWindows += 1; state.healthyWindows = 0 }
                else if ratio < 0.1 { state.healthyWindows += 1; state.badWindows = 0 }
                else { state.badWindows = 0; state.healthyWindows = 0 }
                if state.badWindows >= 2 { state.quality = .degraded }
                if state.healthyWindows >= 3 { state.quality = .normal }
            } else { state.badWindows = 0; state.healthyWindows = 0 }
            // A long observation gap cannot count as consecutive windows.
            if now - start >= 20 {
                state.badWindows = 0; state.healthyWindows = 0
                state.samples.removeAll(keepingCapacity: true)
            }
            state.windowSampleCount = 0
            state.windowStarted = now
        }
        if state.windowStarted == nil { state.windowStarted = now }
        state.lastSampleAt = now
        state.windowSampleCount = min(20, state.windowSampleCount + 1)
        state.samples.append(sample == .timeout)
        if state.samples.count > 20 { state.samples.removeFirst(state.samples.count - 20) }
        services[service] = state
        return state.quality
    }
}
