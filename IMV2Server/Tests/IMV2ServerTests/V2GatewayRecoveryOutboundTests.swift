@testable import IMV2ServerGateway
import Foundation
import IMV2Core
import IMV2ServerContracts
import Synchronization
import Testing

struct V2GatewayRecoveryOutboundTests {
    @Test("Closing joins the actual retained-control worker and revokes its selected socket permit")
    func closeJoinsActualControlWorker() async throws {
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])
        let stream = V2GatewayByteStream(frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 4),
                authenticator: RecoveryOutboundAuthenticator(), capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: RecoveryOutboundCommandHandler(), registry: V2DeviceConnectionRegistry())
        let started = RecoveryOutboundSignal(), release = RecoveryOutboundSignal()
        let cancelled = RecoveryOutboundSignal(), settled = RecoveryOutboundSignal(), finished = RecoveryOutboundSignal()
        let selected = Mutex<V2GatewayScopedNotificationWrite?>(nil)
        defer { release.mark() }
        #expect(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            scopedNotificationWriter: { write in
                selected.withLock { $0 = write }; started.mark()
                return await withTaskCancellationHandler {
                    // Deliberately ignore cancellation until the actual callback
                    // is released, so cancellation cannot masquerade as drain.
                    await release.wait()
                    let accepted = write.enqueueIfCurrent { Issue.record("A closed connection accepted a retained control write") }
                    settled.mark()
                    return accepted
                } onCancel: { cancelled.mark() }
            }))
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: limits))
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "opaque"; auth.authenticate.deviceID = hello.clientHello.deviceID
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version), limits: limits))
        let room = try RoomID("00000000-0000-0000-0000-000000000A03")
        await stream.sendRealtimeCoverage(scope: .room, scopeID: room.rawValue,
            scopeGeneration: 1, ready: false, reason: .installing,
            scopePermit: { enqueue in enqueue(); return true })
        let until = ContinuousClock.now + .seconds(3)
        while !started.isMarked {
            guard ContinuousClock.now < until else { throw RecoveryOutboundTestFailure.timeout }
            await Task.yield()
        }
        let write = try #require(selected.withLock { $0 })
        let closing = Task {
            try await stream.finish()
            #expect(settled.isMarked) // finish cannot publish completion ahead of its actual writer.
            finished.mark()
        }
        await cancelled.wait()
        #expect(!finished.isMarked && !settled.isMarked)
        #expect(await stream.recoveryOutboundSnapshot().revoked)
        #expect(!write.enqueueIfCurrent { Issue.record("A late selected permit survived connection close") })
        release.mark()
        try await closing.value
        #expect(settled.isMarked && finished.isMarked)
    }

    @Test("a selected coverage notification cannot enter the socket after session expiry")
    func expiryRejectsSelectedCoverageWrite() async throws {
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])
        let clock = Mutex(Date(timeIntervalSince1970: 10))
        let stream = V2GatewayByteStream(frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 4),
                authenticator: RecoveryOutboundAuthenticator(expiresAt: Date(timeIntervalSince1970: 11)),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission(),
                now: { clock.withLock { $0 } }),
            handler: RecoveryOutboundCommandHandler(), registry: V2DeviceConnectionRegistry())
        let selected = RecoveryOutboundSignal(), release = RecoveryOutboundSignal(), settled = RecoveryOutboundSignal()
        defer { release.mark() }
        let accepted = Mutex(false)
        let readyAdmitted = RecoveryOutboundSignal()
        #expect(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            scopedNotificationWriter: { write in
                selected.mark()
                await release.wait()
                let result = write.enqueueIfCurrent { Issue.record("Expired coverage entered the socket") }
                accepted.withLock { $0 = result }; settled.mark()
                return result
            }))
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: limits))
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "opaque"; auth.authenticate.deviceID = hello.clientHello.deviceID
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version), limits: limits))
        await stream.sendRealtimeCoverage(scope: .directory, scopeID: "user-a", scopeGeneration: 1,
            ready: false, reason: .installing, scopePermit: { enqueue in enqueue(); return true })
        await selected.wait()
        await stream.sendRealtimeCoverage(scope: .directory, scopeID: "user-a", scopeGeneration: 1,
            ready: true, reason: .unspecified, confirms: { true },
            scopePermit: { enqueue in enqueue(); return true }, onReadyAdmitted: { readyAdmitted.mark() })
        #expect(!readyAdmitted.isMarked)
        clock.withLock { $0 = Date(timeIntervalSince1970: 11) }
        release.mark()
        await settled.wait()
        #expect(!accepted.withLock { $0 })
        // Session expiry, rather than a transport close, rejected this write.
        #expect(!(await stream.recoveryOutboundSnapshot()).revoked)
        try await stream.finish()
        #expect(!readyAdmitted.isMarked)
    }

    @Test("Retained Recovering does not acknowledge admission and cannot be overtaken by H or Ready",
          arguments: [IMV2RealtimeCoverage.Scope.room, .directory])
    func coveragePredecessorOrdering(scope: IMV2RealtimeCoverage.Scope) async throws {
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])
        let stream = V2GatewayByteStream(frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 4),
                authenticator: RecoveryOutboundAuthenticator(), capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: RecoveryOutboundCommandHandler(), registry: V2DeviceConnectionRegistry())
        let recorder = RecoveryOutboundWireRecorder()
        let readyAdmitted = RecoveryOutboundSignal()
        #expect(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            scopedNotificationWriter: { recorder.write($0) }))
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: limits))
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "opaque"; auth.authenticate.deviceID = hello.clientHello.deviceID
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version), limits: limits))
        let room = try RoomID("00000000-0000-0000-0000-000000000A03")
        let permit: @Sendable (@Sendable () -> Void) -> Bool = { enqueue in enqueue(); return true }
        await stream.sendRealtimeCoverage(scope: scope, scopeID: room.rawValue,
            scopeGeneration: 1, ready: false, reason: .installing, scopePermit: permit)
        #expect(recorder.frames.isEmpty)
        #expect(!(await stream.retainGroupEventAvailable(roomID: room, highWatermark: 7, enqueueIfCurrent: permit)))
        await stream.sendRealtimeCoverage(scope: scope, scopeID: room.rawValue,
            scopeGeneration: 1, highWatermark: 7, ready: true, reason: .unspecified,
            confirms: { true }, scopePermit: permit, onReadyAdmitted: { readyAdmitted.mark() })
        #expect(!readyAdmitted.isMarked)
        #expect(recorder.frames.isEmpty)
        recorder.enable()
        // The caller does not submit Ready again: the original successor must
        // survive predecessor rejection and be delivered by the owned retry.
        let until = ContinuousClock.now + .seconds(3)
        while true {
            let ready = try recorder.frames.contains { bytes in
                let envelope = try V2ServerProtobufFrameCodec.decode(V2FrameCodec.decodeExactlyOne(bytes, limits: limits))
                if case .realtimeCoverage(let state) = envelope.body { return state.state == .ready }
                return false
            }
            if ready { break }
            guard ContinuousClock.now < until else { throw RecoveryOutboundTestFailure.timeout }
            await Task.yield()
        }
        await readyAdmitted.wait()
        #expect(readyAdmitted.isMarked)
        #expect(await stream.retainGroupEventAvailable(roomID: room, highWatermark: 7, enqueueIfCurrent: permit))
        let envelopes = try recorder.frames.map {
            try V2ServerProtobufFrameCodec.decode(V2FrameCodec.decodeExactlyOne($0, limits: limits))
        }
        let headIndex = try #require(envelopes.firstIndex { if case .groupEventAvailable = $0.body { return true }; return false })
        let readyIndex = try #require(envelopes.firstIndex { if case .realtimeCoverage(let state) = $0.body { return state.state == .ready }; return false })
        #expect(headIndex > 0 && readyIndex > 0)
        if case .realtimeCoverage(let first) = envelopes.first?.body {
            #expect(first.state == .recovering)
        } else { Issue.record("Recovering predecessor was not first") }
        try await stream.finish()
    }

    @Test("A suspended socket operation retains one bounded slot without delaying another connection")
    func slowConnectionDoesNotBlockAnother() async {
        let slow = V2GatewayRecoveryOutbound(), fast = V2GatewayRecoveryOutbound()
        let started = RecoveryOutboundGate(), release = RecoveryOutboundGate()
        let slowResults = RecoveryOutboundResults(), fastResults = RecoveryOutboundResults()
        #expect(await slow.offer(kind: 1, operation: {
            await started.open(); await release.wait(); return true
        }, onSettled: { await slowResults.append($0) }))
        await started.wait()
        #expect(await fast.offer(kind: 1, operation: { true }, onSettled: { await fastResults.append($0) }))
        await fastResults.waitForCount(1)
        #expect(await fastResults.values == [true])
        let snapshot = await slow.snapshot()
        #expect(snapshot.retained == 1 && snapshot.executing)
        #expect(!(await slow.offer(kind: 1, operation: { true }, onSettled: { _ in })))
        await release.open()
        await slowResults.waitForCount(1)
        #expect(await slowResults.values == [true])
        await slow.drain(); await fast.drain()
    }

    @Test("Revocation settles queued handoffs once and preserves the actual executing slot until completion")
    func revocationKeepsActualOwnership() async {
        let owner = V2GatewayRecoveryOutbound(), started = RecoveryOutboundGate(), release = RecoveryOutboundGate()
        let results = RecoveryOutboundResults(), unexpectedlyExecuted = RecoveryOutboundResults()
        #expect(await owner.offer(kind: 1, operation: {
            await started.open(); await release.wait(); return true
        }, onSettled: { await results.append($0) }))
        await started.wait()
        for kind in 2...5 {
            #expect(await owner.offer(kind: kind, operation: {
                await unexpectedlyExecuted.append(true); return true
            }, onSettled: { await results.append($0) }))
        }
        #expect(!(await owner.offer(kind: 6, operation: { true }, onSettled: { _ in })))
        #expect(owner.enqueueIfActive { true })
        owner.revoke()
        #expect(!owner.enqueueIfActive { Issue.record("A revoked connection must not reach actual enqueue"); return true })
        #expect(!(await owner.offer(kind: 2, operation: { true }, onSettled: { _ in })))
        let snapshot = await owner.snapshot()
        #expect(snapshot.retained == 5 && snapshot.executing && snapshot.revoked)
        await release.open()
        await owner.drain()
        #expect(await results.values == [false, false, false, false, false])
        #expect(await unexpectedlyExecuted.values.isEmpty)
        #expect(await owner.snapshot().retained == 0)
    }
}

