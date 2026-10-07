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

    /// Validation and control preparation happen before owner-write admission.
    /// The returned capability retains per-command validation positions while
    /// the store rechecks current authority in the owner transaction.
    public func prepareSendOperationBatch(_ commands: [V2MessageSendOperationCommand],
                                         deadline: ContinuousClock.Instant) async throws -> V2PreparedRoomSendOperationBatch {
        V2SendPathTrace.current?.mark("messaging_prepare_enter")
        guard !commands.isEmpty, commands.allSatisfy({ $0.command.roomID == token.roomID }) else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        var validationResults = Array<V2RoomMessagingResult?>(repeating: nil, count: commands.count)
        var eligible: [V2MessageSendOperationCommand] = []
        var indices: [Int] = []
        for (index, command) in commands.enumerated() {
            if command.command.text.utf8.count > limits.maxUTF8Bytes {
                validationResults[index] = .failure(.sendValidation(.invalidTextLength))
            } else {
                eligible.append(command)
                indices.append(index)
            }
        }
        let prepared = eligible.isEmpty ? nil : try await persistence.prepareSendOperationBatch(eligible, deadline: deadline)
        let fixedResults = validationResults
        let eligibleIndices = indices
        return .init {
            var output = fixedResults
            if let prepared {
                let results = try await prepared.execute()
                guard results.count == eligibleIndices.count else { throw V2RoomCallFailure.outcomeUnknown }
                for (index, result) in zip(eligibleIndices, results) { output[index] = result }
            }
            return try output.map {
                guard let result = $0 else { throw V2RoomCallFailure.outcomeUnknown }
                return result
            }
        }
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
}

/// Room ownership spans preparation and execution. SQL capacity is acquired only
/// by the actual reader or write dispatcher, without a second admission wrapper.
package func v2ExecutePreparedRoomSendOperationBatch(
    prepare: @Sendable () async throws -> V2PreparedRoomSendOperationBatch
) async throws -> [V2RoomMessagingResult] {
    V2SendPathTrace.current?.mark("prepared_batch_enter")
    let prepared = try await prepare()
    V2SendPathTrace.current?.mark("prepared_batch_ready")
    return try await prepared.execute()
}
