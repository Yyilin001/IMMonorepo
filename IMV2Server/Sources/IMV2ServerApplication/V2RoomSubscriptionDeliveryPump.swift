import Foundation
import IMV2Core
import IMV2ActorContracts

/// Owns bounded online RPCs independently of room commit and socket workers.
/// A transport deadline bounds each admitted call. Failed admission retains
/// Relay responsibility; rejected authorization waits for a trusted new baseline.
public actor V2RoomSubscriptionDeliveryPump {
    public struct Key: Hashable, Sendable {
        public let roomID: RoomID
        public let gateway: V2GatewayRealtimeIdentity
        public init(roomID: RoomID, gateway: V2GatewayRealtimeIdentity) {
            self.roomID = roomID; self.gateway = gateway
        }
    }
    public typealias Send = @Sendable (V2RoomSubscriptionDelivery, String, V2GatewayRealtimeDescriptor) async throws -> V2RoomSubscriptionDeliveryResult
    public typealias SendBatch = @Sendable (V2RoomSubscriptionDeliveryBatch, String, V2GatewayRealtimeDescriptor) async throws -> V2RoomSubscriptionBatchResult
    private let controls: V2RoomSubscriptionLanePump
    private let messages: V2RoomSubscriptionLanePump
    private var bindingFlights: [Key: Task<Bool, Never>] = [:]
    private var closed = false
    public init(maximumEntries: Int = 8192, maximumCalls: Int = 4,
                send: @escaping Send) {
        let batch: SendBatch = { batch, shard, target in
            let delivery = batch.deliveries[0]
            let result = try await send(delivery, shard, target)
            return .init(receipts: [.init(fence: delivery.fence, result: result)])
        }
        controls = .init(maximumEntries: maximumEntries, maximumCalls: min(2, maximumCalls), maximumBatchItems: 1,
            maximumBatchBytes: 1_048_576, lane: .authorization, sendBatch: batch)
        messages = .init(maximumEntries: maximumEntries, maximumCalls: maximumCalls, maximumBatchItems: 1,
            maximumBatchBytes: 1_048_576, lane: .message, sendBatch: batch)
    }
    public init(maximumEntries: Int = 8192, maximumCalls: Int,
                maximumBatchItems: Int = 64, maximumBatchBytes: Int = 245_760,
                sendBatch: @escaping SendBatch) {
        controls = .init(maximumEntries: maximumEntries, maximumCalls: min(2, maximumCalls),
            maximumBatchItems: maximumBatchItems, maximumBatchBytes: maximumBatchBytes,
            lane: .authorization, sendBatch: sendBatch)
        messages = .init(maximumEntries: maximumEntries, maximumCalls: maximumCalls,
            maximumBatchItems: maximumBatchItems, maximumBatchBytes: maximumBatchBytes,
            lane: .message, sendBatch: sendBatch)
    }
    public func snapshot() async -> (actualCalls: Int, activeRoomPrefixes: Int, queuedGroups: Int, queuedRooms: Int, retryGroups: Int) {
        let a = await controls.snapshot(), b = await messages.snapshot()
        return (a.actualCalls + b.actualCalls, a.activeRoomPrefixes + b.activeRoomPrefixes,
            a.queuedGroups + b.queuedGroups, a.queuedRooms + b.queuedRooms, a.retryGroups + b.retryGroups)
    }
    @discardableResult
    public func bind(_ key: Key, relay: V2RoomSubscriptionRelay,
                     descriptor: V2GatewayRealtimeDescriptor, sourceShardID: String) async -> Bool {
        guard !closed, bindingFlights[key] == nil, key.gateway == descriptor.identity,
              !sourceShardID.isEmpty else { return false }
        let controls = self.controls, messages = self.messages
        let flight = Task {
            guard await controls.reserveBinding(key) else { return false }
            guard await messages.reserveBinding(key) else {
                await controls.releaseBinding(key); return false
            }
            await controls.installBinding(key, relay: relay, descriptor: descriptor, sourceShardID: sourceShardID)
            await messages.installBinding(key, relay: relay, descriptor: descriptor, sourceShardID: sourceShardID)
            await controls.signal(key); await messages.signal(key)
            return true
        }
        bindingFlights[key] = flight
        let result = await flight.value
        bindingFlights.removeValue(forKey: key)
        return result
    }
    public func signal(_ key: Key) async { await controls.signal(key); await messages.signal(key) }
    public func baselineInstalled(_ key: Key) async { await controls.baselineInstalled(key); await messages.baselineInstalled(key) }
    public func unbind(_ key: Key) async {
        _ = await bindingFlights[key]?.value
        await controls.unbind(key); await messages.unbind(key)
    }
    public func unbindAndJoin(_ key: Key, expectedFence: V2RoomSubscriptionFence? = nil) async {
        _ = await bindingFlights[key]?.value
        async let a: Void = controls.unbindAndJoin(key, expectedFence: expectedFence)
        async let b: Void = messages.unbindAndJoin(key, expectedFence: expectedFence)
        _ = await (a, b)
    }
    public func start() async { await controls.start(); await messages.start() }
    public func close() async {
        closed = true
        let bindings = Array(bindingFlights.values)
        for binding in bindings { _ = await binding.value }
        async let a: Void = controls.close()
        async let b: Void = messages.close()
        _ = await (a, b)
    }
}

