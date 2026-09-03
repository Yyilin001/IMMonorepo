import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

struct V2GatewayRuntimeConfigurationTests {
    @Test("frame compression is opt-in and bounded by the frame policy")
    func validatesFrameCompressionPolicy() throws {
        let defaults = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(runtimeValues)
        )
        #expect(defaults.frameCompression == nil)
        #expect(defaults.frameCompressionThresholdBytes == 1_024)
        #expect(defaults.frameCompressionMaximumExpansionRatio == 64)

        var enabled = runtimeValues
        enabled["IM_V2_FRAME_COMPRESSION"] = "zlib"
        enabled["IM_V2_FRAME_COMPRESSION_THRESHOLD_BYTES"] = "2048"
        enabled["IM_V2_FRAME_COMPRESSION_MAX_EXPANSION_RATIO"] = "32"
        let configured = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(enabled)
        )
        #expect(configured.frameCompression == .zlib)
        #expect(configured.frameCompressionThresholdBytes == 2_048)
        #expect(configured.frameCompressionMaximumExpansionRatio == 32)

        var oversizedThreshold = enabled
        oversizedThreshold["IM_V2_FRAME_COMPRESSION_THRESHOLD_BYTES"] = "65537"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_FRAME_COMPRESSION_THRESHOLD_BYTES"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(oversizedThreshold)
            )
        }
    }

    @Test("foreground group batching has a bounded pressure extension")
    func validatesForegroundGroupBatchingPolicy() throws {
        let defaults = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(runtimeValues)
        )
        #expect(defaults.foregroundGroupBatchMaximumEvents == 64)
        #expect(defaults.foregroundGroupPendingMaximumEventsPerRoom == 1_024)
        #expect(defaults.foregroundGroupBatchDelayMilliseconds == 10)
        #expect(defaults.foregroundGroupBatchExtensionDelayMilliseconds == 10)
        #expect(defaults.foregroundGroupBatchExtensionMinimumEvents == 8)
        #expect(defaults.readReceiptBatchSize == 32)
        #expect(defaults.readReceiptBatchMaximumDelayMilliseconds == 2)
        #expect(defaults.readReceiptBatchMaximumInFlightBatches == 8)
        #expect(
            defaults.readReceiptBatchMaximumPendingRequests ==
                defaults.foregroundWriteDatabaseWorkMaximumQueued
        )

        var configured = runtimeValues
        configured["IM_V2_FOREGROUND_GROUP_BATCH_MAX_EVENTS"] = "128"
        configured["IM_V2_FOREGROUND_GROUP_PENDING_MAX_EVENTS_PER_ROOM"] = "2048"
        configured["IM_V2_FOREGROUND_GROUP_BATCH_DELAY_MS"] = "5"
        configured["IM_V2_FOREGROUND_GROUP_BATCH_EXTENSION_DELAY_MS"] = "15"
        configured["IM_V2_FOREGROUND_GROUP_BATCH_EXTENSION_MIN_EVENTS"] = "16"
        configured["IM_V2_READ_RECEIPT_BATCH_SIZE"] = "64"
        configured["IM_V2_READ_RECEIPT_BATCH_MAX_DELAY_MS"] = "4"
        configured["IM_V2_READ_RECEIPT_BATCH_MAX_IN_FLIGHT"] = "6"
        configured["IM_V2_READ_RECEIPT_BATCH_MAX_PENDING_REQUESTS"] = "4096"
        let parsed = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(configured)
        )
        #expect(parsed.foregroundGroupBatchMaximumEvents == 128)
        #expect(parsed.foregroundGroupPendingMaximumEventsPerRoom == 2_048)
        #expect(parsed.foregroundGroupBatchDelayMilliseconds == 5)
        #expect(parsed.foregroundGroupBatchExtensionDelayMilliseconds == 15)
        #expect(parsed.foregroundGroupBatchExtensionMinimumEvents == 16)
        #expect(parsed.readReceiptBatchSize == 64)
        #expect(parsed.readReceiptBatchMaximumDelayMilliseconds == 4)
        #expect(parsed.readReceiptBatchMaximumInFlightBatches == 6)
        #expect(parsed.readReceiptBatchMaximumPendingRequests == 4_096)

        let error = V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_FOREGROUND_GROUP_BATCH_MAX_EVENTS/IM_V2_FOREGROUND_GROUP_PENDING_MAX_EVENTS_PER_ROOM/IM_V2_FOREGROUND_GROUP_BATCH_DELAY_MS/IM_V2_FOREGROUND_GROUP_BATCH_EXTENSION_DELAY_MS/IM_V2_FOREGROUND_GROUP_BATCH_EXTENSION_MIN_EVENTS"
        )
        var invalidThreshold = runtimeValues
        invalidThreshold["IM_V2_FOREGROUND_GROUP_BATCH_MAX_EVENTS"] = "8"
        invalidThreshold["IM_V2_FOREGROUND_GROUP_PENDING_MAX_EVENTS_PER_ROOM"] = "8"
        invalidThreshold["IM_V2_FOREGROUND_GROUP_BATCH_EXTENSION_MIN_EVENTS"] = "9"
        #expect(throws: error) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(invalidThreshold)
            )
        }

        var invalidPendingBound = runtimeValues
        invalidPendingBound["IM_V2_FOREGROUND_GROUP_BATCH_MAX_EVENTS"] = "128"
        invalidPendingBound["IM_V2_FOREGROUND_GROUP_PENDING_MAX_EVENTS_PER_ROOM"] = "64"
        #expect(throws: error) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(invalidPendingBound)
            )
        }

        var invalidTotalDelay = runtimeValues
        invalidTotalDelay["IM_V2_FOREGROUND_GROUP_BATCH_DELAY_MS"] = "80"
        invalidTotalDelay["IM_V2_FOREGROUND_GROUP_BATCH_EXTENSION_DELAY_MS"] = "30"
        #expect(throws: error) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(invalidTotalDelay)
            )
        }

        var invalidReceiptBatch = runtimeValues
        invalidReceiptBatch["IM_V2_READ_RECEIPT_BATCH_SIZE"] = "129"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_READ_RECEIPT_BATCH_SIZE"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(invalidReceiptBatch)
            )
        }

        var invalidReceiptPending = runtimeValues
        invalidReceiptPending["IM_V2_READ_RECEIPT_BATCH_SIZE"] = "64"
        invalidReceiptPending[
            "IM_V2_READ_RECEIPT_BATCH_MAX_PENDING_REQUESTS"
        ] = "63"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_READ_RECEIPT_BATCH_MAX_PENDING_REQUESTS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(invalidReceiptPending)
            )
        }
    }

    @Test("prepared group-event page cache is opt-in and requires both bounds")
    func validatesPreparedGroupEventPageCachePolicy() throws {
        let defaults = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(runtimeValues)
        )
        #expect(defaults.preparedGroupEventPageCacheMaximumEntries == 0)
        #expect(defaults.preparedGroupEventPageCacheMaximumBytes == 0)
        #expect(defaults.preparedGroupEventPageCacheShardCount == 0)

        var enabled = runtimeValues
        enabled["IM_V2_PREPARED_GROUP_EVENT_PAGE_CACHE_MAX_ENTRIES"] = "8192"
        enabled["IM_V2_PREPARED_GROUP_EVENT_PAGE_CACHE_MAX_BYTES"] = "268435456"
        enabled["IM_V2_PREPARED_GROUP_EVENT_PAGE_CACHE_SHARDS"] = "16"
        let configured = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(enabled)
        )
        #expect(configured.preparedGroupEventPageCacheMaximumEntries == 8_192)
        #expect(configured.preparedGroupEventPageCacheMaximumBytes == 268_435_456)
        #expect(configured.preparedGroupEventPageCacheShardCount == 16)

        var missingByteBound = runtimeValues
        missingByteBound["IM_V2_PREPARED_GROUP_EVENT_PAGE_CACHE_MAX_ENTRIES"] = "8192"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_PREPARED_GROUP_EVENT_PAGE_CACHE_MAX_ENTRIES/IM_V2_PREPARED_GROUP_EVENT_PAGE_CACHE_MAX_BYTES/IM_V2_PREPARED_GROUP_EVENT_PAGE_CACHE_SHARDS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(missingByteBound)
            )
        }
    }

    @Test("runtime has no secret or capacity defaults")
    func rejectsMissingConfiguration() {
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_DATABASE_URL")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment([:]))
        }
    }

    @Test("message projection rollout modes are validated as one compatibility fence")
    func validatesMessageProjectionRolloutModes() throws {
        let defaults = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(runtimeValues)
        )
        #expect(defaults.messageProjectionWriteMode == .dual)
        #expect(defaults.messageProjectionReadMode == .preferShared)
        #expect(defaults.messageProjectionStateRetentionSeconds == 604_800)
        #expect(defaults.directFanoutMode == .planner)
        #expect(defaults.directRoomLogAdmissionMode == .room)
        #expect(defaults.directRoomLogShardAdmissionCreditBatchSize == 0)
        #expect(defaults.directRoomLogRoomAdmissionCreditBatchSize == 0)
        #expect(defaults.directRoomLogAppendBatchSize == 0)
        #expect(defaults.directRoomLogAppendBatchMaximumInFlightBatches == 8)
        #expect(defaults.directRoomLogAppendLaneCount == 1)
        #expect(defaults.directRoomLogAppendBatchMaximumDelayMilliseconds == 2)
        #expect(defaults.directRoomLogAppendBatchHighActivityMaximumDelayMilliseconds == nil)
        #expect(defaults.directRoomLogAppendBatchHighActivityMinimumRequests == nil)
        #expect(defaults.directRoomLogAppendBatchHighActivityWindowMilliseconds == nil)
        #expect(defaults.directSendPolicyCacheMaximumEntries == 50_000)
        #expect(defaults.directRoomLogEventCacheMaximumEntries == 0)
        #expect(defaults.directRoomLogEventCacheMaximumBytes == 0)
        #expect(defaults.directRoomLogEventCacheMaximumEntriesPerRoom == 0)
        #expect(defaults.directRoomLogEventCacheShardCount == 0)
        #expect(defaults.directRoomLogEventCacheMaximumPendingWrites == 0)
        #expect(defaults.livePresenceRenewalBatchSize == 256)
        #expect(defaults.livePresenceRenewalMaximumDelayMilliseconds == 2)
        #expect(defaults.groupEventWakePollIntervalMilliseconds == 500)
        #expect(defaults.shutdownGraceMilliseconds == 20_000)
        #expect(defaults.fanoutPayloadWriteMode == .body)

        var shared = runtimeValues
        shared["IM_V2_MESSAGE_PROJECTION_WRITE_MODE"] = "shared"
        shared["IM_V2_MESSAGE_PROJECTION_READ_MODE"] = "shared"
        shared["IM_V2_MESSAGE_PROJECTION_STATE_RETENTION_SECONDS"] = "86400"
        let sharedConfiguration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(shared)
        )
        #expect(sharedConfiguration.messageProjectionWriteMode == .shared)
        #expect(sharedConfiguration.messageProjectionReadMode == .shared)
        #expect(sharedConfiguration.messageProjectionStateRetentionSeconds == 86_400)

        var preplanned = runtimeValues
        preplanned["IM_V2_DIRECT_FANOUT_MODE"] = "preplanned"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(preplanned)
        ).directFanoutMode == .preplanned)

        var roomLog = runtimeValues
        roomLog["IM_V2_DIRECT_FANOUT_MODE"] = "room_log"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(roomLog)
        ).directFanoutMode == .roomLog)

        var shardOnlyAdmission = roomLog
        shardOnlyAdmission["IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE"] = "shard_only"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(shardOnlyAdmission)
        ).directRoomLogAdmissionMode == .shardOnly)

        var shardOnlyAdmissionOutsideRoomLog = runtimeValues
        shardOnlyAdmissionOutsideRoomLog["IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE"] = "shard_only"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(shardOnlyAdmissionOutsideRoomLog)
            )
        }

        var credits = roomLog
        credits["IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE"] = "64"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(credits)
        ).directRoomLogShardAdmissionCreditBatchSize == 64)

        var roomCredits = credits
        roomCredits["IM_V2_DIRECT_ROOM_LOG_ROOM_CREDIT_BATCH_SIZE"] = "16"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(roomCredits)
        ).directRoomLogRoomAdmissionCreditBatchSize == 16)

        var roomCreditsWithoutShardCredits = roomLog
        roomCreditsWithoutShardCredits["IM_V2_DIRECT_ROOM_LOG_ROOM_CREDIT_BATCH_SIZE"] = "16"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_ROOM_CREDIT_BATCH_SIZE"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(roomCreditsWithoutShardCredits)
            )
        }

        var roomCreditsWithShardOnlyAdmission = shardOnlyAdmission
        roomCreditsWithShardOnlyAdmission["IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE"] = "64"
        roomCreditsWithShardOnlyAdmission["IM_V2_DIRECT_ROOM_LOG_ROOM_CREDIT_BATCH_SIZE"] = "16"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_ROOM_CREDIT_BATCH_SIZE"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(roomCreditsWithShardOnlyAdmission)
            )
        }

        var oversizedRoomCredits = credits
        oversizedRoomCredits["IM_V2_DIRECT_ROOM_LOG_ROOM_CREDIT_BATCH_SIZE"] = "33"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_ROOM_CREDIT_BATCH_SIZE"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(oversizedRoomCredits)
            )
        }

        var appendBatch = credits
        appendBatch["IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE"] = "32"
        appendBatch["IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_DELAY_MS"] = "2"
        let appendBatchConfiguration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(appendBatch)
        )
        #expect(appendBatchConfiguration.directRoomLogAppendBatchSize == 32)
        #expect(appendBatchConfiguration.directRoomLogAppendBatchMaximumInFlightBatches == 8)
        #expect(appendBatchConfiguration.directRoomLogAppendMaximumPendingRequests == 288)
        #expect(appendBatchConfiguration.directRoomLogAppendLaneCount == 1)
        #expect(appendBatchConfiguration.directRoomLogAppendBatchMaximumDelayMilliseconds == 2)

        var burstSizedAppendBatch = appendBatch
        burstSizedAppendBatch[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_MAX_PENDING_REQUESTS"
        ] = "4096"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(burstSizedAppendBatch)
        ).directRoomLogAppendMaximumPendingRequests == 4_096)

        var appendPendingWithoutBatching = credits
        appendPendingWithoutBatching[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_MAX_PENDING_REQUESTS"
        ] = "4096"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_MAX_PENDING_REQUESTS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(appendPendingWithoutBatching)
            )
        }

        var undersizedAppendPending = appendBatch
        undersizedAppendPending[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_MAX_PENDING_REQUESTS"
        ] = "31"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_MAX_PENDING_REQUESTS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(undersizedAppendPending)
            )
        }

        var largerAppendBatch = appendBatch
        largerAppendBatch["IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE"] = "64"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(largerAppendBatch)
        ).directRoomLogAppendBatchSize == 64)

        var shardedAppendBatch = appendBatch
        shardedAppendBatch["IM_V2_DIRECT_ROOM_LOG_APPEND_LANES"] = "4"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(shardedAppendBatch)
        ).directRoomLogAppendLaneCount == 4)

        var shardingWithoutBatching = credits
        shardingWithoutBatching["IM_V2_DIRECT_ROOM_LOG_APPEND_LANES"] = "2"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_LANES"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(shardingWithoutBatching)
            )
        }

        var tooManyAppendLanes = appendBatch
        tooManyAppendLanes["IM_V2_DIRECT_ROOM_LOG_APPEND_LANES"] = "9"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_LANES"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(tooManyAppendLanes)
            )
        }

        var widenedAppendBatchConcurrency = appendBatch
        widenedAppendBatchConcurrency[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_IN_FLIGHT"
        ] = "12"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(widenedAppendBatchConcurrency)
        ).directRoomLogAppendBatchMaximumInFlightBatches == 12)

        var appendBatchConcurrencyWithoutBatching = credits
        appendBatchConcurrencyWithoutBatching[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_IN_FLIGHT"
        ] = "12"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_IN_FLIGHT"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(appendBatchConcurrencyWithoutBatching)
            )
        }

        var oversizedAppendBatchConcurrency = appendBatch
        oversizedAppendBatchConcurrency[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_IN_FLIGHT"
        ] = "37"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_IN_FLIGHT"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(oversizedAppendBatchConcurrency)
            )
        }

        var eventCache = roomLog
        eventCache["IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES"] = "4096"
        eventCache["IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_BYTES"] = "16777216"
        eventCache["IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES_PER_ROOM"] = "32"
        eventCache["IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_SHARDS"] = "8"
        eventCache["IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_PENDING_WRITES"] = "2048"
        let eventCacheConfiguration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(eventCache)
        )
        #expect(eventCacheConfiguration.directRoomLogEventCacheMaximumEntries == 4096)
        #expect(eventCacheConfiguration.directRoomLogEventCacheMaximumBytes == 16_777_216)
        #expect(eventCacheConfiguration.directRoomLogEventCacheMaximumEntriesPerRoom == 32)
        #expect(eventCacheConfiguration.directRoomLogEventCacheShardCount == 8)
        #expect(eventCacheConfiguration.directRoomLogEventCacheMaximumPendingWrites == 2_048)

        var largeEventCache = roomLog
        largeEventCache["IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES"] = "262144"
        largeEventCache["IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_BYTES"] = "268435456"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(largeEventCache)
        ).directRoomLogEventCacheMaximumEntries == 262_144)

        var deepHotRoomEventCache = largeEventCache
        deepHotRoomEventCache[
            "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES_PER_ROOM"
        ] = "4096"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(deepHotRoomEventCache)
        ).directRoomLogEventCacheMaximumEntriesPerRoom == 4_096)

        var oversizedHotRoomEventCache = largeEventCache
        oversizedHotRoomEventCache[
            "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES_PER_ROOM"
        ] = "16385"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_BYTES/IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES_PER_ROOM/IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_SHARDS/IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_PENDING_WRITES"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(oversizedHotRoomEventCache)
            )
        }

        var largerPolicyCache = runtimeValues
        largerPolicyCache["IM_V2_DIRECT_SEND_POLICY_CACHE_MAX_ENTRIES"] = "131072"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(largerPolicyCache)
        ).directSendPolicyCacheMaximumEntries == 131_072)

        var largerFastAppendCache = runtimeValues
        largerFastAppendCache[
            "IM_V2_DIRECT_ROOM_LOG_FAST_APPEND_CACHE_MAX_ENTRIES"
        ] = "131072"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(largerFastAppendCache)
        ).directRoomLogFastAppendCacheMaximumEntries == 131_072)

        var longerFastAppendCache = runtimeValues
        longerFastAppendCache[
            "IM_V2_DIRECT_ROOM_LOG_FAST_APPEND_CACHE_TTL_SECONDS"
        ] = "900"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(longerFastAppendCache)
        ).directRoomLogFastAppendCacheLifetimeSeconds == 900)

        var invalidPolicyCache = runtimeValues
        invalidPolicyCache["IM_V2_DIRECT_SEND_POLICY_CACHE_MAX_ENTRIES"] = "0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_SEND_POLICY_CACHE_MAX_ENTRIES"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(invalidPolicyCache)
            )
        }

        var invalidFastAppendCache = runtimeValues
        invalidFastAppendCache[
            "IM_V2_DIRECT_ROOM_LOG_FAST_APPEND_CACHE_MAX_ENTRIES"
        ] = "0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_FAST_APPEND_CACHE_MAX_ENTRIES"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(invalidFastAppendCache)
            )
        }

        var invalidFastAppendCacheLifetime = runtimeValues
        invalidFastAppendCacheLifetime[
            "IM_V2_DIRECT_ROOM_LOG_FAST_APPEND_CACHE_TTL_SECONDS"
        ] = "0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_FAST_APPEND_CACHE_TTL_SECONDS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(invalidFastAppendCacheLifetime)
            )
        }

        var eventCacheOutsideRoomLog = runtimeValues
        eventCacheOutsideRoomLog["IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES"] = "4096"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(eventCacheOutsideRoomLog)
            )
        }

        var highActivityAppendBatch = appendBatch
        highActivityAppendBatch["IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_DELAY_MS"] = "20"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(highActivityAppendBatch)
        ).directRoomLogAppendBatchMaximumDelayMilliseconds == 20)

        var adaptiveHighActivityAppendBatch = appendBatch
        adaptiveHighActivityAppendBatch[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_DELAY_MS"
        ] = "20"
        adaptiveHighActivityAppendBatch[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_MIN_REQUESTS"
        ] = "8"
        adaptiveHighActivityAppendBatch[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_WINDOW_MS"
        ] = "20"
        let adaptiveHighActivityConfiguration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(adaptiveHighActivityAppendBatch)
        )
        #expect(adaptiveHighActivityConfiguration
            .directRoomLogAppendBatchHighActivityMaximumDelayMilliseconds == 20)
        #expect(adaptiveHighActivityConfiguration
            .directRoomLogAppendBatchHighActivityMinimumRequests == 8)
        #expect(adaptiveHighActivityConfiguration
            .directRoomLogAppendBatchHighActivityWindowMilliseconds == 20)

        // The production high-throughput overlay uses a one-second, 400
        // request threshold: at a 20 ms long-delay budget this predicts at
        // least eight arrivals to amortise the additional interactive wait.
        // Keep that larger valid boundary covered so a future parser change
        // cannot silently reject the deployed profile.
        var productionAdaptiveHighActivityAppendBatch = appendBatch
        productionAdaptiveHighActivityAppendBatch[
            "IM_V2_FOREGROUND_WRITE_DATABASE_WORK_MAX_QUEUED"
        ] = "512"
        productionAdaptiveHighActivityAppendBatch[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_DELAY_MS"
        ] = "20"
        productionAdaptiveHighActivityAppendBatch[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_MIN_REQUESTS"
        ] = "400"
        productionAdaptiveHighActivityAppendBatch[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_WINDOW_MS"
        ] = "1000"
        let productionAdaptiveHighActivityConfiguration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(productionAdaptiveHighActivityAppendBatch)
        )
        #expect(productionAdaptiveHighActivityConfiguration
            .directRoomLogAppendBatchHighActivityMinimumRequests == 400)
        #expect(productionAdaptiveHighActivityConfiguration
            .directRoomLogAppendBatchHighActivityWindowMilliseconds == 1000)

        // The single-host deployment reserves the same 32 isolated
        // foreground permits as 12/4/16 (append/control/read). This protects
        // the read-biased 1,000 msg/s profile from being rejected on startup
        // while retaining an explicit physical-pool fence.
        var readBiasedForeground = runtimeValues
        readBiasedForeground["IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP"] = "16"
        readBiasedForeground["IM_V2_DATABASE_FOREGROUND_CONNECTIONS_PER_EVENT_LOOP"] = "8"
        readBiasedForeground["IM_V2_DATABASE_SYNC_CONNECTIONS_PER_EVENT_LOOP"] = "4"
        readBiasedForeground["IM_V2_DATABASE_DELIVERY_CONNECTIONS_PER_EVENT_LOOP"] = "2"
        readBiasedForeground["IM_V2_FOREGROUND_WRITE_DATABASE_WORK_LIMIT"] = "12"
        readBiasedForeground["IM_V2_FOREGROUND_CONTROL_WRITE_DATABASE_WORK_LIMIT"] = "4"
        readBiasedForeground["IM_V2_INTERACTIVE_READ_DATABASE_WORK_LIMIT"] = "16"
        readBiasedForeground["IM_V2_SYNC_DATABASE_WORK_LIMIT"] = "16"
        let readBiasedForegroundConfiguration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(readBiasedForeground)
        )
        #expect(readBiasedForegroundConfiguration.foregroundWriteDatabaseWorkLimit == 12)
        #expect(readBiasedForegroundConfiguration.interactiveReadDatabaseWorkLimit == 16)

        var incompleteAdaptiveHighActivityAppendBatch = appendBatch
        incompleteAdaptiveHighActivityAppendBatch[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_DELAY_MS"
        ] = "20"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_DELAY_MS/IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_MIN_REQUESTS/IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_WINDOW_MS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(incompleteAdaptiveHighActivityAppendBatch)
            )
        }

        var nonIncreasingAdaptiveHighActivityAppendBatch = adaptiveHighActivityAppendBatch
        nonIncreasingAdaptiveHighActivityAppendBatch[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_DELAY_MS"
        ] = "2"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_DELAY_MS/IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_MIN_REQUESTS/IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_WINDOW_MS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(nonIncreasingAdaptiveHighActivityAppendBatch)
            )
        }

        var excessiveAppendBatchDelay = appendBatch
        excessiveAppendBatchDelay["IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_DELAY_MS"] = "26"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_DELAY_MS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(excessiveAppendBatchDelay)
            )
        }

        var appendBatchWithoutCredits = roomLog
        appendBatchWithoutCredits["IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE"] = "16"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(appendBatchWithoutCredits)
            )
        }

        var oversizedAppendBatch = credits
        oversizedAppendBatch["IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE"] = "129"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(oversizedAppendBatch)
            )
        }

        var creditsOutsideRoomLog = runtimeValues
        creditsOutsideRoomLog["IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE"] = "64"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(creditsOutsideRoomLog)
            )
        }

        var oversizedCredits = roomLog
        oversizedCredits["IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE"] = "129"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(oversizedCredits)
            )
        }

        var referencePayload = runtimeValues
        referencePayload["IM_V2_FANOUT_PAYLOAD_WRITE_MODE"] = "reference"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(referencePayload)
        ).fanoutPayloadWriteMode == .reference)

        var invalidDirectFanout = runtimeValues
        invalidDirectFanout["IM_V2_DIRECT_FANOUT_MODE"] = "client_selected"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DIRECT_FANOUT_MODE")) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(invalidDirectFanout)
            )
        }

        var invalidFanoutPayload = runtimeValues
        invalidFanoutPayload["IM_V2_FANOUT_PAYLOAD_WRITE_MODE"] = "client_selected"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_FANOUT_PAYLOAD_WRITE_MODE")) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(invalidFanoutPayload)
            )
        }

        var unsafe = runtimeValues
        unsafe["IM_V2_MESSAGE_PROJECTION_WRITE_MODE"] = "shared"
        unsafe["IM_V2_MESSAGE_PROJECTION_READ_MODE"] = "inline"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_MESSAGE_PROJECTION_WRITE_MODE/IM_V2_MESSAGE_PROJECTION_READ_MODE"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(unsafe)
            )
        }

        var shortRetention = runtimeValues
        shortRetention["IM_V2_MESSAGE_PROJECTION_STATE_RETENTION_SECONDS"] = "86399"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_MESSAGE_PROJECTION_STATE_RETENTION_SECONDS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(shortRetention)
            )
        }
    }

    @Test("runtime requires an explicit protobuf nesting limit")
    func rejectsMissingProtobufNestingLimit() {
        var values = runtimeValues
        values.removeValue(forKey: "IM_V2_MAX_PROTOBUF_MESSAGE_DEPTH")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_MAX_PROTOBUF_MESSAGE_DEPTH")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("runtime requires an explicit fan-out fresh-burst fairness policy")
    func rejectsMissingFanoutFreshBurstPolicy() {
        var values = runtimeValues
        values.removeValue(forKey: "IM_V2_FANOUT_FRESH_BURST_PASSES")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_FANOUT_FRESH_BURST_PASSES")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("server idempotency retention cannot undercut the client retry contract")
    func rejectsShortIdempotencyRetention() throws {
        var values = runtimeValues
        values["IM_V2_IDEMPOTENCY_RETENTION_SECONDS"] = String(
            Int(V2IdempotencyPolicy.minimumServerRetention) - 1
        )
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_IDEMPOTENCY_RETENTION_SECONDS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(values)
            )
        }
    }

    @Test("runtime requires a bounded fan-out delivery commit batch size")
    func validatesFanoutDeliveryCommitBatchSize() {
        var missing = runtimeValues
        missing.removeValue(forKey: "IM_V2_FANOUT_DELIVERY_COMMIT_BATCH_SIZE")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_FANOUT_DELIVERY_COMMIT_BATCH_SIZE")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(missing))
        }
        var oversized = runtimeValues
        oversized["IM_V2_FANOUT_DELIVERY_COMMIT_BATCH_SIZE"] = "129"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_FANOUT_DELIVERY_COMMIT_BATCH_SIZE")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(oversized))
        }
    }

    @Test("runtime requires a bounded cross-store fan-out delivery commit batch size")
    func validatesCrossStoreFanoutDeliveryCommitBatchSize() {
        var missing = runtimeValues
        missing.removeValue(forKey: "IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_BATCH_SIZE")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_BATCH_SIZE")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(missing))
        }
        var oversized = runtimeValues
        oversized["IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_BATCH_SIZE"] = "257"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_BATCH_SIZE")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(oversized))
        }
    }

    @Test("runtime requires a bounded cross-store fan-out commit concurrency")
    func validatesCrossStoreFanoutDeliveryCommitConcurrency() {
        var missing = runtimeValues
        missing.removeValue(forKey: "IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_CONCURRENCY")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_CONCURRENCY")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(missing))
        }
        var oversized = runtimeValues
        oversized["IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_CONCURRENCY"] = "3"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_CONCURRENCY")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(oversized))
        }
    }

    @Test("runtime requires a bounded fan-out delivery claim batch size")
    func validatesFanoutDeliveryClaimBatchSize() {
        var missing = runtimeValues
        missing.removeValue(forKey: "IM_V2_FANOUT_DELIVERY_CLAIM_BATCH_SIZE")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_FANOUT_DELIVERY_CLAIM_BATCH_SIZE")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(missing))
        }
        var oversized = runtimeValues
        oversized["IM_V2_FANOUT_DELIVERY_CLAIM_BATCH_SIZE"] = "2001"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_FANOUT_DELIVERY_CLAIM_BATCH_SIZE")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(oversized))
        }
    }

    @Test("runtime requires an explicit PostgreSQL pool ceiling")
    func rejectsMissingDatabasePoolCeiling() {
        var values = runtimeValues
        values.removeValue(forKey: "IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("gateway workload pools are explicit and cannot exceed the legacy ceiling")
    func validatesDatabaseWorkloadPoolBudget() {
        var missing = runtimeValues
        missing.removeValue(forKey: "IM_V2_DATABASE_SYNC_CONNECTIONS_PER_EVENT_LOOP")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing(
            "IM_V2_DATABASE_SYNC_CONNECTIONS_PER_EVENT_LOOP"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(missing)
            )
        }

        var oversized = runtimeValues
        oversized["IM_V2_DATABASE_FOREGROUND_CONNECTIONS_PER_EVENT_LOOP"] = "5"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DATABASE_WORKLOAD_POOL_BUDGET"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(oversized)
            )
        }
    }

    @Test("PostgreSQL policy bounds every wait and the aggregate physical pool budget")
    func validatesPostgresRuntimePolicy() throws {
        let configuration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(runtimeValues)
        )
        #expect(configuration.databasePolicy.eventLoopThreads == 4)
        #expect(configuration.databaseWorkloadPoolBudget.totalConnectionsPerEventLoop == 8)
        #expect(configuration.databaseWorkloadPoolIsolationEnabled)
        #expect(configuration.databasePolicy.poolTimeoutMilliseconds == 3_000)
        #expect(configuration.databasePolicy.startupParameters.count == 1)
        #expect(configuration.databasePolicy.startupParameters.first?.0 == "options")
        #expect(
            configuration.databasePolicy.startupParameters.first?.1 ==
            "-c statement_timeout=5000 -c lock_timeout=2000 -c idle_in_transaction_session_timeout=10000"
        )

        var invalidLock = runtimeValues
        invalidLock["IM_V2_DATABASE_LOCK_TIMEOUT_MS"] = "5001"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DATABASE_LOCK_TIMEOUT_MS/IM_V2_DATABASE_STATEMENT_TIMEOUT_MS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(invalidLock)
            )
        }

        var exhausted = runtimeValues
        exhausted["IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS"] = "31"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(exhausted)
            )
        }
    }

    @Test("isolated projection capacity accounts for every schema on one physical database")
    func validatesProjectionLanesPerPhysicalDatabase() {
        var values = runtimeValues
        values["IM_V2_USER_SHARD_STORES_JSON"] = """
        [{"bucket":"users-primary","database_url":"postgres://v2:password@db/im_v2","schema":"im_v2"},
         {"bucket":"users-next","database_url":"postgres://v2:password@db/im_v2","schema":"im_v2_next"}]
        """
        // Four projection connections cannot safely reserve two projector
        // lanes plus one snapshot builder for each of the two schemas.
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_USER_PROJECTION_CONCURRENCY/IM_V2_DATABASE_PROJECTION_CONNECTIONS_PER_EVENT_LOOP"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(values)
            )
        }

        values["IM_V2_DATABASE_PROJECTION_CONNECTIONS_PER_EVENT_LOOP"] = "2"
        values["IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP"] = "9"
        #expect(throws: Never.self) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(values)
            )
        }
    }

    @Test("logical user-shard stores have an independent process bound")
    func boundsLogicalUserShardStores() {
        var values = runtimeValues
        values["IM_V2_MAX_USER_SHARD_STORES"] = "1"
        values["IM_V2_USER_SHARD_STORES_JSON"] = """
        [{"bucket":"users-primary","database_url":"postgres://v2:password@db/im_v2","schema":"im_v2"},
         {"bucket":"users-next","database_url":"postgres://v2:password@db-next/im_v2","schema":"im_v2"}]
        """
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_MAX_USER_SHARD_STORES"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(values)
            )
        }
    }

    @Test("runtime parses a complete explicit deployment configuration")
    func parsesCompleteConfiguration() throws {
        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(runtimeValues))
        #expect(configuration.tls.port == 7443)
        #expect(configuration.databaseMaxConnectionsPerEventLoop == 8)
        #expect(configuration.frameLimits.maximumPayloadBytes == 65_536)
        #expect(configuration.maximumProtobufMessageDepth == 32)
        #expect(configuration.maximumConnections == 10_000)
        #expect(configuration.listenBacklog == 4_096)
        #expect(configuration.acceptBatchSize == 256)
        #expect(configuration.authenticatedConnectionAdmissionPolicy.maximumConnectionsPerDevice == 2)
        #expect(configuration.authenticatedConnectionAdmissionPolicy.maximumConnectionsPerUser == 8)
        #expect(configuration.commandRateLimitPolicy.deviceBurst == 64)
        #expect(configuration.maximumQueuedInboundChunks == 512)
        #expect(configuration.authenticationTimeoutMilliseconds == 10_000)
        #expect(configuration.capacityProfile.id == "standard")
        #expect(configuration.capacityProfile.limits.maxEligibleMembers == 100_000)
        #expect(configuration.workerBatchSize == 256)
        #expect(configuration.workerPollIntervalMilliseconds == 100)
        #expect(configuration.userProjectionConcurrency == 2)
        #expect(configuration.userProjectionMaximumConsecutiveBusyPasses == 16)
        #expect(configuration.userProjectionBusyDrainBudgetMilliseconds == 50)
        #expect(configuration.foregroundWriteDatabaseWorkLimit == 9)
        #expect(configuration.foregroundControlWriteDatabaseWorkLimit == 3)
        #expect(configuration.interactiveReadDatabaseWorkLimit == 4)
        #expect(configuration.syncDatabaseWorkLimit == 4)
        #expect(configuration.foregroundWriteDatabaseWorkMaximumQueued == 288)
        #expect(configuration.foregroundControlWriteDatabaseWorkMaximumQueued == 288)
        #expect(configuration.interactiveReadDatabaseWorkMaximumQueued == 96)
        #expect(configuration.syncDatabaseWorkMaximumQueued == 128)
        #expect(configuration.databaseWorkAdmissionTimeoutMilliseconds == 200)
        #expect(configuration.databaseWorkAdmissionEnabled)
        #expect(configuration.syncWakeCoalescingMilliseconds == 40)
        #expect(configuration.syncWakeMaximumPendingUsers == 50_000)
        #expect(configuration.syncWakeDeliveryConcurrency == 64)
        #expect(configuration.syncWakeCoalescingEnabled)
        #expect(configuration.acceptedMessageProjectionBatchEnabled)
        #expect(configuration.commandSuccessLogSamplePermille == 10)
        #expect(configuration.commandSlowLogThresholdMilliseconds == 250)
        #expect(configuration.commandDiagnosticLogMaximumPerSecond == 20)
        #expect(configuration.fanoutDeliveryCommitBatchSize == 128)
        #expect(configuration.crossStoreFanoutDeliveryCommitBatchSize == 256)
        #expect(configuration.crossStoreFanoutDeliveryCommitConcurrency == 2)
        #expect(configuration.fanoutDeliveryClaimBatchSize == 2_000)
        #expect(configuration.fanoutFreshBurstPasses == 7)
        #expect(configuration.durableRetryPolicy.initialDelay == 1)
        #expect(configuration.durableRetryPolicy.maximumDelay == 60)
        #expect(configuration.durableRetryPolicy.maximumAttempts == 10)
        #expect(configuration.durableRetryPolicy.jitterFraction == 0.2)
        #expect(configuration.maintenancePollIntervalMilliseconds == 60_000)
        #expect(configuration.backlogMaintenanceIdlePollIntervalMilliseconds == 1_000)
        #expect(configuration.backlogMaintenanceMaximumConsecutiveBusyPasses == 4)
        #expect(configuration.backlogMaintenanceBusyDrainBudgetMilliseconds == 100)
        #expect(configuration.mediaWithdrawnRetentionSeconds == 2_592_000)
        #expect(configuration.idempotencyRetentionSeconds == 3_888_000)
        let expectedMetrics = try V2MetricsListenerConfiguration(host: "127.0.0.1", port: 9464)
        #expect(configuration.metrics == expectedMetrics)
        #expect(configuration.metricsMinimumRefreshIntervalMilliseconds == 30_000)
        #expect(configuration.metricsRefreshTimeoutMilliseconds == 4_000)
        #expect(configuration.idleTimeoutMilliseconds == 60_000)
        #expect(configuration.gatewayNodeID == "gateway-a")
        #expect(configuration.gatewayReplicaCount == 1)
        #expect(configuration.userShardRoute.bucket == "users-primary")
        #expect(configuration.userShardRoute.observedRouterEpoch == 7)
        #expect(configuration.userShardStorage == [try .init(bucket: "users-primary", databaseURL: "postgres://v2:password@db/im_v2")])
        #expect(configuration.directRoomShardID == "rooms-primary")
        #expect(configuration.directRoomShardRouter.shardIDs == ["rooms-primary"])
        #expect(configuration.groupRoomShardID == "rooms-primary")
        #expect(configuration.groupRoomShardIDs == ["rooms-primary"])
        #expect(configuration.strangerMessagePolicy.maximumMessagesPerWindow == 3)
        #expect(configuration.strangerMessagePolicy.window == 86_400)
        #expect(configuration.contentReviewSafetyActorUserID == nil)
        guard case .durablePollingOnly = configuration.fanoutHint else {
            Issue.record("Expected durable polling without NATS configuration")
            return
        }
    }

    @Test("runtime rejects a malformed direct room owner route before readiness")
    func rejectsMalformedDirectRoomShardRoute() {
        var values = runtimeValues
        values["IM_V2_DIRECT_ROOM_SHARD_ID"] = "rooms-load-00,,rooms-load-01"

        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DIRECT_ROOM_SHARD_ID")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("metrics exact-aggregate cadence cannot be shorter than its timeout")
    func rejectsMetricsRefreshCadenceBelowTimeout() {
        var values = runtimeValues
        values["IM_V2_METRICS_MINIMUM_REFRESH_INTERVAL_MS"] = "3999"

        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_METRICS_REFRESH_TIMEOUT_MS/IM_V2_METRICS_MINIMUM_REFRESH_INTERVAL_MS/IM_V2_DATABASE_STATEMENT_TIMEOUT_MS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(values)
            )
        }
    }

    @Test("content-review safety actor must be a valid opaque user identifier")
    func validatesContentReviewSafetyActor() {
        var values = runtimeValues
        values["IM_V2_CONTENT_REVIEW_SAFETY_ACTOR_USER_ID"] = "not-a-user-id"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_CONTENT_REVIEW_SAFETY_ACTOR_USER_ID")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("content-review mode explicitly enables or disables the durable lane")
    func parsesContentReviewMode() throws {
        var values = runtimeValues
        values["IM_V2_CONTENT_REVIEW_MODE"] = "disabled"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(values)
        ).contentReviewMode == .disabled)

        values["IM_V2_CONTENT_REVIEW_MODE"] = "unexpected"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_CONTENT_REVIEW_MODE")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("content-review policy parses only when the trusted actor is explicitly provisioned")
    func parsesContentReviewPolicy() throws {
        var values = runtimeValues
        values["IM_V2_CONTENT_REVIEW_SAFETY_ACTOR_USER_ID"] = "00000000-0000-0000-0000-000000000901"
        values["IM_V2_CONTENT_REVIEW_VIOLATION_TERMS"] = "blocked, malware "
        values["IM_V2_CONTENT_REVIEW_ESCALATION_TERMS"] = "manual-review"

        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        #expect(configuration.contentReviewSafetyActorUserID?.rawValue == "00000000-0000-0000-0000-000000000901")
        #expect(configuration.contentReviewViolationTerms == ["blocked", "malware"])
        #expect(configuration.contentReviewEscalationTerms == ["manual-review"])
    }

    @Test("NATS hint requires both endpoint and subject")
    func parsesAndValidatesNATSHintConfiguration() throws {
        var values = runtimeValues
        values["IM_V2_NATS_URL"] = "tls://nats.internal:4222"
        values["IM_V2_NATS_SUBJECT"] = "imv2.fanout.wake"
        values["IM_V2_NATS_TOKEN"] = "test-broker-token"
        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        guard case .nats(let nats) = configuration.fanoutHint else {
            Issue.record("Expected NATS hint")
            return
        }
        #expect(nats.subject == "imv2.fanout.wake")

        values["IM_V2_NATS_URL"] = "nats://nats.internal:4222"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_NATS_URL/IM_V2_NATS_SUBJECT")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
        values["IM_V2_NATS_URL"] = "tls://nats.internal:4222"
        values.removeValue(forKey: "IM_V2_NATS_TOKEN")
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_NATS_URL/IM_V2_NATS_SUBJECT")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
        values["IM_V2_NATS_TOKEN"] = "test-broker-token"
        values.removeValue(forKey: "IM_V2_NATS_SUBJECT")
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_NATS_URL/IM_V2_NATS_SUBJECT")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("Hybrid wake routing requires an opaque-subject key with its NATS configuration")
    func parsesAndValidatesGroupWakeNATSConfiguration() throws {
        var values = runtimeValues
        values["IM_V2_GROUP_WAKE_NATS_URL"] = "tls://nats.internal:4222"
        values["IM_V2_GROUP_WAKE_NATS_SUBJECT_PREFIX"] = "imv2.group.wake"
        values["IM_V2_GROUP_WAKE_NATS_TOKEN"] = "test-broker-token"
        values["IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64"] = Data(repeating: 9, count: 32).base64EncodedString()
        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        guard case .nats(let nats) = configuration.groupEventWake else {
            Issue.record("Expected group wake NATS configuration")
            return
        }
        #expect(nats.routingKey == Data(repeating: 9, count: 32))
        #expect(nats.payloadEncoding == .json)
        #expect(nats.wakeDeferralDelayMilliseconds == 60)
        #expect(nats.usesTLS)

        values["IM_V2_GROUP_WAKE_NATS_URL"] = "nats://nats.internal:4222"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_GROUP_WAKE_NATS_URL/IM_V2_GROUP_WAKE_NATS_SUBJECT_PREFIX/IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
        values["IM_V2_GROUP_WAKE_NATS_URL"] = "tls://nats.internal:4222"

        values["IM_V2_GROUP_WAKE_DEFERRAL_MS"] = "75"
        let deferredConfiguration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(values)
        )
        guard case .nats(let deferredNATS) = deferredConfiguration.groupEventWake else {
            Issue.record("Expected deferred NATS group wake configuration")
            return
        }
        #expect(deferredNATS.wakeDeferralDelayMilliseconds == 75)
        values.removeValue(forKey: "IM_V2_GROUP_WAKE_DEFERRAL_MS")

        values["IM_V2_GROUP_WAKE_NATS_PAYLOAD_ENCODING"] = "protobuf_v1"
        let binaryConfiguration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(values)
        )
        guard case .nats(let binaryNATS) = binaryConfiguration.groupEventWake else {
            Issue.record("Expected binary NATS group wake configuration")
            return
        }
        #expect(binaryNATS.payloadEncoding == .protobufV1)

        values["IM_V2_GROUP_WAKE_NATS_PAYLOAD_ENCODING"] = "unknown"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_GROUP_WAKE_NATS_PAYLOAD_ENCODING"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(values)
            )
        }
        values.removeValue(forKey: "IM_V2_GROUP_WAKE_NATS_PAYLOAD_ENCODING")

        values["IM_V2_GROUP_WAKE_DEFERRAL_MS"] = "1001"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_GROUP_WAKE_DEFERRAL_MS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(values)
            )
        }
        values.removeValue(forKey: "IM_V2_GROUP_WAKE_DEFERRAL_MS")

        values.removeValue(forKey: "IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64")
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_GROUP_WAKE_NATS_URL/IM_V2_GROUP_WAKE_NATS_SUBJECT_PREFIX/IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("Hybrid durable wake cadence is independently bounded")
    func validatesGroupEventWakePollInterval() throws {
        var values = runtimeValues
        values["IM_V2_GROUP_EVENT_WAKE_POLL_INTERVAL_MS"] = "750"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(values)
        ).groupEventWakePollIntervalMilliseconds == 750)

        values["IM_V2_GROUP_EVENT_WAKE_POLL_INTERVAL_MS"] = "0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_GROUP_EVENT_WAKE_POLL_INTERVAL_MS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(values)
            )
        }
        values["IM_V2_GROUP_EVENT_WAKE_POLL_INTERVAL_MS"] = "2001"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_GROUP_EVENT_WAKE_POLL_INTERVAL_MS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(values)
            )
        }
    }

    @Test("a multi-gateway topology cannot silently use process-local hybrid wakes")
    func rejectsLocalOnlyGroupWakeForMultipleGatewayReplicas() {
        var values = runtimeValues
        values["IM_V2_GATEWAY_REPLICA_COUNT"] = "2"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_GATEWAY_REPLICA_COUNT/IM_V2_GROUP_WAKE_NATS_URL/IM_V2_GROUP_WAKE_NATS_SUBJECT_PREFIX/IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("runtime requires an explicit versioned user-shard route")
    func rejectsMissingOrNegativeUserShardRoute() {
        var missingBucket = runtimeValues
        missingBucket.removeValue(forKey: "IM_V2_USER_SHARD_BUCKET")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_USER_SHARD_BUCKET")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(missingBucket))
        }
        var negativeEpoch = runtimeValues
        negativeEpoch["IM_V2_USER_SHARD_ROUTER_EPOCH"] = "-1"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_ROUTER_EPOCH")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(negativeEpoch))
        }
    }

    @Test("runtime bounds the durable gateway node identifier")
    func rejectsInvalidGatewayNodeID() {
        var invalidCharacter = runtimeValues
        invalidCharacter["IM_V2_GATEWAY_NODE_ID"] = "gateway/a"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_GATEWAY_NODE_ID")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(invalidCharacter))
        }

        var overlong = runtimeValues
        overlong["IM_V2_GATEWAY_NODE_ID"] = String(repeating: "a", count: 129)
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_GATEWAY_NODE_ID")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(overlong))
        }
    }

    @Test("runtime validates an explicit logical-bucket storage registry")
    func parsesAndRejectsInvalidUserShardStorageRegistry() throws {
        var values = runtimeValues
        values["IM_V2_USER_SHARD_STORES_JSON"] = """
        [{"bucket":"users-primary","database_url":"postgres://v2:password@db/im_v2","schema":"im_v2"},
         {"bucket":"users-next","database_url":"postgres://v2:password@db-next/im_v2","schema":"im_v2"}]
        """
        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        #expect(configuration.userShardStorage.map(\.bucket) == ["users-primary", "users-next"])

        values["IM_V2_USER_SHARD_STORES_JSON"] = "[{\"bucket\":\"users-next\",\"database_url\":\"postgres://v2:password@db-next/im_v2\",\"schema\":\"im_v2\"}]"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_STORES_JSON")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }

        values["IM_V2_USER_SHARD_STORES_JSON"] = "[{\"bucket\":\"users-primary\",\"database_url\":\"postgres://v2:password@db/im_v2\",\"schema\":\"im_v2\"},{\"bucket\":\"users-next\",\"database_url\":\"postgres://v2:password@db/im_v2\",\"schema\":\"im_v2\"}]"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_STORES_JSON")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("runtime resolves every logical room owner through an explicit physical registry")
    func parsesAndRejectsInvalidRoomShardStorageRegistry() throws {
        let defaultConfiguration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(runtimeValues)
        )
        #expect(Set(defaultConfiguration.roomShardStorage.map(\.shardID)) == Set([
            "rooms-primary",
        ]))
        #expect(defaultConfiguration.roomShardStorage.allSatisfy {
            $0.databaseURL == "postgres://v2:password@db/im_v2"
        })

        var values = runtimeValues
        values["IM_V2_DIRECT_ROOM_SHARD_ID"] = "rooms-00,rooms-01"
        values["IM_V2_GROUP_ROOM_SHARD_ID"] = "groups-01,groups-00"
        values["IM_V2_ROOM_SHARD_STORES_JSON"] = """
        [{"shard_id":"rooms-00","database_url":"postgres://v2:password@rooms-a/im_v2","schema":"im_v2"},
         {"shard_id":"rooms-01","database_url":"postgres://v2:password@rooms-b/im_v2","schema":"im_v2"},
         {"shard_id":"groups-00","database_url":"postgres://v2:password@groups-a/im_v2","schema":"im_v2"},
         {"shard_id":"groups-01","database_url":"postgres://v2:password@groups-b/im_v2","schema":"im_v2"}]
        """
        let configuration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(values)
        )
        #expect(configuration.roomShardStorage.map(\.shardID) == [
            "rooms-00", "rooms-01", "groups-00", "groups-01",
        ])
        #expect(configuration.groupRoomShardIDs == ["groups-00", "groups-01"])

        values["IM_V2_ROOM_SHARD_STORES_JSON"] = """
        [{"shard_id":"rooms-00","database_url":"postgres://v2:password@rooms-a/im_v2","schema":"im_v2"},
         {"shard_id":"rooms-01","database_url":"postgres://v2:password@rooms-b/im_v2","schema":"im_v2"},
         {"shard_id":"groups-00","database_url":"postgres://v2:password@groups-a/im_v2","schema":"im_v2"}]
        """
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_ROOM_SHARD_STORES_JSON"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(values)
            )
        }

        values["IM_V2_ROOM_SHARD_STORES_JSON"] = """
        [{"shard_id":"rooms-00","database_url":"postgres://v2:password@rooms-a/im_v2","schema":"room_00"},
         {"shard_id":"rooms-01","database_url":"postgres://v2:password@rooms-b/im_v2","schema":"im_v2"},
         {"shard_id":"groups-00","database_url":"postgres://v2:password@groups-a/im_v2","schema":"im_v2"},
         {"shard_id":"groups-01","database_url":"postgres://v2:password@groups-b/im_v2","schema":"im_v2"}]
        """
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_ROOM_SHARD_STORES_JSON"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(values)
            )
        }
    }

    @Test("APNs mode requires explicit provider and endpoint secrets")
    func rejectsIncompleteAPNSConfiguration() {
        var values = runtimeValues
        values["IM_V2_PUSH_PROVIDER"] = "apns"
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("APNs mode parses explicit provider configuration")
    func parsesAPNSConfiguration() throws {
        var values = runtimeValues
        values["IM_V2_PUSH_PROVIDER"] = "apns"
        values["IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64"] = Data(repeating: 1, count: 32).base64EncodedString()
        values["IM_V2_APNS_TEAM_ID"] = "TEAM123"
        values["IM_V2_APNS_KEY_ID"] = "KEY123"
        values["IM_V2_APNS_PRIVATE_KEY_RAW_BASE64"] = Data(repeating: 2, count: 32).base64EncodedString()
        values["IM_V2_APNS_TOPIC"] = "com.example.im"
        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        guard case .apns(let apns) = configuration.push else {
            Issue.record("Expected APNs configuration")
            return
        }
        #expect(apns.topic == "com.example.im")
    }

    @Test("metrics listener requires an explicit loopback-only address")
    func rejectsPublicMetricsAddress() {
        var publicAddress = runtimeValues
        publicAddress["IM_V2_METRICS_HOST"] = "0.0.0.0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_METRICS_HOST/IM_V2_METRICS_PORT")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(publicAddress))
        }
    }

    @Test("runtime rejects an invalid durable retry budget")
    func rejectsInvalidDurableRetryBudget() {
        var values = runtimeValues
        values["IM_V2_DURABLE_RETRY_MAX_DELAY_MS"] = "999"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DURABLE_RETRY_MAX_DELAY_MS")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }

        values = runtimeValues
        values["IM_V2_DURABLE_RETRY_JITTER_PERCENT"] = "101"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DURABLE_RETRY_JITTER_PERCENT")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    private var runtimeValues: [String: String] {
        [
            "IM_V2_DATABASE_URL": "postgres://v2:password@db/im_v2",
            "IM_V2_DATABASE_EVENT_LOOP_THREADS": "4",
            "IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP": "8",
            "IM_V2_DATABASE_FOREGROUND_CONNECTIONS_PER_EVENT_LOOP": "4",
            "IM_V2_DATABASE_SYNC_CONNECTIONS_PER_EVENT_LOOP": "1",
            "IM_V2_DATABASE_DELIVERY_CONNECTIONS_PER_EVENT_LOOP": "1",
            "IM_V2_DATABASE_PROJECTION_CONNECTIONS_PER_EVENT_LOOP": "1",
            "IM_V2_DATABASE_MAINTENANCE_CONNECTIONS_PER_EVENT_LOOP": "1",
            "IM_V2_DATABASE_WORKLOAD_POOL_ISOLATION_ENABLED": "true",
            "IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS": "512",
            "IM_V2_MAX_USER_SHARD_STORES": "16",
            "IM_V2_DATABASE_CONNECT_TIMEOUT_MS": "5000",
            "IM_V2_DATABASE_POOL_TIMEOUT_MS": "3000",
            "IM_V2_DATABASE_STATEMENT_TIMEOUT_MS": "5000",
            "IM_V2_DATABASE_LOCK_TIMEOUT_MS": "2000",
            "IM_V2_DATABASE_IDLE_TRANSACTION_TIMEOUT_MS": "10000",
            "IM_V2_TLS_HOST": "0.0.0.0",
            "IM_V2_TLS_PORT": "7443",
            "IM_V2_TLS_CERTIFICATE_CHAIN_PATH": "/run/secrets/tls-chain.pem",
            "IM_V2_TLS_PRIVATE_KEY_PATH": "/run/secrets/tls-key.pem",
            "IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64": Data(repeating: 3, count: 32).base64EncodedString(),
            "IM_V2_CAPABILITY_PROFILE": "base",
            "IM_V2_MAX_MESSAGE_UTF8_BYTES": "4096",
            "IM_V2_MAX_FRAME_BYTES": "65536",
            "IM_V2_MAX_PROTOBUF_MESSAGE_DEPTH": "32",
            "IM_V2_MAX_IN_FLIGHT_REQUESTS": "32",
            "IM_V2_MAX_CONNECTIONS": "10000",
            "IM_V2_LISTEN_BACKLOG": "4096",
            "IM_V2_ACCEPT_BATCH_SIZE": "256",
            "IM_V2_MAX_CONNECTIONS_PER_DEVICE": "2",
            "IM_V2_MAX_CONNECTIONS_PER_USER": "8",
            "IM_V2_DEVICE_COMMANDS_PER_SECOND": "32",
            "IM_V2_DEVICE_COMMAND_BURST": "64",
            "IM_V2_USER_COMMANDS_PER_SECOND": "128",
            "IM_V2_USER_COMMAND_BURST": "256",
            "IM_V2_RATE_LIMIT_MAX_TRACKED_IDENTITIES": "20000",
            "IM_V2_MAX_QUEUED_INBOUND_BYTES": "262144",
            "IM_V2_MAX_QUEUED_INBOUND_CHUNKS": "512",
            "IM_V2_AUTHENTICATION_TIMEOUT_MS": "10000",
            "IM_V2_IDLE_TIMEOUT_MS": "60000",
            "IM_V2_WORKER_BATCH_SIZE": "256",
            "IM_V2_WORKER_POLL_INTERVAL_MS": "100",
            "IM_V2_USER_PROJECTION_CONCURRENCY": "2",
            "IM_V2_USER_PROJECTION_MAX_CONSECUTIVE_BUSY_PASSES": "16",
            "IM_V2_USER_PROJECTION_BUSY_DRAIN_BUDGET_MS": "50",
            "IM_V2_FOREGROUND_WRITE_DATABASE_WORK_LIMIT": "9",
            "IM_V2_FOREGROUND_CONTROL_WRITE_DATABASE_WORK_LIMIT": "3",
            "IM_V2_INTERACTIVE_READ_DATABASE_WORK_LIMIT": "4",
            "IM_V2_SYNC_DATABASE_WORK_LIMIT": "4",
            "IM_V2_FOREGROUND_WRITE_DATABASE_WORK_MAX_QUEUED": "288",
            "IM_V2_FOREGROUND_CONTROL_WRITE_DATABASE_WORK_MAX_QUEUED": "288",
            "IM_V2_INTERACTIVE_READ_DATABASE_WORK_MAX_QUEUED": "96",
            "IM_V2_SYNC_DATABASE_WORK_MAX_QUEUED": "128",
            "IM_V2_DATABASE_WORK_ADMISSION_TIMEOUT_MS": "200",
            "IM_V2_DATABASE_WORK_ADMISSION_ENABLED": "true",
            "IM_V2_SYNC_WAKE_COALESCING_MS": "40",
            "IM_V2_SYNC_WAKE_MAX_PENDING_USERS": "50000",
            "IM_V2_SYNC_WAKE_DELIVERY_CONCURRENCY": "64",
            "IM_V2_SYNC_WAKE_COALESCING_ENABLED": "true",
            "IM_V2_ACCEPTED_MESSAGE_PROJECTION_BATCH_ENABLED": "true",
            "IM_V2_COMMAND_SUCCESS_LOG_SAMPLE_PERMILLE": "10",
            "IM_V2_COMMAND_SLOW_LOG_THRESHOLD_MS": "250",
            "IM_V2_COMMAND_DIAGNOSTIC_LOG_MAX_PER_SECOND": "20",
            "IM_V2_FANOUT_DELIVERY_COMMIT_BATCH_SIZE": "128",
            "IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_BATCH_SIZE": "256",
            "IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_CONCURRENCY": "2",
            "IM_V2_FANOUT_DELIVERY_CLAIM_BATCH_SIZE": "2000",
            "IM_V2_FANOUT_FRESH_BURST_PASSES": "7",
            "IM_V2_DURABLE_RETRY_INITIAL_DELAY_MS": "1000",
            "IM_V2_DURABLE_RETRY_MAX_DELAY_MS": "60000",
            "IM_V2_DURABLE_RETRY_MAX_ATTEMPTS": "10",
            "IM_V2_DURABLE_RETRY_JITTER_PERCENT": "20",
            "IM_V2_MAINTENANCE_POLL_INTERVAL_MS": "60000",
            "IM_V2_BACKLOG_MAINTENANCE_IDLE_POLL_INTERVAL_MS": "1000",
            "IM_V2_BACKLOG_MAINTENANCE_MAX_CONSECUTIVE_BUSY_PASSES": "4",
            "IM_V2_BACKLOG_MAINTENANCE_BUSY_DRAIN_BUDGET_MS": "100",
            "IM_V2_MEDIA_WITHDRAWN_RETENTION_SECONDS": "2592000",
            "IM_V2_IDEMPOTENCY_RETENTION_SECONDS": "3888000",
            "IM_V2_METRICS_HOST": "127.0.0.1",
            "IM_V2_METRICS_PORT": "9464",
            "IM_V2_METRICS_MINIMUM_REFRESH_INTERVAL_MS": "30000",
            "IM_V2_METRICS_REFRESH_TIMEOUT_MS": "4000",
            "IM_V2_GATEWAY_NODE_ID": "gateway-a",
            "IM_V2_GATEWAY_REPLICA_COUNT": "1",
            "IM_V2_USER_SHARD_BUCKET": "users-primary",
            "IM_V2_USER_SHARD_ROUTER_EPOCH": "7",
            "IM_V2_DIRECT_ROOM_SHARD_ID": "rooms-primary",
            "IM_V2_GROUP_ROOM_SHARD_ID": "rooms-primary",
            "IM_V2_STRANGER_MESSAGE_MAX_PER_WINDOW": "3",
            "IM_V2_STRANGER_MESSAGE_WINDOW_SECONDS": "86400",
            "IM_V2_CONTENT_REVIEW_MODE": "enabled",
            "IM_V2_CAPACITY_PROFILE_ID": "standard",
            "IM_V2_MAX_ELIGIBLE_MEMBERS": "100000",
            "IM_V2_MAX_COMMANDS_PER_WINDOW": "1000",
            "IM_V2_MAX_FANOUT_UNITS_PER_WINDOW": "100000",
            "IM_V2_MAX_OUTSTANDING_FANOUT_UNITS": "1000000",
            "IM_V2_MAX_OUTSTANDING_PLANS": "10000",
            "IM_V2_MAX_ENUMERATION_PAGE_SIZE": "1000",
            "IM_V2_MAX_PLANNER_CONCURRENCY": "8",
            "IM_V2_MAX_DELIVERY_CONCURRENCY": "16",
            "IM_V2_RATE_LIMIT_RETRY_AFTER_SECONDS": "3",
        ]
    }
}
