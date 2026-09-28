import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Provider-neutral group avatar commands")
struct V2HTTPGroupAvatarCommandClientTests {
    private let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())

    @Test("lost responses reuse the exact command and accept its original receipt")
    func recovery() async throws {
        let command = try command()
        let response = try response(command)
        let transport = AvatarCommandTransport(bytes: try JSONEncoder().encode(response), failFirst: true)
        let client = try client(transport)
        await #expect(throws: V2GroupAvatarSubmissionError.outcomeUnknown) { _ = try await client.submitGroupAvatar(command) }
        #expect(try await client.submitGroupAvatar(command) == response)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].httpBody == requests[1].httpBody)
        #expect(requests[1].httpMethod == "POST" && requests[1].url?.path == "/v2/rooms/\(room.rawValue)/avatar")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer account-secret")
        #expect(requests[1].value(forHTTPHeaderField: "X-IM-Device-ID") == device.rawValue)
        #expect(requests[1].value(forHTTPHeaderField: "Cache-Control") == "no-store")
    }

    @Test("a receipt from another identity, command, status or oversized body is rejected",
          arguments: ["actor", "device", "operation", "mutation", "status", "size"])
    func replyBinding(field: String) async throws {
        let original = try command()
        let command = try V2GroupAvatarCommand(operationID: field == "operation" ? .init(uuid: UUID()) : original.operationID,
            roomID: room, expectedRevision: 0, mutation: field == "mutation" ? .remove : original.mutation)
        let value = try response(command, actor: field == "actor" ? .init(uuid: UUID()) : actor,
            device: field == "device" ? .init(uuid: UUID()) : device)
        let bytes = field == "size" ? Data(repeating: 32, count: 17 * 1_024) : try JSONEncoder().encode(value)
        let transport = AvatarCommandTransport(bytes: bytes, status: field == "status" ? 409 : 200)
        await #expect(throws: V2GroupAvatarSubmissionError.invalidResponse) { _ = try await client(transport).submitGroupAvatar(original) }
    }

    @Test("business denials and rate limits remain distinct from unknown outcomes")
    func failures() async throws {
        let command = try command()
        for (outcome, status): (V2GroupAvatarCommandResponse.Outcome, Int) in [(.revisionConflict, 409), (.idempotencyConflict, 409),
            (.resourceUnavailable, 422), (.forbidden, 403)] {
            let value = try V2GroupAvatarCommandResponse(actorUserID: actor, deviceID: device, command: command, outcome: outcome)
            #expect(try await client(AvatarCommandTransport(bytes: JSONEncoder().encode(value), status: status)).submitGroupAvatar(command) == value)
        }
        await #expect(throws: V2GroupAvatarSubmissionError.authorizationDenied) {
            _ = try await client(AvatarCommandTransport(bytes: Data("{}".utf8), status: 403)).submitGroupAvatar(command)
        }
        await #expect(throws: V2GroupAvatarSubmissionError.throttled(retryAfter: 10000)) {
            _ = try await client(AvatarCommandTransport(bytes: Data(), status: 429)).submitGroupAvatar(command)
        }
        await #expect(throws: V2GroupAvatarSubmissionError.outcomeUnknown) {
            _ = try await client(AvatarCommandTransport(bytes: Data(), status: 503)).submitGroupAvatar(command)
        }
        await #expect(throws: V2GroupAvatarSubmissionError.operationClosed) {
            _ = try await client(AvatarCommandTransport(bytes: Data(), status: 410)).submitGroupAvatar(command)
        }
    }

    @Test("recovery retries preserve the frozen command and requested action", arguments: [V2GroupAvatarRecoveryRequest.Action.query, .closeIfAbsent])
    func recoveryRequest(action: V2GroupAvatarRecoveryRequest.Action) async throws {
        let request = try V2GroupAvatarRecoveryRequest(command: command(), action: action)
        let response = try V2GroupAvatarRecoveryResponse(actorUserID: actor, deviceID: device, request: request, result: .closed)
        let transport = AvatarCommandTransport(bytes: try JSONEncoder().encode(response), failFirst: true), client = try client(transport)
        await #expect(throws: V2GroupAvatarSubmissionError.outcomeUnknown) { _ = try await client.recoverGroupAvatar(request) }
        #expect(try await client.recoverGroupAvatar(request) == response)
        let sent = await transport.requests
        #expect(sent.count == 2 && sent[0].httpBody == sent[1].httpBody)
        #expect(sent[1].url?.path == "/v2/rooms/\(room.rawValue)/avatar/recovery" && sent[1].httpMethod == "POST")
        #expect(sent[1].cachePolicy == .reloadIgnoringLocalAndRemoteCacheData && sent[1].timeoutInterval == 15)
        #expect(sent[1].value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(sent[1].value(forHTTPHeaderField: "Authorization") == "Bearer account-secret")
        #expect(sent[1].value(forHTTPHeaderField: "X-IM-Device-ID") == device.rawValue)
    }

    @Test("recovery proof validation includes actor, device, operation, room, revision and requested action",
          arguments: ["actor", "device", "operation", "room", "revision", "action", "size"])
    func recoveryBinding(field: String) async throws {
        let original = try V2GroupAvatarRecoveryRequest(command: command(), action: .closeIfAbsent)
        let changed = try V2GroupAvatarCommand(operationID: field == "operation" ? .init(uuid: UUID()) : original.command.operationID,
            roomID: field == "room" ? .init(uuid: UUID()) : room, expectedRevision: field == "revision" ? 1 : 0,
            mutation: original.command.mutation)
        let response = try V2GroupAvatarRecoveryResponse(actorUserID: field == "actor" ? .init(uuid: UUID()) : actor,
            deviceID: field == "device" ? .init(uuid: UUID()) : device,
            request: .init(command: changed, action: field == "action" ? .query : .closeIfAbsent), result: .closed)
        let bytes = field == "size" ? Data(repeating: 32, count: 17 * 1_024) : try JSONEncoder().encode(response)
        await #expect(throws: V2GroupAvatarSubmissionError.invalidResponse) {
            _ = try await client(AvatarCommandTransport(bytes: bytes)).recoverGroupAvatar(original)
        }
    }

    @Test("recovery HTTP status alone never becomes a closure proof", arguments: [401, 403, 410, 429, 503])
    func recoveryStatuses(status: Int) async throws {
        let request = try V2GroupAvatarRecoveryRequest(command: command(), action: .closeIfAbsent)
        let error: V2GroupAvatarSubmissionError = status == 401 ? .authorizationUnavailable : status == 403 ? .authorizationDenied
            : status == 429 ? .throttled(retryAfter: 10000) : .outcomeUnknown
        await #expect(throws: error) {
            _ = try await client(AvatarCommandTransport(bytes: Data(), status: status)).recoverGroupAvatar(request)
        }
    }

    private func command() throws -> V2GroupAvatarCommand {
        try .init(operationID: .init(uuid: UUID()), roomID: room, expectedRevision: 0, mutation: .set(.init(uuid: UUID())))
    }
    private func response(_ command: V2GroupAvatarCommand, actor: UserID? = nil, device: DeviceID? = nil) throws -> V2GroupAvatarCommandResponse {
        try .init(actorUserID: actor ?? self.actor, deviceID: device ?? self.device, command: command,
            outcome: .committed(.init(state: .init(roomID: room, mediaID: command.mutation.mediaID, revision: command.expectedRevision + 1),
                roomSequence: 1, updatedAt: Date())))
    }
    private func client(_ transport: AvatarCommandTransport) throws -> V2HTTPGroupAvatarCommandClient {
        try .init(roomsEndpoint: #require(URL(string: "https://account.invalid/v2/rooms")), actorUserID: actor,
            credentials: AvatarCommandCredentials(device: device), transport: transport)
    }
}

private struct AvatarCommandCredentials: V2ClientMediaEdgeCredentialProvider {
    let device: DeviceID
    func mediaEdgeCredentials() throws -> V2ClientMediaEdgeCredentials { .init(accessToken: "account-secret", deviceID: device) }
}
private actor AvatarCommandTransport: V2ClientMediaEdgeHTTPTransport {
    let bytes: Data; let status: Int; let failFirst: Bool
    var requests: [URLRequest] = []
    init(bytes: Data, status: Int = 200, failFirst: Bool = false) { self.bytes = bytes; self.status = status; self.failFirst = failFirst }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if failFirst && requests.count == 1 { throw URLError(.networkConnectionLost) }
        let url = try #require(request.url)
        return (bytes, try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "Retry-After": "10000"])))
    }
}
