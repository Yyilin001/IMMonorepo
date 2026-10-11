import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import Testing
@testable import IMV2ServerGateway

@Suite("Recovery scheduler ownership and tail progress")
struct V2RecoverySchedulerOwnershipTests {
    @Test("unrepresented scopes refill after actual query return and successful Ready position release", arguments: [false, true])
    func tailScopeBeyondCapacityProgresses(successfulOutput: Bool) async throws {
        let coordinator = V2RealtimeRecoveryCoordinator(maximumConnections: 2_000)
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        let queries = SchedulerOwnershipQueries()
        let confirmation = makeConfirmation()
        let writes = SchedulerSuccessfulWrites()
        func diagnostics() async -> String {
            let admission = await coordinator.schedulingAdmissionSnapshot()
            let recovery = await coordinator.realtimeRecoverySnapshot()
            let owners = await coordinator.schedulingOwnershipSnapshot()
            let provider = await queries.diagnosticSnapshot()
            return "successfulOutput=\(successfulOutput), admission=\(admission), recovery=\(recovery), scheduler=\(owners), provider=\(provider), ready=\(writes.readyCount), refused=\(writes.refusedPresenceWrites)"
        }
        do {
        var entries: [(context: V2RealtimeRecoveryConnectionContext, room: RoomID, target: UserID)] = []
        for index in 0..<(successfulOutput ? 1_101 : 1_100) {
            let context = successfulOutput
                ? try await makeAuthenticatedContext(registry: registry, lifecycle: UInt64(index + 1), writes: writes)
                : try makeContext(registry: registry, lifecycle: UInt64(index + 1))
            entries.append((context, RoomID(uuid: UUID()), UserID(uuid: UUID())))
        }
        let byConnection = Dictionary(uniqueKeysWithValues: entries.map { ($0.context.handle.connectionID, $0) })
        await coordinator.configureLiveActivity(SchedulerOwnershipInterests())
        await coordinator.configureCoverage(current: { _, _ in confirmation }, confirms: { _, _, _ in true })
        coordinator.configurePorts(.init(preparePresence: { key, lifecycle, generation in
            guard let entry = byConnection[key.connection], key.id == entry.target.rawValue else {
                throw SchedulerOwnershipFailure.firstQuery
            }
            return try await queries.preparePresence(.init(connection: key.connection, lifecycle: lifecycle,
                generation: generation, request: .init(roomID: entry.room,
                    viewerUserID: entry.context.handle.identity.userID, targetUserID: entry.target),
                stream: entry.context.handle.stream,
                state: .init(roomID: entry.room, targetUserID: entry.target, isOnline: true, expiresAt: Date().addingTimeInterval(30)),
                deadline: .now + .seconds(30)))
        }, compensateScope: { _, _, _, _ in }))
        if successfulOutput {
            await queries.releaseAll()
            let entry = entries[0]
            coordinator.installConnection(entry.context)
            await coordinator.beginScopeRecovery(connection: entry.context.handle.connectionID,
                kind: .userPresence, id: entry.target.rawValue)
            try await wait(diagnostic: diagnostics) {
                let state = await coordinator.realtimeRecoverySnapshot()
                return writes.readyCount == 1 && state.desired == 0
            }
            await queries.pause()
        }
        let queued = successfulOutput ? Array(entries.dropFirst()) : entries
        for (index, entry) in queued.enumerated() {
            coordinator.installConnection(entry.context)
            await coordinator.beginScopeRecovery(connection: entry.context.handle.connectionID,
                kind: .userPresence, id: entry.target.rawValue)
            if index < 4 { try await wait(diagnostic: diagnostics) { await queries.held == index + 1 } }
        }
        let saturated = await coordinator.realtimeRecoverySnapshot()
        #expect(saturated.desired > 1024)
        #expect(saturated.queryRoots == 4)
        #expect(saturated.positions <= 1024)
        // All 1,100 demands are installed, including the unrepresented tail.
        // No new begin/invalidation may rescue it after actual query return.
        let tail = try #require(queued.last).room
        #expect(!(await queries.seen.contains(tail)))
        await queries.releaseAll()
        // Demand was already installed. No extra invalidate or begin call may
        // rescue the tail after the first actual query positions are returned.
        try await wait(diagnostic: diagnostics) { await queries.seen.contains(tail) }
        if successfulOutput {
            // All scopes, including at least 76 originally outside the position
            // ledger, must finish on real accepted writes. No refused-output
            // retry timer is available to rescue refill after successful Ready.
            try await wait(diagnostic: diagnostics) {
                let state = await coordinator.realtimeRecoverySnapshot()
                return state.desired == 0 && writes.readyCount == 1_101
            }
            #expect(writes.refusedPresenceWrites == 0)
            #expect(await queries.seen.count == 1_101)
        }
        let progressed = await coordinator.realtimeRecoverySnapshot()
        #expect(progressed.positions <= 1024)
        #expect(progressed.queryRoots <= 4 && progressed.interest <= 4 && progressed.control <= 4)
        await coordinator.shutdown()
        #expect(await coordinator.realtimeRecoverySnapshot().actual == 0)
        let scheduling = await coordinator.schedulingOwnershipSnapshot()
        #expect(scheduling.scheduler == 0 && scheduling.wake == 0)
        await registry.shutdownRealtimeRecovery()
        } catch {
            await queries.releaseAll()
            await coordinator.shutdown()
            await registry.shutdownRealtimeRecovery()
            throw error
        }
    }

