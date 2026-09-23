#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import IMV2Compression
import IMV2Core
import IMV2Server
@preconcurrency import NIOConcurrencyHelpers
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL

@main
enum IMV2GatewayLoadGenerator {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.count == 2, arguments[0] == "--validate-scenario" {
                let scenario = try LoadScenario.load(path: arguments[1])
                let totalSeconds = scenario.phases.reduce(0) { $0 + $1.durationSeconds }
                print("scenario valid name=\(scenario.name) personas=\(scenario.personas.count) phases=\(scenario.phases.count) duration_seconds=\(totalSeconds) scheduler_hz=\(scenario.schedulerTicksPerSecond ?? 10)")
                return
            }
            let configuration = try LoadConfiguration(arguments: arguments)
            let credentials = try LoadCredential.load(from: configuration.credentialsPath)
            guard credentials.count >= configuration.connections else {
                throw LoadError.insufficientCredentials(required: configuration.connections, available: credentials.count)
            }
            let report = try await LoadRun(configuration: configuration, credentials: Array(credentials.prefix(configuration.connections))).execute()
            let data = try JSONEncoder.loadReport.encode(report)
            try data.write(to: URL(fileURLWithPath: configuration.reportPath), options: .atomic)
            print(report.summary)
        } catch {
            FileHandle.standardError.write(Data("load generator failed: \(error)\n".utf8))
            #if canImport(Darwin)
            Darwin.exit(1)
            #elseif os(Linux)
            Glibc.exit(1)
            #endif
        }
    }
}

/// 定义当一个加权场景选中的设备已达其配置的在途消息请求数时该如何处理。
///
/// 默认行为模拟拒绝继续缓冲用户操作的客户端。
/// 有界队列模式是为测量服务端饱和而刻意选择性启用的：
/// 它在本地保留需求，但同时记录队列压力与溢出，
/// 因此不会把客户端背压伪装成服务端的成功吞吐。
private enum ScenarioSendDispatch: String, Decodable, Sendable {
    case strictPerDevice = "strict_per_device"
    case boundedClientQueue = "bounded_client_queue"
}

/// 选择模拟设备打开其单聊房间之后所采用的房间日志游标位置。
///
/// `zero` 会演练持久历史恢复。
/// `tail` 先执行一次授权订阅，然后从返回的高水位开始稳态负载，
/// 使重复的稳态运行不会悄悄重读一段不断增长的历史。
private enum RoomLogInitialCursor: String, Sendable {
    case zero
    case tail
}

/// 定义模拟客户端推进活跃房间持久游标的原因。
///
/// `messageAcknowledgement` 保留最初的压测模式。
/// 生产客户端通常使用经由既有 TLS 流送达的提交后可用性唤醒，
/// 因此 `availabilityHint` 才是更贴近线上的模式。
private enum RoomLogReadTrigger: String, Sendable {
    case messageAcknowledgement = "message_ack"
    case availabilityHint = "availability_hint"
}

/// 场景中的对等端可以组成沿历史邻接关系构成的环，也可以组成互不相交的配对。
///
/// 配对会让两端选中同一个活跃单聊房间，这是模拟前台 WebSocket 唤醒所必需的。
private enum PeerTopology: String, Sendable {
    case ring
    case pairs
}

/// 针对失败的负载断言生成低基数的协议诊断标签。
///
/// 运维输出中绝不能包含载荷、标识符、令牌或用户数据。
///
/// - Parameter body: 待分类的响应正文。
/// - Returns: 低基数的响应类型标签。
private func loadResponseKind(_ body: IMV2Envelope.OneOf_Body?) -> String {
    switch body {
    case .serverHello: "server_hello"
    case .authenticated: "authenticated"
    case .heartbeatAck: "heartbeat_ack"
    case .messageAccepted: "message_accepted"
    case .directRoomOpened: "direct_room_opened"
    case .groupEventPage: "group_event_page"
    case .groupEventSubscribed: "group_event_subscribed"
    case .groupEventAvailable: "group_event_available"
    case .readReceiptRecorded: "read_receipt_recorded"
    case .roomSyncStateBatchResult: "room_sync_state_batch_result"
    case .roomLatestVisibleBatchResult: "room_latest_visible_batch_result"
    case .error: "error"
    case nil: "none"
    default: "other"
    }
}

private struct LoadConfiguration: Sendable {
    let host: String
    let port: Int
    let revision: String
    let serverName: String
    let caPath: String
    let credentialsPath: String
    let reportPath: String
    let connections: Int
    let rampPerSecond: Int
    let rampBatchSize: Int
    let workloadRampPerSecond: Int
    let holdSeconds: Int
    let eventLoops: Int
    let messagesPerSecond: Int
    let maximumInFlightMessagesPerConnection: Int
    let messageBytes: Int
    let targetsPerConnection: Int
    let targetOffset: Int
    let syncReads: Bool
    let roomLogReads: Bool
    let roomLogInitialCursor: RoomLogInitialCursor
    let roomLogReadTrigger: RoomLogReadTrigger
    let roomLogRecoveryGraceMilliseconds: Int
    let peerTopology: PeerTopology
    let heartbeatSeconds: Int
    let recoveryBatchTimeoutSeconds: Int
    let maximumRSSMegabytes: Int
    let maximumFailurePercent: Double
    let scenario: LoadScenario?
    let scenarioRateScale: Double

    var scenarioSendDispatch: ScenarioSendDispatch {
        scenario?.sendDispatch ?? .strictPerDevice
    }

    var maximumQueuedScenarioMessagesPerConnection: Int {
        scenario?.maximumQueuedMessagesPerConnection ?? 0
    }

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else { throw LoadError.invalidArguments }
            values[key] = arguments[index + 1]
            index += 2
        }

        guard let host = values["--host"], !host.isEmpty,
              let caPath = values["--ca-path"], !caPath.isEmpty,
              let credentialsPath = values["--credentials"], !credentialsPath.isEmpty,
              let reportPath = values["--report"], !reportPath.isEmpty
        else { throw LoadError.invalidArguments }

        self.host = host
        revision = values["--revision"] ?? "unknown"
        serverName = values["--server-name"] ?? "localhost"
        self.caPath = caPath
        self.credentialsPath = credentialsPath
        self.reportPath = reportPath
        port = try Self.integer(values["--port"] ?? "443", range: 1...65_535)
        // This is a generator-side guard, not the Gateway admission limit.
        // A mixed-source 10k run assigns 8k connections to one isolated load
        // worker, so allow one worker to own the full validated test scale.
        connections = try Self.integer(values["--connections"] ?? "100", range: 1...10_000)
        rampPerSecond = try Self.integer(values["--ramp-per-second"] ?? "50", range: 1...1_000)
        rampBatchSize = try Self.integer(
            values["--ramp-batch-size"] ?? String(min(rampPerSecond, 100)),
            range: 1...1_000
        )
        workloadRampPerSecond = try Self.integer(
            values["--workload-ramp-per-second"] ?? String(rampPerSecond),
            range: 1...1_000
        )
        holdSeconds = try Self.integer(values["--hold-seconds"] ?? "60", range: 10...28_800)
        eventLoops = try Self.integer(values["--event-loops"] ?? "2", range: 1...4)
        heartbeatSeconds = try Self.integer(values["--heartbeat-seconds"] ?? "30", range: 10...50)
        recoveryBatchTimeoutSeconds = try Self.integer(
            values["--recovery-batch-timeout-seconds"] ?? "10", range: 1...60
        )
        // This is deliberately a generator-side safety bound, not a Gateway
        // capacity claim.  A 1,000 msg/s cap prevented the load tool from
        // locating the next server-side saturation point after a successful
        // 1,000-msg/s run.  The guarded launcher continues to enforce local
        // CPU/RSS limits and the run itself fails on connection/error-rate
        // thresholds, so permit a materially higher controlled target here.
        messagesPerSecond = try Self.integer(values["--messages-per-second"] ?? "0", range: 0...10_000)
        maximumInFlightMessagesPerConnection = try Self.integer(
            values["--max-inflight-messages-per-connection"] ?? "1",
            range: 1...32
        )
        messageBytes = try Self.integer(values["--message-bytes"] ?? "128", range: 1...4_096)
        targetsPerConnection = try Self.integer(values["--targets-per-connection"] ?? "3", range: 1...32)
        targetOffset = try Self.integer(values["--target-offset"] ?? "1", range: 1...4_999)
        syncReads = try Self.integer(values["--sync-reads"] ?? "1", range: 0...1) == 1
        roomLogReads = try Self.integer(values["--room-log-reads"] ?? "0", range: 0...1) == 1
        guard let roomLogInitialCursor = RoomLogInitialCursor(
            rawValue: (values["--room-log-initial-cursor"] ?? "zero").lowercased()
        ) else { throw LoadError.invalidArguments }
        self.roomLogInitialCursor = roomLogInitialCursor
        guard let roomLogReadTrigger = RoomLogReadTrigger(
            rawValue: (values["--room-log-read-trigger"] ?? "message_ack").lowercased()
        ), let peerTopology = PeerTopology(
            rawValue: (values["--peer-topology"] ?? "ring").lowercased()
        ) else { throw LoadError.invalidArguments }
        self.roomLogReadTrigger = roomLogReadTrigger
        roomLogRecoveryGraceMilliseconds = try Self.integer(
            values["--room-log-recovery-grace-ms"] ?? "0",
            range: 0...2_000
        )
        self.peerTopology = peerTopology
        maximumRSSMegabytes = try Self.integer(values["--max-rss-mb"] ?? "2048", range: 256...8_192)
        guard let maximumFailurePercent = Double(values["--max-failure-percent"] ?? "1"),
              maximumFailurePercent >= 0, maximumFailurePercent <= 100
        else { throw LoadError.invalidArguments }
        self.maximumFailurePercent = maximumFailurePercent
        if let scenarioPath = values["--scenario"] {
            let loadedScenario = try LoadScenario.load(path: scenarioPath)
            guard loadedScenario.phases.allSatisfy({
                $0.effectiveReadReceiptsPerSecond == 0
            }) || (roomLogReads && loadedScenario.personas.contains {
                $0.effectiveReadReceiptWeight > 0
            }) else { throw LoadError.invalidScenario(
                "read receipts require room-log reads and a weighted persona"
            ) }
            scenario = loadedScenario
        } else {
            scenario = nil
        }
        // Scenario warm-up waits for both direct rooms and tail cursors, so a
        // phase never mixes recovery traffic with its steady workload.
        guard roomLogInitialCursor == .zero || roomLogReads
        else { throw LoadError.invalidArguments }
        guard roomLogReadTrigger != .availabilityHint || roomLogReads else {
            throw LoadError.invalidArguments
        }
        guard peerTopology != .pairs
                  || (connections.isMultiple(of: 2) && targetsPerConnection == 1)
        else { throw LoadError.invalidArguments }
        guard let scenarioRateScale = Double(values["--scenario-rate-scale"] ?? "1"),
              scenarioRateScale > 0, scenarioRateScale <= 1
        else { throw LoadError.invalidArguments }
        self.scenarioRateScale = scenarioRateScale
        guard (messagesPerSecond == 0 && scenario == nil)
                  || targetOffset + targetsPerConnection - 1 < connections else {
            throw LoadError.invalidArguments
        }
    }

    private static func integer(_ raw: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(raw), range.contains(value) else { throw LoadError.invalidArguments }
        return value
    }
}

/// 可复现的加权负载。
///
/// 场景决定已连接设备中*哪些*会行动；
/// CLI 仍控制传输端点以及分配给本工作者的设备数量。
/// 因此多个工作者可以配合按比例缩放的 `--scenario-rate-scale` 共用同一场景。
private struct LoadScenario: Decodable, Sendable {
    struct Persona: Decodable, Sendable {
        let name: String
        let share: Double
        let sendWeight: Double
        let roomLogReadWeight: Double
        let syncPullWeight: Double
        let readReceiptWeight: Double?
        let roomSyncStateBatchWeight: Double?
        let roomLatestVisibleBatchWeight: Double?

        var effectiveReadReceiptWeight: Double { readReceiptWeight ?? 0 }
        var effectiveRoomSyncStateBatchWeight: Double { roomSyncStateBatchWeight ?? 0 }
        var effectiveRoomLatestVisibleBatchWeight: Double { roomLatestVisibleBatchWeight ?? 0 }
    }

    struct Phase: Decodable, Sendable {
        let name: String
        let durationSeconds: Int
        let messagesPerSecond: Double
        let roomLogReadsPerSecond: Double
        let syncPullsPerSecond: Double
        let readReceiptsPerSecond: Double?
        let roomSyncStateBatchesPerSecond: Double?
        let roomLatestVisibleBatchesPerSecond: Double?
        let reconnectPercentPerMinute: Double

        var effectiveReadReceiptsPerSecond: Double {
            readReceiptsPerSecond ?? 0
        }
        var effectiveRoomSyncStateBatchesPerSecond: Double { roomSyncStateBatchesPerSecond ?? 0 }
        var effectiveRoomLatestVisibleBatchesPerSecond: Double { roomLatestVisibleBatchesPerSecond ?? 0 }
    }

    let name: String
    let seed: UInt64
    let roomWarmupTimeoutSeconds: Int
    /// 容量场景可以要求每个阶段在结束时都没有本地客户端积压。
    ///
    /// 这能把可持续的施加速率与「仅在生成器停止排程后才慢慢排空」的速率区分开。
    let requiresSteadyStateDrain: Bool?
    /// 在阶段边界上，真实网络客户端出现少量在途响应尾流是正常的。
    ///
    /// 严格场景会设置这个显式上限，
    /// 从而仍能拒绝实质性堆积，而不必要求在最后一个调度 tick 上恰为零这种不可能的条件。
    let maximumSteadyStateQueuedMessages: Int?
    /// 在传输拆除之前，给在途协议响应一段简短的显式宽限期。
    ///
    /// 它不计入阶段的吞吐：其结果会在报告中单独记录。
    let completionDrainSeconds: Int?
    /// 在拆除之前，把已排空的连接继续保持一段有界时间。
    ///
    /// 分区运行使用相同的值，使提前完成的工作者不会在同伴仍在排空最后一批协议响应时
    /// 制造一场连接关闭风暴。
    /// 这段保持既不重试也不排程消息，因此无法掩盖不可持续的施加速率。
    let postDrainHoldSeconds: Int?
    /// 用于分摊每秒施加工作的单调调度 tick 数量。
    ///
    /// 较旧的场景默认 10 Hz 以保证报告可复现。
    /// 真实用户容量场景选择 100 Hz，使五个分区工作者不会制造同步的 100 ms 突发。
    let schedulerTicksPerSecond: Int?
    let sendDispatch: ScenarioSendDispatch?
    let maximumQueuedMessagesPerConnection: Int?
    let personas: [Persona]
    let phases: [Phase]

    static func load(path: String) throws -> Self {
        let scenario = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard !scenario.name.isEmpty,
              scenario.roomWarmupTimeoutSeconds > 0,
              (scenario.completionDrainSeconds ?? 10) >= 0,
              (scenario.completionDrainSeconds ?? 10) <= 60,
              (scenario.postDrainHoldSeconds ?? 0) >= 0,
              (scenario.postDrainHoldSeconds ?? 0) <= 60,
              (scenario.schedulerTicksPerSecond ?? 10) >= 10,
              (scenario.schedulerTicksPerSecond ?? 10) <= 1_000,
              (scenario.maximumSteadyStateQueuedMessages ?? 0) >= 0,
              (scenario.maximumSteadyStateQueuedMessages ?? 0) <= (scenario.maximumQueuedMessagesPerConnection ?? 0) * 5_000,
              !scenario.personas.isEmpty,
              !scenario.phases.isEmpty
        else { throw LoadError.invalidScenario("missing required scenario fields") }
        let share = scenario.personas.reduce(0) { $0 + $1.share }
        guard abs(share - 1) < 0.000_001,
              scenario.personas.allSatisfy({
                  !$0.name.isEmpty && $0.share >= 0 && $0.sendWeight >= 0
                      && $0.roomLogReadWeight >= 0 && $0.syncPullWeight >= 0
                      && $0.effectiveReadReceiptWeight >= 0
                      && $0.effectiveRoomSyncStateBatchWeight >= 0
                      && $0.effectiveRoomLatestVisibleBatchWeight >= 0
              }),
              scenario.personas.contains(where: {
                  $0.sendWeight > 0 || $0.effectiveRoomSyncStateBatchWeight > 0
                      || $0.effectiveRoomLatestVisibleBatchWeight > 0
              }),
              (scenario.sendDispatch != .boundedClientQueue
                  || ((scenario.maximumQueuedMessagesPerConnection ?? 0) >= 1
                      && (scenario.maximumQueuedMessagesPerConnection ?? 0) <= 1_024)),
              scenario.phases.allSatisfy({
                  !$0.name.isEmpty && $0.durationSeconds > 0 && $0.messagesPerSecond >= 0
                      && $0.roomLogReadsPerSecond >= 0 && $0.syncPullsPerSecond >= 0
                      && $0.effectiveReadReceiptsPerSecond >= 0
                      && $0.effectiveRoomSyncStateBatchesPerSecond >= 0
                      && $0.effectiveRoomLatestVisibleBatchesPerSecond >= 0
                      && $0.reconnectPercentPerMinute >= 0 && $0.reconnectPercentPerMinute <= 100
              }),
              (scenario.phases.allSatisfy { $0.effectiveRoomSyncStateBatchesPerSecond == 0 }
                  || scenario.personas.contains { $0.effectiveRoomSyncStateBatchWeight > 0 }),
              (scenario.phases.allSatisfy { $0.effectiveRoomLatestVisibleBatchesPerSecond == 0 }
                  || scenario.personas.contains { $0.effectiveRoomLatestVisibleBatchWeight > 0 })
        else { throw LoadError.invalidScenario("invalid persona weights or phase rates") }
        return scenario
    }
}

