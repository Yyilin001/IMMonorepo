import IMV2ActorContracts
import Crypto
import Foundation
import FluentKit
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import SQLKit

/// Trusted server commands frozen before revocation. Request credentials and
/// transient receive times are excluded, so retries preserve the same identity.
package enum V2DurablePolicyMutation: Codable, Sendable {
    case social(V2SocialOperationCommand)
    case strangerPreference(V2AccountPreferenceCommand)
    case disable(V2DurableAccountDisableCommand)

    package func validate() throws {
        switch self {
        case .social: break // The command's initializer/decoder validates its scope.
        case .strangerPreference(let command):
            guard command.identity.kind == .strangerMessagePreference else {
                throw V2AccountPreferenceValidationError.invalidCommand
            }
        case .disable(let command): _ = try command.validatedCommand()
        }
    }

    package var scope: V2PolicyAuthorizationScope {
        switch self {
        case .social(let command): .pair(command.actorUserID.uuidValue!, command.targetUserID.uuidValue!)
        case .strangerPreference(let command): .stranger(command.identity.accountID.uuidValue!)
        case .disable(let command): .account(command.userID)
        }
    }

    package var operationKey: String {
        switch self {
        case .social(let command): "social:" + command.identity.storageKey
        case .strangerPreference(let command): "preference:" + command.identity.storageKey
        case .disable(let command): "disable:" + command.operationID.uuidString.lowercased()
        }
    }

    package var fingerprint: Data {
        get throws {
            switch self {
            case .social(let command): try command.fingerprint.digest
            case .strangerPreference(let command): try command.fingerprint.digest
            case .disable(let command): Data(SHA256.hash(data: try Self.encoder().encode(command)))
            }
        }
    }

    package var json: String { get throws { String(decoding: try Self.encoder().encode(self), as: UTF8.self) } }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }
}

package struct V2DurableAccountDisableCommand: Codable, Sendable {
    package let userID: UUID
    package let operationID: UUID
    package let reason: V2AccountDisableReason
    package let operatorPrincipal: String

    package init(command: V2AccountDisableCommand, operatorPrincipal: String) {
        userID = command.userID.uuidValue!; operationID = command.operationID
        reason = command.reason; self.operatorPrincipal = operatorPrincipal
    }

    package func validatedCommand() throws -> V2AccountDisableCommand {
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal) else {
            throw V2AccountDisableError.invalidOperatorPrincipal
        }
        return try .init(userID: .init(uuid: userID), operationID: operationID, reason: reason)
    }
}

extension V2PolicyAccountDisableReceipt {
    package init(_ outcome: V2AccountDisableOutcome) {
        switch outcome {
        case .disabled(let date): self.init(kind: .disabled, disabledAt: date)
        case .idempotent(let date): self.init(kind: .idempotent, disabledAt: date)
        case .alreadyDisabled(let date): self.init(kind: .alreadyDisabled, disabledAt: date)
        }
    }
    package var outcome: V2AccountDisableOutcome {
        switch kind {
        case .disabled: .disabled(disabledAt: disabledAt)
        case .idempotent: .idempotent(disabledAt: disabledAt)
        case .alreadyDisabled: .alreadyDisabled(disabledAt: disabledAt)
        }
    }
}

extension V2DurablePolicyMutation {
    init(wire: V2PolicyMutationCommand) throws {
        switch wire {
        case .social(let command): self = .social(command)
        case .strangerPreference(let command): self = .strangerPreference(command)
        case .disable(let wire):
            guard let reason = V2AccountDisableReason(rawValue: wire.reason) else {
                throw V2PolicyAuthorizationLifecycleError.invalidTarget
            }
            let command = try V2AccountDisableCommand(userID: .init(uuid: wire.userID), operationID: wire.operationID, reason: reason)
            self = .disable(.init(command: command, operatorPrincipal: wire.operatorPrincipal))
        }
        try validate()
    }
    var wire: V2PolicyMutationCommand {
        switch self {
        case .social(let command): .social(command)
        case .strangerPreference(let command): .strangerPreference(command)
        case .disable(let command): .disable(.init(userID: command.userID, operationID: command.operationID,
            reason: command.reason.rawValue, operatorPrincipal: command.operatorPrincipal))
        }
    }
}

/// Runs existing domain validations and effects in the journal's transaction.
/// Projection delivery happens after commit through its durable outboxes.
package struct PostgresV2PolicyMutationDispatcher: Sendable {
    private let database: any Database
    private let delivery: any V2UserShardProjectionDelivering

    package init(database: any Database, projectionDelivery: any V2UserShardProjectionDelivering) {
        self.database = database; delivery = projectionDelivery
    }

    package func apply(context: V2PolicyMutationContext, change: V2PolicyAuthorizationChange) async throws -> Data {
        let mutation = try JSONDecoder().decode(V2DurablePolicyMutation.self, from: Data(change.commandJSON.utf8))
        try mutation.validate()
        try context.require(scope: mutation.scope, operationKey: mutation.operationKey, fingerprint: mutation.fingerprint)
        guard let sql = context.transaction as? any SQLDatabase,
              let clock = try await sql.raw("SELECT clock_timestamp() AS value").first(decoding: Clock.self) else {
            throw V2PolicyAuthorizationLifecycleError.corruptPersistence
        }
        let result: V2PolicyMutationResult
        switch mutation {
        case .social(let command):
            let store = V2PostgresSocialRelationshipPersistence(database: database, projectionDelivery: delivery)
            result = .social(try await store.applyPolicyOperation(command, now: clock.value, context: context))
        case .strangerPreference(let command):
            let store = V2PostgresAccountPreferencePersistence(database: database, projectionDelivery: delivery)
            result = .preference(try await store.applyPolicyOperation(command, now: clock.value, context: context))
        case .disable(let frozen):
            let store = try V2PostgresAccountDisableMutation(operatorPrincipal: frozen.operatorPrincipal)
            result = .disable(.init(try await store.applyPolicyOperation(frozen.validatedCommand(), occurredAt: clock.value, context: context)))
        }
        return try JSONEncoder().encode(result)
    }

    private struct Clock: Decodable { let value: Date }
}
