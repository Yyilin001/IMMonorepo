import Foundation

actor IMMessageWriteMetrics {
    struct StageSnapshot: Sendable {
        var count: Int = 0
        var totalMillis: Int = 0
        var maxMillis: Int = 0

        var averageMillis: Int {
            guard count > 0 else {
                return 0
            }
            return totalMillis / count
        }
    }

    struct Snapshot: Sendable {
        var sequenceBlocksReserved: Int = 0
        var sequenceBlockReserveFailures: Int = 0
        var sequenceBlockRemaining: Int = 0
        var ownerForwardCount: Int = 0
        var ownerForwardFailureCount: Int = 0
        var writeQueueDepth: Int = 0
        var memberCacheHits: Int = 0
        var memberCacheMisses: Int = 0
        var messageWriteBatches: Int = 0
        var messageWriteBatchMessages: Int = 0
        var writeQueueRejected: Int = 0
        var commandSendRequests: Int = 0
        var commandSendFailures: Int = 0
        var commandSendFullResponses: Int = 0
        var commandSendCompactResponses: Int = 0
        var commandSendTotalMillis: Int = 0
        var commandSendMaxMillis: Int = 0
        var commandSendDecodeMillis: Int = 0
        var commandSendDecodeMaxMillis: Int = 0
        var commandSendPersistMillis: Int = 0
        var commandSendPersistMaxMillis: Int = 0
        var commandSendResponseEncodeMillis: Int = 0
        var commandSendResponseEncodeMaxMillis: Int = 0
        var prepareMessages: Int = 0
        var prepareTotalMillis: Int = 0
        var prepareMaxMillis: Int = 0
        var batchQueueWaitMessages: Int = 0
        var batchQueueWaitTotalMillis: Int = 0
        var batchQueueWaitMaxMillis: Int = 0
        var persistencePipelineBatches: Int = 0
        var persistencePipelineMessages: Int = 0
        var persistencePipelineTotalMillis: Int = 0
        var persistencePipelineMaxMillis: Int = 0
        var persistencePipelineMaxRecipients: Int = 0
        var persistenceStages: [String: StageSnapshot] = [:]
    }

    private var snapshot = Snapshot()

    func recordSequenceBlockReserved() { snapshot.sequenceBlocksReserved += 1 }
    func recordSequenceBlockReserveFailed() { snapshot.sequenceBlockReserveFailures += 1 }
    func recordSequenceBlockRemaining(_ value: Int) { snapshot.sequenceBlockRemaining = value }
    func recordOwnerForwarded() { snapshot.ownerForwardCount += 1 }
    func recordOwnerForwardFailed() { snapshot.ownerForwardFailureCount += 1 }
    func recordWriteQueueDepth(_ value: Int) { snapshot.writeQueueDepth = value }
    func recordMemberCacheHit() { snapshot.memberCacheHits += 1 }
    func recordMemberCacheMiss() { snapshot.memberCacheMisses += 1 }
    func recordWriteQueueRejected() { snapshot.writeQueueRejected += 1 }
    func recordMessageWriteBatch(messageCount: Int) {
        snapshot.messageWriteBatches += 1
        snapshot.messageWriteBatchMessages += messageCount
    }

    func recordCommandSend(
        durationMillis: Int,
        decodeMillis: Int,
        persistMillis: Int,
        responseEncodeMillis: Int,
        fullResponse: Bool,
        didFail: Bool
    ) {
        let safeDuration = max(0, durationMillis)
        let safeDecode = max(0, decodeMillis)
        let safePersist = max(0, persistMillis)
        let safeEncode = max(0, responseEncodeMillis)
        snapshot.commandSendRequests += 1
        if didFail {
            snapshot.commandSendFailures += 1
        }
        if fullResponse {
            snapshot.commandSendFullResponses += 1
        } else {
            snapshot.commandSendCompactResponses += 1
        }
        snapshot.commandSendTotalMillis += safeDuration
        snapshot.commandSendMaxMillis = max(snapshot.commandSendMaxMillis, safeDuration)
        snapshot.commandSendDecodeMillis += safeDecode
        snapshot.commandSendDecodeMaxMillis = max(snapshot.commandSendDecodeMaxMillis, safeDecode)
        snapshot.commandSendPersistMillis += safePersist
        snapshot.commandSendPersistMaxMillis = max(snapshot.commandSendPersistMaxMillis, safePersist)
        snapshot.commandSendResponseEncodeMillis += safeEncode
        snapshot.commandSendResponseEncodeMaxMillis = max(snapshot.commandSendResponseEncodeMaxMillis, safeEncode)
    }

    func recordPrepareMessage(durationMillis: Int) {
        let safeDuration = max(0, durationMillis)
        snapshot.prepareMessages += 1
        snapshot.prepareTotalMillis += safeDuration
        snapshot.prepareMaxMillis = max(snapshot.prepareMaxMillis, safeDuration)
    }

    func recordBatchQueueWait(durationMillis: Int, messageCount: Int) {
        let safeDuration = max(0, durationMillis)
        let safeMessageCount = max(0, messageCount)
        snapshot.batchQueueWaitMessages += safeMessageCount
        snapshot.batchQueueWaitTotalMillis += safeDuration * safeMessageCount
        snapshot.batchQueueWaitMaxMillis = max(snapshot.batchQueueWaitMaxMillis, safeDuration)
    }

    func recordPersistencePipeline(
        messageCount: Int,
        recipientCount: Int,
        totalMillis: Int,
        stageMillis: [String: Int]
    ) {
        let safeMessageCount = max(0, messageCount)
        let safeRecipientCount = max(0, recipientCount)
        let safeTotal = max(0, totalMillis)
        snapshot.persistencePipelineBatches += 1
        snapshot.persistencePipelineMessages += safeMessageCount
        snapshot.persistencePipelineTotalMillis += safeTotal
        snapshot.persistencePipelineMaxMillis = max(snapshot.persistencePipelineMaxMillis, safeTotal)
        snapshot.persistencePipelineMaxRecipients = max(snapshot.persistencePipelineMaxRecipients, safeRecipientCount)
        for (name, millis) in stageMillis {
            let safeMillis = max(0, millis)
            var stage = snapshot.persistenceStages[name] ?? StageSnapshot()
            stage.count += 1
            stage.totalMillis += safeMillis
            stage.maxMillis = max(stage.maxMillis, safeMillis)
            snapshot.persistenceStages[name] = stage
        }
    }

    func currentSnapshot() -> Snapshot { snapshot }
}
