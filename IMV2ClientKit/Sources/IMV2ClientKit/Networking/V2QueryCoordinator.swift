import Foundation

public struct V2QueryScope: Hashable, Sendable {
    public let accountID: String
    public let authorizationDomain: String
    public let activationID: UUID
    public let generation: UInt64
    public init(accountID: String, authorizationDomain: String, activationID: UUID, generation: UInt64 = 0) {
        self.accountID = accountID; self.authorizationDomain = authorizationDomain
        self.activationID = activationID; self.generation = generation
    }
}
public enum V2QueryReadConsistency: Hashable, Sendable {
    case refresh
    case authority(minimumRevision: UInt64?)
}
public struct V2QueryKey: Hashable, Sendable {
    public let scope: V2QueryScope
    public let requestID: String
    public let consistency: V2QueryReadConsistency
    public init(scope: V2QueryScope, requestID: String, consistency: V2QueryReadConsistency = .refresh) {
        self.scope = scope; self.requestID = requestID; self.consistency = consistency
    }
}

/// Shares only current remote work, never an authorization lease or a cached result.
/// One cancelled subscriber cannot cancel another. A cancelled last subscriber's
/// non-cooperative transport retains its physical slot until it actually returns.
public actor V2QueryCoordinator<Value: Sendable> {
    public enum QueryError: Error, Sendable { case overloaded, closed }
    public struct Configuration: Sendable {
        public let maximumFlights: Int
        public let maximumSubscribers: Int
        public let maximumSubscribersPerFlight: Int
        public init(maximumFlights: Int = 32, maximumSubscribers: Int = 256, maximumSubscribersPerFlight: Int = 64) {
            precondition(maximumFlights > 0 && maximumSubscribers > 0 && maximumSubscribersPerFlight > 0)
            self.maximumFlights = maximumFlights; self.maximumSubscribers = maximumSubscribers
            self.maximumSubscribersPerFlight = maximumSubscribersPerFlight
        }
    }
    public struct Snapshot: Sendable { public let flights: Int; public let subscribers: Int; public let closed: Bool }
    private struct Flight {
        let key: V2QueryKey
        var task: Task<Void, Never>?
        var subscribers: [UUID: CheckedContinuation<Value, any Error>]
    }
    private let configuration: Configuration
    private var flights: [UUID: Flight] = [:]
    private var current: [V2QueryKey: UUID] = [:]
    private var subscriberCount = 0
    private var closed = false
    private var drains: [CheckedContinuation<Void, Never>] = []
    public init(configuration: Configuration = .init()) { self.configuration = configuration }
    public func snapshot() -> Snapshot { .init(flights: flights.count, subscribers: subscriberCount, closed: closed) }
    public func query(_ key: V2QueryKey, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let subscriberID = UUID()
        let result: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !closed else { continuation.resume(throwing: QueryError.closed); return }
                guard subscriberCount < configuration.maximumSubscribers else { continuation.resume(throwing: QueryError.overloaded); return }
                if let id = current[key], let flight = flights[id] {
                    guard flight.subscribers.count < configuration.maximumSubscribersPerFlight else {
                        continuation.resume(throwing: QueryError.overloaded); return
                    }
                    flights[id]?.subscribers[subscriberID] = continuation
                    subscriberCount += 1
                    return
                }
                guard flights.count < configuration.maximumFlights else { continuation.resume(throwing: QueryError.overloaded); return }
                let id = UUID()
                flights[id] = Flight(key: key, task: nil, subscribers: [subscriberID: continuation])
                current[key] = id; subscriberCount += 1
                flights[id]?.task = Task { [weak self] in
                    let result: Result<Value, any Error>
                    do { result = .success(try await operation()) } catch { result = .failure(error) }
                    await self?.finish(id, result: result)
                }
            }
        } onCancel: { Task { await self.cancelSubscriber(subscriberID) } }
        try Task.checkCancellation()
        return result
    }
    /// Invalidates current logical demand without pretending its transport has stopped.
    public func invalidate(scope: V2QueryScope) {
        let ids = flights.filter { $0.value.key.scope == scope }.map(\.key)
        for id in ids { cancelFlight(id, error: CancellationError()) }
    }
    public func beginClose() {
        guard !closed else { return }
        closed = true
        for id in Array(flights.keys) { cancelFlight(id, error: QueryError.closed) }
    }
    public func closeAndDrain() async {
        beginClose()
        if !flights.isEmpty { await withCheckedContinuation { drains.append($0) } }
    }
    private func cancelSubscriber(_ subscriberID: UUID) {
        guard let id = flights.first(where: { $0.value.subscribers[subscriberID] != nil })?.key,
              let subscriber = flights[id]?.subscribers.removeValue(forKey: subscriberID) else { return }
        subscriberCount -= 1
        subscriber.resume(throwing: CancellationError())
        if flights[id]?.subscribers.isEmpty == true {
            if let key = flights[id]?.key, current[key] == id { current[key] = nil }
            flights[id]?.task?.cancel()
        }
    }
    private func cancelFlight(_ id: UUID, error: any Error) {
        guard let flight = flights[id] else { return }
        if current[flight.key] == id { current[flight.key] = nil }
        flights[id]?.subscribers.removeAll()
        subscriberCount -= flight.subscribers.count
        for subscriber in flight.subscribers.values { subscriber.resume(throwing: error) }
        flight.task?.cancel()
    }
    private func finish(_ id: UUID, result: Result<Value, any Error>) {
        guard let flight = flights.removeValue(forKey: id) else { return }
        if current[flight.key] == id { current[flight.key] = nil }
        subscriberCount -= flight.subscribers.count
        for subscriber in flight.subscribers.values { subscriber.resume(with: result) }
        if flights.isEmpty { let waiting = drains; drains.removeAll(); for waiter in waiting { waiter.resume() } }
    }
}