    @Test("a future retry wakes without new input and shutdown joins its real query")
    func retryWakeAndActualShutdownOwnership() async throws {
        let coordinator = V2RealtimeRecoveryCoordinator()
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        let queries = SchedulerOwnershipQueries(failFirst: true)
        let confirmation = makeConfirmation()
        do {
        await coordinator.configureLiveActivity(SchedulerOwnershipInterests())
        await coordinator.configureCoverage(current: { _, _ in confirmation }, confirms: { _, _, _ in true })
        let context = try makeContext(registry: registry, lifecycle: 1)
        let room = RoomID(uuid: UUID()), target = UserID(uuid: UUID())
        coordinator.configurePorts(.init(preparePresence: { key, lifecycle, generation in
            try await queries.preparePresence(.init(connection: key.connection, lifecycle: lifecycle,
                generation: generation, request: .init(roomID: room,
                    viewerUserID: context.handle.identity.userID, targetUserID: target), stream: context.handle.stream,
                state: .init(roomID: room, targetUserID: target, isOnline: true, expiresAt: Date().addingTimeInterval(30)),
                deadline: .now + .seconds(30)))
        }, compensateScope: { _, _, _, _ in }))
        coordinator.installConnection(context)
        await coordinator.beginScopeRecovery(connection: context.handle.connectionID, kind: .userPresence, id: target.rawValue)
        // Only the original begin is sent. The second real provider call must
        // be started by the scheduler's retained future-retry ownership.
        try await wait {
            let calls = await queries.calls
            let held = await queries.held
            return calls == 2 && held == 1
        }
        // The failed attempt returned its existing position to queued retry.
        // Its real timer must start the second query without a primary round.
        #expect((coordinator.schedulingTelemetrySnapshot().scans[.desired] ?? 0) == 0)
        let activeMetrics = await coordinator.registryRecoveryMetricsSnapshot()
        #expect(activeMetrics.stages[.presence]?[.actualScopes]?.count == 1)
        #expect(activeMetrics.recoveryAttemptStages[.queryRoot]?.count == 1)
        let completed = Mutex(false)
        let shutdown = Task { await coordinator.shutdown(); completed.withLock { $0 = true } }
        try await wait { await coordinator.realtimeRecoverySnapshot().closed }
        #expect(!completed.withLock { $0 })
        let held = await coordinator.realtimeRecoverySnapshot()
        #expect(held.queryRoots == 1)
        await queries.releaseAll()
        await shutdown.value
        let drained = await coordinator.realtimeRecoverySnapshot()
        #expect(completed.withLock { $0 })
        #expect(drained.closed && drained.actual == 0 && drained.queryRoots == 0)
        let drainedMetrics = await coordinator.registryRecoveryMetricsSnapshot()
        #expect((drainedMetrics.stages[.presence]?[.actualScopes]?.count ?? 0) == 0)
        #expect((drainedMetrics.recoveryAttemptStages[.queryRoot]?.count ?? 0) == 0)
        let scheduling = await coordinator.schedulingOwnershipSnapshot()
        #expect(scheduling.scheduler == 0 && scheduling.wake == 0)
        await registry.shutdownRealtimeRecovery()
        } catch {
            await queries.releaseAll()
            await coordinator.shutdown()
            await registry.shutdownRealtimeRecovery()
            throw error
        }
    }

