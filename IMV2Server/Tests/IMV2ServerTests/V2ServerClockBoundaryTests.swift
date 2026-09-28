import Foundation
import IMV2Core
import Synchronization
import Testing
@testable import IMV2Server

@Suite("Server clock integer boundaries")
struct V2ServerClockBoundaryTests {
    @Test("Handshake and active-session clock failures retain their infrastructure classification",
          arguments: ["before-lookup", "during-lookup", "active-session"], [false, true])
    func gatewayHandshakeClock(stage: String, nonExpiring: Bool) async throws {
        let version = UInt8(IMV2ProtocolVersion.current)
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, Double(Int64.max) / 1_000] {
            let clock = BoundaryClock()
            clock.value = Date(timeIntervalSince1970: 1.25)
            let invalid = Date(timeIntervalSince1970: seconds)
            let adapter = HandshakeClockAuthenticator(clock: clock,
                completionClock: stage == "during-lookup" ? invalid : nil,
                expiresAt: nonExpiring ? nil : Date(timeIntervalSince1970: 60))
            let session = V2GatewaySession(limits: try .init(maximumInFlightRequests: 1),
                authenticator: adapter, capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission(), now: { clock.value })
            let handshakeDeviceID = UUID().uuidString
            var hello = IMV2Envelope(); hello.requestID = 1
            hello.clientHello.supportedProtocolVersions = [UInt32(version)]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            hello.clientHello.deviceID = handshakeDeviceID
            _ = try await session.receiveBootstrap(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0))
            var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
            auth.authenticate.accessToken = "local-clock-fixture"; auth.authenticate.deviceID = handshakeDeviceID
            let authFrame = try V2ServerProtobufFrameCodec.encode(auth, frameVersion: version)
            var heartbeat = IMV2Envelope(); heartbeat.requestID = 3; heartbeat.protocolVersion = UInt32(version)
            heartbeat.heartbeat = .init()
            let heartbeatFrame = try V2ServerProtobufFrameCodec.encode(heartbeat, frameVersion: version)