private enum RecoveryOutboundTestFailure: Error { case timeout }

private final class RecoveryOutboundSignal: Sendable {
    private struct State { var marked = false; var waiters: [CheckedContinuation<Void, Never>] = [] }
    private let state = Mutex(State())
    var isMarked: Bool { state.withLock { $0.marked } }
    func mark() {
        let waiters = state.withLock { state in
            state.marked = true
            let waiters = state.waiters; state.waiters.removeAll(); return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyMarked = state.withLock { state in
                if state.marked { return true }
                state.waiters.append(continuation); return false
            }
            if alreadyMarked { continuation.resume() }
        }
    }
}

private final class RecoveryOutboundWireRecorder: Sendable {
    private struct State { var enabled = false; var frames: [Data] = [] }
    private let state = Mutex(State())
    var frames: [Data] { state.withLock { $0.frames } }
    func enable() { state.withLock { $0.enabled = true } }
    func write(_ write: V2GatewayScopedNotificationWrite) -> Bool {
        guard state.withLock({ $0.enabled }) else { return false }
        return write.enqueueIfCurrent { self.append(write.bytes) }
    }
    private func append(_ bytes: Data) { state.withLock { $0.frames.append(bytes) } }
}

private struct RecoveryOutboundAuthenticator: V2GatewayAuthenticator {
    var expiresAt: Date? = nil
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init("user-a"), expiresAt: expiresAt)
    }
}

private struct RecoveryOutboundCommandHandler: V2GatewayCommandHandler {
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        var response = IMV2Envelope(); response.acknowledged = .init(); return response
    }
}

private actor RecoveryOutboundGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let current = waiters; waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private actor RecoveryOutboundResults {
    private(set) var values: [Bool] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func append(_ result: Bool) {
        values.append(result)
        let ready = waiters.filter { $0.0 <= values.count }
        waiters.removeAll { $0.0 <= values.count }
        for (_, waiter) in ready { waiter.resume() }
    }
    func waitForCount(_ count: Int) async {
        if values.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
