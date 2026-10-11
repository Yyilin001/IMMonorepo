import Foundation
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerInfrastructure

import FluentKit

struct PostgresV2MessageEditStore: V2MessageEditStore {
    private let database: any Database
    private let contentReviewMode: V2ContentReviewMode
    private let identities: (any V2MembershipIdentitySnapshotValidating)?
    init(database: any Database, contentReviewMode: V2ContentReviewMode, identities: (any V2MembershipIdentitySnapshotValidating)? = nil) { self.database = database; self.contentReviewMode = contentReviewMode; self.identities = identities }
    func edit(command: V2EditMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageEditOutcome {
        try await database.transaction { transaction in
            try await V2PostgresMessageEditPersistence(transaction: transaction, contentReviewMode: contentReviewMode, identities: identities)
                .edit(command: command, capacityProfile: capacityProfile, eventID: eventID, now: now)
        }
    }
}

struct PostgresV2MessageWithdrawalStore: V2MessageWithdrawalStore {
    private let database: any Database
    init(database: any Database) { self.database = database }
    func withdraw(command: V2WithdrawMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageWithdrawalOutcome {
        try await database.transaction { transaction in
            try await V2PostgresMessageWithdrawalPersistence(transaction: transaction)
                .withdraw(command: command, capacityProfile: capacityProfile, eventID: eventID, now: now)
        }
    }
}

struct PostgresV2MessageReactionStore: V2MessageReactionStore {
    private let database: any Database
    init(database: any Database) { self.database = database }
    func change(command: V2ChangeMessageReactionCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageReactionOutcome {
        try await database.transaction { transaction in
            try await V2PostgresMessageReactionPersistence(transaction: transaction)
                .change(command: command, capacityProfile: capacityProfile, eventID: eventID, now: now)
        }
    }
}