            if stage == "active-session" {
                _ = try await session.receiveBootstrap(authFrame)
                clock.value = invalid
                #expect(await session.authenticatedIdentity() == nil)
                #expect(await session.authenticatedProtocolVersion() == nil)
                #expect(await session.authenticatedFrameContract() == nil)
                await #expect(throws: V2GatewaySessionError.invalidServerClock) {
                    try await session.receiveAuthenticated(heartbeatFrame, handler: BoundaryHandler())
                }
            } else {
                if stage == "before-lookup" { clock.value = invalid }
                await #expect(throws: V2GatewaySessionError.invalidServerClock) {
                    try await session.receiveBootstrap(authFrame)
                }
                #expect(await adapter.calls() == (stage == "before-lookup" ? 0 : 1))
            }
            clock.value = Date(timeIntervalSince1970: 2.5)
            if stage == "during-lookup" {
                // The transport closes a failed in-progress handshake. A
                // corrected clock alone must not complete that handshake.
                #expect(await session.authenticatedIdentity() == nil)
                #expect(await session.authenticatedProtocolVersion() == nil)
                #expect(await session.authenticatedFrameContract() == nil)
            } else {
                if stage == "before-lookup" {
                    let response = try await session.receiveBootstrap(authFrame)
                    #expect(try V2ServerProtobufFrameCodec.decode(response).authenticated.deviceID == handshakeDeviceID)
                }
                let response = try await session.receiveAuthenticated(heartbeatFrame, handler: BoundaryHandler())
                #expect(try V2ServerProtobufFrameCodec.decode(response).heartbeatAck.serverTimeMs == 2_500)
                #expect(await session.authenticatedIdentity() != nil)
                #expect(await session.authenticatedProtocolVersion() == version)
                #expect(await session.authenticatedFrameContract()?.protocolVersion == version)
                #expect(await adapter.calls() == 1)
            }
            await session.close()
        }
    }

    @Test("Invalid account clock throws instead of trapping", arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, Double(Int64.max) / 1_000])
    func invalidIssueClock(value: Double) throws {
        let issuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 5, count: 32), now: { Date(timeIntervalSince1970: value) })
        #expect(throws: V2AccountAssertionError.invalidClock) { try issuer.issue(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID())) }
    }

    @Test("Valid current time with unrepresentable or already elapsed encoded expiry is rejected")
    func expiryArithmetic() throws {
        let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let nearBoundary = Double(Int64.max) / 1_000 - 16
        #expect(Int64(exactly: (nearBoundary * 1_000).rounded(.towardZero)) != nil)
        let overflowing = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 5, count: 32), now: { Date(timeIntervalSince1970: nearBoundary) })
        #expect(throws: V2AccountAssertionError.invalidClock) { try overflowing.issue(userID: user, deviceID: device) }
        let tooShort = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 5, count: 32), lifetime: 0.0001, now: { Date(timeIntervalSince1970: 1_750_000_000) })
        #expect(throws: V2AccountAssertionError.invalidClock) { try tooShort.issue(userID: user, deviceID: device) }
    }

    @Test("Verifier distinguishes server clock failure from invalid authority")
    func verificationClock() throws {
        let key = Data(repeating: 5, count: 32), user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let issuer = try V2HMACAccountAssertionIssuer(rawKey: key, now: { Date(timeIntervalSince1970: 1_750_000_000.125) })
        let proof = try issuer.issue(userID: user, deviceID: device)
        #expect(try issuer.verifiedUserID(for: proof, deviceID: device) == user)
        let invalid = try V2HMACAccountAssertionIssuer(rawKey: key, now: { Date(timeIntervalSince1970: .nan) })
        #expect(throws: V2AccountAssertionError.invalidClock) { try invalid.verifiedUserID(for: proof, deviceID: device) }
        #expect(throws: V2AccountAssertionError.invalidAssertion) { try invalid.verifiedUserID(for: "forged", deviceID: device) }
    }

    @Test("Rejected hello and heartbeat leave reusable protocol state", arguments: [false, true])
    func gatewayClock(changesDuringAdmission: Bool) async throws {
        let clock = BoundaryClock()
        let admission = BoundaryAdmission(clock: clock)
        let version = UInt8(IMV2ProtocolVersion.current)
        let session = V2GatewaySession(limits: try .init(maximumInFlightRequests: 1), authenticator: BoundaryAuthenticator(),
            capabilityProfile: "base", commandAdmission: admission, now: { clock.value })
        let handshakeDeviceID = UUID().uuidString
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        hello.clientHello.deviceID = handshakeDeviceID
        let helloFrame = try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0)
        clock.value = Date(timeIntervalSince1970: .nan)
        await #expect(throws: V2GatewaySessionError.invalidServerClock) { try await session.receiveBootstrap(helloFrame) }
        clock.value = Date(timeIntervalSince1970: 1.25)
        let helloResponse = try await session.receiveBootstrap(helloFrame)
        #expect(try V2ServerProtobufFrameCodec.decode(helloResponse).serverHello.serverTimeMs == 1_250)
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "fixture-token"; auth.authenticate.deviceID = handshakeDeviceID
        _ = try await session.receiveBootstrap(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version))
        var heartbeat = IMV2Envelope(); heartbeat.requestID = 3; heartbeat.protocolVersion = UInt32(version)
        heartbeat.heartbeat = .init()
        let frame = try V2ServerProtobufFrameCodec.encode(heartbeat, frameVersion: version)
        if changesDuringAdmission { await admission.invalidateNext() }
        else { clock.value = Date(timeIntervalSince1970: .infinity) }
        await #expect(throws: V2GatewaySessionError.invalidServerClock) { try await session.receiveAuthenticated(frame, handler: BoundaryHandler()) }
        clock.value = Date(timeIntervalSince1970: 2.5)
        let response = try await session.receiveAuthenticated(frame, handler: BoundaryHandler())
        #expect(try V2ServerProtobufFrameCodec.decode(response).heartbeatAck.serverTimeMs == 2_500)
        #expect(await session.authenticatedIdentity() != nil)
    }
}

private final class BoundaryClock: Sendable {
    private let storage = Mutex(Date(timeIntervalSince1970: 0))
    var value: Date { get { storage.withLock { $0 } } set { storage.withLock { $0 = newValue } } }
}
private actor BoundaryAdmission: V2AuthenticatedGatewayCommandAdmitting {
    let clock: BoundaryClock
    var invalidates = false
    init(clock: BoundaryClock) { self.clock = clock }
    func invalidateNext() { invalidates = true }
    func admit(identity: V2AuthenticatedConnection, cost: Int, now: Date) -> Bool {
        if invalidates { clock.value = Date(timeIntervalSince1970: .nan); invalidates = false }
        return true
    }
}
private struct BoundaryAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        .init(userID: .init(uuid: UUID()), expiresAt: Date(timeIntervalSince1970: 60))
    }
}
private actor HandshakeClockAuthenticator: V2GatewayAuthenticator {
    let clock: BoundaryClock
    let completionClock: Date?
    let expiresAt: Date?
    private var invocationCount = 0
    init(clock: BoundaryClock, completionClock: Date?, expiresAt: Date?) {
        self.clock = clock; self.completionClock = completionClock; self.expiresAt = expiresAt
    }
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) async -> V2GatewayAuthentication {
        invocationCount += 1
        await Task.yield()
        if let completionClock { clock.value = completionClock }
        return .init(userID: .init(uuid: UUID()), expiresAt: expiresAt)
    }
    func calls() -> Int { invocationCount }
}
private struct BoundaryHandler: V2GatewayCommandHandler {
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        Issue.record("Heartbeat must not reach the domain handler")
        return .init()
    }
}
