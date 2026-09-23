import Foundation
import IMV2ActorContracts
import IMV2Core

/// Prepared exactly once after a send obtains its room turn. A host batcher may
/// combine these values, retaining the token, generated IDs and server clock.
public struct V2PreparedActorSend: Sendable {
    public let token: V2RoomActivationToken
    public let request: V2RoomWriteRequest
}

/// Concrete D1 implementation. The room runtime supplies serialization and
/// lifecycle; every store independently fences SQL with this exact token.
public struct V2RoomMessagingExecutor: Sendable {
    public let token: V2RoomActivationToken
    private let writes: PostgresV2RoomWriteStore
    private let edits: V2MessageEditService
    private let withdrawals: V2MessageWithdrawalService
    private let reactions: V2MessageReactionService
    private let capacityProfile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let identifiers: V2AcceptanceIDFactory
    private let maximumEditBytes: Int
    private let now: @Sendable () -> Date

    public init(
        token: V2RoomActivationToken,
        writes: PostgresV2RoomWriteStore,
        edits: PostgresV2MessageEditStore,
        withdrawals: PostgresV2MessageWithdrawalStore,
        reactions: PostgresV2MessageReactionStore,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        maximumEditBytes: Int,
        identifiers: V2AcceptanceIDFactory = .init(),
        editIdentifiers: V2MessageEditIDFactory = .init(),
        withdrawalIdentifiers: V2MessageWithdrawalIDFactory = .init(),
        reactionIdentifiers: V2MessageReactionIDFactory = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard maximumEditBytes > 0 else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        let scope = try V2RoomActivationWriteScope(tokens: [token])
        self.token = token
        self.writes = writes.usingActivationScope(scope)
        self.edits = .init(store: edits.usingActivationScope(scope), capacityProfile: capacityProfile,
            maximumTextUTF8Bytes: maximumEditBytes, identifiers: editIdentifiers, now: now)
        self.withdrawals = .init(store: withdrawals.usingActivationScope(scope), capacityProfile: capacityProfile,
            identifiers: withdrawalIdentifiers, now: now)
        self.reactions = .init(store: reactions.usingActivationScope(scope), capacityProfile: capacityProfile,
            identifiers: reactionIdentifiers, now: now)
        self.capacityProfile = capacityProfile
        self.limits = limits
        self.identifiers = identifiers
        self.maximumEditBytes = maximumEditBytes
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
            switch command {
            case .send(let value):
                return try await executePreparedSend(prepareSend(value))
            case .edit(let value):
                return .edit(.init(try await edits.edit(value.toAuthenticated(maximumTextUTF8Bytes: maximumEditBytes))))
            case .withdraw(let value):
                return .withdraw(.init(try await withdrawals.withdraw(value.toAuthenticated())))
            case .reaction(let value):
                return .reaction(.init(try await reactions.change(value.toAuthenticated())))
            }
        } catch {
            if let failure = V2ActorMessagingErrorWire(domainError: error) { return .failure(failure) }
            // Unknown commit, expired authority, and driver failures are not
            // business results. The enclosing turn must retain their evidence.
            throw error
        }
    }

    public func executePreparedSend(_ value: V2PreparedActorSend) async throws -> V2RoomMessagingResult {
        guard value.token == token, value.request.command.roomID == token.roomID else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        let request = value.request
        do {
            return .send(.init(try await writes.accept(command: request.command,
                capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now)))
        } catch {
            if let failure = V2ActorMessagingErrorWire(domainError: error) { return .failure(failure) }
            throw error
        }
    }
}