private struct LoadCredential: Decodable, Sendable {
    let userID: String
    let deviceID: String
    let accessToken: String
    let accessTokenExpiresAtMilliseconds: Int64
    /// 在专门的预热运行中解析出的可选单聊房间标识。
    ///
    /// 提供它们可以让被测运行专注在稳态消息上，
    /// 而不必为每个模拟设备重复执行开房授权。
    let targetRoomIDs: [String]?

    static func load(from path: String) throws -> [Self] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let decoder = JSONDecoder()
        var credentials: [Self] = []
        var devices = Set<String>()
        for line in content.split(whereSeparator: \ .isNewline) {
            let decoded = try decoder.decode(Self.self, from: Data(line.utf8))
            guard let userID = UUID(uuidString: decoded.userID),
                  let deviceID = UUID(uuidString: decoded.deviceID),
                  !decoded.accessToken.isEmpty
            else { throw LoadError.invalidCredentialFile }
            let targetRoomIDs = try decoded.targetRoomIDs?.map { rawRoomID in
                guard let roomID = UUID(uuidString: rawRoomID) else {
                    throw LoadError.invalidCredentialFile
                }
                return roomID.uuidString
            }
            let credential = Self(
                userID: userID.uuidString,
                deviceID: deviceID.uuidString,
                accessToken: decoded.accessToken,
                accessTokenExpiresAtMilliseconds: decoded.accessTokenExpiresAtMilliseconds,
                targetRoomIDs: targetRoomIDs
            )
            guard devices.insert(credential.deviceID).inserted else {
                throw LoadError.invalidCredentialFile
            }
            credentials.append(credential)
        }
        guard !credentials.isEmpty else { throw LoadError.invalidCredentialFile }
        return credentials
    }
}

private enum RecoveryBatchKind: Sendable {
    case roomSyncState
    case roomLatestVisible

    var failureLabel: String {
        switch self {
        case .roomSyncState: "room_sync_state_batch"
        case .roomLatestVisible: "room_latest_visible_batch"
        }
    }
}

private struct RecoveryBatchStats {
    var scheduled = 0
    var sent = 0
    var completed = 0
    var skipped = 0
    var successfulRooms = 0
    var unavailableRooms = 0
    var retryRooms = 0
    var rejected = 0
    var timedOut = 0
    var latency = LatencyHistogram()
}

private final class LoadStatistics: @unchecked Sendable {
    struct State {
        var attempted = 0
        var authenticated = 0
        var failed = 0
        var connectionFailuresByError: [String: Int] = [:]
        var active = 0
        var peakActive = 0
        var disconnected = 0
        var plannedReconnects = 0
        var heartbeatSent = 0
        var heartbeatAcknowledged = 0
        var heartbeatMissed = 0
        var directRoomAttempted = 0
        var directRoomOpened = 0
        var roomLogTailReady = 0
        var workloadFailed = 0
        var workloadFailuresByKindAndCode: [String: Int] = [:]
        var messagesSent = 0
        var messagesAcknowledged = 0
        var messagesSkipped = 0
        var scenarioMessagesScheduled = 0
        var scenarioMessagesDeferred = 0
        var scenarioMessageQueueOverflowed = 0
        var scenarioMessageQueueAbandoned = 0
        var queuedScenarioMessages = 0
        var maximumQueuedScenarioMessages = 0
        var syncPullsSent = 0
        var syncBatchesReceived = 0
        var syncRecordsReceived = 0
        var syncAcknowledged = 0
        var roomEventPullsSent = 0
        var roomEventPullRetryableRejections = 0
        var roomEventPagesReceived = 0
        var roomEventRecordsReceived = 0
        var roomEventAvailabilityHintsReceived = 0
        var roomEventLivePayloadsApplied = 0
        var roomEventLiveGapFramesDetected = 0
        var roomEventLiveMissingSequences: UInt64 = 0
        var roomEventMetadataGapsObserved = 0
        var roomEventMetadataMissingSequences: UInt64 = 0
        var roomEventRecoveryGracesScheduled = 0
        var roomEventRecoveryGracesAvoided = 0
        var roomEventRecoveryGracesExpired = 0
        var roomEventLocalEchoesApplied = 0
        var roomEventLocalEchoGapsDetected = 0
        var roomEventStalePagesReceived = 0
        var readReceiptsScheduled = 0
        var readReceiptsSent = 0
        var readReceiptsAcknowledged = 0
        var readReceiptsCoalesced = 0
        var authenticationLatency = LatencyHistogram()
        var heartbeatLatency = LatencyHistogram()
        var messageLatency = LatencyHistogram()
        var syncPullLatency = LatencyHistogram()
        var roomEventPullLatency = LatencyHistogram()
        var readReceiptLatency = LatencyHistogram()
        var roomSyncStateBatch = RecoveryBatchStats()
        var roomLatestVisibleBatch = RecoveryBatchStats()
        var maximumRSSBytes: UInt64 = 0
    }

    private let lock = NIOLock()
    private var state = State()

    func recordAttempt() { lock.withLock { state.attempted += 1 } }
    func recordFailure(_ error: Error) {
        lock.withLock {
            state.failed += 1
            let key = Self.connectionFailureKey(error)
            state.connectionFailuresByError[key, default: 0] += 1
        }
    }
    func recordAuthenticated(milliseconds: Double) {
        lock.withLock {
            state.authenticated += 1
            state.active += 1
            state.peakActive = max(state.peakActive, state.active)
            state.authenticationLatency.record(milliseconds)
        }
    }
    func recordDisconnected() {
        lock.withLock {
            state.disconnected += 1
            state.active = max(0, state.active - 1)
        }
    }
    func recordPlannedReconnect() { lock.withLock { state.plannedReconnects += 1 } }
    func recordHeartbeatSent() { lock.withLock { state.heartbeatSent += 1 } }
    func recordHeartbeatAcknowledged(milliseconds: Double) {
        lock.withLock {
            state.heartbeatAcknowledged += 1
            state.heartbeatLatency.record(milliseconds)
        }
    }
    func recordHeartbeatMissed() { lock.withLock { state.heartbeatMissed += 1 } }
    func recordDirectRoomAttempted() { lock.withLock { state.directRoomAttempted += 1 } }
    func recordDirectRoomOpened() { lock.withLock { state.directRoomOpened += 1 } }
    func recordRoomLogTailReady() { lock.withLock { state.roomLogTailReady += 1 } }
    func recordWorkloadFailure(kind: String, code: String, retryable: Bool = false) {
        lock.withLock {
            state.workloadFailed += 1
            let key = "\(kind):\(code):\(retryable ? "retryable" : "terminal")"
            state.workloadFailuresByKindAndCode[key, default: 0] += 1
        }
    }
    func recordMessageSent() { lock.withLock { state.messagesSent += 1 } }
    func recordMessageAcknowledged(milliseconds: Double) {
        lock.withLock {
            state.messagesAcknowledged += 1
            state.messageLatency.record(milliseconds)
        }
    }
    func recordMessageSkipped() { lock.withLock { state.messagesSkipped += 1 } }
    func recordScenarioMessageScheduled() { lock.withLock { state.scenarioMessagesScheduled += 1 } }
    func recordScenarioMessageDeferred() {
        lock.withLock {
            state.scenarioMessagesDeferred += 1
            state.queuedScenarioMessages += 1
            state.maximumQueuedScenarioMessages = max(
                state.maximumQueuedScenarioMessages,
                state.queuedScenarioMessages
            )
        }
    }
    func recordScenarioMessageDequeued() {
        lock.withLock { state.queuedScenarioMessages = max(0, state.queuedScenarioMessages - 1) }
    }
    func recordScenarioMessageQueueOverflow() {
        lock.withLock {
            state.scenarioMessageQueueOverflowed += 1
            state.messagesSkipped += 1
        }
    }
    func recordScenarioMessageQueueAbandoned(count: Int) {
        guard count > 0 else { return }
        lock.withLock {
            state.scenarioMessageQueueAbandoned += count
            state.queuedScenarioMessages = max(0, state.queuedScenarioMessages - count)
        }
    }
    func recordSyncPullSent() { lock.withLock { state.syncPullsSent += 1 } }
    func recordSyncBatch(milliseconds: Double, records: Int) {
        lock.withLock {
            state.syncBatchesReceived += 1
            state.syncRecordsReceived += records
            state.syncPullLatency.record(milliseconds)
        }
    }
    func recordSyncAcknowledged() { lock.withLock { state.syncAcknowledged += 1 } }
    func recordRoomEventPullSent() { lock.withLock { state.roomEventPullsSent += 1 } }
    func recordRoomEventPullRetryableRejection() {
        lock.withLock { state.roomEventPullRetryableRejections += 1 }
    }
    func recordRoomEventAvailabilityHint() {
        lock.withLock { state.roomEventAvailabilityHintsReceived += 1 }
    }
    func recordRoomEventLivePayloadApplied() {
        lock.withLock { state.roomEventLivePayloadsApplied += 1 }
    }
    func recordRoomEventLiveGap(missingSequences: UInt64) {
        guard missingSequences > 0 else { return }
        lock.withLock {
            state.roomEventLiveGapFramesDetected += 1
            let sum = state.roomEventLiveMissingSequences.addingReportingOverflow(
                missingSequences
            )
            state.roomEventLiveMissingSequences = sum.overflow
                ? .max
                : sum.partialValue
        }
    }
    func recordRoomEventMetadataGap(missingSequences: UInt64) {
        guard missingSequences > 0 else { return }
        lock.withLock {
            state.roomEventMetadataGapsObserved += 1
            let sum = state.roomEventMetadataMissingSequences.addingReportingOverflow(
                missingSequences
            )
            state.roomEventMetadataMissingSequences = sum.overflow
                ? .max
                : sum.partialValue
        }
    }
    func recordRoomEventRecoveryGraceScheduled() {
        lock.withLock { state.roomEventRecoveryGracesScheduled += 1 }
    }
    func recordRoomEventRecoveryGraceAvoided() {
        lock.withLock { state.roomEventRecoveryGracesAvoided += 1 }
    }
    func recordRoomEventRecoveryGraceExpired() {
        lock.withLock { state.roomEventRecoveryGracesExpired += 1 }
    }
    func recordRoomEventLocalEchoApplied() {
        lock.withLock { state.roomEventLocalEchoesApplied += 1 }
    }
    func recordRoomEventLocalEchoGapDetected() {
        lock.withLock { state.roomEventLocalEchoGapsDetected += 1 }
    }
    func recordRoomEventStalePageReceived() {
        lock.withLock { state.roomEventStalePagesReceived += 1 }
    }
    func recordRoomEventPage(milliseconds: Double, records: Int) {
        lock.withLock {
            state.roomEventPagesReceived += 1
            state.roomEventRecordsReceived += records
            state.roomEventPullLatency.record(milliseconds)
        }
    }
    func recordReadReceiptScheduled() {
        lock.withLock { state.readReceiptsScheduled += 1 }
    }
    func recordReadReceiptSent() {
        lock.withLock { state.readReceiptsSent += 1 }
    }
    func recordReadReceiptAcknowledged(milliseconds: Double) {
        lock.withLock {
            state.readReceiptsAcknowledged += 1
            state.readReceiptLatency.record(milliseconds)
        }
    }
    func recordReadReceiptCoalesced() {
        lock.withLock { state.readReceiptsCoalesced += 1 }
    }
    private func updateRecovery(_ kind: RecoveryBatchKind,
                                _ update: (inout RecoveryBatchStats) -> Void) {
        lock.withLock {
            switch kind {
            case .roomSyncState: update(&state.roomSyncStateBatch)
            case .roomLatestVisible: update(&state.roomLatestVisibleBatch)
            }
        }
    }
    func recordRecoveryScheduled(_ kind: RecoveryBatchKind) {
        updateRecovery(kind) { $0.scheduled += 1 }
    }
    func recordRecoverySent(_ kind: RecoveryBatchKind) {
        updateRecovery(kind) { $0.sent += 1 }
    }
    func recordRecoverySkipped(_ kind: RecoveryBatchKind) {
        updateRecovery(kind) { $0.skipped += 1 }
    }
    func recordRecoveryCompleted(_ kind: RecoveryBatchKind, milliseconds: Double,
                                 successful: Int, unavailable: Int, retry: Int) {
        updateRecovery(kind) {
            $0.completed += 1
            $0.successfulRooms += successful
            $0.unavailableRooms += unavailable
            $0.retryRooms += retry
            $0.latency.record(milliseconds)
        }
    }
    func recordRecoveryRejected(_ kind: RecoveryBatchKind, code: String, retryable: Bool) {
        lock.withLock {
            switch kind {
            case .roomSyncState: state.roomSyncStateBatch.rejected += 1
            case .roomLatestVisible: state.roomLatestVisibleBatch.rejected += 1
            }
            state.workloadFailed += 1
            state.workloadFailuresByKindAndCode[
                "\(kind.failureLabel):\(code):\(retryable ? "retryable" : "terminal")", default: 0
            ] += 1
        }
    }
    func recordRecoveryTimedOut(_ kind: RecoveryBatchKind) {
        lock.withLock {
            switch kind {
            case .roomSyncState: state.roomSyncStateBatch.timedOut += 1
            case .roomLatestVisible: state.roomLatestVisibleBatch.timedOut += 1
            }
            state.workloadFailed += 1
            state.workloadFailuresByKindAndCode["\(kind.failureLabel):CLIENT_DEADLINE:terminal", default: 0] += 1
        }
    }
    func recordRSS(_ bytes: UInt64) { lock.withLock { state.maximumRSSBytes = max(state.maximumRSSBytes, bytes) } }
    func snapshot() -> State { lock.withLock { state } }

    private static func connectionFailureKey(_ error: Error) -> String {
        let typeName = String(reflecting: type(of: error))
        let description = String(describing: error)
            .split(whereSeparator: \ .isWhitespace)
            .joined(separator: " ")
        return "\(typeName):\(description.prefix(240))"
    }
}

private struct LoadRun {
    let configuration: LoadConfiguration
    let credentials: [LoadCredential]

