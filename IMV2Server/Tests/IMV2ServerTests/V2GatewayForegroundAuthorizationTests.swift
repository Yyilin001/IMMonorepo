@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

@Suite("Gateway foreground authorization")
struct V2GatewayForegroundAuthorizationTests {
    private let version = UInt8(IMV2ProtocolVersion.current)

    @Test("foreground fast path stops at the exact authenticated lease expiry")
    func fastPathExpiresWithoutAnotherInboundCommand() async throws {
        let clock = AuthorizationTestClock(Date(timeIntervalSince1970: 10))
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: ExpiringAuthorizationAuthenticator(),
            capabilityProfile: "base",
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { clock.read() }
        )
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])
        let stream = V2GatewayByteStream(
            frameLimits: limits, session: session,
            handler: AuthorizationCommandHandler(), registry: V2DeviceConnectionRegistry()
        )
        let writes = AuthorizationWriteCount()
        #expect(await stream.attachTransport(
            deviceRevocationHandler: {}, outboundWriter: { _ in },
            foregroundWriter: { _ in writes.increment() }
        ))
        try await authenticate(stream, limits: limits)
        let prepared = try #require(V2PreparedGatewayGroupEventAvailable(
            roomID: try RoomID("00000000-0000-0000-0000-000000000e01"),
            highWatermark: 1, directEvent: nil, frameLimits: limits,
            protocolVersion: version
        ))
        #expect(stream.submitGroupEventAvailable(prepared))
        #expect(writes.read() == 1)
        clock.set(Date(timeIntervalSince1970: 11))
        #expect(!stream.submitGroupEventAvailable(prepared))
        #expect(writes.read() == 1)
        try await stream.finish()
    }

    @Test("synchronous invalidation rejects foreground and session work before actor cleanup")
    func immediateInvalidationStopsNewWork() async throws {
        let clock = AuthorizationTestClock(Date(timeIntervalSince1970: 10))
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: ExpiringAuthorizationAuthenticator(),
            capabilityProfile: "base",
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { clock.read() }
        )
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])
        let stream = V2GatewayByteStream(
            frameLimits: limits, session: session,
            handler: AuthorizationCommandHandler(), registry: V2DeviceConnectionRegistry()
        )
        #expect(await stream.attachTransport(
            deviceRevocationHandler: {}, outboundWriter: { _ in },
            foregroundWriter: { _ in }
        ))
        try await authenticate(stream, limits: limits)
        let prepared = try #require(V2PreparedGatewayGroupEventAvailable(
            roomID: try RoomID("00000000-0000-0000-0000-000000000e02"),
            highWatermark: 1, directEvent: nil, frameLimits: limits,
            protocolVersion: version
        ))
        #expect(stream.submitGroupEventAvailable(prepared))
        stream.invalidateForegroundAuthorization()
        #expect(!stream.submitGroupEventAvailable(prepared))

        var heartbeat = IMV2Envelope()
        heartbeat.requestID = 3
        heartbeat.protocolVersion = UInt32(version)
        heartbeat.heartbeat = .init()
        let frame = try V2ServerProtobufFrameCodec.encode(heartbeat, frameVersion: version)
        await #expect(throws: V2GatewaySessionError.unsupportedCommand) {
            _ = try await session.receiveAuthenticated(frame, handler: AuthorizationCommandHandler())
        }
        try await stream.finish()
    }

    @Test("invalidation during asynchronous admission stops command dispatch")
    func invalidationDuringAdmission() async throws {
        let admission = SuspendedAuthorizationAdmission()
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: ExpiringAuthorizationAuthenticator(),
            capabilityProfile: "base", commandAdmission: admission,
            now: { Date(timeIntervalSince1970: 10) }
        )
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])
        let handler = CountingAuthorizationHandler()
        let stream = V2GatewayByteStream(
            frameLimits: limits, session: session, handler: handler,
            registry: V2DeviceConnectionRegistry()
        )
        try await authenticate(stream, limits: limits)

        var request = IMV2Envelope()
        request.requestID = 3
        request.protocolVersion = UInt32(version)
        request.syncPull = .init()
        let frame = try V2ServerProtobufFrameCodec.encode(request, frameVersion: version)
        let pending = Task {
            try await session.receiveAuthenticated(frame, handler: handler)
        }
        await admission.waitUntilEntered()
        stream.invalidateForegroundAuthorization()
        await admission.release()
        await #expect(throws: V2GatewaySessionError.unsupportedCommand) {
            _ = try await pending.value
        }
        #expect(await handler.callCount() == 0)
        try await stream.finish()
    }

    @Test("unregister revokes the foreground fast path before suspended interest cleanup")
    func unregisterRevokesBeforeInterestCleanup() async throws {
        let registry = V2DeviceConnectionRegistry()
        let interests = SuspendedAuthorizationInterestCleanup()
        await registry.configureUserSyncInterests(V2SharedGroupEventWakeInterests(underlying: interests))
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: ExpiringAuthorizationAuthenticator(userID: "00000000-0000-0000-0000-000000000e03"),
            capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { Date(timeIntervalSince1970: 10) }
        )
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])
        let connectionID = UUID()
        let stream = V2GatewayByteStream(frameLimits: limits, session: session,
            handler: AuthorizationCommandHandler(), connectionID: connectionID, registry: registry)
        let writes = AuthorizationWriteCount()
        #expect(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            foregroundWriter: { _ in writes.increment() }))
        try await authenticate(stream, limits: limits)
        await interests.waitForActivation()
        let prepared = try #require(V2PreparedGatewayGroupEventAvailable(
            roomID: try RoomID("00000000-0000-0000-0000-000000000e04"),
            highWatermark: 1, directEvent: nil, frameLimits: limits, protocolVersion: version))
        #expect(stream.submitGroupEventAvailable(prepared))
        let close = Task { await registry.unregister(connectionID: connectionID) }
        await interests.waitForRemoval()
        #expect(!stream.submitGroupEventAvailable(prepared))
        #expect(writes.read() == 1)
        await interests.releaseRemoval()
        await close.value
        try await stream.finish()
        await registry.shutdownRealtimeRecovery()
    }

    private func authenticate(_ stream: V2GatewayByteStream, limits: V2FrameLimits) async throws {
        let device = "00000000-0000-0000-0000-000000000A02"
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello.deviceID = device
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        let helloFrame = try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0)
        _ = try await stream.receive(try V2FrameCodec.encode(helloFrame, limits: limits))

        var authentication = IMV2Envelope()
        authentication.requestID = 2
        authentication.protocolVersion = UInt32(version)
        authentication.authenticate.accessToken = "opaque"
        authentication.authenticate.deviceID = device
        let authFrame = try V2ServerProtobufFrameCodec.encode(authentication, frameVersion: version)
        _ = try await stream.receive(try V2FrameCodec.encode(authFrame, limits: limits))
    }
}

