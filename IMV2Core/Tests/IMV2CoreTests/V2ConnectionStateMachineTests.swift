import Foundation
import Testing
@testable import IMV2Core

struct V2ConnectionStateMachineTests {
    @Test("hello negotiation authentication and correlated request lifecycle")
    func legalLifecycle() throws {
        var machine = V2ConnectionStateMachine(limits: try .init(maximumInFlightRequests: 2))
        let selected = try machine.receiveClientHello(.init(version: 0, command: .clientHello, requestID: 1, payload: Data()), clientSupportedVersions: [1, 2], serverSupportedVersions: [2, 3])
        #expect(selected == 2)
        try machine.receiveAuthenticate(.init(version: 2, command: .authenticate, requestID: 2, payload: Data()))
        try machine.completeAuthentication(.init(userID: try .init("user"), deviceID: try .init("device"), capabilityProfile: "base"))
        try machine.receiveAuthenticatedRequest(.init(version: 2, command: .syncPull, requestID: 3, payload: Data()))
        try machine.completeResponse(requestID: 3)
        #expect(machine.inFlightRequestIDs.isEmpty)
    }

    @Test("bootstrap order, duplicate ids and device revocation fail closed")
    func illegalLifecycleIsRejected() throws {
        var machine = V2ConnectionStateMachine(limits: try .init(maximumInFlightRequests: 1))
        #expect(throws: V2ConnectionStateError.bootstrapVersionMustBeZero) { _ = try machine.receiveClientHello(.init(version: 1, command: .clientHello, requestID: 1, payload: Data()), clientSupportedVersions: [1], serverSupportedVersions: [1]) }
        _ = try machine.receiveClientHello(.init(version: 0, command: .clientHello, requestID: 1, payload: Data()), clientSupportedVersions: [1], serverSupportedVersions: [1])
        try machine.receiveAuthenticate(.init(version: 1, command: .authenticate, requestID: 2, payload: Data()))
        try machine.completeAuthentication(.init(userID: try .init("user"), deviceID: try .init("device"), capabilityProfile: "base"))
        try machine.receiveAuthenticatedRequest(.init(version: 1, command: .syncPull, requestID: 3, payload: Data()))
        #expect(throws: V2ConnectionStateError.tooManyInFlightRequests) { try machine.receiveAuthenticatedRequest(.init(version: 1, command: .syncAck, requestID: 4, payload: Data())) }
        machine.revokeDevice()
        #expect(machine.phase == .closing)
        #expect(machine.inFlightRequestIDs.isEmpty)
    }
}