    private func makeConfirmation() -> V2RealtimeCoverageConfirmation {
        .init(token: .init(partitionID: 0, host: .init(nodeID: "fixture", serviceID: "fixture", incarnationID: UUID()),
            epoch: 1, leaseToken: UUID()), sessionID: UUID(), interestGeneration: 1,
            highWatermark: 0, deadline: .now + .seconds(30))
    }
    private func makeContext(registry: V2DeviceConnectionRegistry, lifecycle: UInt64) throws -> V2RealtimeRecoveryConnectionContext {
        let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), connection = UUID()
        let stream = V2GatewayByteStream(frameLimits: try .init(maximumPayloadBytes: 4096, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: SchedulerOwnershipAuthenticator(user: user),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: SchedulerOwnershipHandler(), connectionID: connection, registry: registry)
        return .init(handle: .init(connectionID: connection, lifecycle: lifecycle,
            identity: .init(userID: user, deviceID: device, capabilityProfile: "base"), stream: stream), accountScope: nil)
    }
    private func makeAuthenticatedContext(registry: V2DeviceConnectionRegistry, lifecycle: UInt64,
        writes: SchedulerSuccessfulWrites) async throws -> V2RealtimeRecoveryConnectionContext {
        let context = try makeContext(registry: registry, lifecycle: lifecycle)
        let stream = context.handle.stream, device = context.handle.identity.deviceID
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [0, version])
        #expect(await stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            scopedNotificationWriter: { writes.record($0) }))
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello.deviceID = device.rawValue
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: limits))
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = device.rawValue
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version), limits: limits))
        return context
    }
    private func wait(line: Int = #line, diagnostic: (() async -> String)? = nil,
        _ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else {
                throw SchedulerOwnershipFailure.timeout(line: line, detail: await diagnostic?() ?? "")
            }
            await Task.yield()
        }
    }
}
private enum SchedulerOwnershipFailure: Error { case timeout(line: Int, detail: String), firstQuery }
private struct SchedulerOwnershipAuthenticator: V2GatewayAuthenticator {
    let user: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        .init(userID: user, expiresAt: nil)
    }
}
private struct SchedulerOwnershipHandler: V2GatewayCommandHandler {
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope { .init() }
}
private actor SchedulerOwnershipInterests: V2LiveActivityInterestManaging, V2LiveActivityPublishing {
    func activatePresence(targetUserID _: UserID) {}
    func deactivatePresence(targetUserID _: UserID) {}
    func activateTyping(roomID _: RoomID) {}
    func deactivateTyping(roomID _: RoomID) {}
    func publishPresence(targetUserID _: UserID, isOnline _: Bool, expiresAt _: Date) {}
    func publishTyping(_: V2TypingState) {}
}
private actor SchedulerOwnershipQueries {
    private let failFirst: Bool
    private var released = false
    private var gates: [CheckedContinuation<Void, Never>] = []
    private(set) var seen: Set<RoomID> = []
    private(set) var calls = 0
    var held: Int { gates.count }
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    func diagnosticSnapshot() -> (calls: Int, held: Int, seen: Int) { (calls, gates.count, seen.count) }
    func preparePresence(_ proof: V2PreparedPresenceHandoff) async throws -> V2PreparedPresenceHandoff {
        try await awaitQuery(rooms: [proof.request.roomID])
        return proof
    }
    private func awaitQuery(rooms: Set<RoomID>) async throws {
        calls += 1; seen.formUnion(rooms)
        if failFirst && calls == 1 { throw SchedulerOwnershipFailure.firstQuery }
        if !released { await withCheckedContinuation { gates.append($0) } }
    }
    func pause() { released = false }
    func releaseAll() {
        released = true
        let current = gates; gates.removeAll()
        for gate in current { gate.resume() }
    }
}

private final class SchedulerSuccessfulWrites: Sendable {
    private let counts = Mutex((ready: 0, refused: 0))
    var readyCount: Int { counts.withLock { $0.ready } }
    var refusedPresenceWrites: Int { counts.withLock { $0.refused } }
    func record(_ write: V2GatewayScopedNotificationWrite) -> Bool {
        let version = UInt8(IMV2ProtocolVersion.current)
        var decoder = V2FrameDecoder(limits: try! .init(maximumPayloadBytes: 4096, acceptedVersions: [version]))
        guard let frame = try? decoder.append(write.bytes).first,
              let envelope = try? V2ServerProtobufFrameCodec.decode(frame) else { return false }
        let accepted = write.enqueueIfCurrent({})
        if case .realtimeCoverage(let coverage)? = envelope.body, coverage.scope == .presence {
            counts.withLock { counts in
                if !accepted { counts.refused += 1 }
                else if coverage.state == .ready { counts.ready += 1 }
            }
        }
        return accepted
    }
}
