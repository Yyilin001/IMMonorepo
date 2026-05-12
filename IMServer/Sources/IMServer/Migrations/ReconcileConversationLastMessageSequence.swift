import Fluent

struct ReconcileConversationLastMessageSequence: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await ConversationSequenceCounterRepairService(db: database).reconcileLastMessageSequences()
    }

    func revert(on database: any Database) async throws { }
}
