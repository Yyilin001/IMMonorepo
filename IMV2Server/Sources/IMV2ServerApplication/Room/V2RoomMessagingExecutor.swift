import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

public struct V2RoomMessagingExecutor: Sendable {
    public let token: V2RoomActivationToken
    private let persistence: any V2RoomMessagingPersisting
    private let limits: V2MessageCommandLimits

    package init(token: V2RoomActivationToken, persistence: any V2RoomMessagingPersisting,
         limits: V2MessageCommandLimits, maximumEditBytes: Int) throws {
        guard maximumEditBytes > 0 else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        self.token = token
        self.persistence = persistence
        self.limits = limits
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
}

/// Room ownership spans preparation and execution. SQL capacity is acquired only
/// by the actual reader or write dispatcher, without a second admission wrapper.
package func v2ExecutePreparedRoomSendOperationBatch(
    prepare: @Sendable () async throws -> V2PreparedRoomSendOperationBatch
) async throws -> [V2RoomMessagingResult] {
    V2SendPathTrace.current?.mark("prepared_batch_enter")
    let prepared: V2PreparedRoomSendOperationBatch
    do {
        prepared = try await prepare()
    } catch {
        // No message execution capability has run. A failed preparation read
        // cannot make the message commit uncertain or poison the room lane.
        // Preserve proven authority failures so stale activations still retire.
        let completion: V2RoomTransactionCompletion<Void> = v2RoomDomainCompletion(error)
        if case .rolledBack(let reason) = completion {
            throw V2RoomCallFailure.notAccepted(reason)
        }
        if error is CancellationError || Task.isCancelled {
            throw V2RoomCallFailure.notAccepted(.cancelled)
        }
        throw V2RoomCallFailure.notAccepted(.unavailable)
    }
    V2SendPathTrace.current?.mark("prepared_batch_ready")
    // Once execution begins, unknown outcomes must retain recovery semantics.
    return try await prepared.execute()
}
