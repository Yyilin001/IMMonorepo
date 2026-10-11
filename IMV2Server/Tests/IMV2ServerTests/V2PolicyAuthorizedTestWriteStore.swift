import FluentKit
import Foundation
import IMV2Core
import IMV2ActorContracts
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure

/// Explicit composition for scalar persistence tests. Uses the real Policy
/// Owner and activation boundary; does not give raw stores an authorization default.
struct V2PolicyAuthorizedTestWriteStore: V2RoomWriteStore {
    let database: any Database
    let controlDatabase: any Database
    let store: PostgresV2RoomWriteStore
    let shardID: String
    let epoch: Int64
    var activationToken: V2RoomActivationToken? = nil
    var activationScope: V2RoomActivationWriteScope? = nil
    var policyOwners: PostgresV2PolicyOwnerDirectory? = nil

    func accept(command: consuming V2SendMessageCommand, capacityProfile: V2CapacityProfile,
                identifiers: V2AcceptanceIdentifiers, now: Date) async throws -> V2SendMessageOutcome {
        let command = command
        if let activationToken = try activationToken ?? activationScope?.token(for: command.roomID.uuidValue!) {
            return try await accept(command: command, capacityProfile: capacityProfile,
                identifiers: identifiers, now: now, token: activationToken)
        }
        return try await withRoomActivation(database: database, roomID: command.roomID,
                                           shardID: shardID, epoch: epoch) { token in
            try await accept(command: command, capacityProfile: capacityProfile,
                identifiers: identifiers, now: now, token: token)
        }
    }

    /// The caller owns this activation; the fixture neither acquires a competing
    /// lease nor releases the token when its policy execution finishes.
    private func accept(command: V2SendMessageCommand, capacityProfile: V2CapacityProfile,
                        identifiers: V2AcceptanceIdentifiers, now: Date,
                        token: V2RoomActivationToken) async throws -> V2SendMessageOutcome {
            let owners = policyOwners ?? PostgresV2PolicyOwnerDirectory(journal: .init(database: controlDatabase),
                dispatcher: .init(database: controlDatabase,
                    projectionDelivery: V2DiscardingUserShardProjectionDelivery()))
            let directory = PostgresV2RoomPolicyAuthorizationDirectory(database: database,
                endpoint: "scalar-persistence-test", maximumRooms: 1,
                currentLoader: { _, sender, recipient, replied in
                    let scopes: [V2PolicyAuthorizationScope] = recipient.map {
                        [.account(sender), .account($0), .pair(sender, $0)]
                    } ?? [.account(sender)]
                    var snapshots = try await owners.registrationSnapshots(scopes: scopes)
                    if let recipient {
                        guard let relationship = snapshots.first(where: {
                            $0.scope.key == V2PolicyAuthorizationScope.pair(sender, recipient).key
                        }), case .pair(let social) = relationship.facts else {
                            throw V2PolicyAuthorizationLifecycleError.invalidTarget
                        }
                        let ordinary = snapshots.filter {
                            guard case .account(let account) = $0.facts else { return false }
                            return account.specialKind == nil
                        }.count == 2
                        if !social.isFriend && !(replied && ordinary) {
                            snapshots += try await owners.registrationSnapshots(scopes: [.stranger(recipient)])
                        }
                        return try .direct(pair: .init(sender: sender, recipient: recipient),
                            snapshots: snapshots, recipientReplyConfirmed: replied)
                    }
                    return try .account(sender: sender, snapshots: snapshots)
                })
            do {
                let runtime = try await directory.registry(token: token)
                    .runtime(sender: command.senderUserID.uuidValue!, token: token)
                let scoped = store.usingControlDatabase(controlDatabase)
                    .usingActivationScope(try .init(tokens: [token]))
                let result = try await runtime.execute(command: command, callerDeadline: .now + .seconds(10)) { execution in
                    try await scoped.usingPolicyExecution(execution).accept(command: command,
                        capacityProfile: capacityProfile, identifiers: identifiers, now: now)
                }
                await directory.shutdown()
                if policyOwners == nil { await owners.shutdown() }
                return result
            } catch {
                await directory.shutdown()
                if policyOwners == nil { await owners.shutdown() }
                throw error
            }
    }
}

/// Forward target fixtures use the production authorization service and the
/// target room's activation, including media retries and terminal recovery.
extension V2PolicyAuthorizedTestWriteStore: V2ForwardExportImporting {
    func importForwardExport(_ export: V2ForwardExport, capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits, identifiers: V2AcceptanceIdentifiers,
        now: Date) async throws -> V2ForwardImportOutcome {
        func execute(_ token: V2RoomActivationToken) async throws -> V2ForwardImportOutcome {
            let owners = policyOwners ?? PostgresV2PolicyOwnerDirectory(journal: .init(database: controlDatabase),
                dispatcher: .init(database: controlDatabase,
                    projectionDelivery: V2DiscardingUserShardProjectionDelivery()))
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: database,
                policyOwners: owners, endpoint: "forward-persistence-test", maximumRooms: 1)
            let write = store.usingControlDatabase(controlDatabase).usingPolicyAuthorizations(policies)
            do {
                let result = try await write.importForwardExport(export, activationToken: token,
                    capacityProfile: capacityProfile, limits: limits, identifiers: identifiers, now: now)
                await policies.shutdown()
                if policyOwners == nil { await owners.shutdown() }
                return result
            } catch {
                await policies.shutdown()
                if policyOwners == nil { await owners.shutdown() }
                throw error
            }
        }
        if let token = try activationToken ?? activationScope?.token(for: export.intent.targetRoomID) {
            return try await execute(token)
        }
        return try await withRoomActivation(database: database, roomID: .init(uuid: export.intent.targetRoomID),
            shardID: shardID, epoch: epoch) { token in try await execute(token) }
    }
}
