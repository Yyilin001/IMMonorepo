@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

struct V2GatewayRuntimeConfigurationTests {
    @Test("online room coverage limits are independent of socket admission")
    func onlineDeliveryCapacity() throws {
        var values = runtimeValues
        values["IM_V2_MAX_CONNECTIONS"] = "1"
        var config = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        #expect(config.onlineDeliveryMaximumRooms == 65_536)
        #expect(config.onlineDeliveryMaximumRelations == 262_144)
        values["IM_V2_ONLINE_DELIVERY_MAX_ROOMS"] = "300"
        values["IM_V2_ONLINE_DELIVERY_MAX_RELATIONS"] = "900"
        config = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        #expect(config.maximumConnections == 1)
        #expect(config.onlineDeliveryMaximumRooms == 300)
        #expect(config.onlineDeliveryMaximumRelations == 900)
        for key in ["IM_V2_ONLINE_DELIVERY_MAX_ROOMS", "IM_V2_ONLINE_DELIVERY_MAX_RELATIONS"] {
            for invalid in ["0", "-1", "1000001", "invalid"] {
                var invalidValues = values
                invalidValues[key] = invalid
                #expect(throws: V2GatewayRuntimeConfigurationError.invalid(key)) {
                    _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(invalidValues))
                }
            }
        }
    }

    @Test("durable scheduling retains only pending and fallback connection limits", arguments: [288, 16])
    func durableOwnerSchedulingConfiguration(pending: Int) throws {
        var environment = runtimeValues
        environment["IM_V2_FOREGROUND_WRITE_DATABASE_WORK_MAX_QUEUED"] = String(pending)
        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(environment))
        let durable = configuration.durableSendSchedulingConfiguration()
        #expect(durable.maximumPendingRequests == pending)
        #expect(durable.fallbackConnectionCapacity == configuration.directRoomLogAppendBatchMaximumInFlightBatches)
    }

    @Test("author supplements default off and require an explicit boolean rollout value")
    func authorPresentationRollout() throws {
        #expect(try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(runtimeValues)).authorPresentationsEnabled == false)
        for (value, expected) in [("true", true), ("1", true), ("false", false), ("0", false)] {
            var environment = runtimeValues; environment["IM_V2_AUTHOR_PRESENTATIONS_ENABLED"] = value
            #expect(try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(environment)).authorPresentationsEnabled == expected)
        }
        var environment = runtimeValues; environment["IM_V2_AUTHOR_PRESENTATIONS_ENABLED"] = "automatic"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_AUTHOR_PRESENTATIONS_ENABLED")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(environment))
        }
    }
    @Test("Gateway frame configuration respects the wire length range")
    func framePayloadWireRange() throws {
        for limit in [-1, Int(UInt32.max) + 1, Int.max] {
            var environment = runtimeValues
            environment["IM_V2_MAX_FRAME_BYTES"] = String(limit)
            #expect(throws: V2FrameCodecError.invalidLimits) {
                _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(environment))
            }
        }
        for limit in [0, 65_536, Int(UInt32.max)] {
            var environment = runtimeValues
            environment["IM_V2_MAX_FRAME_BYTES"] = String(limit)
            let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(environment))
            #expect(configuration.frameLimits.maximumPayloadBytes == limit)
        }
    }

    @Test("Idle timeout must be exactly representable by the NIO nanosecond timer")
    func idleTimeoutNanosecondsBoundary() throws {
        let maximum = Int(Int64.max / 1_000_000)
        for value in [0, -1, maximum + 1, Int.max] {
            var environment = runtimeValues
            environment["IM_V2_IDLE_TIMEOUT_MS"] = String(value)
            #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_IDLE_TIMEOUT_MS")) {
                _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(environment))
            }
        }
        for value in [1, 60_000, maximum] {
            var environment = runtimeValues
            environment["IM_V2_IDLE_TIMEOUT_MS"] = String(value)
            #expect(try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(environment)).idleTimeoutMilliseconds == value)
        }
    }

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

    @Test("read receipt batching has bounded pending work")
    func validatesReadReceiptBatchingPolicy() throws {
        let defaults = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(runtimeValues)
        )
        #expect(defaults.readReceiptBatchSize == 32)
        #expect(defaults.readReceiptBatchMaximumDelayMilliseconds == 2)
        #expect(defaults.readReceiptBatchMaximumInFlightBatches == 8)
        #expect(
            defaults.readReceiptBatchMaximumPendingRequests ==
                defaults.foregroundWriteDatabaseWorkMaximumQueued
        )

        var configured = runtimeValues
        configured["IM_V2_READ_RECEIPT_BATCH_SIZE"] = "64"
        configured["IM_V2_READ_RECEIPT_BATCH_MAX_DELAY_MS"] = "4"
        configured["IM_V2_READ_RECEIPT_BATCH_MAX_IN_FLIGHT"] = "6"
        configured["IM_V2_READ_RECEIPT_BATCH_MAX_PENDING_REQUESTS"] = "4096"
        let parsed = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(configured)
        )
        #expect(parsed.readReceiptBatchSize == 64)
        #expect(parsed.readReceiptBatchMaximumDelayMilliseconds == 4)
        #expect(parsed.readReceiptBatchMaximumInFlightBatches == 6)
        #expect(parsed.readReceiptBatchMaximumPendingRequests == 4_096)

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

    @Test("room-log runtime limits and retention are validated")
    func validatesRoomLogRuntimeLimits() throws {
        let defaults = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(runtimeValues)
        )
        #expect(defaults.messageProjectionStateRetentionSeconds == 604_800)
        // 保留窗口默认是"永久"=不裁剪历史，与既有行为一致；窗口模式必须显式选择。
        #expect(defaults.roomLogRetentionMode == .permanent)
        #expect(defaults.roomLogRetentionWindowSeconds == V2GatewayRuntimeConfiguration.defaultRoomLogRetentionWindowSeconds)
        #expect(defaults.directRoomLogAppendBatchMaximumInFlightBatches == 8)
        #expect(defaults.directRoomLogAppendBatchMaximumDelayMilliseconds == 2)
        #expect(defaults.directRoomLogAppendBatchHighActivityMaximumDelayMilliseconds == nil)
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

        var shared = runtimeValues
        shared["IM_V2_MESSAGE_PROJECTION_STATE_RETENTION_SECONDS"] = "86400"
        let sharedConfiguration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(shared)
        )
        #expect(sharedConfiguration.messageProjectionStateRetentionSeconds == 86_400)

        let roomLog = runtimeValues
        for retiredMode in ["", "room", "shard_only"] {
            var retiredAdmission = roomLog
            retiredAdmission["IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE"] = retiredMode
            #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE"
            )) {
                _ = try V2GatewayRuntimeConfiguration(
                    environment: V2DictionaryRuntimeEnvironment(retiredAdmission)
                )
            }
        }

        var appendBatch = roomLog
        appendBatch["IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_DELAY_MS"] = "2"
        let appendBatchConfiguration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(appendBatch)
        )
        #expect(appendBatchConfiguration.directRoomLogAppendBatchMaximumInFlightBatches == 8)
        #expect(appendBatchConfiguration.directRoomLogAppendMaximumPendingRequests == 288)
        #expect(appendBatchConfiguration.directRoomLogAppendBatchMaximumDelayMilliseconds == 2)

        var burstSizedAppendBatch = appendBatch
        burstSizedAppendBatch[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_MAX_PENDING_REQUESTS"
        ] = "4096"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(burstSizedAppendBatch)
        ).directRoomLogAppendMaximumPendingRequests == 4_096)

        var undersizedAppendPending = appendBatch
        undersizedAppendPending[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_MAX_PENDING_REQUESTS"
        ] = "0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_MAX_PENDING_REQUESTS"
        )) {
            _ = try V2GatewayRuntimeConfiguration(
                environment: V2DictionaryRuntimeEnvironment(undersizedAppendPending)
            )
        }

        var widenedAppendBatchConcurrency = appendBatch
        widenedAppendBatchConcurrency[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_IN_FLIGHT"
        ] = "12"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(widenedAppendBatchConcurrency)
        ).directRoomLogAppendBatchMaximumInFlightBatches == 12)

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

        var highActivityAppendBatch = appendBatch
        highActivityAppendBatch["IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_DELAY_MS"] = "20"
        #expect(try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(highActivityAppendBatch)
        ).directRoomLogAppendBatchMaximumDelayMilliseconds == 20)

        var adaptiveHighActivityAppendBatch = appendBatch
        adaptiveHighActivityAppendBatch[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_DELAY_MS"
        ] = "20"
        let adaptiveHighActivityConfiguration = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(adaptiveHighActivityAppendBatch)
        )
        #expect(adaptiveHighActivityConfiguration
            .directRoomLogAppendBatchHighActivityMaximumDelayMilliseconds == 20)

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

        var nonIncreasingAdaptiveHighActivityAppendBatch = adaptiveHighActivityAppendBatch
        nonIncreasingAdaptiveHighActivityAppendBatch[
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_DELAY_MS"
        ] = "2"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_DELAY_MS"
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

        var windowedRetention = runtimeValues
        windowedRetention["IM_V2_ROOM_LOG_RETENTION_MODE"] = "window"
        windowedRetention["IM_V2_ROOM_LOG_RETENTION_WINDOW_SECONDS"] = "86400"
        let windowed = try V2GatewayRuntimeConfiguration(
            environment: V2DictionaryRuntimeEnvironment(windowedRetention)
        )
        #expect(windowed.roomLogRetentionMode == .window)
        #expect(windowed.roomLogRetentionWindowSeconds == 86_400)

        var invalidRetention = runtimeValues
        invalidRetention["IM_V2_ROOM_LOG_RETENTION_MODE"] = "forever"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_ROOM_LOG_RETENTION_MODE")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(invalidRetention))
        }
        var invalidRetentionWindow = runtimeValues
        invalidRetentionWindow["IM_V2_ROOM_LOG_RETENTION_WINDOW_SECONDS"] = "0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_ROOM_LOG_RETENTION_WINDOW_SECONDS")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(invalidRetentionWindow))
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

    @Test("route and direct authority pools stay inside the process connection ceiling", arguments: [false, true], [false, true])
    func userStateRoutePoolBudget(isolated: Bool, separateOwner: Bool) throws {
        var values = runtimeValues
        values["IM_V2_DATABASE_WORKLOAD_POOL_ISOLATION_ENABLED"] = isolated ? "true" : "false"
        let controlURL = try #require(values["IM_V2_DATABASE_URL"])
        let ownerURL = separateOwner ? "postgres://v2:password@owner/im_v2" : controlURL
        values["IM_V2_ROOM_SHARD_STORES_JSON"] = """
        [{"shard_id":"room-a","database_url":"\(ownerURL)"},
         {"shard_id":"room-b","database_url":"\(ownerURL)"}]
        """
        // Logical aliases share physical data and resolution pools.
        let physicalStores = separateOwner ? 2 : 1
        values["IM_V2_DIRECT_ROOM_SHARD_ID"] = "room-a"
        values["IM_V2_GROUP_ROOM_SHARD_ID"] = "room-b"
        values["IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS"] = "32"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
        let controlConnections = isolated ? 4 : 8
        let total = 4 * (8 * physicalStores + 1 + controlConnections + physicalStores)
        values["IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS"] = String(total - 1)
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
        values["IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS"] = String(total)
        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        #expect(configuration.directSendControlConnectionsPerEventLoop == controlConnections)
        #expect(configuration.directAuthorizationResolutionDatabaseURLs == Set([controlURL, ownerURL]).sorted())
    }

    @Test("policy control overrides preserve other pools and obey the process ceiling", arguments: [false, true])
    func independentPolicyControlPool(isolated: Bool) throws {
        var values = runtimeValues
        let key = "IM_V2_DATABASE_POLICY_CONTROL_CONNECTIONS_PER_EVENT_LOOP"
        values["IM_V2_DATABASE_WORKLOAD_POOL_ISOLATION_ENABLED"] = isolated ? "true" : "false"
        values["IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS"] = "1000"
        let baseline = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        let count = baseline.directSendControlConnectionsPerEventLoop + 4
        values[key] = String(count)
        let configured = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        #expect(configured.directSendControlConnectionsPerEventLoop == count)
        #expect(configured.databaseWorkloadPoolBudget.messageWriteConnectionsPerEventLoop == baseline.databaseWorkloadPoolBudget.messageWriteConnectionsPerEventLoop)
        #expect(configured.databaseWorkloadPoolBudget.foregroundConnectionsPerEventLoop == baseline.databaseWorkloadPoolBudget.foregroundConnectionsPerEventLoop)
        for bad in ["0", "-1", "invalid"] {
            var invalid = values; invalid[key] = bad
            #expect(throws: V2GatewayRuntimeConfigurationError.invalid(key)) {
                _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(invalid))
            }
        }
        values[key] = "1000"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("message EventLoops increase without multiplying non-message or control budgets")
    func messageEventLoopsKeepNodeConnectionBudget() throws {
        var values = runtimeValues
        values["IM_V2_DATABASE_EVENT_LOOP_THREADS"] = "2"
        values["IM_V2_DATABASE_NON_MESSAGE_POOL_EVENT_LOOP_THREADS"] = "1"
        values["IM_V2_DATABASE_MESSAGE_WRITE_CONNECTIONS_PER_EVENT_LOOP"] = "2"
        values["IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP"] = "11"
        values["IM_V2_DATABASE_FOREGROUND_CONNECTIONS_PER_EVENT_LOOP"] = "4"
        values["IM_V2_DATABASE_SYNC_CONNECTIONS_PER_EVENT_LOOP"] = "1"
        values["IM_V2_DATABASE_DELIVERY_CONNECTIONS_PER_EVENT_LOOP"] = "1"
        values["IM_V2_DATABASE_PROJECTION_CONNECTIONS_PER_EVENT_LOOP"] = "2"
        values["IM_V2_DATABASE_MAINTENANCE_CONNECTIONS_PER_EVENT_LOOP"] = "1"
        values["IM_V2_FOREGROUND_WRITE_DATABASE_WORK_LIMIT"] = "5"
        values["IM_V2_FOREGROUND_CONTROL_WRITE_DATABASE_WORK_LIMIT"] = "0"
        values["IM_V2_INTERACTIVE_READ_DATABASE_WORK_LIMIT"] = "2"
        values["IM_V2_SYNC_DATABASE_WORK_LIMIT"] = "1"
        values["IM_V2_USER_PROJECTION_CONCURRENCY"] = "1"
        values["IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS"] = "19"
        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        #expect(configuration.databasePoolEventLoopCount(for: .messageWrite) == 2)
        #expect(configuration.databasePoolEventLoopCount(for: .foreground) == 1)
        #expect(configuration.databasePoolEventLoopCount(for: .sync) == 1)
        #expect(configuration.databaseNonMessagePoolEventLoopThreads == 1)
        values["IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS"] = "18"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
        values["IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS"] = "19"
        values["IM_V2_DATABASE_NON_MESSAGE_POOL_EVENT_LOOP_THREADS"] = "3"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_NON_MESSAGE_POOL_EVENT_LOOP_THREADS")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
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
        exhausted["IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS"] = "0"
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
        #expect(configuration.commandSuccessLogSamplePermille == 10)
        #expect(configuration.commandSlowLogThresholdMilliseconds == 250)
        #expect(configuration.commandDiagnosticLogMaximumPerSecond == 20)
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

    @Test("Actor routing is the default and requires its authenticated cluster configuration")
    func actorRoutingDefault() throws {
        var values = runtimeValues
        values.removeValue(forKey: "IM_V2_REALTIME_ROOM_TRANSPORT")
        values.removeValue(forKey: "IMV2_ROOM_ACTOR_CONFIGURATION_FILE")
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IMV2_ROOM_ACTOR_CONFIGURATION_FILE")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
        values["IMV2_ROOM_ACTOR_CONFIGURATION_FILE"] = "/run/im-v2-room-actor/configuration.json"
        values["IM_V2_GATEWAY_REPLICA_COUNT"] = "2"
        guard case .actor = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values)).groupEventWake else {
            Issue.record("Expected Actor routing"); return
        }
        values["IM_V2_REALTIME_ROOM_TRANSPORT"] = "unsupported"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_REALTIME_ROOM_TRANSPORT")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
        values["IM_V2_REALTIME_ROOM_TRANSPORT"] = "local"
        values["IM_V2_GATEWAY_REPLICA_COUNT"] = "1"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_REALTIME_ROOM_TRANSPORT")) {
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
        values["IM_V2_REALTIME_ROOM_TRANSPORT"] = "local"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_REALTIME_ROOM_TRANSPORT")) {
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

    @Test("message-write pool has its own budget without increasing the total pool ceiling")
    func validatesMessageWritePoolBudget() throws {
        var values = runtimeValues
        values["IM_V2_DATABASE_MESSAGE_WRITE_CONNECTIONS_PER_EVENT_LOOP"] = "2"
        values["IM_V2_FOREGROUND_CONTROL_WRITE_DATABASE_WORK_LIMIT"] = "0"
        values["IM_V2_DATABASE_FOREGROUND_CONNECTIONS_PER_EVENT_LOOP"] = "1"
        values["IM_V2_DATABASE_PROJECTION_CONNECTIONS_PER_EVENT_LOOP"] = "2"
        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        #expect(configuration.databaseWorkloadPoolBudget.totalConnectionsPerEventLoop == 8)
        #expect(configuration.databaseWorkloadPoolBudget.messageWriteConnectionsPerEventLoop == 2)
        #expect(configuration.databaseWorkloadPoolBudget.foregroundConnectionsPerEventLoop == 1)
        // Write admission's legacy limit is not a second send execution budget.
        #expect(configuration.foregroundWriteDatabaseWorkLimit > 8)
        values["IM_V2_DATABASE_MESSAGE_WRITE_CONNECTIONS_PER_EVENT_LOOP"] = "3"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_WORKLOAD_POOL_BUDGET")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
        values["IM_V2_DATABASE_MESSAGE_WRITE_CONNECTIONS_PER_EVENT_LOOP"] = "0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_MESSAGE_WRITE_CONNECTIONS_PER_EVENT_LOOP")) {
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
            "IM_V2_GROUP_INVITE_TOKEN_HMAC_KEY_BASE64": Data(repeating: 8, count: 32).base64EncodedString(),
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
            "IM_V2_COMMAND_SUCCESS_LOG_SAMPLE_PERMILLE": "10",
            "IM_V2_COMMAND_SLOW_LOG_THRESHOLD_MS": "250",
            "IM_V2_COMMAND_DIAGNOSTIC_LOG_MAX_PER_SECOND": "20",
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
            "IM_V2_REALTIME_ROOM_TRANSPORT": "actor",
            "IMV2_ROOM_ACTOR_CONFIGURATION_FILE": "/run/im-v2-room-actor/configuration.json",
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
            "IM_V2_RATE_LIMIT_RETRY_AFTER_SECONDS": "3",
        ]
    }
}
