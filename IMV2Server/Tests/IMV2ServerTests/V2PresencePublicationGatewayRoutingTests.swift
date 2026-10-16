import Foundation
import Synchronization
import Testing
import IMV2Core
@testable import IMV2ServerGateway

struct V2PresencePublicationGatewayRoutingTests {
    @Test(arguments: ["send", "recover", "sync"])
    func ordinaryCommandsBypassOccupiedRegistry(command: String) async throws {
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        let identity = V2AuthenticatedConnection(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), capabilityProfile: "base")
        let connection = UUID(), originating = UUID()
        let delegate = RoutingDelegate(expectedIdentity: identity, expectedOrigin: originating)
        let handler = V2PresencePublicationGatewayHandler(delegate: delegate, registry: registry, connectionID: connection)
        var request = IMV2Envelope(); request.requestID = 47
        switch command {
        case "send": request.messageSendOperation = .init()
        case "recover": request.messageSendOperationRecover = .init()
        default: request.syncPull = .init()
        }
        let barrier = RegistryRoutingBarrier()
        let held = Task { await registry.holdForRoutingTest(barrier) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !barrier.entered.withLock({ $0 }) {
            guard ContinuousClock.now < deadline else { barrier.release.signal(); throw CancellationError() }
            await Task.yield()
        }
        do {
            let response = try await handler.handle(envelope: request, identity: identity, originatingConnectionID: originating)
            #expect(response.requestID == 47)
            if case .acknowledged = response.body {} else { Issue.record("delegate response was not preserved") }
            #expect(await delegate.calls == 1)
            #expect(!barrier.exited.withLock { $0 }) // No registry-executor turn was required.
            barrier.release.signal()
            #expect(await held.value)
        } catch { barrier.release.signal(); _ = await held.value; throw error }
    }

    @Test(arguments: ["progress", "unsubscribe", "presence"])
    func ownedControlsStillValidateRegistryIdentity(command: String) async throws {
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        let identity = V2AuthenticatedConnection(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), capabilityProfile: "base")
        let delegate = RoutingDelegate(expectedIdentity: identity, expectedOrigin: nil)
        let handler = V2PresencePublicationGatewayHandler(delegate: delegate, registry: registry, connectionID: UUID())
        var request = IMV2Envelope()
        switch command {
        case "progress": request.deviceRoomProgressReport = .init()
        case "unsubscribe": request.groupEventUnsubscribe.roomID = UUID().uuidString
        default: request.presencePublicationControl.mode = .suppressed
        }
        let response = try await handler.handle(envelope: request, identity: identity, originatingConnectionID: nil)
        #expect(response.error.code == (command == "presence" ? "UNAVAILABLE" : "INVALID_ARGUMENT"))
        #expect(await delegate.calls == 0)
    }
}

private actor RoutingDelegate: V2GatewayCommandHandler {
    let expectedIdentity: V2AuthenticatedConnection
    let expectedOrigin: UUID?
    var calls = 0
    init(expectedIdentity: V2AuthenticatedConnection, expectedOrigin: UUID?) {
        self.expectedIdentity = expectedIdentity; self.expectedOrigin = expectedOrigin
    }
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        try await handle(envelope: envelope, identity: identity, originatingConnectionID: nil)
    }
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection, originatingConnectionID: UUID?) async throws -> IMV2Envelope {
        #expect(identity == expectedIdentity && originatingConnectionID == expectedOrigin)
        calls += 1
        var response = IMV2Envelope(); response.requestID = envelope.requestID; response.acknowledged = .init()
        return response
    }
}

// Test-only bounded executor obstruction. Production performs no blocking wait.
private final class RegistryRoutingBarrier: @unchecked Sendable {
    let entered = Mutex(false)
    let exited = Mutex(false)
    let release = DispatchSemaphore(value: 0)
}
private extension V2DeviceConnectionRegistry {
    func holdForRoutingTest(_ barrier: RegistryRoutingBarrier) -> Bool {
        barrier.entered.withLock { $0 = true }
        let released = barrier.release.wait(timeout: .now() + 2) == .success
        barrier.exited.withLock { $0 = true }
        return released
    }
}
