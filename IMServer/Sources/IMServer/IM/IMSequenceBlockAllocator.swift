import Fluent
import SQLKit
import Vapor

actor IMSequenceBlockAllocator {
    private struct Block {
        var next: Int
        let end: Int
    }

    private var blocks: [UUID: Block] = [:]

    func nextSequences(
        count: Int,
        conversationID: UUID,
        blockSize: Int,
        updatedAt: Date,
        on database: any Database,
        app: Application?
    ) async throws -> [Int] {
        guard count > 0 else {
            return []
        }

        var sequences: [Int] = []
        sequences.reserveCapacity(count)
        for _ in 0..<count {
            sequences.append(
                try await nextSequence(
                    conversationID: conversationID,
                    blockSize: blockSize,
                    updatedAt: updatedAt,
                    on: database,
                    app: app
                )
            )
        }
        return sequences
    }

    func nextSequence(
        conversationID: UUID,
        blockSize: Int,
        updatedAt: Date,
        on database: any Database,
        app: Application?
    ) async throws -> Int {
        if var block = blocks[conversationID], block.next <= block.end {
            let sequence = block.next
            block.next += 1
            blocks[conversationID] = block
            await app?.messageWriteMetrics.recordSequenceBlockRemaining(max(0, block.end - block.next + 1))
            return sequence
        }

        do {
            let reserved = try await ConversationSequenceAllocator(db: database).reserve(
                count: blockSize,
                conversationID: conversationID,
                updatedAt: updatedAt
            )
            guard let start = reserved.first, let end = reserved.last else {
                throw Abort(.notFound, reason: "会话不存在。")
            }
            blocks[conversationID] = Block(next: start + 1, end: end)
            await app?.messageWriteMetrics.recordSequenceBlockReserved()
            await app?.messageWriteMetrics.recordSequenceBlockRemaining(blockSize - 1)
            return start
        } catch {
            await app?.messageWriteMetrics.recordSequenceBlockReserveFailed()
            throw error
        }
    }
}