package enum V2RoomSubscriptionLane: Sendable { case authorization, message }

/// A lane owns its actual calls and retry permits until they exit. A held
/// message call cannot reserve the authorization lane's peer or call slots.
private actor V2RoomSubscriptionLanePump {
    typealias Key = V2RoomSubscriptionDeliveryPump.Key
    typealias SendBatch = V2RoomSubscriptionDeliveryPump.SendBatch
    private struct Entry: Sendable {
        let id: UUID
        let relay: V2RoomSubscriptionRelay
        let descriptor: V2GatewayRealtimeDescriptor
        let shardID: String
        var waitingBaseline = false
    }
    private struct Group: Hashable, Sendable {
        let gateway: V2GatewayRealtimeIdentity
        let shardID: String
    }
    private struct Work: Sendable {
        let key: Key
        let entry: Entry
        let last: V2RoomSubscriptionDelivery
    }
    private struct KeyQueue: Sendable {
        private var storage: [Key] = []
        private var index = 0
        var count: Int { storage.count - index }
        var isEmpty: Bool { count == 0 }
        mutating func append(_ key: Key) { storage.append(key) }
        mutating func popFirst() -> Key? {
            guard !isEmpty else { return nil }
            let key = storage[index]; index += 1
            if index >= 1024 && index * 2 >= storage.count {
                storage.removeFirst(index); index = 0
            }
            return key
        }
        mutating func remove(_ key: Key) {
            storage = storage.dropFirst(index).filter { $0 != key }; index = 0
        }
    }
    private let maximumEntries: Int
    private let maximumCalls: Int
    private let sendBatch: SendBatch
    private let maximumBatchItems: Int
    private let maximumBatchBytes: Int
    private var entries: [Key: Entry] = [:]
    private var active: [UUID: Task<Void, Never>] = [:]
    private var activeKeys: Set<Key> = []
    private var bindingReservations: [Key: Bool] = [:]
    private var reservedNewBindings = 0
    private struct Binding: Hashable { let key: Key; let entryID: UUID }
    private var reservedBindings: [Key: UUID] = [:]
    private var bindingWaiters: [Binding: [CheckedContinuation<Task<Void, Never>?, Never>]] = [:]
    private var bindingTasks: [Binding: Task<Void, Never>] = [:]
    private var bindingFences: [Binding: V2RoomSubscriptionFence] = [:]
    private var retrying: [Group: Task<Void, Never>] = [:]
    private var activePeers: Set<V2GatewayRealtimeIdentity> = []
    private var queue: [Group] = []
    private var queueIndex = 0
    private var queued: Set<Group> = []
    private var groupKeys: [Group: KeyQueue] = [:]
    private var queuedKeys: Set<Key> = []
    private var owner: Task<Void, Never>?
    private var closed = false
    private let wakes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    public func snapshot() -> (actualCalls: Int, activeRoomPrefixes: Int, queuedGroups: Int, queuedRooms: Int, retryGroups: Int) {
        (active.count, activeKeys.count, queued.count, queuedKeys.count, retrying.count)
    }

    private let lane: V2RoomSubscriptionLane
    init(maximumEntries: Int, maximumCalls: Int, maximumBatchItems: Int,
         maximumBatchBytes: Int, lane: V2RoomSubscriptionLane,
         sendBatch: @escaping SendBatch) {
        precondition(maximumEntries > 0 && maximumCalls > 0 && maximumBatchItems > 0 && maximumBatchItems <= 64 && maximumBatchBytes > 0)
        self.maximumEntries = maximumEntries; self.maximumCalls = maximumCalls
        self.maximumBatchItems = maximumBatchItems; self.maximumBatchBytes = maximumBatchBytes
        self.lane = lane; self.sendBatch = sendBatch
    }
    func reserveBinding(_ key: Key) -> Bool {
        guard !closed, !activeKeys.contains(key), bindingReservations[key] == nil,
              entries[key] != nil || entries.count + reservedNewBindings < maximumEntries else { return false }
        let isNew = entries[key] == nil
        bindingReservations[key] = isNew
        if isNew { reservedNewBindings += 1 }
        return true
    }
    func releaseBinding(_ key: Key) {
        if bindingReservations.removeValue(forKey: key) == true { reservedNewBindings -= 1 }
        signal(key)
    }
    func installBinding(_ key: Key, relay: V2RoomSubscriptionRelay,
                        descriptor: V2GatewayRealtimeDescriptor, sourceShardID: String) {
        let wasNew = bindingReservations.removeValue(forKey: key)
        precondition(wasNew != nil && !closed)
        if wasNew == true { reservedNewBindings -= 1 }
        entries[key] = Entry(id: UUID(), relay: relay, descriptor: descriptor, shardID: sourceShardID)
    }
    public func signal(_ key: Key) {
        guard !closed, let entry = entries[key], !entry.waitingBaseline else { return }
        // A queued key already owns a wake. Completion/retry wakes blocked
        // groups explicitly, so repeated room signals need no extra hop.
        guard queuedKeys.insert(key).inserted else { return }
        let group = Group(gateway: key.gateway, shardID: entry.shardID)
        groupKeys[group, default: KeyQueue()].append(key)
        enqueue(group)
        wakes.continuation.yield(())
    }
    private func enqueue(_ group: Group) {
        if queued.insert(group).inserted { queue.append(group) }
    }
    public func baselineInstalled(_ key: Key) {
        guard !closed, var entry = entries[key] else { return }
        entry.waitingBaseline = false; entries[key] = entry; signal(key)
    }
    public func unbind(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) {
            let group = Group(gateway: key.gateway, shardID: entry.shardID)
            groupKeys[group]?.remove(key)
            if groupKeys[group]?.isEmpty == true {
                groupKeys.removeValue(forKey: group); queued.remove(group)
                queue = queue.dropFirst(queueIndex).filter { $0 != group }; queueIndex = 0
            }
            queuedKeys.remove(key)
        }
        // A sleeping retry remains owned until it wakes or close joins it.
        // Active calls retain their handles and peer reservation until complete.
    }
    /// Removes only this installation and joins its retained actual call. A
    /// shared batch is never cancelled: other rooms retain their RPC ownership.
    /// Reservations made while assembling a batch also participate in the join.
    public func unbindAndJoin(_ key: Key, expectedFence: V2RoomSubscriptionFence? = nil) async {
        let entryID: UUID
        if let entry = entries[key] {
            if let expectedFence {
                let currentFence = await entry.relay.status(for: key.gateway)?.fence
                let binding = Binding(key: key, entryID: entry.id)
                guard entries[key]?.id == entry.id else { return }
                if currentFence == expectedFence { unbind(key) }
                else if bindingFences[binding] != expectedFence { return }
            } else { unbind(key) }
            entryID = entry.id
        } else {
            guard let reserved = reservedBindings[key] else { return }
            if let expectedFence, bindingFences[Binding(key: key, entryID: reserved)] != expectedFence { return }
            entryID = reserved
        }
        guard reservedBindings[key] == entryID else { return }
        let actualCall = await withCheckedContinuation { continuation in
            bindingWaiters[Binding(key: key, entryID: entryID), default: []].append(continuation)
        }
        await actualCall?.value
    }
    private func releaseReservation(_ key: Key, entryID: UUID) {
        guard reservedBindings[key] == entryID else { return }
        reservedBindings.removeValue(forKey: key); activeKeys.remove(key)
        let binding = Binding(key: key, entryID: entryID)
        bindingFences.removeValue(forKey: binding)
        let actualCall = bindingTasks.removeValue(forKey: binding)
        let waiters = bindingWaiters.removeValue(forKey: binding) ?? []
        for waiter in waiters { waiter.resume(returning: actualCall) }
    }

    public func start() {
        guard !closed, owner == nil else { return }
        owner = Task { [weak self, stream = wakes.stream] in
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                await self.admit()
            }
        }
        wakes.continuation.yield(())
    }
    private func admit() async {
        // Visit each originally queued peer/shard group at most once. Blocked peers return
        // to the tail, without starving a fast peer beyond the first quantum.
        let visits = queue.count - queueIndex
        for ordinal in 0..<visits {
            if ordinal > 0, ordinal % 64 == 0 { await Task.yield() }
            guard !closed, active.count < maximumCalls, queueIndex < queue.count else { break }
            let group = queue[queueIndex]; queueIndex += 1; queued.remove(group)
            guard groupKeys[group]?.isEmpty == false else { continue }
            if activePeers.contains(group.gateway) || retrying[group] != nil {
                // Wait for a real peer completion instead of waking our own
                // stream repeatedly while that peer is unavailable.
                enqueue(group)
                continue
            }
            var builder = V2RoomSubscriptionDeliveryBatch.Builder()
            var work: [Work] = []
            var descriptor: V2GatewayRealtimeDescriptor?
            let candidates = min(groupKeys[group]?.count ?? 0, maximumBatchItems)
            work.reserveCapacity(candidates)
            activePeers.insert(group.gateway)
            for _ in 0..<candidates {
                guard !closed, builder.count < maximumBatchItems,
                      let key = groupKeys[group]?.popFirst() else { break }
                queuedKeys.remove(key)
                if bindingReservations[key] != nil { signal(key); continue }
                guard let entry = entries[key], !entry.waitingBaseline,
                      !activeKeys.contains(key) else { continue }
                // Reserve before awaiting the Relay; reentrant bind cannot
                // replace the identity whose pending prefix we are collecting.
                activeKeys.insert(key); reservedBindings[key] = entry.id
                guard let snapshot = await entry.relay.pendingSnapshot(for: key.gateway, lane: lane),
                      entries[key]?.id == entry.id, !closed else {
                    releaseReservation(key, entryID: entry.id); continue
                }
                let status = snapshot.status
                bindingFences[Binding(key: key, entryID: entry.id)] = status.fence
                if status.needsBaseline {
                    releaseReservation(key, entryID: entry.id); waitForBaseline(key, entry: entry); continue
                }
                let pending = snapshot.pending
                var last: V2RoomSubscriptionDelivery?
                for delivery in pending.prefix(maximumBatchItems - builder.count) {
                    guard (try? builder.append(delivery, maximumBytes: maximumBatchBytes)) == true else { break }
                    last = delivery
                }
                if let last {
                    work.append(.init(key: key, entry: entry, last: last))
                    if descriptor == nil { descriptor = entry.descriptor }
                } else {
                    releaseReservation(key, entryID: entry.id)
                    if pending.isEmpty { continue }
                    if builder.count == 0 { waitForBaseline(key, entry: entry) }
                    else { signal(key); break }
                }
            }
            if groupKeys[group]?.isEmpty == true { groupKeys.removeValue(forKey: group) }
            if groupKeys[group]?.isEmpty == false { enqueue(group) }
            guard !closed, let descriptor, !work.isEmpty else {
                for item in work { releaseReservation(item.key, entryID: item.entry.id) }
                activePeers.remove(group.gateway); continue
            }
            let batch = builder.finish()
            let callID = UUID()
            let admittedWork = work
            let sendBatch = self.sendBatch
            active[callID] = Task { [weak self] in
                let result: Result<V2RoomSubscriptionBatchResult, any Error>
                do { try Task.checkCancellation(); result = .success(try await sendBatch(batch, group.shardID, descriptor)) }
                catch { result = .failure(error) }
                await self?.complete(callID, group: group, work: admittedWork, result: result)
            }
            for item in admittedWork {
                bindingTasks[Binding(key: item.key, entryID: item.entry.id)] = active[callID]
            }
        }
        if queueIndex >= 1024 && queueIndex * 2 >= queue.count {
            queue.removeFirst(queueIndex); queueIndex = 0
        }
    }
    private func waitForBaseline(_ key: Key, entry: Entry) {
        guard entries[key]?.id == entry.id else { return }
        var current = entry; current.waitingBaseline = true; entries[key] = current
    }
    private func complete(_ callID: UUID, group: Group, work: [Work],
                          result: Result<V2RoomSubscriptionBatchResult, any Error>) async {
        defer {
            active.removeValue(forKey: callID); activePeers.remove(group.gateway)
            for item in work { releaseReservation(item.key, entryID: item.entry.id) }
            wakes.continuation.yield(())
        }
        guard !closed else { return }
        let receipts: [V2RoomSubscriptionFence: V2RoomSubscriptionDeliveryResult]?
        if case .success(let response) = result {
            receipts = validatedReceipts(response, work: work)
        } else { receipts = nil }
        if case .failure = result {
            // One retry owner per peer/shard batch, rather than one sleeping
            // task for every room that happened to share the failed call.
            retrying[group] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await self?.retry(group)
            }
        }
        for item in work {
            let key = item.key, entry = item.entry
            guard !closed, entries[key]?.id == entry.id else { continue }
            if let receipts, case .appliedThrough(let through) = receipts[item.last.fence], through == item.last.deliverySequence {
                do { try await entry.relay.acknowledge(gateway: key.gateway, fence: item.last.fence, through: through, lane: lane) }
                catch { /* A newer baseline owns its own exact fence. */ }
                signal(key)
            } else if lane == .message, let receipts, case .stale = receipts[item.last.fence] {
                try? await entry.relay.recoverRejectedMessages(gateway: key.gateway, fence: item.last.fence,
                    through: item.last.deliverySequence)
                signal(key)
                if retrying[group] == nil {
                    retrying[group] = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        await self?.retry(group)
                    }
                }
            } else if case .success = result {
                if lane == .authorization {
                    waitForBaseline(key, entry: entry)
                } else {
                    signal(key)
                    if retrying[group] == nil {
                        retrying[group] = Task { [weak self] in
                            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                            await self?.retry(group)
                        }
                    }
                }
            } else {
                signal(key)
            }
        }
    }
    private func validatedReceipts(_ response: V2RoomSubscriptionBatchResult, work: [Work])
        -> [V2RoomSubscriptionFence: V2RoomSubscriptionDeliveryResult]? {
        guard response.receipts.count == work.count else { return nil }
        var receipts: [V2RoomSubscriptionFence: V2RoomSubscriptionDeliveryResult] = [:]
        receipts.reserveCapacity(work.count)
        for receipt in response.receipts {
            guard receipts.updateValue(receipt.result, forKey: receipt.fence) == nil else { return nil }
        }
        guard work.allSatisfy({ receipts[$0.last.fence] != nil }) else { return nil }
        return receipts
    }
    private func retry(_ group: Group) {
        retrying.removeValue(forKey: group)
        if groupKeys[group]?.isEmpty == false { enqueue(group); wakes.continuation.yield(()) }
    }
    public func close() async {
        closed = true; wakes.continuation.finish(); owner?.cancel()
        let calls = Array(active.values), retries = Array(retrying.values)
        for task in calls + retries { task.cancel() }
        await owner?.value
        for task in calls + retries { await task.value }
        entries.removeAll(); queued.removeAll(); queue.removeAll(); groupKeys.removeAll(); queuedKeys.removeAll()
        active.removeAll(); activeKeys.removeAll(); retrying.removeAll(); activePeers.removeAll()
    }
}
