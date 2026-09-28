import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Routed message send operations")
struct V2RoutedMessageSendOperationClientTests {
    @Test func healthySubmitAndPersistedRecoveryChooseSeparateTransports() async throws {
        let command = try sampleCommand()
        let tcp = RouteRealtime(account: command.command.senderUserID)
        let http = RouteHTTP()
        let router = V2RoutedMessageSendOperationClient(accountID: command.command.senderUserID, realtime: tcp, http: http)
        _ = try await router.submit(command)
        #expect(await tcp.submissions == 1)
        #expect(await http.submissions == 0)
        let recovery = try V2MessageSendOperationRecoveryRequest(identity: command.identity, fingerprint: command.fingerprint,
            domainFingerprint: command.command.fingerprint, action: .query)
        _ = try await router.recover(recovery)
        #expect(await tcp.recoveries == 0)
        #expect(await http.recoveries == 1)
        #expect(await router.routeObservations().count == 2)
    }

    @Test func unknownNeverIssuesHiddenHTTPSubmit() async throws {
        let command = try sampleCommand()
        let tcp = RouteRealtime(account: command.command.senderUserID)
        await tcp.setFailure(.outcomeUnknown)
        let http = RouteHTTP()
        let router = V2RoutedMessageSendOperationClient(accountID: command.command.senderUserID, realtime: tcp, http: http)
        await #expect(throws: V2MessageSendTransportError.outcomeUnknown) { try await router.submit(command) }
        #expect(await tcp.submissions == 1)
        #expect(await http.submissions == 0)
    }

    @Test func absentSessionAndForcedModesRespectSelection() async throws {
        let command = try sampleCommand()
        let tcp = RouteRealtime(account: command.command.senderUserID)
        await tcp.setReady(false)
        let http = RouteHTTP()
        let automatic = V2RoutedMessageSendOperationClient(accountID: command.command.senderUserID, realtime: tcp, http: http)
        _ = try await automatic.submit(command)
        #expect(await http.submissions == 1)
        let forced = V2RoutedMessageSendOperationClient(accountID: command.command.senderUserID, realtime: tcp, http: http, mode: .realtimeOnly)
        await #expect(throws: V2MessageSendTransportError.unavailableBeforeSubmission) { try await forced.submit(command) }
        #expect(await http.submissions == 1)
    }

    @Test func negotiatedPayloadLimitSelectsHTTPBeforeTCPSubmission() async throws {
        let command = try sampleCommand()
        let tcp = RouteRealtime(account: command.command.senderUserID)
        await tcp.setPayloadAllowed(false)
        let http = RouteHTTP()
        let router = V2RoutedMessageSendOperationClient(accountID: command.command.senderUserID, realtime: tcp, http: http)
        _ = try await router.submit(command)
        #expect(await tcp.submissions == 0)
        #expect(await http.submissions == 1)
        #expect(await router.routeObservations().first?.reason == .payloadLimit)
    }

    private func sampleCommand() throws -> V2MessageSendOperationCommand {
        let account = UserID(uuid: UUID())
        let command = try V2SendMessageCommand(roomID: .init(uuid: UUID()), senderUserID: account,
            clientMessageID: .init(uuid: UUID()), text: "routed", media: [], mentions: [], entities: [],
            replyTo: nil, limits: .init(maxUTF8Bytes: 65_536))
        return try .init(command: command, firstSubmissionDeadlineMilliseconds: UInt64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000))
    }
}

private actor RouteRealtime: V2MessageSendRealtimeClient {
    let account: UserID
    var ready = true
    var payloadAllowed = true
    var failure: V2MessageSendTransportError?
    var submissions = 0
    var recoveries = 0
    init(account: UserID) { self.account = account }
    func setReady(_ value: Bool) { ready = value }
    func setPayloadAllowed(_ value: Bool) { payloadAllowed = value }
    func setFailure(_ value: V2MessageSendTransportError) { failure = value }
    func canSubmit(_: V2MessageSendOperationCommand) -> Bool { payloadAllowed }
    func readiness() -> V2MessageSendRealtimeReadiness? {
        ready ? .init(generation: UUID(), accountID: account, deviceID: .init(uuid: UUID()), protocolVersion: 45, maximumPayloadBytes: 1_052_672) : nil
    }
    func submit(_: V2MessageSendOperationCommand) throws -> V2MessageSendOperationRecoveryResult {
        submissions += 1
        if let failure { throw failure }
        guard ready else { throw V2MessageSendTransportError.unavailableBeforeSubmission }
        return .unresolved
    }
    func recover(_: V2MessageSendOperationRecoveryRequest) -> V2MessageSendOperationRecoveryResult {
        recoveries += 1
        return .unresolved
    }
}

private actor RouteHTTP: V2MessageSendOperationClient {
    var submissions = 0
    var recoveries = 0
    func submit(_: V2MessageSendOperationCommand) -> V2MessageSendOperationRecoveryResult {
        submissions += 1
        return .unresolved
    }
    func recover(_: V2MessageSendOperationRecoveryRequest) -> V2MessageSendOperationRecoveryResult {
        recoveries += 1
        return .unresolved
    }
}
