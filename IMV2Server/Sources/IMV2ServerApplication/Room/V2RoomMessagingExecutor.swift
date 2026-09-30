import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

/// A send is prepared once before the host batcher merges room turns.
public struct V2PreparedActorSend: Sendable {
    public let token: V2RoomActivationToken
    public let request: V2RoomWriteRequest
}

public struct V2RoomMessagingExecutor: Sendable {
    public let token: V2RoomActivationToken
    private let persistence: any V2RoomMessagingPersisting
    private let capacityProfile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let identifiers: V2AcceptanceIDFactory
    private let now: @Sendable () -> Date

    package init(token: V2RoomActivationToken, persistence: any V2RoomMessagingPersisting,
         capacityProfile: V2CapacityProfile, limits: V2MessageCommandLimits,
         maximumEditBytes: Int, identifiers: V2AcceptanceIDFactory,
         now: @escaping @Sendable () -> Date) throws {
        guard maximumEditBytes > 0 else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        self.token = token
        self.persistence = persistence
        self.capacityProfile = capacityProfile
        self.limits = limits
        self.identifiers = identifiers
        self.now = now
    }

    public func prepareSend(_ value: V2ActorSendMessageWire) throws -> V2PreparedActorSend {
        guard value.roomID == token.roomID else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        let authenticated = try value.toAuthenticated(limits: limits)
        let command = try V2SendMessageCommand(roomID: authenticated.roomID,
            senderUserID: authenticated.actorUserID, clientMessageID: authenticated.clientMessageID,
            text: authenticated.text, media: authenticated.media, mentions: authenticated.mentions,
            entities: authenticated.entities, replyTo: authenticated.replyTo, limits: limits)
        let acceptedAt = now()
        return .init(token: token, request: .init(command: command, capacityProfile: capacityProfile,
            identifiers: try identifiers.make(at: acceptedAt), now: acceptedAt))
    }

    public func execute(_ command: V2RoomMessagingCommand) async throws -> V2RoomMessagingResult {
        guard command.roomID == token.roomID else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        do {
            if case .sendOperation(let value) = command,
               value.command.text.utf8.count > limits.maxUTF8Bytes {
                throw V2RoomCallFailure.notAccepted(.invalidRequest)
            }
            return try await persistence.execute(command)
        } catch {
            if let failure = V2ActorMessagingErrorWire(domainError: error) { return .failure(failure) }
            throw error
        }
    }

    public func executeSendOperationBatch(_ commands: [V2MessageSendOperationCommand]) async throws -> [V2RoomMessagingResult] {
        guard !commands.isEmpty, commands.allSatisfy({ $0.command.roomID == token.roomID }) else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        var output = Array<V2RoomMessagingResult?>(repeating: nil, count: commands.count)
        let eligible = commands.enumerated().compactMap { index, command -> (Int, V2MessageSendOperationCommand)? in
            guard command.command.text.utf8.count <= limits.maxUTF8Bytes else {
                output[index] = .failure(.sendValidation(.invalidTextLength))
                return nil
            }
            return (index, command)
        }
        guard !eligible.isEmpty else { return output.compactMap { $0 } }
        // Persistence resolves command-level failures inside each savepoint.
        // An escaped batch error cannot identify a failed command or replace
        // any permanent receipt; preserve the host's transaction recovery path.
        let results = try await persistence.executeSendOperationBatch(eligible.map(\.1))
        guard results.count == eligible.count else { throw V2RoomCallFailure.outcomeUnknown }
        for ((index, _), result) in zip(eligible, results) { output[index] = result }
        return try output.map { guard let result = $0 else { throw V2RoomCallFailure.outcomeUnknown }; return result }
    }

    public func executePreparedSend(_ value: V2PreparedActorSend) async throws -> V2RoomMessagingResult {
        guard value.token == token, value.request.command.roomID == token.roomID else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        do {
            return try await persistence.accept(value.request)
        } catch {
            if let failure = V2ActorMessagingErrorWire(domainError: error) { return .failure(failure) }
            throw error
        }
    }

    public func executeGrantedSendTurn(_ sends: [V2ActorSendMessageWire],
        batchDeadline: ContinuousClock.Instant,
        callDeadline: ContinuousClock.Instant = .now + .seconds(10),
        using adapter: V2ActorGrantedSendBatchAdapter) async throws -> [V2RoomMessagingResult] {
        guard !sends.isEmpty else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        var prepared: [V2PreparedActorSend] = []
        var preparedIndices: [Int] = []
        var results = Array<V2RoomMessagingResult?>(repeating: nil, count: sends.count)
        for (index, send) in sends.enumerated() {
            do {
                prepared.append(try prepareSend(send))
                preparedIndices.append(index)
            } catch {
                guard let failure = V2ActorMessagingErrorWire(domainError: error) else { throw error }
                results[index] = .failure(failure)
            }
        }
        if !prepared.isEmpty {
            let accepted = try await adapter.execute(prepared,
                batchDeadline: batchDeadline, callDeadline: callDeadline)
            guard accepted.count == preparedIndices.count else { throw V2RoomCallFailure.outcomeUnknown }
            for (index, result) in zip(preparedIndices, accepted) { results[index] = result }
        }
        return try results.map { result in
            guard let result else { throw V2RoomCallFailure.outcomeUnknown }
            return result
        }
    }
}