private final class AuthorizationTestClock: Sendable {
    private let value: Mutex<Date>
    init(_ initial: Date) { value = Mutex(initial) }
    func read() -> Date { value.withLock { $0 } }
    func set(_ date: Date) { value.withLock { $0 = date } }
}

private final class AuthorizationWriteCount: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    func read() -> Int { value.withLock { $0 } }
}

private struct ExpiringAuthorizationAuthenticator: V2GatewayAuthenticator {
    var userID = "user-a"
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init(userID), expiresAt: Date(timeIntervalSince1970: 11))
    }
}

private actor SuspendedAuthorizationInterestCleanup: V2GroupEventWakeInterestManaging {
    private var activated = false
    private var activationWaiters: [CheckedContinuation<Void, Never>] = []
    private var removal: CheckedContinuation<Void, Never>?
    private var removalWaiters: [CheckedContinuation<Void, Never>] = []
    func activate(roomID _: RoomID) {
        activated = true
        for waiter in activationWaiters { waiter.resume() }
        activationWaiters.removeAll()
    }
    func deactivate(roomID _: RoomID) async {
        await withCheckedContinuation { continuation in
            removal = continuation
            for waiter in removalWaiters { waiter.resume() }
            removalWaiters.removeAll()
        }
    }
    func waitForActivation() async {
        if activated { return }
        await withCheckedContinuation { activationWaiters.append($0) }
    }
    func waitForRemoval() async {
        if removal != nil { return }
        await withCheckedContinuation { removalWaiters.append($0) }
    }
    func releaseRemoval() { removal?.resume(); removal = nil }
}

private struct AuthorizationCommandHandler: V2GatewayCommandHandler {
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        var response = IMV2Envelope()
        response.error.code = "UNAVAILABLE"
        return response
    }
}

private actor SuspendedAuthorizationAdmission: V2AuthenticatedGatewayCommandAdmitting {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func admit(identity _: V2AuthenticatedConnection, cost _: Int, now _: Date) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for waiter in enteredWaiters { waiter.resume() }
            enteredWaiters.removeAll()
        }
    }

    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        continuation?.resume(returning: true)
        continuation = nil
    }
}

private actor CountingAuthorizationHandler: V2GatewayCommandHandler {
    private var calls = 0
    func callCount() -> Int { calls }
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) -> IMV2Envelope {
        calls += 1
        var response = IMV2Envelope()
        response.error.code = "UNAVAILABLE"
        return response
    }
}