    func execute() async throws -> LoadReport {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv13
        tls.maximumTLSVersion = .tlsv13
        tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(configuration.caPath))
        let sslContext = try NIOSSLContext(configuration: tls)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: configuration.eventLoops)
        let eventLoopLagMetrics = V2EventLoopLagMetrics()
        eventLoopLagMetrics.start(on: group)
        let statistics = LoadStatistics()
        let scenarioPhaseReports = ScenarioPhaseReportCollector()
        let startedAt = Date()
        var slots: [LoadConnectionSlot] = []
        var terminalError: Error?
        var scenarioPhases: [ScenarioPhaseReport] = []
        var scenarioDrain: ScenarioDrainReport?

        do {
            var offset = 0
            // The credential file may deliberately contain a larger reusable
            // corpus than an individual run. Honour `--connections` so a
            // small diagnostic run does not unexpectedly authenticate every
            // credential in that corpus.
            while offset < configuration.connections {
                let upperBound = min(configuration.connections, offset + configuration.rampBatchSize)
                let batch = credentials[offset..<upperBound]
                let batchStart = NIODeadline.now()
                let futures = batch.enumerated().map { localIndex, credential in
                    let connectionIndex = offset + localIndex
                    let slot = LoadConnectionSlot(
                        credential: credential,
                        targetUserIDs: targetUserIDs(for: connectionIndex),
                        connectionIndex: connectionIndex
                    )
                    return connect(
                        credential: credential,
                        targetUserIDs: slot.targetUserIDs,
                        connectionIndex: connectionIndex,
                        group: group,
                        sslContext: sslContext,
                        statistics: statistics
                    ).map { channel in
                        slot.replace(channel)
                        return slot
                    }
                }
                let results = try await EventLoopFuture.whenAllComplete(futures, on: group.next()).get()
                for result in results {
                    switch result {
                    case .success(let slot): slots.append(slot)
                    case .failure(let error): statistics.recordFailure(error)
                    }
                }
                offset = upperBound
                try enforceGuards(statistics: statistics)
                let snapshot = statistics.snapshot()
                print("ramp attempted=\(snapshot.attempted) authenticated=\(snapshot.authenticated) active=\(snapshot.active) failed=\(snapshot.failed) rss_mb=\(snapshot.maximumRSSBytes / 1_048_576)")
                let elapsedNanoseconds = max(0, (NIODeadline.now() - batchStart).nanoseconds)
                let rampIntervalNanoseconds = max(
                    1,
                    Int64(batch.count) * 1_000_000_000 / Int64(configuration.rampPerSecond)
                )
                if offset < credentials.count, elapsedNanoseconds < rampIntervalNanoseconds {
                    try await Task.sleep(nanoseconds: UInt64(rampIntervalNanoseconds - elapsedNanoseconds))
                }
            }

            if configuration.messagesPerSecond > 0 || configuration.scenario != nil {
                try await startWorkloads(channels: slots.compactMap(\.channel))
            }
            if let scenario = configuration.scenario {
                try await waitForRoomWarmup(scenario: scenario, statistics: statistics)
                try await runScenario(
                    scenario,
                    slots: slots,
                    group: group,
                    sslContext: sslContext,
                    statistics: statistics,
                    reports: scenarioPhaseReports
                )
                scenarioPhases = scenarioPhaseReports.snapshot()
                scenarioDrain = await drainScenarioMessages(
                    channels: slots.compactMap(\.channel),
                    maximumSeconds: scenario.completionDrainSeconds ?? 10
                )
                if scenario.requiresSteadyStateDrain == true {
                    let maximumQueued = scenario.maximumSteadyStateQueuedMessages ?? 0
                    if let stalled = scenarioPhases.first(where: {
                        !$0.isSteadyStateDrained(maximumQueuedMessages: maximumQueued)
                    }) {
                        throw LoadError.scenarioPhaseNotDrained(
                            phase: stalled.name,
                            queued: stalled.queuedScenarioMessagesAtEnd,
                            maximumQueued: maximumQueued,
                            sent: stalled.messagesSent,
                            acknowledged: stalled.messagesAcknowledged
                        )
                    }
                    guard scenarioDrain?.drained == true else {
                        let pending = scenarioDrain?.pending ?? .zero
                        throw LoadError.scenarioCompletionDrainTimedOut(
                            queued: pending.queued,
                            inFlight: pending.inFlight
                        )
                    }
                }
                if scenarioDrain?.drained == true,
                   let postDrainHoldSeconds = scenario.postDrainHoldSeconds,
                   postDrainHoldSeconds > 0 {
                    try await Task.sleep(
                        nanoseconds: UInt64(postDrainHoldSeconds) * 1_000_000_000
                    )
                }
            } else {
                for second in 1...configuration.holdSeconds {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try enforceGuards(statistics: statistics)
                    if second.isMultiple(of: 10) || second == configuration.holdSeconds {
                        printHold(second: second, statistics: statistics)
                    }
                }
            }
        } catch {
            terminalError = error
        }

        scenarioPhases = scenarioPhaseReports.snapshot()
        let roomCursorSnapshots = await snapshotRoomCursors(channels: slots.compactMap(\.channel))
        await close(channels: slots.compactMap(\.channel))
        eventLoopLagMetrics.stop()
        let eventLoopLag = eventLoopLagMetrics.snapshot()
        try await group.shutdownGracefully()
        let report = LoadReport(configuration: configuration, startedAt: startedAt, endedAt: Date(), state: statistics.snapshot(), eventLoopLag: eventLoopLag, scenarioPhases: scenarioPhases, scenarioDrain: scenarioDrain, terminalError: terminalError, roomCursorSnapshots: roomCursorSnapshots)
        if let terminalError {
            let data = try JSONEncoder.loadReport.encode(report)
            try data.write(to: URL(fileURLWithPath: configuration.reportPath), options: .atomic)
            throw terminalError
        }
        return report
    }

    private func connect(
        credential: LoadCredential,
        targetUserIDs: [String],
        connectionIndex: Int,
        group: MultiThreadedEventLoopGroup,
        sslContext: NIOSSLContext,
        statistics: LoadStatistics
    ) -> EventLoopFuture<Channel> {
        statistics.recordAttempt()
        let eventLoop = group.next()
        let authenticated = eventLoop.makePromise(of: Void.self)
        let started = NIODeadline.now()
        let connection = ClientBootstrap(group: eventLoop)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSLClientHandler(context: sslContext, serverHostname: configuration.serverName)
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        LoadConnectionHandler(
                            credential: credential,
                            targetUserIDs: targetUserIDs,
                            connectionIndex: connectionIndex,
                            heartbeatSeconds: configuration.heartbeatSeconds,
                            recoveryBatchTimeoutSeconds: configuration.recoveryBatchTimeoutSeconds,
                            messagesPerSecond: configuration.messagesPerSecond,
                            totalConnections: configuration.connections,
                            maximumInFlightMessagesPerConnection: configuration.maximumInFlightMessagesPerConnection,
                            scenarioSendDispatch: configuration.scenarioSendDispatch,
                            maximumQueuedScenarioMessages: configuration.maximumQueuedScenarioMessagesPerConnection,
                            messageBytes: configuration.messageBytes,
                            syncReads: configuration.syncReads,
                            roomLogReads: configuration.roomLogReads,
                            roomLogInitialCursor: configuration.roomLogInitialCursor,
                            roomLogReadTrigger: configuration.roomLogReadTrigger,
                            roomLogRecoveryGraceMilliseconds:
                                configuration.roomLogRecoveryGraceMilliseconds,
                            started: started,
                            authenticated: authenticated,
                            statistics: statistics
                        )
                    )
                }
            }
            .connect(host: configuration.host, port: configuration.port)

        // A TCP/TLS setup failure happens before LoadConnectionHandler owns the
        // authentication promise. Resolve that otherwise-unowned branch so a
        // failed ramp can shut its EventLoopGroup down without leaking promises.
        connection.cascadeFailure(to: authenticated)
        return connection.flatMap { channel in authenticated.futureResult.map { channel } }
    }

    private func enforceGuards(statistics: LoadStatistics) throws {
        let rss = residentMemoryBytes()
        statistics.recordRSS(rss)
        let snapshot = statistics.snapshot()
        guard rss <= UInt64(configuration.maximumRSSMegabytes) * 1_048_576 else {
            throw LoadError.memoryGuardTriggered(megabytes: Int(rss / 1_048_576))
        }
        guard snapshot.attempted == 0 || Double(snapshot.failed) / Double(snapshot.attempted) * 100 <= configuration.maximumFailurePercent else {
            throw LoadError.failureGuardTriggered(failed: snapshot.failed, attempted: snapshot.attempted)
        }
        let unexpectedDisconnects = max(0, snapshot.authenticated - snapshot.active - snapshot.plannedReconnects)
        guard snapshot.authenticated == 0 || Double(unexpectedDisconnects) / Double(snapshot.authenticated) * 100 <= configuration.maximumFailurePercent else {
            throw LoadError.connectionLossGuardTriggered(
                disconnected: unexpectedDisconnects,
                authenticated: snapshot.authenticated
            )
        }
        let workloadAttempted = snapshot.directRoomAttempted + snapshot.messagesSent
            + snapshot.syncPullsSent + snapshot.readReceiptsSent
            + snapshot.roomSyncStateBatch.sent + snapshot.roomLatestVisibleBatch.sent
        guard workloadAttempted == 0 || Double(snapshot.workloadFailed) / Double(workloadAttempted) * 100 <= configuration.maximumFailurePercent else {
            throw LoadError.workloadFailureGuardTriggered(failed: snapshot.workloadFailed, attempted: workloadAttempted)
        }
    }

    private func waitForRoomWarmup(scenario: LoadScenario, statistics: LoadStatistics) async throws {
        let required = configuration.connections * configuration.targetsPerConnection
        for second in 0...scenario.roomWarmupTimeoutSeconds {
            try enforceGuards(statistics: statistics)
            let snapshot = statistics.snapshot()
            let tailReady = configuration.roomLogInitialCursor == .tail
                ? snapshot.roomLogTailReady >= configuration.connections
                : true
            if snapshot.directRoomOpened >= required, tailReady {
                print("scenario room warmup complete opened=\(snapshot.directRoomOpened) tail_ready=\(snapshot.roomLogTailReady) required=\(required)")
                return
            }
            if second.isMultiple(of: 10) {
                print("scenario room warmup second=\(second) opened=\(snapshot.directRoomOpened) tail_ready=\(snapshot.roomLogTailReady) required=\(required) active=\(snapshot.active)")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw LoadError.roomWarmupTimedOut(opened: statistics.snapshot().directRoomOpened, required: required)
    }

    private func runScenario(
        _ scenario: LoadScenario,
        slots: [LoadConnectionSlot],
        group: MultiThreadedEventLoopGroup,
        sslContext: NIOSSLContext,
        statistics: LoadStatistics,
        reports: ScenarioPhaseReportCollector
    ) async throws {
        let assignments = ScenarioAssignments(
            scenario: scenario,
            slots: slots,
            totalConnections: configuration.connections
        )
        var random = ScenarioRandom(seed: scenario.seed)
        let ticksPerSecond = scenario.schedulerTicksPerSecond ?? 10
        let tickNanoseconds = Int64(1_000_000_000 / ticksPerSecond)
        for phase in scenario.phases {
            let started = statistics.snapshot()
            let phaseStarted = NIODeadline.now()
            var completedTicks = 0
            var messageCarry = 0.0
            var roomLogCarry = 0.0
            var syncCarry = 0.0
            var readReceiptCarry = 0.0
            var roomSyncStateCarry = 0.0
            var roomLatestVisibleCarry = 0.0
            var reconnectCarry = 0.0
            let messageRate = phase.messagesPerSecond * configuration.scenarioRateScale
            let roomLogRate = phase.roomLogReadsPerSecond * configuration.scenarioRateScale
            let syncRate = phase.syncPullsPerSecond * configuration.scenarioRateScale
            let readReceiptRate = phase.effectiveReadReceiptsPerSecond
                * configuration.scenarioRateScale
            let roomSyncStateRate = phase.effectiveRoomSyncStateBatchesPerSecond
                * configuration.scenarioRateScale
            let roomLatestVisibleRate = phase.effectiveRoomLatestVisibleBatchesPerSecond
                * configuration.scenarioRateScale
            print("scenario phase=\(phase.name) seconds=\(phase.durationSeconds) scheduler_hz=\(ticksPerSecond) messages_per_second=\(messageRate) room_log_reads_per_second=\(roomLogRate) sync_pulls_per_second=\(syncRate) read_receipts_per_second=\(readReceiptRate) room_sync_state_batches_per_second=\(roomSyncStateRate) room_latest_visible_batches_per_second=\(roomLatestVisibleRate)")
            do {
                for tick in 0..<(phase.durationSeconds * ticksPerSecond) {
                    messageCarry += messageRate / Double(ticksPerSecond)
                    roomLogCarry += roomLogRate / Double(ticksPerSecond)
                    syncCarry += syncRate / Double(ticksPerSecond)
                    readReceiptCarry += readReceiptRate / Double(ticksPerSecond)
                    roomSyncStateCarry += roomSyncStateRate / Double(ticksPerSecond)
                    roomLatestVisibleCarry += roomLatestVisibleRate / Double(ticksPerSecond)
                    reconnectCarry += phase.reconnectPercentPerMinute / 100
                        * Double(slots.count) / Double(60 * ticksPerSecond)
                    let messageCount = Int(messageCarry.rounded(.down))
                    let roomLogCount = Int(roomLogCarry.rounded(.down))
                    let syncCount = Int(syncCarry.rounded(.down))
                    let readReceiptCount = Int(readReceiptCarry.rounded(.down))
                    let roomSyncStateCount = Int(roomSyncStateCarry.rounded(.down))
                    let roomLatestVisibleCount = Int(roomLatestVisibleCarry.rounded(.down))
                    let reconnectCount = Int(reconnectCarry.rounded(.down))
                    messageCarry -= Double(messageCount)
                    roomLogCarry -= Double(roomLogCount)
                    syncCarry -= Double(syncCount)
                    readReceiptCarry -= Double(readReceiptCount)
                    roomSyncStateCarry -= Double(roomSyncStateCount)
                    roomLatestVisibleCarry -= Double(roomLatestVisibleCount)
                    reconnectCarry -= Double(reconnectCount)
                    for _ in 0..<messageCount { assignments.pick(kind: .send, random: &random)?.pipeline.fireUserInboundEventTriggered(ScenarioSendEvent()) }
                    for _ in 0..<roomLogCount { assignments.pick(kind: .roomLogRead, random: &random)?.pipeline.fireUserInboundEventTriggered(ScenarioRoomLogReadEvent()) }
                    for _ in 0..<syncCount { assignments.pick(kind: .syncPull, random: &random)?.pipeline.fireUserInboundEventTriggered(ScenarioSyncPullEvent()) }
                    for _ in 0..<readReceiptCount { assignments.pick(kind: .readReceipt, random: &random)?.pipeline.fireUserInboundEventTriggered(ScenarioReadReceiptEvent()) }
                    for _ in 0..<roomSyncStateCount { assignments.pick(kind: .roomSyncStateBatch, random: &random)?.pipeline.fireUserInboundEventTriggered(ScenarioRoomSyncStateBatchEvent()) }
                    for _ in 0..<roomLatestVisibleCount { assignments.pick(kind: .roomLatestVisibleBatch, random: &random)?.pipeline.fireUserInboundEventTriggered(ScenarioRoomLatestVisibleBatchEvent()) }
                    for _ in 0..<reconnectCount {
                        if let slot = assignments.pickSlot(random: &random) {
                            try await reconnect(slot: slot, group: group, sslContext: sslContext, statistics: statistics)
                        }
                    }
                    let nextTick = phaseStarted + .nanoseconds(
                        Int64(tick + 1) * tickNanoseconds
                    )
                    let remaining = nextTick - .now()
                    if remaining.nanoseconds > 0 {
                        try await Task.sleep(nanoseconds: UInt64(remaining.nanoseconds))
                    }
                    completedTicks = tick + 1
                    if completedTicks.isMultiple(of: ticksPerSecond) {
                        if completedTicks.isMultiple(of: ticksPerSecond * 10) {
                            try enforceGuards(statistics: statistics)
                        }
                        printScenarioProgress(
                            phase: phase.name,
                            second: completedTicks / ticksPerSecond,
                            statistics: statistics
                        )
                    }
                }
                try enforceGuards(statistics: statistics)
            } catch {
                reports.append(.init(
                    phase: phase,
                    rateScale: configuration.scenarioRateScale,
                    observedDurationSeconds: Double(completedTicks) / Double(ticksPerSecond),
                    completed: false,
                    started: started,
                    ended: statistics.snapshot()
                ))
                throw error
            }
            reports.append(.init(
                phase: phase,
                rateScale: configuration.scenarioRateScale,
                observedDurationSeconds: Double(phase.durationSeconds),
                completed: true,
                started: started,
                ended: statistics.snapshot()
            ))
        }
    }

    /// 在关闭 TLS 连接之前，于其所属事件循环上轮询每个通道的模拟器状态。
    ///
    /// 它刻意是有界的，且只是拆除辅助：
    /// `requiresSteadyStateDrain` 评估的是*每个阶段结束时*采样的积压，早于本次排空开始。
    ///
    /// - Parameters:
    ///   - channels: 待排空的通道列表。
    ///   - maximumSeconds: 本次排空的最长秒数。
    /// - Returns: 排空报告。
    private func drainScenarioMessages(
        channels: [Channel],
        maximumSeconds: Int
    ) async -> ScenarioDrainReport {
        let started = NIODeadline.now()
        let deadline = started + .seconds(Int64(maximumSeconds))
        var pending = await scenarioPendingMessages(channels: channels)
        while !pending.isZero, NIODeadline.now() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
            pending = await scenarioPendingMessages(channels: channels)
        }
        return .init(
            drained: pending.isZero,
            durationMilliseconds: Int((NIODeadline.now() - started).millisecondsDouble.rounded(.towardZero)),
            pending: pending
        )
    }

    private func scenarioPendingMessages(channels: [Channel]) async -> ScenarioPendingMessages {
        guard let first = channels.first else { return .zero }
        let futures = channels.map { channel -> EventLoopFuture<ScenarioPendingMessages> in
            let promise = channel.eventLoop.makePromise(of: ScenarioPendingMessages.self)
            channel.eventLoop.execute {
                guard channel.isActive else {
                    promise.succeed(.zero)
                    return
                }
                channel.pipeline.fireUserInboundEventTriggered(ScenarioDrainProbe(completion: promise))
            }
            return promise.futureResult
        }
        let values = (try? await EventLoopFuture.whenAllSucceed(futures, on: first.eventLoop).get()) ?? []
        return values.reduce(into: .zero) { total, next in total.add(next) }
    }

    // Read each handler on its own event loop before closing the transport.
    // Missing channels produce no snapshots; consumers must check coverage.
    private func snapshotRoomCursors(channels: [Channel]) async -> [RoomCursorSnapshot] {
        guard let first = channels.first else { return [] }
        let futures = channels.map { channel -> EventLoopFuture<[RoomCursorSnapshot]> in
            let promise = channel.eventLoop.makePromise(of: [RoomCursorSnapshot].self)
            channel.eventLoop.execute {
                guard channel.isActive else { promise.succeed([]); return }
                channel.pipeline.fireUserInboundEventTriggered(RoomCursorProbe(completion: promise))
            }
            return promise.futureResult
        }
        let values = (try? await EventLoopFuture.whenAllSucceed(futures, on: first.eventLoop).get()) ?? []
        return values.flatMap { $0 }.sorted {
            ($0.connectionIndex, $0.roomID) < ($1.connectionIndex, $1.roomID)
        }
    }

    private func targetUserIDs(for connectionIndex: Int) -> [String] {
        guard configuration.messagesPerSecond > 0 || configuration.scenario != nil else { return [] }
        if configuration.peerTopology == .pairs {
            let peerIndex = connectionIndex.isMultiple(of: 2)
                ? connectionIndex + 1
                : connectionIndex - 1
            return [credentials[peerIndex].userID]
        }
        if configuration.scenario != nil {
            // Scenario peers are symmetric: a passive recipient has the same
            // room ID in its local set and can therefore perform a real room
            // log pull for traffic sent by its neighbour.  The legacy fixed
            // workload remains forward-only for backwards-compatible baselines.
            let offsets = (1...configuration.targetsPerConnection).map { ordinal -> Int in
                let magnitude = (ordinal + 1) / 2
                return ordinal.isMultiple(of: 2) ? -magnitude : magnitude
            }
            return offsets.map { offset in
                credentials[(connectionIndex + offset + credentials.count) % credentials.count].userID
            }
        }
        return (configuration.targetOffset..<(configuration.targetOffset + configuration.targetsPerConnection)).map {
            credentials[(connectionIndex + $0) % credentials.count].userID
        }
    }

    private func reconnect(
        slot: LoadConnectionSlot,
        group: MultiThreadedEventLoopGroup,
        sslContext: NIOSSLContext,
        statistics: LoadStatistics
    ) async throws {
        if let current = slot.channel {
            statistics.recordPlannedReconnect()
            _ = try? await current.close().get()
        }
        let channel = try await connect(
            credential: slot.credential,
            targetUserIDs: slot.targetUserIDs,
            connectionIndex: slot.connectionIndex,
            group: group,
            sslContext: sslContext,
            statistics: statistics
        ).get()
        slot.replace(channel)
        channel.pipeline.fireUserInboundEventTriggered(StartWorkloadEvent())
    }

    private func printHold(second: Int, statistics: LoadStatistics) {
        let snapshot = statistics.snapshot()
        print("hold second=\(second) active=\(snapshot.active) heartbeat_ack=\(snapshot.heartbeatAcknowledged) missed=\(snapshot.heartbeatMissed) messages_ack=\(snapshot.messagesAcknowledged) sync_records=\(snapshot.syncRecordsReceived) workload_failed=\(snapshot.workloadFailed) rss_mb=\(snapshot.maximumRSSBytes / 1_048_576)")
    }

    private func printScenarioProgress(phase: String, second: Int, statistics: LoadStatistics) {
        let snapshot = statistics.snapshot()
        print("scenario phase=\(phase) second=\(second) active=\(snapshot.active) heartbeat_ack=\(snapshot.heartbeatAcknowledged) missed=\(snapshot.heartbeatMissed) messages_ack=\(snapshot.messagesAcknowledged) room_event_local_echoes=\(snapshot.roomEventLocalEchoesApplied) room_event_local_echo_gaps=\(snapshot.roomEventLocalEchoGapsDetected) room_event_pulls=\(snapshot.roomEventPullsSent) room_event_records=\(snapshot.roomEventRecordsReceived) read_receipts_ack=\(snapshot.readReceiptsAcknowledged) read_receipts_coalesced=\(snapshot.readReceiptsCoalesced) sync_records=\(snapshot.syncRecordsReceived) room_sync_state_success_rooms=\(snapshot.roomSyncStateBatch.successfulRooms) room_sync_state_retry_rooms=\(snapshot.roomSyncStateBatch.retryRooms) room_sync_state_unavailable_rooms=\(snapshot.roomSyncStateBatch.unavailableRooms) room_latest_visible_success_rooms=\(snapshot.roomLatestVisibleBatch.successfulRooms) room_latest_visible_retry_rooms=\(snapshot.roomLatestVisibleBatch.retryRooms) room_latest_visible_unavailable_rooms=\(snapshot.roomLatestVisibleBatch.unavailableRooms) workload_failed=\(snapshot.workloadFailed) rss_mb=\(snapshot.maximumRSSBytes / 1_048_576)")
    }

    private func startWorkloads(channels: [Channel]) async throws {
        var offset = 0
        while offset < channels.count {
            let upperBound = min(channels.count, offset + configuration.workloadRampPerSecond)
            let batchStart = NIODeadline.now()
            for channel in channels[offset..<upperBound] {
                channel.pipeline.fireUserInboundEventTriggered(StartWorkloadEvent())
            }
            offset = upperBound
            let elapsedNanoseconds = max(0, (NIODeadline.now() - batchStart).nanoseconds)
            let rampIntervalNanoseconds: Int64 = 1_000_000_000
            if offset < channels.count, elapsedNanoseconds < rampIntervalNanoseconds {
                try await Task.sleep(nanoseconds: UInt64(rampIntervalNanoseconds - elapsedNanoseconds))
            }
        }
    }

    private func close(channels: [Channel]) async {
        var offset = 0
        while offset < channels.count {
            let upperBound = min(channels.count, offset + 100)
            let futures = channels[offset..<upperBound].map { $0.close() }
            _ = try? await EventLoopFuture.whenAllComplete(futures, on: channels[offset].eventLoop).get()
            offset = upperBound
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

private struct StartWorkloadEvent: Sendable {}
private struct ScenarioSendEvent: Sendable {}
private struct ScenarioRoomLogReadEvent: Sendable {}
private struct ScenarioSyncPullEvent: Sendable {}
private struct ScenarioReadReceiptEvent: Sendable {}
private struct ScenarioRoomSyncStateBatchEvent: Sendable {}
private struct ScenarioRoomLatestVisibleBatchEvent: Sendable {}

private struct ScenarioPendingMessages: Sendable, Equatable, Encodable {
    var queued: Int
    var inFlight: Int

    static let zero = Self(queued: 0, inFlight: 0)
    var isZero: Bool { queued == 0 && inFlight == 0 }

    mutating func add(_ other: Self) {
        queued += other.queued
        inFlight += other.inFlight
    }
}

private struct RoomCursorSnapshot: Encodable, Sendable {
    let connectionIndex: Int
    let roomID: String
    let appliedRoomSequence: UInt64
}

private struct RoomCursorProbe {
    let completion: EventLoopPromise<[RoomCursorSnapshot]>
}

private struct ScenarioDrainProbe {
    let completion: EventLoopPromise<ScenarioPendingMessages>
}

private enum ScenarioAction {
    case send
    case roomLogRead
    case syncPull
    case readReceipt
    case roomSyncStateBatch
    case roomLatestVisibleBatch
}

private final class LoadConnectionSlot: @unchecked Sendable {
    let credential: LoadCredential
    let targetUserIDs: [String]
    let connectionIndex: Int
    private let lock = NIOLock()
    private var currentChannel: Channel?

    init(credential: LoadCredential, targetUserIDs: [String], connectionIndex: Int) {
        self.credential = credential
        self.targetUserIDs = targetUserIDs
        self.connectionIndex = connectionIndex
    }

    var channel: Channel? { lock.withLock { currentChannel } }

    func replace(_ channel: Channel) {
        lock.withLock { currentChannel = channel }
    }
}

/// 固定的累积权重让场景对给定种子保持确定性，且不会为每条连接保留一个任务。
///
/// 单个调度器会在每个 100ms tick 上挑选个别通道，
/// 从而模拟稀疏的活跃子集，而不是让每条连接都以均匀间隔发送。
private struct ScenarioAssignments {
    private struct Entry {
        let cumulativeWeight: Double
        let slot: LoadConnectionSlot
    }

    private let sends: [Entry]
    private let roomLogReads: [Entry]
    private let syncPulls: [Entry]
    private let readReceipts: [Entry]
    private let roomSyncStateBatches: [Entry]
    private let roomLatestVisibleBatches: [Entry]
    private let reconnectCandidates: [LoadConnectionSlot]

    init(scenario: LoadScenario, slots: [LoadConnectionSlot], totalConnections: Int) {
        precondition(slots.count <= totalConnections)
        var random = ScenarioRandom(seed: scenario.seed)
        var sendEntries: [(Double, LoadConnectionSlot)] = []
        var roomLogEntries: [(Double, LoadConnectionSlot)] = []
        var syncEntries: [(Double, LoadConnectionSlot)] = []
        var readReceiptEntries: [(Double, LoadConnectionSlot)] = []
        var roomSyncStateEntries: [(Double, LoadConnectionSlot)] = []
        var roomLatestVisibleEntries: [(Double, LoadConnectionSlot)] = []
        let personas = Self.shuffledPersonas(total: totalConnections, scenario: scenario, random: &random)
        for (index, slot) in slots.enumerated() {
            let persona = personas[index]
            if persona.sendWeight > 0 { sendEntries.append((persona.sendWeight, slot)) }
            if persona.roomLogReadWeight > 0 { roomLogEntries.append((persona.roomLogReadWeight, slot)) }
            if persona.syncPullWeight > 0 { syncEntries.append((persona.syncPullWeight, slot)) }
            if persona.effectiveReadReceiptWeight > 0 {
                readReceiptEntries.append((persona.effectiveReadReceiptWeight, slot))
            }
            if persona.effectiveRoomSyncStateBatchWeight > 0 {
                roomSyncStateEntries.append((persona.effectiveRoomSyncStateBatchWeight, slot))
            }
            if persona.effectiveRoomLatestVisibleBatchWeight > 0 {
                roomLatestVisibleEntries.append((persona.effectiveRoomLatestVisibleBatchWeight, slot))
            }
        }
        sends = Self.entries(sendEntries)
        roomLogReads = Self.entries(roomLogEntries)
        syncPulls = Self.entries(syncEntries)
        readReceipts = Self.entries(readReceiptEntries)
        roomSyncStateBatches = Self.entries(roomSyncStateEntries)
        roomLatestVisibleBatches = Self.entries(roomLatestVisibleEntries)
        reconnectCandidates = slots
    }

    func pick(kind: ScenarioAction, random: inout ScenarioRandom) -> Channel? {
        let entries: [Entry]
        switch kind {
        case .send: entries = sends
        case .roomLogRead: entries = roomLogReads
        case .syncPull: entries = syncPulls
        case .readReceipt: entries = readReceipts
        case .roomSyncStateBatch: entries = roomSyncStateBatches
        case .roomLatestVisibleBatch: entries = roomLatestVisibleBatches
        }
        guard let total = entries.last?.cumulativeWeight, total > 0 else { return nil }
        let target = random.nextUnit() * total
        var lower = 0
        var upper = entries.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if entries[middle].cumulativeWeight < target { lower = middle + 1 }
            else { upper = middle }
        }
        return entries[lower].slot.channel
    }

    func pickSlot(random: inout ScenarioRandom) -> LoadConnectionSlot? {
        guard !reconnectCandidates.isEmpty else { return nil }
        return reconnectCandidates[min(reconnectCandidates.count - 1, Int(random.nextUnit() * Double(reconnectCandidates.count)))]
    }

    private static func entries(_ raw: [(Double, LoadConnectionSlot)]) -> [Entry] {
        var total = 0.0
        return raw.map { weight, slot in
            total += weight
            return .init(cumulativeWeight: total, slot: slot)
        }
    }

    private static func shuffledPersonas(
        total: Int,
        scenario: LoadScenario,
        random: inout ScenarioRandom
    ) -> [LoadScenario.Persona] {
        // Allocate by largest remainder before shuffling.  This makes the
        // configured mix exact whenever the shares and worker size permit it
        // (all 5,000-connection production workers do), without clustering
        // adjacent direct-message peers into the same persona.
        let quotas = scenario.personas.map { $0.share * Double(total) }
        var counts = quotas.map { Int($0.rounded(.down)) }
        var remaining = total - counts.reduce(0, +)
        let priority = quotas.indices.sorted {
            let left = quotas[$0] - Double(counts[$0])
            let right = quotas[$1] - Double(counts[$1])
            return left == right ? $0 < $1 : left > right
        }
        for index in priority where remaining > 0 {
            counts[index] += 1
            remaining -= 1
        }

        var assignments: [LoadScenario.Persona] = []
        assignments.reserveCapacity(total)
        for (index, persona) in scenario.personas.enumerated() {
            assignments.append(contentsOf: repeatElement(persona, count: counts[index]))
        }
        guard assignments.count > 1 else { return assignments }
        for index in stride(from: assignments.count - 1, through: 1, by: -1) {
            let swapIndex = min(index, Int(random.nextUnit() * Double(index + 1)))
            assignments.swapAt(index, swapIndex)
        }
        return assignments
    }
}

private struct ScenarioRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func nextUnit() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11) * (1.0 / Double(1 << 53))
    }
}

