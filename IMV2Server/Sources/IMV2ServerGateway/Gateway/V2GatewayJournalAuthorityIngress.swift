import Foundation
import Synchronization
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts

public struct V2GatewayJournalRecoveryControls: Sendable {
    public var versions: [UserID: UInt64] = [:]
    public var devices: Set<V2RealtimeJournalDeviceKey> = []
    public var membershipRooms: [UserID: Set<RoomID>] = [:]
    public var membershipVersions: [UserID: UInt64] = [:]
    public init() {}
}

/// The signed RPC remains synchronous. Database recovery and local notification
/// are owned by four bounded consumers and joined at shutdown. Remote inputs
/// request recovery; only the trusted recover callback can install authority.
public final class V2GatewayJournalAuthorityIngress: V2RealtimeJournalProjectionHandler, Sendable {
    public typealias Recover = @Sendable (V2RealtimeJournalProjectionBatch, String, Int64) async throws -> Void
    public typealias RecoverControls = @Sendable (V2RealtimeJournalProjectionBatch, String, Int64, V2GatewayJournalRecoveryControls) async throws -> Void
    public typealias Notify = @Sendable (Set<RoomID>) async -> Void
    private struct Request: Sendable {
        var batch: V2RealtimeJournalProjectionBatch
        var service: String
        var minimumCut: Int64
        var needsRecovery: Bool
        var rooms: Set<RoomID>
        var controls: V2GatewayJournalRecoveryControls
    }
    private struct State: Sendable {
        var pending: [V2RealtimeJournalSource: Request] = [:]
        var active: Set<V2RealtimeJournalSource> = []
        var queued: Set<V2RealtimeJournalSource> = []
        var order: [V2RealtimeJournalSource] = []
        var offset = 0
        var consumers: [Task<Void, Never>] = []
        var closed = false
    }
    private let state = Mutex(State())
    private let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(4))
    private let receiver: V2GatewayJournalProjectionReceiver
    private let recover: Recover
    private let recoverControls: RecoverControls?
    private let notify: Notify
    private let maximumSources: Int
    public init(receiver: V2GatewayJournalProjectionReceiver, maximumSources: Int = 256,
                recoverControls: RecoverControls? = nil, recover: @escaping Recover, notify: @escaping Notify) {
        precondition(maximumSources > 0)
        self.receiver = receiver; self.maximumSources = maximumSources
        self.recover = recover; self.notify = notify
        self.recoverControls = recoverControls
    }
    public func start() {
        state.withLock { value in
            guard !value.closed, value.consumers.isEmpty else { return }
            value.consumers = (0..<4).map { _ in Task { await self.consume() } }
        }
    }
    public func applyJournalProjection(_ batch: V2RealtimeJournalProjectionBatch,
                                       authenticatedServiceID: String) -> V2RealtimeJournalProjectionResult {
        guard state.withLock({ !$0.closed && !$0.consumers.isEmpty }) else { return .stale }
        let result = receiver.applyJournalProjection(batch, authenticatedServiceID: authenticatedServiceID)
        let needsRecovery: Bool
        switch result {
        case .applied, .headsApplied: needsRecovery = false
        case .snapshotRequired, .stale: needsRecovery = true
        case .invalid, .overloaded: return result
        }
        let cut: Int64
        var rooms: Set<RoomID> = []
        var controls = V2GatewayJournalRecoveryControls()
        switch batch.payload {
        case .baseline(let minimum): cut = minimum
        case .snapshot(let minimum, let grants): cut = minimum; rooms = Set(grants.map(\.roomID))
        case .heads(let heads): cut = 0; rooms = Set(heads.map(\.roomID))
        case .changes(_, let through, let entries):
            cut = through
            for entry in entries {
                switch entry.change {
                case .userControlInvalidation(let user, let version, let device, let membershipRoom):
                    if let membershipRoom {
                        controls.membershipRooms[user, default: []].insert(membershipRoom)
                        controls.membershipVersions[user] = max(controls.membershipVersions[user] ?? 0, version)
                    }
                    controls.versions[user] = max(controls.versions[user] ?? 0, version)
                    if let device, let userUUID = user.uuidValue { controls.devices.insert(.init(userID: userUUID, deviceID: device)) }
                case .authorization(let room): rooms.insert(room.roomID)
                case .head(let room, _, _, _), .invalidate(let room), .controlInvalidation(let room, _, _): rooms.insert(room)
                }
            }
        }
        guard cut >= 0 else { return .invalid }
        // A successful baseline has no new local dirty work to announce.
        if !needsRecovery && rooms.isEmpty { return result }
        let accepted = state.withLock { value -> Bool in
            guard !value.closed else { return false }
            guard value.pending[batch.source] != nil || value.active.contains(batch.source)
                    || value.pending.count + value.active.count < maximumSources else { return false }
            let old = value.pending[batch.source]
            let same = old.map { $0.batch.fence.sameGeneration(as: batch.fence) && $0.service == authenticatedServiceID } ?? false
            var mergedControls = same ? old!.controls : V2GatewayJournalRecoveryControls()
            for (user, version) in controls.versions { mergedControls.versions[user] = max(mergedControls.versions[user] ?? 0, version) }
            for (user, version) in controls.membershipVersions { mergedControls.membershipVersions[user] = max(mergedControls.membershipVersions[user] ?? 0, version) }
            mergedControls.devices.formUnion(controls.devices)
            for (user, rooms) in controls.membershipRooms { mergedControls.membershipRooms[user, default: []].formUnion(rooms) }
            guard mergedControls.membershipRooms.values.reduce(0, { $0 + $1.count }) <= 4096 else { return false }
            guard mergedControls.versions.count <= 4096, mergedControls.devices.count <= 4096 else { return false }
            value.pending[batch.source] = Request(batch: batch, service: authenticatedServiceID,
                minimumCut: same ? max(old!.minimumCut, cut) : cut,
                needsRecovery: needsRecovery || (same && old!.needsRecovery),
                rooms: same ? old!.rooms.union(rooms) : rooms, controls: mergedControls)
            if !value.active.contains(batch.source), value.queued.insert(batch.source).inserted {
                value.order.append(batch.source)
            }
            return true
        }
        guard accepted else { return .overloaded }
        signal.continuation.yield(())
        return needsRecovery ? .snapshotRequired : result
    }
    private func next() -> (V2RealtimeJournalSource, Request)? {
        state.withLock { value in
            guard !value.closed, value.offset < value.order.count else { return nil }
            let source = value.order[value.offset]; value.offset += 1
            value.queued.remove(source)
            if value.offset >= 64 { value.order.removeFirst(value.offset); value.offset = 0 }
            guard let request = value.pending.removeValue(forKey: source) else { return nil }
            value.active.insert(source)
            return (source, request)
        }
    }
    private func consume() async {
        for await _ in signal.stream {
            while let (source, request) = next() {
                do {
                    if request.needsRecovery {
                        if let recoverControls { try await recoverControls(request.batch, request.service, request.minimumCut, request.controls) }
                        else { try await recover(request.batch, request.service, request.minimumCut) }
                    }
                    if !Task.isCancelled { await notify(request.rooms) }
                } catch {
                    // The sender retains source ACK/replay responsibility. No
                    // failed cold read is converted to an applied RPC receipt.
                }
                let pending = state.withLock { value -> Bool in
                    value.active.remove(source)
                    if !value.closed, value.pending[source] != nil, value.queued.insert(source).inserted {
                        value.order.append(source); return true
                    }
                    return false
                }
                if pending { signal.continuation.yield(()) }
            }
        }
    }
    public func shutdown() async {
        let tasks = state.withLock { value in
            value.closed = true; value.pending.removeAll(); value.order.removeAll(); value.queued.removeAll()
            return value.consumers
        }
        signal.continuation.finish()
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        receiver.shutdown()
    }
}