private final class LoadConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Stage { case awaitingHello, awaitingAuthentication, authenticated }
    private enum PendingRequest {
        case heartbeat(sent: NIODeadline)
        case directRoom(
            targetUserID: String,
            operationID: String,
            retryCount: Int,
            sent: NIODeadline
        )
        case message(sent: NIODeadline, roomID: String)
        case syncPull(sent: NIODeadline)
        case roomEventPull(sent: NIODeadline, roomID: String, afterRoomSequence: UInt64)
        case roomEventSubscribe(roomID: String)
        case readReceipt(sent: NIODeadline, roomID: String, roomSequence: UInt64)
        case recovery(kind: RecoveryBatchKind, sent: NIODeadline, roomIDs: [String])
        case syncAck(hasMore: Bool)
    }

    private let credential: LoadCredential
    private let targetUserIDs: [String]
    private let connectionIndex: Int
    private let heartbeatSeconds: Int
    private let recoveryBatchTimeoutSeconds: Int
    private let messageIntervalMilliseconds: Int64?
    private let messageInitialDelayMilliseconds: Int64
    private let maximumInFlightMessagesPerConnection: Int
    private let scenarioSendDispatch: ScenarioSendDispatch
    private let maximumQueuedScenarioMessages: Int
    private let messageText: String
    private let syncReads: Bool
    private let roomLogReads: Bool
    private let roomLogInitialCursor: RoomLogInitialCursor
    private let roomLogReadTrigger: RoomLogReadTrigger
    private let roomLogRecoveryGraceMilliseconds: Int
    private let started: NIODeadline
    private let authenticatedPromise: EventLoopPromise<Void>
    private let statistics: LoadStatistics
    private let limits = try! V2FrameLimits(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
    private var decoder: V2FrameDecoder
    private var negotiatedFrameCompression: V2NegotiatedFrameCompression?
    private var stage: Stage = .awaitingHello
    private var nextRequestID: UInt64 = 3
    private var pendingRequests: [UInt64: PendingRequest] = [:]
    private var heartbeatRequestID: UInt64?
    private var messageRequestIDs: Set<UInt64> = []
    private var queuedScenarioMessages = 0
    private var directRoomIDs: [String] = []
    private var nextRoomIndex = 0
    private var nextSyncToken = ""
    private var syncInFlight = false
    private var syncRequested = false
    private var roomEventCursors: [String: UInt64] = [:]
    private var roomEventAnnouncedHighWatermarks: [String: UInt64] = [:]
    private var roomEventPullRooms: Set<String> = []
    private var roomEventPullRetryCounts: [String: Int] = [:]
    private var roomEventPullRetryTasks: [String: Scheduled<Void>] = [:]
    private var roomEventRecoveryGraceTasks: [String: Scheduled<Void>] = [:]
    private var roomEventCursorSubscriptionPendingRooms: [String] = []
    private var roomEventCursorSubscriptionInFlightRoom: String?
    private var roomEventCursorSubscriptionRetryCounts: [String: Int] = [:]
    private var roomEventCursorInitializationStarted = false
    private var activeRoomLogRoomID: String?
    private var readReceiptInFlightRooms: Set<String> = []
    private var readReceiptAcknowledgedSequences: [String: UInt64] = [:]
    private var readReceiptPendingSequences: [String: UInt64] = [:]
    private var recoveryInFlightRequestID: UInt64?
    private var recoveryDeadlineTask: Scheduled<Void>?
    private var heartbeatTask: RepeatedTask?
    private var messageTask: RepeatedTask?
    private var authenticationCompleted = false
    private var registered = false
    private var workloadStarted = false

    init(
        credential: LoadCredential,
        targetUserIDs: [String],
        connectionIndex: Int,
        heartbeatSeconds: Int,
        recoveryBatchTimeoutSeconds: Int,
        messagesPerSecond: Int,
        totalConnections: Int,
        maximumInFlightMessagesPerConnection: Int,
        scenarioSendDispatch: ScenarioSendDispatch,
        maximumQueuedScenarioMessages: Int,
        messageBytes: Int,
        syncReads: Bool,
        roomLogReads: Bool,
        roomLogInitialCursor: RoomLogInitialCursor,
        roomLogReadTrigger: RoomLogReadTrigger,
        roomLogRecoveryGraceMilliseconds: Int,
        started: NIODeadline,
        authenticated: EventLoopPromise<Void>,
        statistics: LoadStatistics
    ) {
        self.credential = credential
        self.targetUserIDs = targetUserIDs
        // PostgreSQL JSON exports UUIDs in lowercase while Swift UUID values
        // use uppercase hexadecimal. Canonicalize pre-resolved IDs before
        // strict request/response comparison; do not weaken equality checks.
        directRoomIDs = credential.targetRoomIDs?.map {
            UUID(uuidString: $0)?.uuidString ?? $0
        } ?? []
        self.connectionIndex = connectionIndex
        self.heartbeatSeconds = heartbeatSeconds
        self.recoveryBatchTimeoutSeconds = recoveryBatchTimeoutSeconds
        self.maximumInFlightMessagesPerConnection = maximumInFlightMessagesPerConnection
        self.scenarioSendDispatch = scenarioSendDispatch
        self.maximumQueuedScenarioMessages = maximumQueuedScenarioMessages
        if messagesPerSecond > 0 {
            let interval = max(1, Int64(totalConnections) * 1_000 / Int64(messagesPerSecond))
            messageIntervalMilliseconds = interval
            messageInitialDelayMilliseconds = max(
                1,
                Int64(connectionIndex) * max(1, interval / Int64(totalConnections))
            )
        } else {
            messageIntervalMilliseconds = nil
            messageInitialDelayMilliseconds = 1
        }
        messageText = String(repeating: "x", count: messageBytes)
        self.syncReads = syncReads
        self.roomLogReads = roomLogReads
        self.roomLogInitialCursor = roomLogInitialCursor
        self.roomLogReadTrigger = roomLogReadTrigger
        self.roomLogRecoveryGraceMilliseconds = roomLogRecoveryGraceMilliseconds
        self.started = started
        authenticatedPromise = authenticated
        self.statistics = statistics
        decoder = .init(limits: limits)
    }

    func channelActive(context: ChannelHandlerContext) {
        do {
            var hello = IMV2Envelope()
            hello.requestID = 1
            hello.clientHello = .init()
            hello.clientHello.supportedProtocolVersions = [IMV2ProtocolVersion.current]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            hello.clientHello.deviceID = credential.deviceID
            hello.clientHello.supportedFrameCompressions = [.zlib]
            try write(hello, frameVersion: 0, context: context)
        } catch {
            failAuthentication(error, context: context)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do {
            let bytes = Data(unwrapInboundIn(data).readableBytesView)
            try receiveDecodedFrames(try decoder.append(bytes), context: context)
            while decoder.hasBufferedBytes {
                let frames = try decoder.append(Data())
                guard !frames.isEmpty else { break }
                try receiveDecodedFrames(frames, context: context)
            }
        } catch {
            if authenticationCompleted {
                FileHandle.standardError.write(
                    Data("post-auth protocol failure: \(error)\n".utf8)
                )
            }
            failAuthentication(error, context: context)
        }
    }

    private func receiveDecodedFrames(_ frames: [V2Frame], context: ChannelHandlerContext) throws {
        for frame in frames { try receive(frame, context: context) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        heartbeatTask?.cancel()
        messageTask?.cancel()
        for task in roomEventPullRetryTasks.values { task.cancel() }
        roomEventPullRetryTasks.removeAll(keepingCapacity: false)
        for task in roomEventRecoveryGraceTasks.values { task.cancel() }
        roomEventRecoveryGraceTasks.removeAll(keepingCapacity: false)
        statistics.recordScenarioMessageQueueAbandoned(count: queuedScenarioMessages)
        queuedScenarioMessages = 0
        readReceiptInFlightRooms.removeAll(keepingCapacity: false)
        readReceiptPendingSequences.removeAll(keepingCapacity: false)
        recoveryDeadlineTask?.cancel()
        recoveryDeadlineTask = nil
        recoveryInFlightRequestID = nil
        if registered { statistics.recordDisconnected() }
        if !authenticationCompleted { failAuthentication(LoadError.connectionClosed, context: context, close: false) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAuthentication(error, context: context)
    }

    private func receive(_ frame: V2Frame, context: ChannelHandlerContext) throws {
        let envelope = try V2ServerProtobufFrameCodec.decode(
            frame,
            compression: negotiatedFrameCompression,
            maximumUncompressedPayloadBytes: limits.maximumPayloadBytes
        )
        if frame.requestID == 0 {
            guard case .authenticated = stage else { return }
            switch envelope.body {
            case .syncAvailable:
                guard syncReads, !targetUserIDs.isEmpty else { return }
                syncRequested = true
                try startSyncIfNeeded(context: context)
            case .groupEventAvailable(let hint):
                guard roomLogReads, roomLogReadTrigger == .availabilityHint,
                      hint.roomID == activeRoomLogRoomID
                else { return }
                let previous = roomEventAnnouncedHighWatermarks[hint.roomID, default: 0]
                roomEventAnnouncedHighWatermarks[hint.roomID] = max(previous, hint.highWatermark)
                statistics.recordRoomEventAvailabilityHint()
                if !hint.liveEvents.isEmpty {
                    var cursor = roomEventCursors[hint.roomID, default: 0]
                    for event in hint.liveEvents {
                        // The sender may already have advanced its local
                        // cursor from MessageAccepted. Shared group frames are
                        // intentionally identical for every subscriber, so
                        // skip duplicates and apply only one contiguous prefix.
                        if event.roomSequence <= cursor { continue }
                        let expected = cursor == .max ? .max : cursor + 1
                        guard event.roomSequence == expected else {
                            if event.roomSequence > expected {
                                statistics.recordRoomEventLiveGap(
                                    missingSequences: event.roomSequence - expected
                                )
                            }
                            break
                        }
                        guard !event.sourceEventID.isEmpty,
                              !event.projectionKind.isEmpty,
                              !event.payload.isEmpty
                        else { break }
                        cursor = event.roomSequence
                        statistics.recordRoomEventLivePayloadApplied()
                    }
                    roomEventCursors[hint.roomID] = cursor
                    cancelRoomEventRecoveryGraceIfCaughtUp(roomID: hint.roomID)
                    if hint.highWatermark > cursor {
                        try scheduleRoomEventRecoveryIfNeeded(
                            roomID: hint.roomID,
                            context: context
                        )
                    }
                    return
                }
                let currentCursor = roomEventCursors[hint.roomID, default: 0]
                let expectedSequence = currentCursor == .max
                    ? .max
                    : currentCursor + 1
                if hint.roomSequence == hint.highWatermark,
                   hint.roomSequence == expectedSequence,
                   !hint.sourceEventID.isEmpty,
                   !hint.projectionKind.isEmpty,
                   !hint.eventPayload.isEmpty {
                    roomEventCursors[hint.roomID] = hint.roomSequence
                    statistics.recordRoomEventLivePayloadApplied()
                    cancelRoomEventRecoveryGraceIfCaughtUp(roomID: hint.roomID)
                    return
                }
                if hint.roomSequence > expectedSequence,
                   !hint.sourceEventID.isEmpty,
                   !hint.projectionKind.isEmpty,
                   !hint.eventPayload.isEmpty {
                    statistics.recordRoomEventLiveGap(
                        missingSequences: hint.roomSequence - expectedSequence
                    )
                }
                if hint.highWatermark > roomEventCursors[hint.roomID, default: 0] {
                    let cursor = roomEventCursors[hint.roomID, default: 0]
                    statistics.recordRoomEventMetadataGap(
                        missingSequences: hint.highWatermark - cursor
                    )
                    try scheduleRoomEventRecoveryIfNeeded(
                        roomID: hint.roomID,
                        context: context
                    )
                }
            default:
                break
            }
            return
        }
        switch stage {
        case .awaitingHello:
            guard frame.requestID == 1,
                  case .serverHello(let response)? = envelope.body,
                  response.selectedProtocolVersion == IMV2ProtocolVersion.current
            else {
                FileHandle.standardError.write(Data(
                    "protocol mismatch expected=server_hello request_match=\(frame.requestID == 1) actual=\(loadResponseKind(envelope.body))\n".utf8
                ))
                throw LoadError.unexpectedResponse
            }
            switch response.selectedFrameCompression {
            case .unspecified:
                negotiatedFrameCompression = nil
            case .zlib:
                negotiatedFrameCompression = .zlib
            case .UNRECOGNIZED:
                throw LoadError.unexpectedResponse
            }
            stage = .awaitingAuthentication
            var authenticate = IMV2Envelope()
            authenticate.requestID = 2
            authenticate.protocolVersion = IMV2ProtocolVersion.current
            authenticate.authenticate = .init()
            authenticate.authenticate.accessToken = credential.accessToken
            authenticate.authenticate.deviceID = credential.deviceID
            try write(authenticate, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)

        case .awaitingAuthentication:
            guard frame.requestID == 2 else {
                FileHandle.standardError.write(Data(
                    "protocol mismatch expected=authenticated request_match=false actual=\(loadResponseKind(envelope.body))\n".utf8
                ))
                throw LoadError.unexpectedResponse
            }
            guard case .authenticated(let response)? = envelope.body else {
                if case .error(let error)? = envelope.body {
                    FileHandle.standardError.write(Data(
                        "authentication rejected code=\(error.code) retryable=\(error.retryable)\n".utf8
                    ))
                } else {
                    FileHandle.standardError.write(Data(
                        "protocol mismatch expected=authenticated request_match=true actual=\(loadResponseKind(envelope.body))\n".utf8
                    ))
                }
                throw LoadError.unexpectedResponse
            }
            guard response.deviceID == credential.deviceID else {
                FileHandle.standardError.write(Data(
                    "authentication response device mismatch\n".utf8
                ))
                throw LoadError.unexpectedResponse
            }
            let expectedCompression: IMV2FrameCompression = negotiatedFrameCompression == .zlib ? .zlib : .unspecified
            guard response.selectedFrameCompression == expectedCompression else {
                throw LoadError.unexpectedResponse
            }
            stage = .authenticated
            authenticationCompleted = true
            registered = true
            statistics.recordAuthenticated(milliseconds: (NIODeadline.now() - started).millisecondsDouble)
            authenticatedPromise.succeed(())
            scheduleHeartbeat(context: context)

        case .authenticated:
            guard let pending = pendingRequests.removeValue(forKey: frame.requestID) else { return }
            if case .error(let error)? = envelope.body {
                try handleRejected(
                    pending,
                    requestID: frame.requestID,
                    code: error.code,
                    retryable: error.retryable,
                    context: context
                )
                return
            }
            switch pending {
            case .heartbeat(let sent):
                heartbeatRequestID = nil
                guard case .heartbeatAck? = envelope.body else { throw LoadError.unexpectedResponse }
                statistics.recordHeartbeatAcknowledged(milliseconds: (NIODeadline.now() - sent).millisecondsDouble)

            case .directRoom(let targetUserID, _, _, _):
                guard case .directRoomOpened(let response)? = envelope.body,
                      response.targetUserID == targetUserID,
                      !response.roomID.isEmpty
                else { throw LoadError.unexpectedResponse }
                if !directRoomIDs.contains(response.roomID) { directRoomIDs.append(response.roomID) }
                statistics.recordDirectRoomOpened()
                if directRoomIDs.count == targetUserIDs.count {
                    try initializeRoomLogCursorThenScheduleMessages(context: context)
                }

            case .message(let sent, let roomID):
                messageRequestIDs.remove(frame.requestID)
                guard case .messageAccepted(let response)? = envelope.body else {
                    FileHandle.standardError.write(Data(
                        "protocol mismatch expected=message_accepted actual=\(loadResponseKind(envelope.body))\n".utf8
                    ))
                    throw LoadError.unexpectedResponse
                }
                guard response.roomID == roomID, response.roomSequence > 0 else {
                    FileHandle.standardError.write(Data(
                        "protocol mismatch expected=message_accepted room_match=\(response.roomID == roomID) sequence_positive=\(response.roomSequence > 0)\n".utf8
                    ))
                    throw LoadError.unexpectedResponse
                }
                statistics.recordMessageAcknowledged(milliseconds: (NIODeadline.now() - sent).millisecondsDouble)
                if roomLogReads {
                    switch roomLogReadTrigger {
                    case .availabilityHint:
                        // Match the production hybrid-group client: the send
                        // acknowledgement completes the command outbox, but
                        // only an ordered live batch or a durable recovery
                        // page may advance the room-log cursor. In a hot room,
                        // treating the sender's sparse acknowledgements as a
                        // cursor creates a false gap for messages sent by
                        // every other member and amplifies recovery reads.
                        break
                    case .messageAcknowledgement:
                        try sendRoomEventPullIfNeeded(roomID: roomID, context: context)
                    }
                }
                try drainQueuedScenarioMessages(context: context)

            case .readReceipt(let sent, let roomID, let requestedSequence):
                readReceiptInFlightRooms.remove(roomID)
                guard case .readReceiptRecorded(let response)? = envelope.body,
                      response.roomID == roomID,
                      UUID(uuidString: response.userID)
                        == UUID(uuidString: credential.userID),
                      response.readThroughRoomSequence >= requestedSequence
                else { throw LoadError.unexpectedResponse }
                readReceiptAcknowledgedSequences[roomID] = max(
                    readReceiptAcknowledgedSequences[roomID, default: 0],
                    response.readThroughRoomSequence
                )
                statistics.recordReadReceiptAcknowledged(
                    milliseconds: (NIODeadline.now() - sent).millisecondsDouble
                )
                if let pendingSequence = readReceiptPendingSequences.removeValue(
                    forKey: roomID
                ), pendingSequence > response.readThroughRoomSequence {
                    try sendReadReceipt(
                        roomID: roomID,
                        roomSequence: pendingSequence,
                        context: context
                    )
                }

            case .recovery(let kind, let sent, let roomIDs):
                guard recoveryInFlightRequestID == frame.requestID else {
                    throw LoadError.unexpectedResponse
                }
                recoveryDeadlineTask?.cancel()
                recoveryDeadlineTask = nil
                recoveryInFlightRequestID = nil
                let counts = try validateRecoveryResponse(kind: kind, roomIDs: roomIDs,
                                                          body: envelope.body)
                statistics.recordRecoveryCompleted(kind,
                    milliseconds: (NIODeadline.now() - sent).millisecondsDouble,
                    successful: counts.successful, unavailable: counts.unavailable,
                    retry: counts.retry)

            case .syncPull(let sent):
                guard case .syncBatch(let batch)? = envelope.body else {
                    if case .resetRequired? = envelope.body {
                        throw LoadError.unexpectedSyncResponse("reset_required")
                    }
                    throw LoadError.unexpectedSyncResponse("non_sync_batch")
                }
                guard batch.generation > 0 else {
                    throw LoadError.unexpectedSyncResponse("zero_generation")
                }
                guard !batch.nextSyncToken.isEmpty else {
                    throw LoadError.unexpectedSyncResponse("missing_next_token")
                }
                guard !batch.syncReceipt.isEmpty else {
                    throw LoadError.unexpectedSyncResponse("missing_receipt")
                }
                nextSyncToken = batch.nextSyncToken
                statistics.recordSyncBatch(
                    milliseconds: (NIODeadline.now() - sent).millisecondsDouble,
                    records: batch.records.count
                )
                guard let highestSequence = batch.records.last?.userSyncSequence else {
                    syncInFlight = false
                    if batch.hasMore_p || syncRequested { try startSyncIfNeeded(context: context) }
                    return
                }
                try sendSyncAck(
                    generation: batch.generation,
                    highestSequence: highestSequence,
                    receipt: batch.syncReceipt,
                    hasMore: batch.hasMore_p,
                    context: context
                )

            case .roomEventPull(let sent, let roomID, let requestedAfterRoomSequence):
                roomEventPullRooms.remove(roomID)
                roomEventPullRetryCounts.removeValue(forKey: roomID)
                guard case .groupEventPage(let page)? = envelope.body,
                      page.roomID == roomID,
                      page.nextRoomSequence >= requestedAfterRoomSequence,
                      page.events.count <= 100,
                      page.events.first.map({ $0.roomSequence > requestedAfterRoomSequence }) ?? true,
                      zip(page.events, page.events.dropFirst()).allSatisfy({ $0.roomSequence < $1.roomSequence }),
                      (page.events.last?.roomSequence ?? requestedAfterRoomSequence) == page.nextRoomSequence
                else { throw LoadError.unexpectedResponse }
                let currentCursor = roomEventCursors[roomID, default: 0]
                if page.nextRoomSequence <= currentCursor {
                    statistics.recordRoomEventStalePageReceived()
                } else {
                    roomEventCursors[roomID] = page.nextRoomSequence
                }
                statistics.recordRoomEventPage(
                    milliseconds: (NIODeadline.now() - sent).millisecondsDouble,
                    records: page.events.count
                )
                let announcedHighWatermark = roomEventAnnouncedHighWatermarks[roomID, default: 0]
                if page.hasMore_p || roomEventCursors[roomID, default: 0] < announcedHighWatermark {
                    try sendRoomEventPullIfNeeded(roomID: roomID, context: context)
                }

            case .roomEventSubscribe(let roomID):
                guard case .groupEventSubscribed(let subscription)? = envelope.body else {
                    FileHandle.standardError.write(Data(
                        "protocol mismatch expected=group_event_subscribed actual=\(loadResponseKind(envelope.body))\n".utf8
                    ))
                    throw LoadError.unexpectedResponse
                }
                guard subscription.roomID == roomID,
                      roomEventCursorSubscriptionInFlightRoom == roomID
                else {
                    FileHandle.standardError.write(Data(
                        "protocol mismatch expected=group_event_subscribed room_match=\(subscription.roomID == roomID) pending_match=\(roomEventCursorSubscriptionInFlightRoom == roomID)\n".utf8
                    ))
                    throw LoadError.unexpectedResponse
                }
                activeRoomLogRoomID = roomID
                if roomLogInitialCursor == .tail {
                    roomEventCursors[roomID] = subscription.highWatermark
                }
                roomEventAnnouncedHighWatermarks[roomID] = subscription.highWatermark
                roomEventCursorSubscriptionInFlightRoom = nil
                roomEventCursorSubscriptionRetryCounts.removeValue(forKey: roomID)
                if roomLogInitialCursor == .zero {
                    try sendRoomEventPullIfNeeded(roomID: roomID, context: context)
                }
                try sendNextRoomEventCursorSubscriptionOrScheduleMessages(context: context)

            case .syncAck(let hasMore):
                guard case .acknowledged? = envelope.body else { throw LoadError.unexpectedResponse }
                statistics.recordSyncAcknowledged()
                syncInFlight = false
                if hasMore || syncRequested { try startSyncIfNeeded(context: context) }
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is StartWorkloadEvent:
            guard case .authenticated = stage, !workloadStarted, context.channel.isActive else { return }
            workloadStarted = true
            do {
                if !directRoomIDs.isEmpty {
                    guard directRoomIDs.count == targetUserIDs.count,
                          directRoomIDs.allSatisfy({ !$0.isEmpty }),
                          Set(directRoomIDs).count == directRoomIDs.count
                    else { throw LoadError.invalidCredentialFile }
                    for _ in directRoomIDs { statistics.recordDirectRoomOpened() }
                    try initializeRoomLogCursorThenScheduleMessages(context: context)
                    return
                }
                for targetUserID in targetUserIDs {
                    try sendOpenDirectRoom(targetUserID: targetUserID, context: context)
                }
            } catch {
                failAuthentication(error, context: context)
            }
        case is ScenarioSendEvent:
            guard case .authenticated = stage, workloadStarted, context.channel.isActive else { return }
            statistics.recordScenarioMessageScheduled()
            do {
                switch scenarioSendDispatch {
                case .strictPerDevice:
                    try sendMessage(context: context)
                case .boundedClientQueue:
                    try enqueueScenarioMessage(context: context)
                }
            }
            catch {
                statistics.recordWorkloadFailure(kind: "message", code: "CLIENT_WRITE_FAILURE")
                context.close(promise: nil)
            }
        case is ScenarioRoomLogReadEvent:
            guard case .authenticated = stage, workloadStarted, context.channel.isActive,
                  !directRoomIDs.isEmpty
            else { return }
            let roomID = directRoomIDs[nextRoomIndex % directRoomIDs.count]
            nextRoomIndex += 1
            do { try sendRoomEventPullIfNeeded(roomID: roomID, context: context) }
            catch {
                statistics.recordWorkloadFailure(kind: "room_event", code: "CLIENT_WRITE_FAILURE")
                context.close(promise: nil)
            }
        case is ScenarioSyncPullEvent:
            guard case .authenticated = stage, workloadStarted, context.channel.isActive else { return }
            syncRequested = true
            do { try startSyncIfNeeded(context: context) }
            catch {
                statistics.recordWorkloadFailure(kind: "sync", code: "CLIENT_WRITE_FAILURE")
                context.close(promise: nil)
            }
        case is ScenarioReadReceiptEvent:
            guard case .authenticated = stage, workloadStarted,
                  context.channel.isActive, !directRoomIDs.isEmpty
            else { return }
            statistics.recordReadReceiptScheduled()
            let roomID = activeRoomLogRoomID
                ?? directRoomIDs[nextRoomIndex % directRoomIDs.count]
            nextRoomIndex += 1
            do { try scheduleReadReceipt(roomID: roomID, context: context) }
            catch {
                statistics.recordWorkloadFailure(
                    kind: "read_receipt", code: "CLIENT_WRITE_FAILURE"
                )
                context.close(promise: nil)
            }
        case is ScenarioRoomSyncStateBatchEvent:
            guard case .authenticated = stage, workloadStarted, context.channel.isActive else { return }
            statistics.recordRecoveryScheduled(.roomSyncState)
            do { try sendRecoveryBatch(.roomSyncState, context: context) }
            catch {
                statistics.recordWorkloadFailure(kind: "room_sync_state_batch", code: "CLIENT_WRITE_FAILURE")
                context.close(promise: nil)
            }
        case is ScenarioRoomLatestVisibleBatchEvent:
            guard case .authenticated = stage, workloadStarted, context.channel.isActive else { return }
            statistics.recordRecoveryScheduled(.roomLatestVisible)
            do { try sendRecoveryBatch(.roomLatestVisible, context: context) }
            catch {
                statistics.recordWorkloadFailure(kind: "room_latest_visible_batch", code: "CLIENT_WRITE_FAILURE")
                context.close(promise: nil)
            }
        case let probe as RoomCursorProbe:
            probe.completion.succeed(directRoomIDs.map { roomID in
                RoomCursorSnapshot(connectionIndex: connectionIndex, roomID: roomID,
                                   appliedRoomSequence: roomEventCursors[roomID, default: 0])
            })
        case let probe as ScenarioDrainProbe:
            probe.completion.succeed(.init(
                queued: queuedScenarioMessages,
                inFlight: messageRequestIDs.count + readReceiptInFlightRooms.count
                    + (recoveryInFlightRequestID == nil ? 0 : 1)
            ))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func scheduleHeartbeat(context: ChannelHandlerContext) {
        let spread = max(1, heartbeatSeconds - 5)
        let initialSeconds = 5 + connectionIndex % spread
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        heartbeatTask = context.eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(Int64(initialSeconds)),
            delay: .seconds(Int64(heartbeatSeconds))
        ) { _ in
            let handler = handler.value
            let context = boundContext.value
            guard case .authenticated = handler.stage, context.channel.isActive else { return }
            do { try handler.sendHeartbeat(context: context) }
            catch { handler.failAuthentication(error, context: context) }
        }
    }

    private func sendHeartbeat(context: ChannelHandlerContext) throws {
        if let heartbeatRequestID {
            pendingRequests.removeValue(forKey: heartbeatRequestID)
            statistics.recordHeartbeatMissed()
        }
        let requestID = takeRequestID()
        var heartbeat = IMV2Envelope()
        heartbeat.requestID = requestID
        heartbeat.protocolVersion = IMV2ProtocolVersion.current
        heartbeat.heartbeat = .init()
        heartbeat.heartbeat.clientTimeMs = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        heartbeatRequestID = requestID
        pendingRequests[requestID] = .heartbeat(sent: .now())
        statistics.recordHeartbeatSent()
        try write(heartbeat, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    private func sendOpenDirectRoom(
        targetUserID: String,
        operationID: String = UUID().uuidString,
        retryCount: Int = 0,
        context: ChannelHandlerContext
    ) throws {
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.openDirectRoom = .init()
        request.openDirectRoom.operationID = operationID
        request.openDirectRoom.targetUserID = targetUserID
        pendingRequests[requestID] = .directRoom(
            targetUserID: targetUserID,
            operationID: operationID,
            retryCount: retryCount,
            sent: .now()
        )
        statistics.recordDirectRoomAttempted()
        try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    /// 只要保留同一个操作 ID，开单聊房间就是幂等的。
    ///
    /// 只重试服务端显式标记为可重试的响应，并把预算保持有界，
    /// 使真正的故障对负载运行仍然可见，而不会变成一个无界的客户端队列。
    private static let maximumDirectRoomRetries = 6

    private func scheduleDirectRoomRetry(
        targetUserID: String,
        operationID: String,
        retryCount: Int,
        context: ChannelHandlerContext
    ) {
        let exponent = min(retryCount - 1, 5)
        let delay = Int64(50 * (1 << exponent))
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        context.eventLoop.scheduleTask(in: .milliseconds(delay)) {
            let handler = handler.value
            let context = boundContext.value
            guard case .authenticated = handler.stage,
                  handler.workloadStarted,
                  context.channel.isActive
            else { return }
            do {
                try handler.sendOpenDirectRoom(
                    targetUserID: targetUserID,
                    operationID: operationID,
                    retryCount: retryCount,
                    context: context
                )
            } catch {
                handler.statistics.recordWorkloadFailure(
                    kind: "direct_room",
                    code: "CLIENT_WRITE_FAILURE"
                )
                context.close(promise: nil)
            }
        }
    }

    private func scheduleMessages(context: ChannelHandlerContext) {
        guard messageTask == nil else { return }
        guard let interval = messageIntervalMilliseconds else { return }
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        messageTask = context.eventLoop.scheduleRepeatedTask(
            initialDelay: .milliseconds(messageInitialDelayMilliseconds),
            delay: .milliseconds(interval)
        ) { _ in
            let handler = handler.value
            let context = boundContext.value
            guard case .authenticated = handler.stage, context.channel.isActive else { return }
            do { try handler.sendMessage(context: context) }
            catch {
                handler.statistics.recordWorkloadFailure(
                    kind: "message",
                    code: "CLIENT_WRITE_FAILURE"
                )
                context.close(promise: nil)
            }
        }
    }

    /// 在负载开始之前建立活跃房间订阅。
    ///
    /// 订阅是一次已授权的持久状态读取，而不是本地猜测：
    /// 在其返回水位之后提交的消息，仍可通过常规游标拉取看到。
    ///
    /// - Parameter context: 目标通道上下文。
    /// - Throws: 写入失败时抛出。
    private func initializeRoomLogCursorThenScheduleMessages(
        context: ChannelHandlerContext
    ) throws {
        guard !roomEventCursorInitializationStarted else { return }
        roomEventCursorInitializationStarted = true
        guard roomLogReads else {
            scheduleMessages(context: context)
            return
        }
        switch roomLogReadTrigger {
        case .messageAcknowledgement:
            // Preserve the original synthetic stress mode, which exercises
            // every opened room independently.
            roomEventCursorSubscriptionPendingRooms = roomLogInitialCursor == .tail
                ? directRoomIDs.sorted()
                : []
        case .availabilityHint:
            // The production client has one foreground conversation listener
            // per connection.  Selecting the opened room in request order
            // gives the paired topology a deterministic shared active room.
            roomEventCursorSubscriptionPendingRooms = directRoomIDs.prefix(1).map { $0 }
        }
        guard !roomEventCursorSubscriptionPendingRooms.isEmpty else {
            scheduleMessages(context: context)
            return
        }
        try sendNextRoomEventCursorSubscriptionOrScheduleMessages(context: context)
    }

    /// 订阅按连接串行执行。
    ///
    /// 这既让恢复保持有界，又使可用性提示模式能忠实模拟单个前台房间，
    /// 同时保留旧版的「全部房间」压测模式。
    ///
    /// - Parameter context: 目标通道上下文。
    /// - Throws: 状态或写入失败时抛出。
    private func sendNextRoomEventCursorSubscriptionOrScheduleMessages(
        context: ChannelHandlerContext
    ) throws {
        guard roomEventCursorSubscriptionInFlightRoom == nil else {
            throw LoadError.unexpectedResponse
        }
        guard !roomEventCursorSubscriptionPendingRooms.isEmpty else {
            statistics.recordRoomLogTailReady()
            scheduleMessages(context: context)
            return
        }
        let roomID = roomEventCursorSubscriptionPendingRooms.removeFirst()
        roomEventCursorSubscriptionInFlightRoom = roomID
        try sendRoomEventSubscribe(roomID: roomID, context: context)
    }

    private func sendRoomEventSubscribe(
        roomID: String,
        context: ChannelHandlerContext
    ) throws {
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.groupEventSubscribe = .init()
        request.groupEventSubscribe.roomID = roomID
        pendingRequests[requestID] = .roomEventSubscribe(roomID: roomID)
        try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    /// 订阅是一道只读游标围栏，而 `SERVER_BUSY` 是显式的可重试响应。
    ///
    /// 此处只保留一个很小的每房间重试预算，
    /// 使尾部预热表现得像真实客户端，同时不会把不可用的 Gateway 变成无界的隐藏队列。
    private static let maximumRoomEventCursorSubscriptionRetries = 5

    private func scheduleRoomEventCursorSubscriptionRetry(
        roomID: String,
        retryCount: Int,
        context: ChannelHandlerContext
    ) {
        let exponent = min(retryCount - 1, 4)
        let delay = Int64(50 * (1 << exponent))
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        context.eventLoop.scheduleTask(in: .milliseconds(delay)) {
            let handler = handler.value
            let context = boundContext.value
            guard case .authenticated = handler.stage,
                  context.channel.isActive,
                  handler.roomEventCursorSubscriptionInFlightRoom == roomID
            else { return }
            do {
                try handler.sendRoomEventSubscribe(roomID: roomID, context: context)
            } catch {
                handler.statistics.recordWorkloadFailure(
                    kind: "room_event_subscribe",
                    code: "CLIENT_WRITE_FAILURE"
                )
                context.close(promise: nil)
            }
        }
    }

    private func sendMessage(context: ChannelHandlerContext) throws {
        guard !directRoomIDs.isEmpty else { return }
        guard messageRequestIDs.count < maximumInFlightMessagesPerConnection else {
            statistics.recordMessageSkipped()
            return
        }
        let directRoomID: String
        if roomLogReadTrigger == .availabilityHint, let activeRoomLogRoomID {
            directRoomID = activeRoomLogRoomID
        } else {
            directRoomID = directRoomIDs[nextRoomIndex % directRoomIDs.count]
            nextRoomIndex += 1
        }
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.sendMessage = .init()
        request.sendMessage.roomID = directRoomID
        request.sendMessage.clientMessageID = UUID().uuidString
        request.sendMessage.content = .init()
        request.sendMessage.content.text = messageText
        messageRequestIDs.insert(requestID)
        pendingRequests[requestID] = .message(sent: .now(), roomID: directRoomID)
        statistics.recordMessageSent()
        try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    /// 仅当每设备队列存在硬性上限时才保留场景选中的动作。
    ///
    /// 该队列刻意只属于该模拟设备本地：
    /// 这既保留了加权用户行为，又让饱和运行能把服务端积压与先前的立即丢弃模型区分开。
    ///
    /// - Parameter context: 目标通道上下文。
    /// - Throws: 发送或写入失败时抛出。
    private func enqueueScenarioMessage(context: ChannelHandlerContext) throws {
        guard !directRoomIDs.isEmpty else { return }
        if messageRequestIDs.count < maximumInFlightMessagesPerConnection {
            try sendMessage(context: context)
            return
        }
        guard queuedScenarioMessages < maximumQueuedScenarioMessages else {
            statistics.recordScenarioMessageQueueOverflow()
            return
        }
        queuedScenarioMessages += 1
        statistics.recordScenarioMessageDeferred()
    }

    /// ACK 与拒绝都会释放一个设备的在途槽位。
    ///
    /// 最多排空所通告的窗口，绝不通过事件循环递归调用，
    /// 并让 `messagesSent` 始终表示真正写入套接字的数量。
    ///
    /// - Parameter context: 目标通道上下文。
    /// - Throws: 发送或写入失败时抛出。
    private func drainQueuedScenarioMessages(context: ChannelHandlerContext) throws {
        while queuedScenarioMessages > 0,
              messageRequestIDs.count < maximumInFlightMessagesPerConnection,
              context.channel.isActive {
            queuedScenarioMessages -= 1
            statistics.recordScenarioMessageDequeued()
            try sendMessage(context: context)
        }
    }

    /// 真实客户端会把阅读状态推进到其最近应用的房间日志游标。
    ///
    /// 当一条回执仍在途时，多次 UI 更新会合并为一个更高的水位线；
    /// 生成器会如实报告这种合并，而不会为每个渲染出的事件都伪造一次冗余数据库操作。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - context: 目标通道上下文。
    /// - Throws: 发送或写入失败时抛出。
    private func scheduleReadReceipt(
        roomID: String,
        context: ChannelHandlerContext
    ) throws {
        let roomSequence = roomEventCursors[roomID, default: 0]
        guard roomSequence > readReceiptAcknowledgedSequences[roomID, default: 0]
        else {
            statistics.recordReadReceiptCoalesced()
            return
        }
        guard !readReceiptInFlightRooms.contains(roomID) else {
            readReceiptPendingSequences[roomID] = max(
                readReceiptPendingSequences[roomID, default: 0],
                roomSequence
            )
            statistics.recordReadReceiptCoalesced()
            return
        }
        try sendReadReceipt(
            roomID: roomID,
            roomSequence: roomSequence,
            context: context
        )
    }

    private func sendReadReceipt(
        roomID: String,
        roomSequence: UInt64,
        context: ChannelHandlerContext
    ) throws {
        guard readReceiptInFlightRooms.insert(roomID).inserted else {
            throw LoadError.unexpectedResponse
        }
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.recordReadReceipt = .init()
        request.recordReadReceipt.roomID = roomID
        request.recordReadReceipt.operationID = UUID().uuidString
        request.recordReadReceipt.readThroughRoomSequence = roomSequence
        pendingRequests[requestID] = .readReceipt(
            sent: .now(), roomID: roomID, roomSequence: roomSequence
        )
        statistics.recordReadReceiptSent()
        do {
            try write(
                request,
                frameVersion: UInt8(IMV2ProtocolVersion.current),
                context: context
            )
        } catch {
            pendingRequests.removeValue(forKey: requestID)
            readReceiptInFlightRooms.remove(roomID)
            throw error
        }
    }

    private func startSyncIfNeeded(context: ChannelHandlerContext) throws {
        guard syncReads, !syncInFlight else { return }
        syncInFlight = true
        syncRequested = false
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.syncPull = .init()
        request.syncPull.syncToken = nextSyncToken
        request.syncPull.maxRecords = 100
        pendingRequests[requestID] = .syncPull(sent: .now())
        statistics.recordSyncPullSent()
        try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    /// 在需要时安排房间事件恢复拉取。
    ///
    /// 这里模拟的是持久单聊房间的恢复契约：发送方或接收方只会收到一个水位/ACK，
    /// 然后自行推进其房间游标。每个房间只保留一次在途读取以合并突发；
    /// `has_more` 响应会被立即排空，使恢复不会在整页之后停滞，
    /// 而后续消息再安排下一次有界拉取。
    ///
    /// 持久高水位唤醒可能跑在完整前台批次之前，因为它们可能由独立的 Gateway 工作者发布。
    /// 因此让恢复保持有界，但给无损且保序的快速路径一个简短、可取消的追赶窗口，
    /// 以避免创建冗余拉取。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - context: 目标通道上下文。
    /// - Throws: 写入失败时抛出。
    private func scheduleRoomEventRecoveryIfNeeded(
        roomID: String,
        context: ChannelHandlerContext
    ) throws {
        let cursor = roomEventCursors[roomID, default: 0]
        guard roomEventAnnouncedHighWatermarks[roomID, default: 0] > cursor else {
            cancelRoomEventRecoveryGraceIfCaughtUp(roomID: roomID)
            return
        }
        guard !roomEventPullRooms.contains(roomID),
              roomEventRecoveryGraceTasks[roomID] == nil
        else { return }
        guard roomLogRecoveryGraceMilliseconds > 0 else {
            try sendRoomEventPullIfNeeded(roomID: roomID, context: context)
            return
        }

        statistics.recordRoomEventRecoveryGraceScheduled()
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        roomEventRecoveryGraceTasks[roomID] = context.eventLoop.scheduleTask(
            in: .milliseconds(Int64(roomLogRecoveryGraceMilliseconds))
        ) {
            let handler = handler.value
            let context = boundContext.value
            handler.roomEventRecoveryGraceTasks.removeValue(forKey: roomID)
            guard case .authenticated = handler.stage,
                  context.channel.isActive
            else { return }
            guard handler.roomEventAnnouncedHighWatermarks[roomID, default: 0]
                    > handler.roomEventCursors[roomID, default: 0]
            else {
                handler.statistics.recordRoomEventRecoveryGraceAvoided()
                return
            }
            handler.statistics.recordRoomEventRecoveryGraceExpired()
            do {
                try handler.sendRoomEventPullIfNeeded(
                    roomID: roomID,
                    context: context
                )
            } catch {
                handler.statistics.recordWorkloadFailure(
                    kind: "room_event",
                    code: "CLIENT_WRITE_FAILURE"
                )
                context.close(promise: nil)
            }
        }
    }

    private func cancelRoomEventRecoveryGraceIfCaughtUp(roomID: String) {
        guard roomEventAnnouncedHighWatermarks[roomID, default: 0]
                <= roomEventCursors[roomID, default: 0],
              let task = roomEventRecoveryGraceTasks.removeValue(forKey: roomID)
        else { return }
        task.cancel()
        statistics.recordRoomEventRecoveryGraceAvoided()
    }

    private func sendRoomEventPullIfNeeded(roomID: String, context: ChannelHandlerContext) throws {
        roomEventRecoveryGraceTasks.removeValue(forKey: roomID)?.cancel()
        guard roomEventPullRooms.insert(roomID).inserted else { return }
        try sendReservedRoomEventPull(roomID: roomID, context: context)
    }

    /// 发送一次拉取，其每房间在途/重试槽位已经预留。
    ///
    /// 在可重试的过载响应之间保持该槽位至关重要：
    /// 这样后续可用性提示只会抬高已通告的高水位，而不会制造一场同步重试风暴。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - context: 目标通道上下文。
    /// - Throws: 写入失败时抛出。
    private func sendReservedRoomEventPull(
        roomID: String,
        context: ChannelHandlerContext
    ) throws {
        let afterRoomSequence = roomEventCursors[roomID, default: 0]
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.groupEventPull = .init()
        request.groupEventPull.roomID = roomID
        request.groupEventPull.afterRoomSequence = afterRoomSequence
        request.groupEventPull.pageSize = 100
        pendingRequests[requestID] = .roomEventPull(
            sent: .now(),
            roomID: roomID,
            afterRoomSequence: afterRoomSequence
        )
        statistics.recordRoomEventPullSent()
        try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    private func scheduleRoomEventPullRetry(
        roomID: String,
        context: ChannelHandlerContext
    ) {
        guard roomEventPullRetryTasks[roomID] == nil else { return }
        let retryCount = roomEventPullRetryCounts[roomID, default: 0] + 1
        roomEventPullRetryCounts[roomID] = retryCount
        let exponent = min(retryCount - 1, 5)
        let baseDelay = 50 * (1 << exponent)
        let jitter = (connectionIndex &* 17 &+ retryCount &* 31) % 50
        let delay = Int64(min(2_000, baseDelay + jitter))
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        roomEventPullRetryTasks[roomID] = context.eventLoop.scheduleTask(
            in: .milliseconds(delay)
        ) {
            let handler = handler.value
            let context = boundContext.value
            handler.roomEventPullRetryTasks.removeValue(forKey: roomID)
            guard case .authenticated = handler.stage,
                  context.channel.isActive,
                  handler.roomEventPullRooms.contains(roomID)
            else { return }
            do {
                try handler.sendReservedRoomEventPull(roomID: roomID, context: context)
            } catch {
                handler.roomEventPullRooms.remove(roomID)
                handler.statistics.recordWorkloadFailure(
                    kind: "room_event",
                    code: "CLIENT_WRITE_FAILURE"
                )
                context.close(promise: nil)
            }
        }
    }

    private func sendRecoveryBatch(_ kind: RecoveryBatchKind,
                                   context: ChannelHandlerContext) throws {
        // One combined read batch per connection. Keep its complete response
        // under the native frame bound even when every room has a preview.
        guard recoveryInFlightRequestID == nil, !directRoomIDs.isEmpty else {
            statistics.recordRecoverySkipped(kind)
            return
        }
        let roomIDs = Array(directRoomIDs.prefix(32))
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        switch kind {
        case .roomSyncState:
            request.roomSyncStateBatch = .init()
            request.roomSyncStateBatch.roomIds = roomIDs
        case .roomLatestVisible:
            request.roomLatestVisibleBatch = .init()
            request.roomLatestVisibleBatch.roomIds = roomIDs
        }
        pendingRequests[requestID] = .recovery(kind: kind, sent: .now(), roomIDs: roomIDs)
        recoveryInFlightRequestID = requestID
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        recoveryDeadlineTask = context.eventLoop.scheduleTask(
            in: .seconds(Int64(recoveryBatchTimeoutSeconds))
        ) {
            let handler = handler.value
            let context = boundContext.value
            guard handler.recoveryInFlightRequestID == requestID,
                  case .recovery(let pendingKind, _, _)? = handler.pendingRequests.removeValue(forKey: requestID)
            else { return }
            handler.recoveryInFlightRequestID = nil
            handler.recoveryDeadlineTask = nil
            handler.statistics.recordRecoveryTimedOut(pendingKind)
            context.close(promise: nil)
        }
        do {
            try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
            statistics.recordRecoverySent(kind)
        } catch {
            pendingRequests.removeValue(forKey: requestID)
            recoveryDeadlineTask?.cancel()
            recoveryDeadlineTask = nil
            recoveryInFlightRequestID = nil
            throw error
        }
    }

    private func validateRecoveryResponse(kind: RecoveryBatchKind, roomIDs: [String],
                                          body: IMV2Envelope.OneOf_Body?) throws
        -> (successful: Int, unavailable: Int, retry: Int) {
        let expected = Set(roomIDs.compactMap(UUID.init(uuidString:)))
        guard expected.count == roomIDs.count else { throw LoadError.unexpectedResponse }
        var seen: Set<UUID> = []
        var successful = 0
        var unavailable = 0
        var retry = 0
        switch kind {
        case .roomSyncState:
            guard case .roomSyncStateBatchResult(let response)? = body,
                  response.rooms.count == roomIDs.count else { throw LoadError.unexpectedResponse }
            for item in response.rooms {
                guard let room = UUID(uuidString: item.roomID), expected.contains(room),
                      seen.insert(room).inserted else { throw LoadError.unexpectedResponse }
                switch item.result {
                case .state(let state)?:
                    guard UUID(uuidString: state.roomID) == room else {
                        throw LoadError.unexpectedResponse
                    }
                    successful += 1
                case .unavailable?: unavailable += 1
                case .retry(let value)?:
                    guard value.retryAfterSeconds > 0 else { throw LoadError.unexpectedResponse }
                    retry += 1
                case nil: throw LoadError.unexpectedResponse
                }
            }
        case .roomLatestVisible:
            guard case .roomLatestVisibleBatchResult(let response)? = body,
                  response.rooms.count == roomIDs.count else { throw LoadError.unexpectedResponse }
            for item in response.rooms {
                guard let room = UUID(uuidString: item.roomID), expected.contains(room),
                      seen.insert(room).inserted else { throw LoadError.unexpectedResponse }
                switch item.result {
                case .snapshot?:
                    successful += 1
                case .unavailable?: unavailable += 1
                case .retry(let value)?:
                    guard value.retryAfterSeconds > 0 else { throw LoadError.unexpectedResponse }
                    retry += 1
                case nil: throw LoadError.unexpectedResponse
                }
            }
        }
        guard seen == expected else { throw LoadError.unexpectedResponse }
        return (successful, unavailable, retry)
    }

    private func sendSyncAck(
        generation: UInt64,
        highestSequence: UInt64,
        receipt: String,
        hasMore: Bool,
        context: ChannelHandlerContext
    ) throws {
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.syncAck = .init()
        request.syncAck.generation = generation
        request.syncAck.highestContiguousSequence = highestSequence
        request.syncAck.syncReceipt = receipt
        pendingRequests[requestID] = .syncAck(hasMore: hasMore)
        try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    private func handleRejected(
        _ pending: PendingRequest,
        requestID: UInt64,
        code: String,
        retryable: Bool,
        context: ChannelHandlerContext
    ) throws {
        switch pending {
        case .heartbeat:
            heartbeatRequestID = nil
            statistics.recordHeartbeatMissed()
        case .message:
            messageRequestIDs.remove(requestID)
            statistics.recordWorkloadFailure(kind: "message", code: code, retryable: retryable)
            try drainQueuedScenarioMessages(context: context)
        case .syncPull, .syncAck:
            syncInFlight = false
            statistics.recordWorkloadFailure(kind: "sync", code: code, retryable: retryable)
        case .roomEventPull(_, let roomID, _):
            if retryable {
                statistics.recordRoomEventPullRetryableRejection()
                scheduleRoomEventPullRetry(roomID: roomID, context: context)
            } else {
                roomEventPullRooms.remove(roomID)
                roomEventPullRetryCounts.removeValue(forKey: roomID)
                statistics.recordWorkloadFailure(
                    kind: "room_event",
                    code: code,
                    retryable: false
                )
            }
        case .roomEventSubscribe(let roomID):
            guard roomEventCursorSubscriptionInFlightRoom == roomID else {
                throw LoadError.unexpectedResponse
            }
            let retryCount = roomEventCursorSubscriptionRetryCounts[roomID, default: 0]
            if retryable, retryCount < Self.maximumRoomEventCursorSubscriptionRetries {
                let nextRetryCount = retryCount + 1
                roomEventCursorSubscriptionRetryCounts[roomID] = nextRetryCount
                scheduleRoomEventCursorSubscriptionRetry(
                    roomID: roomID,
                    retryCount: nextRetryCount,
                    context: context
                )
                return
            }
            roomEventCursorSubscriptionInFlightRoom = nil
            statistics.recordWorkloadFailure(kind: "room_event_subscribe", code: code, retryable: retryable)
            // A tail cursor must come from the server. Do not start a
            // purported steady workload at cursor zero after its explicit
            // initialization barrier failed.
            throw LoadError.unexpectedResponse
        case .readReceipt(_, let roomID, _):
            readReceiptInFlightRooms.remove(roomID)
            readReceiptPendingSequences.removeValue(forKey: roomID)
            statistics.recordWorkloadFailure(
                kind: "read_receipt", code: code, retryable: retryable
            )
        case .recovery(let kind, _, _):
            guard recoveryInFlightRequestID == requestID else {
                throw LoadError.unexpectedResponse
            }
            recoveryDeadlineTask?.cancel()
            recoveryDeadlineTask = nil
            recoveryInFlightRequestID = nil
            statistics.recordRecoveryRejected(kind, code: code, retryable: retryable)
        case .directRoom(let targetUserID, let operationID, let retryCount, _):
            if retryable, retryCount < Self.maximumDirectRoomRetries {
                scheduleDirectRoomRetry(
                    targetUserID: targetUserID,
                    operationID: operationID,
                    retryCount: retryCount + 1,
                    context: context
                )
                return
            }
            statistics.recordWorkloadFailure(kind: "direct_room", code: code, retryable: retryable)
        }
    }

    private func takeRequestID() -> UInt64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func write(_ envelope: IMV2Envelope, frameVersion: UInt8, context: ChannelHandlerContext) throws {
        let frame = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: frameVersion)
        let bytes = try V2FrameCodec.encode(frame, limits: limits)
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    private func failAuthentication(_ error: Error, context: ChannelHandlerContext, close: Bool = true) {
        heartbeatTask?.cancel()
        messageTask?.cancel()
        recoveryDeadlineTask?.cancel()
        recoveryDeadlineTask = nil
        recoveryInFlightRequestID = nil
        if !authenticationCompleted {
            authenticationCompleted = true
            authenticatedPromise.fail(error)
        }
        if close { context.close(promise: nil) }
    }
}

private struct RecoveryBatchReport: Encodable {
    let scheduled: Int
    let sent: Int
    let completed: Int
    let skipped: Int
    let successfulRooms: Int
    let unavailableRooms: Int
    let retryRooms: Int
    let rejected: Int
    let timedOut: Int
    let latency: Percentiles

    init(start: RecoveryBatchStats, end: RecoveryBatchStats) {
        scheduled = end.scheduled - start.scheduled
        sent = end.sent - start.sent
        completed = end.completed - start.completed
        skipped = end.skipped - start.skipped
        successfulRooms = end.successfulRooms - start.successfulRooms
        unavailableRooms = end.unavailableRooms - start.unavailableRooms
        retryRooms = end.retryRooms - start.retryRooms
        rejected = end.rejected - start.rejected
        timedOut = end.timedOut - start.timedOut
        latency = end.latency.subtracting(start.latency).percentiles
    }
}

private struct LoadReport: Encodable {
    let revision: String
    let host: String
    let port: Int
    let requestedConnections: Int
    let rampPerSecond: Int
    let rampBatchSize: Int
    let workloadRampPerSecond: Int
    let holdSeconds: Int
    let eventLoops: Int
    let messagesPerSecond: Int
    let maximumInFlightMessagesPerConnection: Int
    let messageBytes: Int
    let targetsPerConnection: Int
    let targetOffset: Int
    let syncReads: Bool
    let roomLogReads: Bool
    let roomLogReadTrigger: String
    let roomLogRecoveryGraceMilliseconds: Int
    let recoveryBatchTimeoutSeconds: Int
    let peerTopology: String
    let startedAt: Date
    let endedAt: Date
    let attempted: Int
    let authenticated: Int
    let failed: Int
    let connectionFailuresByError: [String: Int]
    let peakActive: Int
    let disconnected: Int
    let plannedReconnects: Int
    let heartbeatSent: Int
    let heartbeatAcknowledged: Int
    let heartbeatMissed: Int
    let directRoomAttempted: Int
    let directRoomOpened: Int
    let roomLogTailReady: Int
    let workloadFailed: Int
    let workloadFailuresByKindAndCode: [String: Int]
    let messagesSent: Int
    let messagesAcknowledged: Int
    let messagesSkipped: Int
    let scenarioMessagesScheduled: Int
    let scenarioMessagesDeferred: Int
    let scenarioMessageQueueOverflowed: Int
    let scenarioMessageQueueAbandoned: Int
    let queuedScenarioMessagesAtEnd: Int
    let maximumQueuedScenarioMessages: Int
    let syncPullsSent: Int
    let syncBatchesReceived: Int
    let syncRecordsReceived: Int
    let syncAcknowledged: Int
    let roomEventPullsSent: Int
    let roomEventPullRetryableRejections: Int
    let roomEventPagesReceived: Int
    let roomEventRecordsReceived: Int
    let roomEventAvailabilityHintsReceived: Int
    let roomEventLivePayloadsApplied: Int
    let roomEventLiveGapFramesDetected: Int
    let roomEventLiveMissingSequences: UInt64
    let roomEventMetadataGapsObserved: Int
    let roomEventMetadataMissingSequences: UInt64
    let roomEventRecoveryGracesScheduled: Int
    let roomEventRecoveryGracesAvoided: Int
    let roomEventRecoveryGracesExpired: Int
    let roomEventLocalEchoesApplied: Int
    let roomEventLocalEchoGapsDetected: Int
    let roomEventStalePagesReceived: Int
    let readReceiptsScheduled: Int
    let readReceiptsSent: Int
    let readReceiptsAcknowledged: Int
    let readReceiptsCoalesced: Int
    let roomSyncStateBatch: RecoveryBatchReport
    let roomLatestVisibleBatch: RecoveryBatchReport
    let maximumRSSMegabytes: Double
    let authenticationLatency: Percentiles
    let heartbeatLatency: Percentiles
    let messageLatency: Percentiles
    let syncPullLatency: Percentiles
    let roomEventPullLatency: Percentiles
    let readReceiptLatency: Percentiles
    let eventLoopLag: LoadEventLoopLagReport
    let scenarioName: String?
    let scenarioRateScale: Double?
    let scenarioSchedulerTicksPerSecond: Int?
    let scenarioSendDispatch: String?
    let maximumQueuedScenarioMessagesPerConnection: Int?
    let scenarioPhases: [ScenarioPhaseReport]
    let scenarioDrain: ScenarioDrainReport?
    let roomCursorSnapshots: [RoomCursorSnapshot]
    let scenarioPostDrainHoldSeconds: Int?
    let terminalError: String?

    init(configuration: LoadConfiguration, startedAt: Date, endedAt: Date, state: LoadStatistics.State, eventLoopLag: V2RuntimeLatencyHistogramSnapshot, scenarioPhases: [ScenarioPhaseReport], scenarioDrain: ScenarioDrainReport?, terminalError: Error?, roomCursorSnapshots: [RoomCursorSnapshot]) {
        revision = configuration.revision
        host = configuration.host
        port = configuration.port
        requestedConnections = configuration.connections
        rampPerSecond = configuration.rampPerSecond
        rampBatchSize = configuration.rampBatchSize
        workloadRampPerSecond = configuration.workloadRampPerSecond
        holdSeconds = configuration.holdSeconds
        eventLoops = configuration.eventLoops
        messagesPerSecond = configuration.messagesPerSecond
        maximumInFlightMessagesPerConnection = configuration.maximumInFlightMessagesPerConnection
        messageBytes = configuration.messageBytes
        targetsPerConnection = configuration.targetsPerConnection
        targetOffset = configuration.targetOffset
        syncReads = configuration.syncReads
        roomLogReads = configuration.roomLogReads
        roomLogReadTrigger = configuration.roomLogReadTrigger.rawValue
        roomLogRecoveryGraceMilliseconds =
            configuration.roomLogRecoveryGraceMilliseconds
        recoveryBatchTimeoutSeconds = configuration.recoveryBatchTimeoutSeconds
        peerTopology = configuration.peerTopology.rawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        attempted = state.attempted
        authenticated = state.authenticated
        failed = state.failed
        connectionFailuresByError = state.connectionFailuresByError
        peakActive = state.peakActive
        disconnected = state.disconnected
        plannedReconnects = state.plannedReconnects
        heartbeatSent = state.heartbeatSent
        heartbeatAcknowledged = state.heartbeatAcknowledged
        heartbeatMissed = state.heartbeatMissed
        directRoomAttempted = state.directRoomAttempted
        directRoomOpened = state.directRoomOpened
        roomLogTailReady = state.roomLogTailReady
        workloadFailed = state.workloadFailed
        workloadFailuresByKindAndCode = state.workloadFailuresByKindAndCode
        messagesSent = state.messagesSent
        messagesAcknowledged = state.messagesAcknowledged
        messagesSkipped = state.messagesSkipped
        scenarioMessagesScheduled = state.scenarioMessagesScheduled
        scenarioMessagesDeferred = state.scenarioMessagesDeferred
        scenarioMessageQueueOverflowed = state.scenarioMessageQueueOverflowed
        scenarioMessageQueueAbandoned = state.scenarioMessageQueueAbandoned
        queuedScenarioMessagesAtEnd = state.queuedScenarioMessages
        maximumQueuedScenarioMessages = state.maximumQueuedScenarioMessages
        syncPullsSent = state.syncPullsSent
        syncBatchesReceived = state.syncBatchesReceived
        syncRecordsReceived = state.syncRecordsReceived
        syncAcknowledged = state.syncAcknowledged
        roomEventPullsSent = state.roomEventPullsSent
        roomEventPullRetryableRejections = state.roomEventPullRetryableRejections
        roomEventPagesReceived = state.roomEventPagesReceived
        roomEventRecordsReceived = state.roomEventRecordsReceived
        roomEventAvailabilityHintsReceived = state.roomEventAvailabilityHintsReceived
        roomEventLivePayloadsApplied = state.roomEventLivePayloadsApplied
        roomEventLiveGapFramesDetected = state.roomEventLiveGapFramesDetected
        roomEventLiveMissingSequences = state.roomEventLiveMissingSequences
        roomEventMetadataGapsObserved = state.roomEventMetadataGapsObserved
        roomEventMetadataMissingSequences = state.roomEventMetadataMissingSequences
        roomEventRecoveryGracesScheduled = state.roomEventRecoveryGracesScheduled
        roomEventRecoveryGracesAvoided = state.roomEventRecoveryGracesAvoided
        roomEventRecoveryGracesExpired = state.roomEventRecoveryGracesExpired
        roomEventLocalEchoesApplied = state.roomEventLocalEchoesApplied
        roomEventLocalEchoGapsDetected = state.roomEventLocalEchoGapsDetected
        roomEventStalePagesReceived = state.roomEventStalePagesReceived
        readReceiptsScheduled = state.readReceiptsScheduled
        readReceiptsSent = state.readReceiptsSent
        readReceiptsAcknowledged = state.readReceiptsAcknowledged
        readReceiptsCoalesced = state.readReceiptsCoalesced
        roomSyncStateBatch = .init(start: .init(), end: state.roomSyncStateBatch)
        roomLatestVisibleBatch = .init(start: .init(), end: state.roomLatestVisibleBatch)
        maximumRSSMegabytes = Double(state.maximumRSSBytes) / 1_048_576
        authenticationLatency = state.authenticationLatency.percentiles
        heartbeatLatency = state.heartbeatLatency.percentiles
        messageLatency = state.messageLatency.percentiles
        syncPullLatency = state.syncPullLatency.percentiles
        roomEventPullLatency = state.roomEventPullLatency.percentiles
        readReceiptLatency = state.readReceiptLatency.percentiles
        self.eventLoopLag = .init(snapshot: eventLoopLag)
        scenarioName = configuration.scenario?.name
        scenarioRateScale = configuration.scenario.map { _ in configuration.scenarioRateScale }
        scenarioSchedulerTicksPerSecond = configuration.scenario.map {
            $0.schedulerTicksPerSecond ?? 10
        }
        scenarioSendDispatch = configuration.scenario.map { _ in configuration.scenarioSendDispatch.rawValue }
        maximumQueuedScenarioMessagesPerConnection = configuration.scenario.map {
            _ in configuration.maximumQueuedScenarioMessagesPerConnection
        }
        self.scenarioPhases = scenarioPhases
        self.scenarioDrain = scenarioDrain
        self.roomCursorSnapshots = roomCursorSnapshots
        scenarioPostDrainHoldSeconds = configuration.scenario?.postDrainHoldSeconds
        self.terminalError = terminalError.map(String.init(describing:))
    }

    var summary: String {
        "load complete requested=\(requestedConnections) authenticated=\(authenticated) failed=\(failed) peak_active=\(peakActive) messages_ack=\(messagesAcknowledged) messages_skipped=\(messagesSkipped) scenario_queue_max=\(maximumQueuedScenarioMessages) room_event_hints=\(roomEventAvailabilityHintsReceived) room_event_live_payloads=\(roomEventLivePayloadsApplied) room_event_live_gap_frames=\(roomEventLiveGapFramesDetected) room_event_live_missing_sequences=\(roomEventLiveMissingSequences) room_event_metadata_gaps=\(roomEventMetadataGapsObserved) room_event_metadata_missing_sequences=\(roomEventMetadataMissingSequences) room_event_recovery_graces_scheduled=\(roomEventRecoveryGracesScheduled) room_event_recovery_graces_avoided=\(roomEventRecoveryGracesAvoided) room_event_recovery_graces_expired=\(roomEventRecoveryGracesExpired) room_event_local_echoes=\(roomEventLocalEchoesApplied) room_event_local_echo_gaps=\(roomEventLocalEchoGapsDetected) room_event_stale_pages=\(roomEventStalePagesReceived) room_event_pulls=\(roomEventPullsSent) room_event_retryable_rejections=\(roomEventPullRetryableRejections) read_receipts_ack=\(readReceiptsAcknowledged) read_receipts_coalesced=\(readReceiptsCoalesced) sync_records=\(syncRecordsReceived) room_event_records=\(roomEventRecordsReceived) workload_failed=\(workloadFailed) auth_p95_ms=\(authenticationLatency.p95) heartbeat_p95_ms=\(heartbeatLatency.p95) message_p95_ms=\(messageLatency.p95) sync_p95_ms=\(syncPullLatency.p95) room_event_p95_ms=\(roomEventPullLatency.p95) read_receipt_p95_ms=\(readReceiptLatency.p95) event_loop_lag_max_ms=\(eventLoopLag.maximumMilliseconds) max_rss_mb=\(String(format: "%.1f", maximumRSSMegabytes))"
    }
}

private struct LoadEventLoopLagReport: Encodable {
    let samples: UInt64
    let sumMilliseconds: UInt64
    let maximumMilliseconds: UInt64
    let cumulativeBucketsMilliseconds: [String: UInt64]

    init(snapshot: V2RuntimeLatencyHistogramSnapshot) {
        samples = snapshot.samples
        sumMilliseconds = snapshot.sumMilliseconds
        maximumMilliseconds = snapshot.maximumMilliseconds
        cumulativeBucketsMilliseconds = Dictionary(uniqueKeysWithValues:
            V2RuntimeLatencyBucket.allCases.map { bucket in
                (String(bucket.rawValue), snapshot.count(atOrBelow: bucket))
            }
        )
    }
}

private struct ScenarioPhaseReport: Encodable {
    let name: String
    let durationSeconds: Int
    let observedDurationSeconds: Double
    let completed: Bool
    let requestedMessagesPerSecond: Double
    let requestedRoomLogReadsPerSecond: Double
    let requestedSyncPullsPerSecond: Double
    let requestedReadReceiptsPerSecond: Double
    let requestedRoomSyncStateBatchesPerSecond: Double
    let requestedRoomLatestVisibleBatchesPerSecond: Double
    let messagesSent: Int
    let messagesAcknowledged: Int
    let messagesSkipped: Int
    let scenarioMessagesScheduled: Int
    let scenarioMessagesDeferred: Int
    let scenarioMessageQueueOverflowed: Int
    let queuedScenarioMessagesAtEnd: Int
    let roomEventPullsSent: Int
    let roomEventPullRetryableRejections: Int
    let roomEventRecordsReceived: Int
    let roomEventLocalEchoesApplied: Int
    let roomEventLocalEchoGapsDetected: Int
    let roomEventStalePagesReceived: Int
    let readReceiptsScheduled: Int
    let readReceiptsSent: Int
    let readReceiptsAcknowledged: Int
    let readReceiptsCoalesced: Int
    let syncPullsSent: Int
    let syncRecordsReceived: Int
    let workloadFailed: Int
    let heartbeatLatency: Percentiles
    let messageLatency: Percentiles
    let syncPullLatency: Percentiles
    let roomEventPullLatency: Percentiles
    let readReceiptLatency: Percentiles
    let roomSyncStateBatch: RecoveryBatchReport
    let roomLatestVisibleBatch: RecoveryBatchReport

    func isSteadyStateDrained(maximumQueuedMessages: Int) -> Bool {
        scenarioMessageQueueOverflowed == 0 && queuedScenarioMessagesAtEnd <= maximumQueuedMessages
    }

    init(
        phase: LoadScenario.Phase,
        rateScale: Double,
        observedDurationSeconds: Double,
        completed: Bool,
        started: LoadStatistics.State,
        ended: LoadStatistics.State
    ) {
        name = phase.name
        durationSeconds = phase.durationSeconds
        self.observedDurationSeconds = observedDurationSeconds
        self.completed = completed
        requestedMessagesPerSecond = phase.messagesPerSecond * rateScale
        requestedRoomLogReadsPerSecond = phase.roomLogReadsPerSecond * rateScale
        requestedSyncPullsPerSecond = phase.syncPullsPerSecond * rateScale
        requestedReadReceiptsPerSecond = phase.effectiveReadReceiptsPerSecond * rateScale
        requestedRoomSyncStateBatchesPerSecond = phase.effectiveRoomSyncStateBatchesPerSecond * rateScale
        requestedRoomLatestVisibleBatchesPerSecond = phase.effectiveRoomLatestVisibleBatchesPerSecond * rateScale
        messagesSent = ended.messagesSent - started.messagesSent
        messagesAcknowledged = ended.messagesAcknowledged - started.messagesAcknowledged
        messagesSkipped = ended.messagesSkipped - started.messagesSkipped
        scenarioMessagesScheduled = ended.scenarioMessagesScheduled - started.scenarioMessagesScheduled
        scenarioMessagesDeferred = ended.scenarioMessagesDeferred - started.scenarioMessagesDeferred
        scenarioMessageQueueOverflowed = ended.scenarioMessageQueueOverflowed - started.scenarioMessageQueueOverflowed
        queuedScenarioMessagesAtEnd = ended.queuedScenarioMessages
        roomEventPullsSent = ended.roomEventPullsSent - started.roomEventPullsSent
        roomEventPullRetryableRejections = ended.roomEventPullRetryableRejections
            - started.roomEventPullRetryableRejections
        roomEventRecordsReceived = ended.roomEventRecordsReceived - started.roomEventRecordsReceived
        roomEventLocalEchoesApplied = ended.roomEventLocalEchoesApplied - started.roomEventLocalEchoesApplied
        roomEventLocalEchoGapsDetected = ended.roomEventLocalEchoGapsDetected - started.roomEventLocalEchoGapsDetected
        roomEventStalePagesReceived = ended.roomEventStalePagesReceived - started.roomEventStalePagesReceived
        readReceiptsScheduled = ended.readReceiptsScheduled - started.readReceiptsScheduled
        readReceiptsSent = ended.readReceiptsSent - started.readReceiptsSent
        readReceiptsAcknowledged = ended.readReceiptsAcknowledged
            - started.readReceiptsAcknowledged
        readReceiptsCoalesced = ended.readReceiptsCoalesced - started.readReceiptsCoalesced
        syncPullsSent = ended.syncPullsSent - started.syncPullsSent
        syncRecordsReceived = ended.syncRecordsReceived - started.syncRecordsReceived
        workloadFailed = ended.workloadFailed - started.workloadFailed
        heartbeatLatency = ended.heartbeatLatency
            .subtracting(started.heartbeatLatency)
            .percentiles
        messageLatency = ended.messageLatency
            .subtracting(started.messageLatency)
            .percentiles
        syncPullLatency = ended.syncPullLatency
            .subtracting(started.syncPullLatency)
            .percentiles
        roomEventPullLatency = ended.roomEventPullLatency
            .subtracting(started.roomEventPullLatency)
            .percentiles
        readReceiptLatency = ended.readReceiptLatency
            .subtracting(started.readReceiptLatency)
            .percentiles
        roomSyncStateBatch = .init(start: started.roomSyncStateBatch, end: ended.roomSyncStateBatch)
        roomLatestVisibleBatch = .init(start: started.roomLatestVisibleBatch, end: ended.roomLatestVisibleBatch)
    }
}

private final class ScenarioPhaseReportCollector: @unchecked Sendable {
    private let lock = NIOLock()
    private var reports: [ScenarioPhaseReport] = []

    func append(_ report: ScenarioPhaseReport) {
        lock.withLock { reports.append(report) }
    }

    func snapshot() -> [ScenarioPhaseReport] {
        lock.withLock { reports }
    }
}

private struct ScenarioDrainReport: Encodable {
    let drained: Bool
    let durationMilliseconds: Int
    let pending: ScenarioPendingMessages
}

/// 有界的 1 毫秒直方图。
///
/// 它避免了在长达数小时的测试中保留数百万个样本。
/// 超过十秒的值共享一个溢出桶；`maximum` 仍记录它们真实的最大值。
private struct LatencyHistogram: Sendable {
    private static let maximumBucketMilliseconds = 10_000
    private var buckets = Array(repeating: 0, count: maximumBucketMilliseconds + 1)
    private(set) var count = 0
    private(set) var maximum = 0.0

    mutating func record(_ milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        let bucket = min(Self.maximumBucketMilliseconds, Int(milliseconds.rounded(.down)))
        buckets[bucket] += 1
        count += 1
        maximum = max(maximum, milliseconds)
    }

    /// 只返回在捕获 `baseline` 之后记录的样本。
    ///
    /// 负载统计是累积的，因此相减桶计数即可得到精确的阶段分位数，
    /// 无需在负载生成器的每消息热路径上再加锁或更新直方图。
    /// 超过有界直方图范围的值保留可用的最佳最大值：
    /// 若最大值就是在本区间内引入的则记精确值，否则记录溢出桶边界。
    ///
    /// - Parameter baseline: 相减的基线直方图。
    /// - Returns: 表示本区间增量的直方图。
    func subtracting(_ baseline: Self) -> Self {
        var result = Self()
        var highestNonemptyBucket: Int?
        for index in buckets.indices {
            let samples = max(0, buckets[index] - baseline.buckets[index])
            result.buckets[index] = samples
            result.count += samples
            if samples > 0 { highestNonemptyBucket = index }
        }
        guard let highestNonemptyBucket else { return result }
        if maximum > baseline.maximum {
            result.maximum = maximum
        } else {
            result.maximum = Double(highestNonemptyBucket)
        }
        return result
    }

    var percentiles: Percentiles {
        .init(histogram: self)
    }

    func percentile(_ target: Double) -> Double {
        guard count > 0 else { return 0 }
        let rank = min(count, max(1, Int((Double(count) * target).rounded(.up))))
        var cumulative = 0
        for (bucket, samples) in buckets.enumerated() {
            cumulative += samples
            if cumulative >= rank { return Double(bucket) }
        }
        return Double(Self.maximumBucketMilliseconds)
    }
}

private struct Percentiles: Encodable {
    let count: Int
    let p50: Double
    let p95: Double
    let p99: Double
    let maximum: Double

    init(histogram: LatencyHistogram) {
        count = histogram.count
        p50 = histogram.percentile(0.50)
        p95 = histogram.percentile(0.95)
        p99 = histogram.percentile(0.99)
        maximum = (histogram.maximum * 100).rounded() / 100
    }
}

private enum LoadError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidScenario(String)
    case invalidCredentialFile
    case insufficientCredentials(required: Int, available: Int)
    case unexpectedResponse
    case unexpectedSyncResponse(String)
    case connectionClosed
    case memoryGuardTriggered(megabytes: Int)
    case failureGuardTriggered(failed: Int, attempted: Int)
    case connectionLossGuardTriggered(disconnected: Int, authenticated: Int)
    case workloadFailureGuardTriggered(failed: Int, attempted: Int)
    case roomWarmupTimedOut(opened: Int, required: Int)
    case scenarioPhaseNotDrained(phase: String, queued: Int, maximumQueued: Int, sent: Int, acknowledged: Int)
    case scenarioCompletionDrainTimedOut(queued: Int, inFlight: Int)

    var description: String {
        switch self {
        case .invalidArguments:
            return "invalid arguments; required: --host --ca-path --credentials --report"
        case .invalidScenario(let reason): return "invalid scenario: \(reason)"
        case .invalidCredentialFile: return "credential file is empty, duplicated, or malformed"
        case .insufficientCredentials(let required, let available): return "insufficient credentials: required \(required), available \(available)"
        case .unexpectedResponse: return "gateway returned an unexpected protocol response"
        case .unexpectedSyncResponse(let reason):
            return "gateway returned an unexpected sync response: \(reason)"
        case .connectionClosed: return "gateway connection closed before authentication"
        case .memoryGuardTriggered(let megabytes): return "local memory guard triggered at \(megabytes) MB"
        case .failureGuardTriggered(let failed, let attempted): return "connection failure guard triggered: \(failed)/\(attempted)"
        case .connectionLossGuardTriggered(let disconnected, let authenticated): return "active connection loss guard triggered: \(disconnected)/\(authenticated)"
        case .workloadFailureGuardTriggered(let failed, let attempted): return "message workload failure guard triggered: \(failed)/\(attempted)"
        case .roomWarmupTimedOut(let opened, let required): return "room warmup timed out: opened \(opened)/\(required)"
        case .scenarioPhaseNotDrained(let phase, let queued, let maximumQueued, let sent, let acknowledged):
            return "scenario phase did not sustain its offered rate: phase=\(phase) queued=\(queued) maximum_queued=\(maximumQueued) sent=\(sent) acknowledged=\(acknowledged)"
        case .scenarioCompletionDrainTimedOut(let queued, let inFlight):
            return "scenario completion drain timed out: queued=\(queued) in_flight=\(inFlight)"
        }
    }
}

private func residentMemoryBytes() -> UInt64 {
    #if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    #elseif os(Linux)
    // Linux exposes the current resident set without requiring a sampling
    // subprocess. Keep the parser deliberately narrow: VmRSS is expressed in
    // KiB by procfs and a missing/malformed field disables only the local
    // memory guard instead of aborting the workload.
    guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
          let line = status.split(whereSeparator: \.isNewline).first(where: {
              $0.hasPrefix("VmRSS:")
          }),
          let kibibytes = line.split(whereSeparator: \.isWhitespace)
              .dropFirst()
              .compactMap({ UInt64($0) })
              .first
    else { return 0 }
    return kibibytes * 1_024
    #endif
}

private extension TimeAmount {
    var millisecondsDouble: Double { Double(nanoseconds) / 1_000_000 }
}

private extension JSONEncoder {
    static var loadReport: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
