import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerGateway
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Synchronization
import IMV2Compression
import IMV2Core
import IMV2LoadGeneratorSupport
import IMV2Server
import IMV2ServerInfrastructure
import IMV2ToolHTTP
@preconcurrency import NIOConcurrencyHelpers
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL

@main
enum IMV2GatewayLoadGenerator {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--describe-message-transport"] {
                print(LoadConnectionHandler.messageTransportDescription)
                return
            }
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
    case .messageSendOperationResult: "message_send_operation_result"
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

// Inspect only closed tool failures or the error's type. Error descriptions
// may contain URLs or request material and must not enter load reports.
private func loadHTTPFailureCode(_ error: any Error) -> String {
    if let failure = error as? V2ToolOperationHTTP.Failure {
        switch failure {
        case .status(let status): return "HTTP_STATUS_\(status)"
        case .incomplete: return "HTTP_INCOMPLETE"
        case .invalidResponse: return "HTTP_INVALID_RESPONSE"
        case .invalidConfiguration: return "HTTP_INVALID_CONFIGURATION"
        }
    }
    if let code = V2ToolOperationHTTP.clientFailureCode(error) { return code }
    if error is CancellationError { return "HTTP_CLIENT_CANCELLED" }
    if let io = error as? IOError { return "HTTP_CLIENT_IO_\(io.errnoCode)" }
    return "HTTP_CLIENT_" + String(reflecting: type(of: error))
}

private struct LoadConfiguration: Sendable {
    let benchmarkWireVersion: UInt32
    let host: String
    let port: Int
    let revision: String
    let serverName: String
    let accountBaseURL:URL
    let caPath: String
    let credentialsPath: String
    let reportPath: String
    let connections: Int
    let localPortBase: Int?
    let excludedLocalPorts: Set<Int>
    let rampPerSecond: Int
    let rampBatchSize: Int
    let workloadRampPerSecond: Int
    let holdSeconds: Int
    let eventLoops: Int
    let messagesPerSecond: Int
    let onlineOnly: Bool
    let maximumInFlightMessagesPerConnection: Int
    let messageBytes: Int
    let targetsPerConnection: Int
    let targetOffset: Int
    let syncReads: Bool
    let roomLogReads: Bool
    let roomLogInitialCursor: RoomLogInitialCursor
    let roomLogReadTrigger: RoomLogReadTrigger
    let roomNotificationLossCanary: Bool
    let roomLogRecoveryGraceMilliseconds: Int
    let peerTopology: PeerTopology
    let heartbeatSeconds: Int
    let recoveryBatchTimeoutSeconds: Int
    let maximumRSSMegabytes: Int
    let maximumFailurePercent: Double
    let scenario: LoadScenario?
    let scenarioRateScale: Double
    let scenarioReadyPath: String?
    let scenarioStartBarrierPath: String?
    let checkpointRequestPath: String?
    let checkpointResponsePath: String?
    let recoveryBurst: Bool
    let plannedReconnectInflightCanary: Bool
    let recoveryBurstWorkers: Int
    let recoveryBurstMaximumAttempts: Int
    let recoveryBurstObserveSeconds: Int
    let recoveryBurstOfflineSeconds: Int
    let recoveryBurstOfflineMessagesPerRoom: Int
    let recoveryBurstOfflineWriteWorkers: Int
    let recoveryBurstOfflineWriteDeadlineSeconds: Int

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

        // Measurement-only reference adapter; production endpoints remain version-strict.
        let wire = try Self.integer(values["--benchmark-wire-version"] ?? String(IMV2ProtocolVersion.current), range: 1...255)
        guard wire == 45 || wire == Int(IMV2ProtocolVersion.current) else { throw LoadError.invalidArguments }
        benchmarkWireVersion = UInt32(wire)
        self.host = host
        revision = values["--revision"] ?? "unknown"
        serverName = values["--server-name"] ?? "localhost"
        guard let accountBaseURL=URL(string:values["--account-base-url"] ?? "https://localhost:8443") else { throw LoadError.invalidCredentialFile }
        self.accountBaseURL=accountBaseURL
        self.caPath = caPath
        self.credentialsPath = credentialsPath
        self.reportPath = reportPath
        port = try Self.integer(values["--port"] ?? "443", range: 1...65_535)
        // This is a generator-side guard, not the Gateway admission limit.
        // A mixed-source 10k run assigns 8k connections to one isolated load
        // worker, so allow one worker to own the full validated test scale.
        connections = try Self.integer(values["--connections"] ?? "100", range: 1...10_000)
        if let value = values["--local-port-base"] {
            localPortBase = try Self.integer(value, range: 1_024...(65_536 - LocalSourcePortAllocator.span))
        } else {
            localPortBase = nil
        }
        let excluded = (values["--exclude-local-ports"] ?? "").split(separator: ",")
        excludedLocalPorts = try Set(excluded.map { try Self.integer(String($0), range: 1...65_535) })
        if let localPortBase {
            let unavailable = excludedLocalPorts.filter { $0 >= localPortBase && $0 < localPortBase + LocalSourcePortAllocator.span }.count
            guard connections <= LocalSourcePortAllocator.span - unavailable else { throw LoadError.invalidArguments }
        } else if !excludedLocalPorts.isEmpty { throw LoadError.invalidArguments }
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
        onlineOnly = try Self.integer(values["--online-only"] ?? "0", range: 0...1) == 1
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
            values["--room-log-recovery-grace-ms"] ?? "100",
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
        scenarioReadyPath = values["--scenario-ready-path"]
        scenarioStartBarrierPath = values["--scenario-start-barrier-path"]
        guard (scenarioReadyPath == nil && scenarioStartBarrierPath == nil)
            || (scenario != nil && scenarioReadyPath?.isEmpty == false && scenarioStartBarrierPath?.isEmpty == false
                && scenarioReadyPath != scenarioStartBarrierPath) else { throw LoadError.invalidArguments }
        checkpointRequestPath = values["--checkpoint-request-path"]
        checkpointResponsePath = values["--checkpoint-response-path"]
        guard (checkpointRequestPath == nil) == (checkpointResponsePath == nil) else { throw LoadError.invalidArguments }
        if let request = checkpointRequestPath, let response = checkpointResponsePath {
            // Resolve the existing parent for every file, then append its name.
            // Foundation may canonicalize an existing /private/tmp parent to
            // /tmp while preserving /private/tmp on a nonexistent child URL.
            // Resolving those unequal shapes used to reject valid canary paths.
            func ownedFileURL(_ path: String) -> URL {
                let file = URL(fileURLWithPath: path).standardizedFileURL
                return file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                    .appendingPathComponent(file.lastPathComponent, isDirectory: false)
            }
            let reportURL = ownedFileURL(reportPath)
            let directory = reportURL.deletingLastPathComponent().path
            let ownedPrefix = directory.hasSuffix("/") ? directory : directory + "/"
            let requestURL = ownedFileURL(request), responseURL = ownedFileURL(response)
            for path in [request, response] where FileManager.default.fileExists(atPath: path) {
                // Existing symbolic links must not bypass owned-directory validation.
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LoadError.invalidArguments }
            }
            guard benchmarkWireVersion >= 46, scenario != nil,
                  request.hasPrefix("/"), response.hasPrefix("/"), directory != "/",
                  requestURL.path.hasPrefix(ownedPrefix), responseURL.path.hasPrefix(ownedPrefix),
                  requestURL != responseURL, requestURL.path != reportURL.path,
                  responseURL.path != reportURL.path else { throw LoadError.invalidArguments }
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
        recoveryBurst = try Self.integer(values["--recovery-burst"] ?? "0", range: 0...1) == 1
        roomNotificationLossCanary = try Self.integer(values["--room-notification-loss-canary"] ?? "0", range: 0...1) == 1
        guard !roomNotificationLossCanary || (roomLogReads && roomLogReadTrigger == .availabilityHint
            && connections <= 500 && !recoveryBurst
            && (values["--message-transport"] == nil || values["--message-transport"] == "tcp")) else {
            throw LoadError.invalidArguments
        }
        plannedReconnectInflightCanary = try Self.integer(values["--planned-reconnect-inflight-canary"] ?? "0", range: 0...1) == 1
        guard !plannedReconnectInflightCanary || (scenario != nil && roomLogReads && connections <= 500 && !recoveryBurst
            && maximumInFlightMessagesPerConnection == 1
            && scenario?.sendDispatch == .boundedClientQueue
            && (scenario?.maximumQueuedMessagesPerConnection ?? 0) >= 1) else { throw LoadError.invalidArguments }
        recoveryBurstWorkers = try Self.integer(values["--recovery-burst-workers"] ?? "128", range: 1...connections)
        recoveryBurstMaximumAttempts = try Self.integer(values["--recovery-burst-max-attempts"] ?? "1", range: 1...3)
        recoveryBurstOfflineSeconds = try Self.integer(values["--recovery-burst-offline-seconds"] ?? "0", range: 0...300)
        recoveryBurstOfflineMessagesPerRoom = try Self.integer(values["--recovery-burst-offline-messages-per-room"] ?? "0", range: 0...16)
        recoveryBurstOfflineWriteWorkers = try Self.integer(values["--recovery-burst-offline-write-workers"] ?? "8", range: 1...32)
        recoveryBurstOfflineWriteDeadlineSeconds = try Self.integer(values["--recovery-burst-offline-write-deadline-seconds"] ?? "60", range: 1...300)
        guard recoveryBurst || recoveryBurstOfflineMessagesPerRoom == 0 else { throw LoadError.invalidArguments }
        recoveryBurstObserveSeconds = try Self.integer(values["--recovery-burst-observe-seconds"] ?? "60", range: 1...300)
        guard !recoveryBurst || (scenario != nil && roomLogReads &&
            scenario!.phases.allSatisfy { $0.reconnectPercentPerMinute == 0 }) else {
            throw LoadError.invalidArguments
        }
        guard !onlineOnly || (messagesPerSecond == 0 && !syncReads && !roomLogReads
            && !recoveryBurst && !plannedReconnectInflightCanary && !roomNotificationLossCanary
            && scenario != nil && scenario!.phases.allSatisfy {
                $0.messagesPerSecond == 0 && $0.roomLogReadsPerSecond == 0 && $0.syncPullsPerSecond == 0
                && $0.effectiveReadReceiptsPerSecond == 0 && $0.effectiveRoomSyncStateBatchesPerSecond == 0
                && $0.effectiveRoomLatestVisibleBatchesPerSecond == 0 && $0.reconnectPercentPerMinute == 0
            }) else { throw LoadError.invalidArguments }
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
        enum SendSelection: String, Decodable, Sendable {
            case weightedRandom = "weighted_random"
            case roundRobin = "round_robin"
        }

        let name: String
        /// A deterministic sweep is useful for warming every sender's room
        /// before a measured phase retains the normal weighted workload.
        let sendSelection: SendSelection?
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
              !scenario.phases.isEmpty, Set(scenario.phases.map(\.name)).count == scenario.phases.count
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

private struct MessageSendCohortReport: Encodable {
    let messagesSent: Int
    let messagesAcknowledged: Int
    let messageLatency: Percentiles
    let messageEndToEndLatency: Percentiles
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
        var roomProgressReportsSent = 0
        var roomProgressStatesAccepted = 0
        var roomProgressStatesIgnored = 0
        var roomProgressRecoverySignals = 0
        var roomNotificationsDiscarded = 0
        var directRoomAttempted = 0
        var directRoomOpened = 0
        var roomLogTailReady = 0
        var workloadFailed = 0
        var workloadFailuresByKindAndCode: [String: Int] = [:]
        var messagesSent = 0
        var messageTransportEvents: [String: Int] = [:]
        var realtimeCoverageEvents: [String: Int] = [:]
        var messageSendNegotiatedConnections = 0
        var messageSendPayloadLimitMinimum: UInt32?
        var messageSendPayloadLimitMaximum: UInt32?
        var messagesAcknowledged = 0
        var messagesSkipped = 0
        var scenarioMessagesScheduled = 0
        var scenarioMessagesDeferred = 0
        var scenarioMessageQueueOverflowed = 0
        var scenarioMessageQueueAbandoned = 0
        var queuedScenarioMessages = 0
        var maximumQueuedScenarioMessages = 0
        // Initial logical pulls only: retries must not dilute the failure guard.
        var syncPullsSent = 0
        var syncWireAttempts = 0
        var syncRetryAttempts = 0
        var syncLogicalFailures = 0
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
        var messageEndToEndLatency = LatencyHistogram()
        var syncPullLatency = LatencyHistogram()
        var roomEventPullLatency = LatencyHistogram()
        var readReceiptLatency = LatencyHistogram()
        var roomSyncStateBatch = RecoveryBatchStats()
        var roomLatestVisibleBatch = RecoveryBatchStats()
        var maximumRSSBytes: UInt64 = 0
        var protocolFailuresByKindAndCode: [String: Int] = [:]
    }

    private let lock = NIOLock()
    private var state = State()
    // Only accessed under the existing statistics lock. Reference storage avoids
    // copying two large histograms out of the dictionary on every observation.
    private final class MessageCohort {
        var sent = 0
        var acknowledged = 0
        var latency = LatencyHistogram()
        var endToEnd = LatencyHistogram()
    }
    private var cohortWindows = V2LoadMessageCohortWindows()
    private var cohorts: [String: MessageCohort] = [:]
    func registerMessageCohort(name: String, start: NIODeadline, end: NIODeadline) throws {
        try lock.withLock {
            try cohortWindows.register(name: name, start: start.uptimeNanoseconds, end: end.uptimeNanoseconds)
            cohorts[name] = MessageCohort()
        }
    }
    func messageSendCohorts() -> [String: MessageSendCohortReport] {
        lock.withLock {
            cohorts.mapValues { .init(messagesSent: $0.sent, messagesAcknowledged: $0.acknowledged,
                messageLatency: $0.latency.percentiles, messageEndToEndLatency: $0.endToEnd.percentiles) }
        }
    }

    func recordAttempt() { lock.withLock { state.attempted += 1 } }
    func recordFailure(_ error: Error) {
        lock.withLock {
            state.failed += 1
            let key = Self.connectionFailureKey(error)
            state.connectionFailuresByError[key, default: 0] += 1
        }
    }
    func recordProtocolFailure(_ error: Error) {
        guard case .unexpectedServerResponse(let code, let messageType, _)? = error as? LoadError else { return }
        lock.withLock { state.protocolFailuresByKindAndCode["\(messageType):\(code ?? "NONE")", default: 0] += 1 }
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
    func recordRoomNotificationDiscarded() { lock.withLock { state.roomNotificationsDiscarded += 1 } }
    func recordRoomProgressReport() { lock.withLock { state.roomProgressReportsSent += 1 } }
    func recordRoomProgressState(accepted: Bool, recovery: Bool) {
        lock.withLock {
            if accepted { state.roomProgressStatesAccepted += 1 }
            else { state.roomProgressStatesIgnored += 1 }
            if recovery { state.roomProgressRecoverySignals += 1 }
        }
    }
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
    func recordRealtimeCoverage(_ coverage: IMV2RealtimeCoverage) {
        let scope: String
        switch coverage.scope {
        case .account: scope = "account"
        case .room: scope = "room"
        case .directory: scope = "directory"
        case .presence: scope = "presence"
        case .typing: scope = "typing"
        case .unspecified, .UNRECOGNIZED: scope = "unknown"
        }
        let phase: String
        switch coverage.state {
        case .recovering: phase = "recovering"
        case .ready: phase = "ready"
        case .ended: phase = "ended"
        case .unspecified, .UNRECOGNIZED: phase = "unknown"
        }
        // Notification observations never advance a durable cursor or certify
        // catch-up. Labels exclude connection IDs, topic IDs and wire values.
        lock.withLock { state.realtimeCoverageEvents[scope + ":" + phase, default: 0] += 1 }
    }
    func recordMessageTransportEvent(_ code: String) {
        lock.withLock { state.messageTransportEvents[code, default: 0] += 1 }
    }
    func recordMessageSendNegotiated(payloadLimit: UInt32) {
        lock.withLock {
            state.messageSendNegotiatedConnections += 1
            state.messageSendPayloadLimitMinimum = min(state.messageSendPayloadLimitMinimum ?? payloadLimit, payloadLimit)
            state.messageSendPayloadLimitMaximum = max(state.messageSendPayloadLimitMaximum ?? payloadLimit, payloadLimit)
        }
    }
    func recordMessageSent(scheduledAt: NIODeadline) {
        lock.withLock {
            state.messagesSent += 1
            if let name = cohortWindows.cohort(scheduledAt: scheduledAt.uptimeNanoseconds) { cohorts[name]?.sent += 1 }
        }
    }
    func recordMessageAcknowledged(milliseconds: Double, endToEndMilliseconds: Double, scheduledAt: NIODeadline) {
        lock.withLock {
            state.messagesAcknowledged += 1
            state.messageLatency.record(milliseconds)
            state.messageEndToEndLatency.record(endToEndMilliseconds)
            if let name = cohortWindows.cohort(scheduledAt: scheduledAt.uptimeNanoseconds), let cohort = cohorts[name] {
                cohort.acknowledged += 1
                cohort.latency.record(milliseconds)
                cohort.endToEnd.record(endToEndMilliseconds)
            }
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
    func recordSyncWireAttempt(retry: Bool) {
        lock.withLock { state.syncWireAttempts += 1; if retry { state.syncRetryAttempts += 1 } }
    }
    func recordSyncLogicalFailure() { lock.withLock { state.syncLogicalFailures += 1 } }
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

/// All bounded workers register before any connection attempt is released.
private actor RecoveryBurstBarrier {
    private let workers: Int
    private var waiting: [CheckedContinuation<NIODeadline, Never>] = []
    private var released: NIODeadline?
    private var releasedAt: Date?
    init(workers: Int) { self.workers = workers }
    func arrive() async -> NIODeadline {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == workers {
                let start = NIODeadline.now()
                released = start
                releasedAt = Date()
                let pending = waiting
                waiting.removeAll()
                for waiter in pending { waiter.resume(returning: start) }
            }
        }
    }
    func origin() -> NIODeadline { released! }
    func wallTime() -> Date { releasedAt! }
}

/// Cancellation owns the actual socket even while authentication is pending.
private final class RecoveryBurstAttempt: @unchecked Sendable {
    private let lock = NIOLock()
    private var channel: Channel?
    private var cancelled = false
    func install(_ channel: Channel) {
        let shouldClose = lock.withLock { self.channel = channel; return cancelled }
        if shouldClose { channel.close(promise: nil) }
    }
    func cancel() {
        let current = lock.withLock { cancelled = true; return channel }
        current?.close(promise: nil)
    }
}

private struct OfflineWriteReceipt: Encodable, Sendable {
    let roomID: String
    let roomSequence: UInt64
}
private struct OfflineRoomWrite: Sendable {
    let credential: LoadCredential
    let commands: [V2MessageSendOperationCommand]
}
private struct OfflineWriteResult: Sendable {
    let receipts: [OfflineWriteReceipt]
    let failed: Int
}
private struct RecoveryCursorProgress: Encodable, Sendable {
    let connectionIndex: Int
    let roomID: String
    let beforeSequence: UInt64
    let appliedSequence: UInt64?
    let recoveryTarget: UInt64?
    let injectedThrough: UInt64?
    let remainingGap: UInt64?
}

private struct RecoveryBurstReport: Encodable {
    let offlineInjectedRooms: Int
    let offlineWritesRequested: Int
    let offlineWritesAccepted: Int
    let offlineWritesFailed: Int
    let offlineWriteReceipts: [OfflineWriteReceipt]
    let cursorProgress: [RecoveryCursorProgress]
    let requestedConnections: Int
    let barrierReleasedAt: Date
    let workers: Int
    let maximumAttemptsPerConnection: Int
    let observationSeconds: Int
    let actualObservationMilliseconds: Double
    let offlineSeconds: Int
    let startedConnections: Int
    let connectAuthenticated: Int
    let connectUnsuccessful: Int
    let attempts: Int
    let failedAttempts: Int
    let attemptAmplification: Double
    /// Raw bounded per-connection offsets preserve distribution above the histogram's 10s bound.
    let firstAttemptStartMilliseconds: [Double?]
    let allAttemptStartMilliseconds: [[Double]]
    let expectedCursorRooms: Int
    let observedTargetRooms: Int
    let roomsWithCursorBacklog: Int
    let cursorTargetCompletedRooms: Int
    let cursorTargetUncompletedOrUnknownRooms: Int
    let syncPullRequests: Int
    let roomEventPullRequests: Int
    let roomEventRetryableRejections: Int
    let roomSyncStateBatch: RecoveryBatchReport
    let roomLatestVisibleBatch: RecoveryBatchReport
}

private final class RecoveryBurstSamples: @unchecked Sendable {
    private let lock = NIOLock()
    private var next = 0
    private var starts: [[Double]]
    private var successes: Set<Int> = []
    private var failures = 0
    init(count: Int) { starts = Array(repeating: [], count: count) }
    func take() -> Int? {
        lock.withLock {
            guard next < starts.count else { return nil }
            defer { next += 1 }
            return next
        }
    }
    func started(index: Int, offset: Int64) {
        lock.withLock { starts[index].append(Double(max(0, offset)) / 1_000_000) }
    }
    func succeeded(index: Int) { lock.withLock { _ = successes.insert(index) } }
    func failedAttempt() { lock.withLock { failures += 1 } }
    func report(workers: Int, barrierReleasedAt: Date, maximumAttempts: Int, observationSeconds: Int, actualObservationMilliseconds: Double, offlineSeconds: Int,
                before: LoadStatistics.State, after: LoadStatistics.State,
                expectedRooms: Int, observedRooms: Int, backlogRooms: Int, completedRooms: Int,
                offlineRequested: Int, offlineResult: OfflineWriteResult, cursorProgress: [RecoveryCursorProgress]) -> RecoveryBurstReport {
        lock.withLock {
            let attempts = starts.reduce(0) { $0 + $1.count }
            return .init(offlineInjectedRooms: Set(offlineResult.receipts.map(\.roomID)).count,
                offlineWritesRequested: offlineRequested, offlineWritesAccepted: offlineResult.receipts.count,
                offlineWritesFailed: offlineResult.failed, offlineWriteReceipts: offlineResult.receipts,
                cursorProgress: cursorProgress, requestedConnections: starts.count, barrierReleasedAt: barrierReleasedAt, workers: workers,
                maximumAttemptsPerConnection: maximumAttempts, observationSeconds: observationSeconds, actualObservationMilliseconds: actualObservationMilliseconds, offlineSeconds: offlineSeconds,
                startedConnections: starts.filter { !$0.isEmpty }.count,
                connectAuthenticated: successes.count, connectUnsuccessful: starts.count - successes.count,
                attempts: attempts, failedAttempts: failures,
                attemptAmplification: Double(attempts) / Double(starts.count),
                firstAttemptStartMilliseconds: starts.map(\.first), allAttemptStartMilliseconds: starts,
                expectedCursorRooms: expectedRooms, observedTargetRooms: observedRooms, roomsWithCursorBacklog: backlogRooms,
                cursorTargetCompletedRooms: completedRooms,
                cursorTargetUncompletedOrUnknownRooms: expectedRooms - completedRooms,
                syncPullRequests: after.syncPullsSent - before.syncPullsSent,
                roomEventPullRequests: after.roomEventPullsSent - before.roomEventPullsSent,
                roomEventRetryableRejections: after.roomEventPullRetryableRejections - before.roomEventPullRetryableRejections,
                roomSyncStateBatch: .init(start: before.roomSyncStateBatch, end: after.roomSyncStateBatch),
                roomLatestVisibleBatch: .init(start: before.roomLatestVisibleBatch, end: after.roomLatestVisibleBatch))
        }
    }
}

/// The TCP ramp stays independent of account HTTP control work. Keep only a
/// fixed number of HTTPS operations active while retaining frozen operations
/// for the bounded number of planned room opens.
private final class DirectRoomHTTPTaskOwner: @unchecked Sendable {
    static let configuredMaximumConcurrent = 32
    static let configuredMaximumQueued = 10_000
    private struct Work: Sendable {
        let id: UUID
        let operation: @Sendable () async -> Void
    }
    private struct State {
        var closing = false
        var pending: [Work] = []
        var active: [UUID: Task<Void, Never>] = [:]
    }
    private let lock = NIOLock()
    private var state = State()
    private let maximumConcurrent: Int
    private let maximumQueued: Int

    init(maximumConcurrent: Int, maximumQueued: Int) {
        precondition(maximumConcurrent > 0 && maximumQueued > 0)
        self.maximumConcurrent = maximumConcurrent
        self.maximumQueued = maximumQueued
    }

    @discardableResult
    func start(id: UUID, operation: @escaping @Sendable () async -> Void) -> Bool {
        lock.withLock {
            guard !state.closing, state.pending.count < maximumQueued,
                  state.active[id] == nil, !state.pending.contains(where: { $0.id == id })
            else { return false }
            state.pending.append(.init(id: id, operation: operation))
            startPendingLocked()
            return true
        }
    }

    private func startPendingLocked() {
        while !state.closing, state.active.count < maximumConcurrent, !state.pending.isEmpty {
            let work = state.pending.removeFirst()
            state.active[work.id] = Task {
                await work.operation()
                self.finished(id: work.id)
            }
        }
    }

    private func finished(id: UUID) {
        lock.withLock {
            state.active.removeValue(forKey: id)
            startPendingLocked()
        }
    }

    func cancel(id: UUID) {
        lock.withLock {
            state.pending.removeAll(where: { $0.id == id })
            state.active[id]?.cancel()
        }
    }

    func closeAndDrain() async {
        let tasks = lock.withLock { () -> [Task<Void, Never>] in
            state.closing = true
            state.pending.removeAll()
            let tasks = Array(state.active.values)
            for task in tasks { task.cancel() }
            return tasks
        }
        for task in tasks { await task.value }
    }
}

// Explicit ranges let independent destinations reuse local ports without exhausting
// the OS ephemeral range. Every connection attempt consumes a fresh port: a
// reconnect must not reuse the same four-tuple while its prior socket is TIME_WAIT.
private final class LocalSourcePortAllocator: @unchecked Sendable {
    static let span = 10_000
    private let lock = NIOLock()
    private var nextPort: Int
    private let endPort: Int
    private let excluded: Set<Int>

    init(base: Int, excluding: Set<Int> = []) {
        nextPort = base
        endPort = base + Self.span
        excluded = excluding
    }

    func allocate() throws -> Int {
        try lock.withLock {
            while nextPort < endPort, excluded.contains(nextPort) { nextPort += 1 }
            guard nextPort < endPort else { throw LoadError.localSourcePortRangeExhausted }
            defer { nextPort += 1 }
            return nextPort
        }
    }
}

private struct LoadRun: Sendable {
    static let accountHTTPConnectionsPerHostSoftLimit = 256
    let directRoomTasks = DirectRoomHTTPTaskOwner(
        maximumConcurrent: DirectRoomHTTPTaskOwner.configuredMaximumConcurrent,
        maximumQueued: DirectRoomHTTPTaskOwner.configuredMaximumQueued)
    let configuration: LoadConfiguration
    let credentials: [LoadCredential]

    // One pool per run. Both comparison servers use this same loader lifecycle.
    private let accountHTTP: V2ToolOperationHTTP
    private let localSourcePorts: LocalSourcePortAllocator?

    init(configuration: LoadConfiguration, credentials: [LoadCredential]) throws {
        self.configuration = configuration
        self.credentials = credentials
        self.localSourcePorts = configuration.localPortBase.map { LocalSourcePortAllocator(base: $0, excluding: configuration.excludedLocalPorts) }
        self.accountHTTP = try V2ToolOperationHTTP(baseURL: configuration.accountBaseURL, caPath: configuration.caPath,
            http1ConnectionsPerHostSoftLimit: Self.accountHTTPConnectionsPerHostSoftLimit)
    }

    func execute() async throws -> LoadReport {
        let result: Result<LoadReport, any Error>
        do { result = .success(try await executeWithOwnedHTTP()) }
        catch { result = .failure(error) }
        // executeWithOwnedHTTP closes TCP operations and drains direct HTTP tasks before returning.
        // Early setup failures have no tasks; shutdown still occurs exactly once.
        do { try await accountHTTP.shutdown() }
        catch { if case .success = result { throw error } }
        return try result.get()
    }

    private func executeWithOwnedHTTP() async throws -> LoadReport {
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
        var recoveryBurstReport: RecoveryBurstReport?
        var checkpointWorker: RealtimeCheckpointWorker?

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

            if let request = configuration.checkpointRequestPath, let response = configuration.checkpointResponsePath {
                // Capture the completed slot array by value; replacements remain
                // protected by each slot's existing lock. Never capture run's var.
                checkpointWorker = RealtimeCheckpointWorker(slots: slots, requested: configuration.connections,
                    requestPath: request, responsePath: response)
            }
            if !configuration.onlineOnly && (configuration.messagesPerSecond > 0 || configuration.scenario != nil) {
                try await startWorkloads(channels: slots.compactMap(\.channel))
            }
            if let scenario = configuration.scenario {
                if !configuration.onlineOnly { try await waitForRoomWarmup(scenario: scenario, statistics: statistics) }
                if configuration.recoveryBurst {
                    recoveryBurstReport = try await runRecoveryBurst(slots: slots, group: group,
                        sslContext: sslContext, statistics: statistics)
                    guard let burst = recoveryBurstReport,
                          burst.connectAuthenticated == burst.requestedConnections,
                          burst.cursorTargetUncompletedOrUnknownRooms == 0,
                          burst.offlineWritesFailed == 0, burst.offlineWritesAccepted == burst.offlineWritesRequested else { throw LoadError.unexpectedResponse }
                    if configuration.recoveryBurstOfflineMessagesPerRoom > 0 {
                        guard burst.cursorProgress.count == burst.expectedCursorRooms,
                              burst.cursorProgress.allSatisfy({ cursor in
                                  guard let injected = cursor.injectedThrough,
                                        let target = cursor.recoveryTarget,
                                        let applied = cursor.appliedSequence else { return false }
                                  return cursor.beforeSequence < injected && injected <= target && target <= applied && cursor.remainingGap == 0
                              }) else { throw LoadError.unexpectedResponse }
                    }
                }
                if configuration.plannedReconnectInflightCanary {
                    guard let slot = slots.first, let channel = slot.channel else { throw LoadError.unexpectedResponse }
                    let injectionStart = statistics.snapshot()
                    channel.pipeline.fireUserInboundEventTriggered(ScenarioSendEvent())
                    let heldDeadline = NIODeadline.now() + .seconds(15)
                    while statistics.snapshot().messageTransportEvents["CANARY_RECEIPT_HELD", default: 0] == 0 {
                        try enforceGuards(statistics: statistics)
                        guard NIODeadline.now() < heldDeadline else { throw LoadError.unexpectedResponse }
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                    // FIFO on the old event loop queues the second command before ownership transfer.
                    channel.pipeline.fireUserInboundEventTriggered(ScenarioSendEvent())
                    try await reconnect(slot: slot, group: group, sslContext: sslContext, statistics: statistics, requireInFlight: true)
                    let recoveryDeadline = NIODeadline.now() + .seconds(60)
                    while statistics.snapshot().messageTransportEvents["RECOVERED_AFTER_RECONNECT", default: 0] == 0
                        || statistics.snapshot().messagesAcknowledged < injectionStart.messagesAcknowledged + 2
                        || statistics.snapshot().queuedScenarioMessages != injectionStart.queuedScenarioMessages {
                        try enforceGuards(statistics: statistics)
                        guard NIODeadline.now() < recoveryDeadline else { throw LoadError.unexpectedResponse }
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                }
                try await awaitScenarioStartBarrier(scenario: scenario, statistics: statistics)
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

        // A canary checkpoint owns its actual event-loop probes through completion.
        // Signal shutdown instead of cancelling futures, before closing any channel.
        await checkpointWorker?.stopAndDrain()
        scenarioPhases = scenarioPhaseReports.snapshot()
        if configuration.onlineOnly {
            do { try await stopHeartbeats(channels: slots.compactMap(\.channel)) }
            catch { if terminalError == nil { terminalError = error } }
        }
        let finalConnectionSnapshots = await snapshotConnectionCursors(channels: slots.compactMap(\.channel))
        let roomCursorSnapshots = finalConnectionSnapshots.flatMap(\.rooms).sorted {
            ($0.connectionIndex, $0.roomID) < ($1.connectionIndex, $1.roomID)
        }
        let connectionCoverageSnapshots = finalConnectionSnapshots.map(\.coverage).sorted { $0.connectionIndex < $1.connectionIndex }
        await close(channels: slots.compactMap(\.channel))
        await directRoomTasks.closeAndDrain()
        eventLoopLagMetrics.stop()
        let eventLoopLag = eventLoopLagMetrics.snapshot()
        try await group.shutdownGracefully()
        let report = LoadReport(configuration: configuration, startedAt: startedAt, endedAt: Date(), state: statistics.snapshot(), eventLoopLag: eventLoopLag, messageSendCohorts: statistics.messageSendCohorts(), scenarioPhases: scenarioPhases, scenarioDrain: scenarioDrain, terminalError: terminalError, roomCursorSnapshots: roomCursorSnapshots, connectionCoverageSnapshots: connectionCoverageSnapshots, recoveryBurst: recoveryBurstReport)
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
        statistics: LoadStatistics,
        restoredCursors: [String: UInt64]? = nil,
        deadline: NIODeadline? = nil,
        attempt: RecoveryBurstAttempt? = nil,
        reconnectSlot: LoadConnectionSlot? = nil,
        reconnectSnapshot: LoadReconnectSnapshot? = nil
    ) -> EventLoopFuture<Channel> {
        statistics.recordAttempt()
        let eventLoop = group.next()
        let localAddress: SocketAddress?
        do {
            if let localSourcePorts {
                localAddress = try SocketAddress(ipAddress: "127.0.0.1", port: localSourcePorts.allocate())
            } else {
                localAddress = nil
            }
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        let authenticated = eventLoop.makePromise(of: Void.self)
        let started = NIODeadline.now()
        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(deadline.map { .nanoseconds(max(1, min(10_000_000_000, ($0 - .now()).nanoseconds))) } ?? .seconds(10))
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                attempt?.install(channel)
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSLClientHandler(context: sslContext, serverHostname: configuration.serverName)
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        LoadConnectionHandler(
                            credential: credential,
                            benchmarkWireVersion: configuration.benchmarkWireVersion,
                            accountHTTP: accountHTTP,
                            directRoomTasks: directRoomTasks,
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
                            roomNotificationLossCanary: configuration.roomNotificationLossCanary,
                            roomLogRecoveryGraceMilliseconds:
                                configuration.roomLogRecoveryGraceMilliseconds,
                            started: started,
                            authenticated: authenticated,
                            statistics: statistics, restoredCursors: reconnectSnapshot?.cursors ?? restoredCursors,
                            reconnectSlot: reconnectSlot, reconnectForegroundRoom: reconnectSnapshot?.foregroundRoom,
                            holdReceiptForCanary: configuration.plannedReconnectInflightCanary && connectionIndex == 0 && reconnectSlot == nil && restoredCursors == nil
                        )
                    )
                }
            }
        if let localAddress {
            // REUSEPORT permits different workers to bind concurrently before
            // their sockets have distinct connected four-tuples. REUSEADDR alone
            // still rejects that unconnected bind window on macOS.
            _ = bootstrap.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socketOption(NIOBSDSocket.Option(rawValue: SO_REUSEPORT)), value: 1)
                .bind(to: localAddress)
        }
        let connection = bootstrap.connect(host: configuration.host, port: configuration.port)

        // A TCP/TLS setup failure happens before LoadConnectionHandler owns the
        // authentication promise. Resolve that otherwise-unowned branch so a
        // failed ramp can shut its EventLoopGroup down without leaking promises.
        connection.cascadeFailure(to: authenticated)
        guard deadline != nil else {
            return connection.flatMap { channel in authenticated.futureResult.map { channel } }
        }
        return connection.flatMap { channel in
            attempt?.install(channel)
            let timeout = deadline.map { end in
                channel.eventLoop.scheduleTask(deadline: end) {
                    channel.close(promise: nil)
                }
            }
            return authenticated.futureResult.map { channel }.flatMapError { error in
                channel.close().flatMapError { _ in channel.eventLoop.makeSucceededFuture(()) }.flatMapThrowing { throw error }
            }.always { _ in timeout?.cancel() }
        }
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
            guard snapshot.active == configuration.connections else {
                throw LoadError.scenarioStartBarrierFailure("connection lost during room warmup")
            }
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

    private struct ScenarioReady: Encodable {
        let activeConnections: Int
        let requestedConnections: Int
    }
    private struct ScenarioStartBarrier: Decodable {
        let releaseAtUnixMilliseconds: Int64
    }

    /// No workload phase starts until all external workers have warmed their
    /// rooms and cursors. The driver's release timestamp is common wall time;
    /// the wait itself has a monotonic deadline and keeps the normal guards.
    private func awaitScenarioStartBarrier(scenario: LoadScenario, statistics: LoadStatistics) async throws {
        guard let readyPath = configuration.scenarioReadyPath,
              let barrierPath = configuration.scenarioStartBarrierPath else { return }
        let readyURL = URL(fileURLWithPath: readyPath)
        let barrierURL = URL(fileURLWithPath: barrierPath)
        guard !FileManager.default.fileExists(atPath: readyPath),
              !FileManager.default.fileExists(atPath: barrierPath) else {
            throw LoadError.scenarioStartBarrierFailure("ready or barrier path already exists")
        }
        let deadline = ContinuousClock.now + .seconds(min(600, max(60, scenario.roomWarmupTimeoutSeconds)))
        var publishedReady = false
        do {
            try Task.checkCancellation()
            try enforceGuards(statistics: statistics)
            let snapshot = statistics.snapshot()
            guard snapshot.active == configuration.connections else {
                throw LoadError.scenarioStartBarrierFailure("not all requested connections are active")
            }
            try FileManager.default.createDirectory(at: readyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ScenarioReady(activeConnections: snapshot.active,
                requestedConnections: configuration.connections)).write(to: readyURL, options: .atomic)
            publishedReady = true
            while !FileManager.default.fileExists(atPath: barrierPath) {
                try Task.checkCancellation()
                try enforceGuards(statistics: statistics)
                guard statistics.snapshot().active == configuration.connections else {
                    throw LoadError.scenarioStartBarrierFailure("connection lost while waiting")
                }
                guard ContinuousClock.now < deadline else { throw LoadError.scenarioStartBarrierFailure("release wait timed out") }
                try await Task.sleep(for: .milliseconds(50))
            }
            let bytes = try Data(contentsOf: barrierURL)
            guard bytes.count <= 1_024 else { throw LoadError.scenarioStartBarrierFailure("release descriptor oversized") }
            let release = try JSONDecoder().decode(ScenarioStartBarrier.self, from: bytes).releaseAtUnixMilliseconds
            let nowMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
            guard release > 0, release <= nowMilliseconds + 600_000 else {
                throw LoadError.scenarioStartBarrierFailure("release timestamp outside bounded wait")
            }
            while true {
                try Task.checkCancellation()
                try enforceGuards(statistics: statistics)
                guard statistics.snapshot().active == configuration.connections else {
                    throw LoadError.scenarioStartBarrierFailure("connection lost before release")
                }
                let remaining = release - Int64(Date().timeIntervalSince1970 * 1_000)
                if remaining <= 0 {
                    guard remaining >= -1_000 else { throw LoadError.scenarioStartBarrierFailure("release timestamp already stale") }
                    break
                }
                guard ContinuousClock.now < deadline else { throw LoadError.scenarioStartBarrierFailure("release wait timed out") }
                try await Task.sleep(for: .milliseconds(min(50, remaining)))
            }
        } catch {
            if publishedReady { try? FileManager.default.removeItem(at: readyURL) }
            throw error
        }
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
            let phaseClockStarted = ContinuousClock.now
            let phaseStartedAtUnixMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
            let started = statistics.snapshot()
            let phaseStarted = NIODeadline.now()
            try statistics.registerMessageCohort(name: phase.name, start: phaseStarted,
                end: phaseStarted + .seconds(Int64(phase.durationSeconds)))
            var completedTicks = 0
            var messageCarry = 0.0
            var roundRobinSendIndex = 0
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
                    for _ in 0..<messageCount {
                        let channel: Channel?
                        if phase.sendSelection == .roundRobin, !slots.isEmpty {
                            channel = slots[roundRobinSendIndex % slots.count].channel
                            roundRobinSendIndex += 1
                        } else {
                            channel = assignments.pick(kind: .send, random: &random)
                        }
                        channel?.pipeline.fireUserInboundEventTriggered(ScenarioSendEvent(
                            scheduledAt: phaseStarted + .nanoseconds(Int64(tick) * tickNanoseconds)))
                    }
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
                let ended = statistics.snapshot()
                let elapsed = phaseClockStarted.duration(to: .now).components
                let endedAtUnixMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
                reports.append(.init(
                    phase: phase,
                    rateScale: configuration.scenarioRateScale,
                    observedDurationSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000,
                    startedAtUnixMilliseconds: phaseStartedAtUnixMilliseconds,
                    endedAtUnixMilliseconds: endedAtUnixMilliseconds,
                    completed: false,
                    started: started,
                    ended: ended
                ))
                throw error
            }
            let ended = statistics.snapshot()
            let elapsed = phaseClockStarted.duration(to: .now).components
            let endedAtUnixMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
            reports.append(.init(
                phase: phase,
                rateScale: configuration.scenarioRateScale,
                observedDurationSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000,
                startedAtUnixMilliseconds: phaseStartedAtUnixMilliseconds,
                endedAtUnixMilliseconds: endedAtUnixMilliseconds,
                completed: true,
                started: started,
                ended: ended
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
        await snapshotConnectionCursors(channels: channels).flatMap(\.rooms).sorted {
            ($0.connectionIndex, $0.roomID) < ($1.connectionIndex, $1.roomID)
        }
    }
    private func snapshotConnectionCursors(channels: [Channel]) async -> [ConnectionCursorProbeSnapshot] {
        guard let first = channels.first else { return [] }
        let futures = channels.map { channel -> EventLoopFuture<ConnectionCursorProbeSnapshot?> in
            let promise = channel.eventLoop.makePromise(of: ConnectionCursorProbeSnapshot?.self)
            channel.eventLoop.execute {
                guard channel.isActive else { promise.succeed(nil); return }
                channel.pipeline.fireUserInboundEventTriggered(RoomCursorProbe(completion: promise))
            }
            return promise.futureResult
        }
        let values = (try? await EventLoopFuture.whenAllSucceed(futures, on: first.eventLoop).get()) ?? []
        return values.compactMap { $0 }
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
            // log pull for traffic sent by its neighbour. Fixed-rate workloads
            // use the configured forward target offset instead.
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

    /// One opt-in outage. Worker availability and actual start offsets are reported separately.
    private func runRecoveryBurst(slots: [LoadConnectionSlot], group: MultiThreadedEventLoopGroup,
                                  sslContext: NIOSSLContext, statistics: LoadStatistics) async throws -> RecoveryBurstReport {
        guard slots.count == configuration.connections,
              slots.allSatisfy({ $0.credential.targetRoomIDs?.count == configuration.targetsPerConnection })
        else { throw LoadError.invalidCredentialFile }
        let cursors = await snapshotRoomCursors(channels: slots.compactMap(\.channel))
        guard cursors.count == slots.count * configuration.targetsPerConnection else { throw LoadError.unexpectedResponse }
        let byConnection = Dictionary(grouping: cursors, by: \.connectionIndex)
        // Submit every close before awaiting any of them; all close futures are drained before release.
        let closes = slots.compactMap { slot -> EventLoopFuture<Void>? in
            guard let channel = slot.channel else { return nil }
            statistics.recordPlannedReconnect()
            return channel.close()
        }
        let closeResults = try await EventLoopFuture.whenAllComplete(closes, on: group.next()).get()
        for result in closeResults { try result.get() }
        let offline = try await injectOfflineRecoveryWrites(slots: slots, cursors: cursors)
        if configuration.recoveryBurstOfflineSeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(configuration.recoveryBurstOfflineSeconds) * 1_000_000_000)
        }
        let before = statistics.snapshot()
        let workers = min(configuration.recoveryBurstWorkers, slots.count)
        let barrier = RecoveryBurstBarrier(workers: workers)
        let samples = RecoveryBurstSamples(count: slots.count)
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            for _ in 0..<workers {
                tasks.addTask {
                    let origin = await barrier.arrive()
                    let deadline = origin + .seconds(Int64(configuration.recoveryBurstObserveSeconds))
                    while !Task.isCancelled, let index = samples.take() {
                        let slot = slots[index]
                        let restored = Dictionary(uniqueKeysWithValues: byConnection[slot.connectionIndex]!.map { ($0.roomID, $0.appliedRoomSequence) })
                        for ordinal in 1...configuration.recoveryBurstMaximumAttempts {
                            guard !Task.isCancelled, NIODeadline.now() < deadline else { break }
                            samples.started(index: index, offset: (NIODeadline.now() - origin).nanoseconds)
                            let attempt = RecoveryBurstAttempt()
                            do {
                                let channel = try await withTaskCancellationHandler {
                                    try await connect(credential: slot.credential, targetUserIDs: slot.targetUserIDs,
                                        connectionIndex: slot.connectionIndex, group: group, sslContext: sslContext,
                                        statistics: statistics, restoredCursors: restored, deadline: deadline, attempt: attempt).get()
                                } onCancel: { attempt.cancel() }
                                if Task.isCancelled || NIODeadline.now() >= deadline {
                                    _ = try? await channel.close().get()
                                    samples.failedAttempt()
                                    break
                                }
                                slot.replace(channel)
                                samples.succeeded(index: index)
                                channel.pipeline.fireUserInboundEventTriggered(StartWorkloadEvent())
                                break
                            } catch {
                                statistics.recordFailure(error)
                                samples.failedAttempt()
                                if ordinal < configuration.recoveryBurstMaximumAttempts {
                                    try await Task.sleep(nanoseconds: UInt64(100 + index % 100) * 1_000_000)
                                }
                            }
                        }
                    }
                }
            }
            try await tasks.waitForAll()
        }
        let origin = await barrier.origin()
        let remaining = (origin + .seconds(Int64(configuration.recoveryBurstObserveSeconds))) - .now()
        if remaining.nanoseconds > 0 { try await Task.sleep(nanoseconds: UInt64(remaining.nanoseconds)) }
        try Task.checkCancellation()
        let finalCursors = await snapshotRoomCursors(channels: slots.compactMap(\.channel))
        let verified = finalCursors.filter { $0.recoveryTarget != nil }
        // Only a subscription response establishes a target; a successful socket is not completion.
        let completed = finalCursors.filter { cursor in
            guard let target = cursor.recoveryTarget else { return false }
            return cursor.appliedRoomSequence >= target
        }.count
        let finalByConnection = Dictionary(grouping: finalCursors, by: \.connectionIndex)
        var injectedByRoom: [String: UInt64] = [:]
        for receipt in offline.result.receipts { injectedByRoom[receipt.roomID] = max(injectedByRoom[receipt.roomID] ?? 0, receipt.roomSequence) }
        let initial = Dictionary(uniqueKeysWithValues: cursors.map { ("\($0.connectionIndex):\($0.roomID)", $0.appliedRoomSequence) })
        let backlog = verified.filter { cursor in
            guard let start = initial["\(cursor.connectionIndex):\(cursor.roomID)"], let target = cursor.recoveryTarget else { return false }
            return target > start
        }.count
        return samples.report(workers: workers, barrierReleasedAt: await barrier.wallTime(), maximumAttempts: configuration.recoveryBurstMaximumAttempts,
            observationSeconds: configuration.recoveryBurstObserveSeconds, actualObservationMilliseconds: Double((NIODeadline.now() - origin).nanoseconds) / 1_000_000, offlineSeconds: configuration.recoveryBurstOfflineSeconds, before: before, after: statistics.snapshot(),
            expectedRooms: cursors.count, observedRooms: verified.count, backlogRooms: backlog, completedRooms: completed,
            offlineRequested: offline.requested, offlineResult: offline.result,
            cursorProgress: cursors.map { original in
                let recovered = finalByConnection[original.connectionIndex]?.first { $0.roomID == original.roomID }
                let injected = injectedByRoom[original.roomID]
                let target = recovered?.recoveryTarget
                let required = max(target ?? 0, injected ?? 0)
                return .init(connectionIndex: original.connectionIndex, roomID: original.roomID,
                    beforeSequence: original.appliedRoomSequence, appliedSequence: recovered?.appliedRoomSequence,
                    recoveryTarget: target, injectedThrough: injected,
                    remainingGap: recovered.map { required > $0.appliedRoomSequence ? required - $0.appliedRoomSequence : 0 })
            })
    }

    private func injectOfflineRecoveryWrites(slots: [LoadConnectionSlot], cursors: [RoomCursorSnapshot]) async throws -> (requested: Int, result: OfflineWriteResult) {
        let count = configuration.recoveryBurstOfflineMessagesPerRoom
        guard count > 0 else { return (0, .init(receipts: [], failed: 0)) }
        var owners: [String: LoadCredential] = [:]
        for slot in slots {
            guard slot.channel?.isActive != true else { throw LoadError.unexpectedResponse }
            for room in slot.credential.targetRoomIDs ?? [] where owners[room] == nil { owners[room] = slot.credential }
        }
        guard !owners.isEmpty, owners.count <= 100_000 / count else { throw LoadError.invalidArguments }
        var beforeByRoom: [String: UInt64] = [:]
        for cursor in cursors { beforeByRoom[cursor.roomID] = max(beforeByRoom[cursor.roomID] ?? 0, cursor.appliedRoomSequence) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(configuration.recoveryBurstOfflineWriteDeadlineSeconds))
        let raw = Date().timeIntervalSince1970 * 1000
        guard raw.isFinite, raw > 0, raw < Double(Int64.max) - 600_000 else { throw LoadError.invalidArguments }
        let frozenDeadline = UInt64(raw) + UInt64(configuration.recoveryBurstOfflineWriteDeadlineSeconds) * 1000
        let jobs = try owners.keys.sorted().map { room -> OfflineRoomWrite in
            let credential = owners[room]!
            let commands = try (0..<count).map { _ in
                try V2MessageSendOperationCommand(command: .init(roomID: .init(room), senderUserID: .init(credential.userID),
                    clientMessageID: .init(UUID().uuidString), text: String(repeating: "r", count: configuration.messageBytes),
                    limits: .init(maxUTF8Bytes: 65_536)), firstSubmissionDeadlineMilliseconds: frozenDeadline)
            }
            return .init(credential: credential, commands: commands)
        }
        let beforeSequenceByRoom = beforeByRoom
        let client = accountHTTP
        let result = await withTaskGroup(of: OfflineWriteResult.self) { tasks in
            var next = 0, receipts: [OfflineWriteReceipt] = [], failed = 0
            let workers = min(configuration.recoveryBurstOfflineWriteWorkers, jobs.count)
            func add(_ job: OfflineRoomWrite) {
                tasks.addTask {
                    var accepted: [OfflineWriteReceipt] = []
                    for command in job.commands {
                        do {
                            try Task.checkCancellation()
                            guard ContinuousClock.now < deadline else { throw LoadError.unexpectedResponse }
                            let value = try await withThrowingTaskGroup(of: V2MessageOperationAcceptance.self) { request in
                                request.addTask {
                                    guard case .accepted(let proof) = try await client.sendMessage(command,
                                        token: job.credential.accessToken, deviceID: job.credential.deviceID) else { throw LoadError.unexpectedResponse }
                                    return proof
                                }
                                request.addTask {
                                    try await Task.sleep(until: deadline, clock: .continuous)
                                    throw LoadError.unexpectedResponse
                                }
                                defer { request.cancelAll() }
                                guard let proof = try await request.next() else { throw LoadError.unexpectedResponse }
                                return proof
                            }
                            guard value.roomSequence > (beforeSequenceByRoom[command.command.roomID.rawValue] ?? 0) else { throw LoadError.unexpectedResponse }
                            accepted.append(.init(roomID: command.command.roomID.rawValue, roomSequence: value.roomSequence))
                        } catch { return .init(receipts: accepted, failed: job.commands.count - accepted.count) }
                    }
                    return .init(receipts: accepted, failed: 0)
                }
            }
            for _ in 0..<workers { add(jobs[next]); next += 1 }
            while let value = await tasks.next() {
                receipts.append(contentsOf: value.receipts); failed += value.failed
                if next < jobs.count { add(jobs[next]); next += 1 }
            }
            let sortedReceipts: [OfflineWriteReceipt] = receipts.sorted { (lhs: OfflineWriteReceipt, rhs: OfflineWriteReceipt) -> Bool in
                if lhs.roomID == rhs.roomID {
                    return lhs.roomSequence < rhs.roomSequence
                }
                return lhs.roomID < rhs.roomID
            }
            return OfflineWriteResult(receipts: sortedReceipts, failed: failed)
        }
        try Task.checkCancellation()
        return (jobs.count * count, result)
    }

    private func reconnect(
        slot: LoadConnectionSlot,
        group: MultiThreadedEventLoopGroup,
        sslContext: NIOSSLContext,
        statistics: LoadStatistics,
        requireInFlight: Bool = false
    ) async throws {
        guard let current = slot.channel else { throw LoadError.unexpectedResponse }
        let promise = current.eventLoop.makePromise(of: LoadReconnectSnapshot.self)
        current.pipeline.fireUserInboundEventTriggered(PrepareReconnectEvent(completion: promise, requireInFlight: requireInFlight))
        let snapshot = try await promise.futureResult.get()
        slot.installSnapshot(snapshot)
        statistics.recordPlannedReconnect()
        _ = try? await current.close().get()
        do {
            let channel = try await connect(credential: slot.credential, targetUserIDs: slot.targetUserIDs,
                connectionIndex: slot.connectionIndex, group: group, sslContext: sslContext,
                statistics: statistics, reconnectSlot: slot, reconnectSnapshot: snapshot).get()
            slot.replace(channel)
            channel.pipeline.fireUserInboundEventTriggered(StartWorkloadEvent())
        } catch {
            if let unclaimed = slot.takeSnapshot() {
                for _ in unclaimed.operations {
                    statistics.recordMessageTransportEvent("OUTCOME_UNKNOWN")
                    statistics.recordWorkloadFailure(kind: "message", code: "TCP_OUTCOME_UNKNOWN_RECONNECT_FAILED")
                }
                statistics.recordScenarioMessageQueueAbandoned(count: unclaimed.queued)
            }
            throw error
        }
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

    private func stopHeartbeats(channels: [Channel]) async throws {
        guard let first = channels.first else { return }
        let futures = channels.map { channel in
            let promise = channel.eventLoop.makePromise(of: Void.self)
            channel.eventLoop.execute {
                if channel.isActive { channel.pipeline.fireUserInboundEventTriggered(StopHeartbeatEvent(completion: promise)) }
                else { promise.succeed(()) }
            }
            return promise.futureResult
        }
        // Drain every actual pending heartbeat before starting planned disconnects.
        let results = try await EventLoopFuture.whenAllComplete(futures, on: first.eventLoop).get()
        for result in results { _ = try result.get() }
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
private struct StopHeartbeatEvent: Sendable { let completion: EventLoopPromise<Void> }
private struct ScenarioSendEvent: Sendable {
    let scheduledAt: NIODeadline
    init(scheduledAt: NIODeadline = .now()) { self.scheduledAt = scheduledAt }
}
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
    let recoveryTarget: UInt64?
    let activeForeground: Bool
    let announcedHighWatermark: UInt64
    let pullInFlight: Bool
    let pullSlotReserved: Bool
    let pendingPullRequestID: UInt64?
    let pendingPullRequestedAfter: UInt64?
    let retryPending: Bool
    let gracePending: Bool
    let lastAcceptedHintHighWatermark: UInt64?
    let lastAcceptedHintRoomSequence: UInt64?
    let lastAcceptedHintAtUnixMilliseconds: Int64?
    let lastAcceptedHintAgeMilliseconds: Double?
    let lastAcceptedProgressHighWatermark: UInt64?
    let lastAcceptedProgressAtUnixMilliseconds: Int64?
    let snapshotAtUnixMilliseconds: Int64
    let snapshotMonotonicNanoseconds: UInt64
}

private struct AcceptedRoomHintWitness {
    let highWatermark: UInt64
    let roomSequence: UInt64
    let atUnixMilliseconds: Int64
    let monotonicAt: NIODeadline
}

private struct RequestedScopeCoverageSnapshot: Encodable, Sendable {
    let scope: String
    let scopeID: String
    let scopeGeneration: UInt64?
    let revision: UInt64?
    let state: String
    let highWatermark: UInt64?
    let appliedCursor: UInt64
    let passed: Bool
    let reason: String?
    let observedAtUnixMilliseconds: Int64?
    let lastReadyAtUnixMilliseconds: Int64?
    let lastReadyGeneration: UInt64?
}
private struct IgnoredCoverageFrameSnapshot: Encodable, Sendable {
    let rejection: String
    let scope: Int
    let scopeID: String
    let generation: UInt64
    let revision: UInt64
    let state: Int
    let reason: Int
    let observedAtUnixMilliseconds: Int64
}
private struct ServerRoomProgressSnapshot: Encodable, Sendable {
    let ready: Bool
    let generation: UInt64
    let highWatermark: UInt64
    let appliedRoomSequence: UInt64
    let observedAtUnixMilliseconds: Int64
}
private struct ConnectionCoverageSnapshot: Encodable, Sendable {
    let connectionIndex: Int
    let physicalConnectionID: UUID
    let localSourcePort: Int?
    let remoteGatewayPort: Int?
    let lastHeartbeatRequestID: UInt64?
    let lastHeartbeatClientTimeMilliseconds: UInt64?
    let wireVersion: UInt32
    let requestedScopes: [RequestedScopeCoverageSnapshot]
    let ignoredCoverageFrames: Int
    let ignoredCoverageReasons: [String: Int]
    let lastIgnoredCoverageFrame: IgnoredCoverageFrameSnapshot?
    let lastServerRoomProgress: ServerRoomProgressSnapshot?
    let heartbeatSent: Int
    let heartbeatAcknowledged: Int
    let heartbeatMissed: Int
    let snapshotAtUnixMilliseconds: Int64
    let passed: Bool
}
private struct ConnectionCursorProbeSnapshot: Sendable {
    let rooms: [RoomCursorSnapshot]
    let coverage: ConnectionCoverageSnapshot
}
private struct RoomCursorProbe {
    let completion: EventLoopPromise<ConnectionCursorProbeSnapshot?>
}
private struct ObservedScopeCoverage {
    let generation: UInt64
    let revision: UInt64
    let state: String
    let highWatermark: UInt64
    let reason: String
    let observedAtUnixMilliseconds: Int64
    let lastReadyAtUnixMilliseconds: Int64?
    let lastReadyGeneration: UInt64?
}

/// Immutable worklog; ownership moves from old event loop to slot to authenticated handler.
private struct LoadMessageSnapshot: Sendable {
    let command: V2MessageSendOperationCommand
    let identity: V2OperationIdentity
    let fingerprint: V2OperationFingerprint
    let sent: NIODeadline
    let scheduledAt: NIODeadline
    let deadline: NIODeadline
    let attempts: Int
}
private struct LoadReconnectSnapshot: Sendable {
    let operations: [LoadMessageSnapshot]
    let queuedStarts: [NIODeadline]
    var queued: Int { queuedStarts.count }
    let cursors: [String: UInt64]
    let foregroundRoom: String?
}
private struct PrepareReconnectEvent {
    let completion: EventLoopPromise<LoadReconnectSnapshot>
    let requireInFlight: Bool
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
    private var reconnectSnapshot: LoadReconnectSnapshot?

    init(credential: LoadCredential, targetUserIDs: [String], connectionIndex: Int) {
        self.credential = credential
        self.targetUserIDs = targetUserIDs
        self.connectionIndex = connectionIndex
    }

    var channel: Channel? { lock.withLock { currentChannel } }

    func installSnapshot(_ snapshot: LoadReconnectSnapshot) {
        lock.withLock { precondition(reconnectSnapshot == nil); reconnectSnapshot = snapshot }
    }
    func takeSnapshot() -> LoadReconnectSnapshot? {
        lock.withLock { let result = reconnectSnapshot; reconnectSnapshot = nil; return result }
    }
    func replace(_ channel: Channel) {
        lock.withLock { currentChannel = channel }
    }
}

private struct RealtimeCheckpointRequest: Decodable {
    let nonce: UUID
    let requestedAtUnixMilliseconds: Int64
    let connectionIndices: [Int]?
    func selectedIndices(requested: Int) -> [Int]? {
        if let indices = connectionIndices {
            guard !indices.isEmpty, indices.count <= 32, Set(indices).count == indices.count,
                  indices.allSatisfy({ $0 >= 0 && $0 < requested }) else { return nil }
            return indices
        }
        guard requested <= 500 else { return nil }
        return Array(0..<requested)
    }
}
private struct RealtimeCheckpointSlot: Encodable, Sendable {
    let connectionIndex: Int
    let state: String
    let physicalConnectionID: UUID?
    let coverage: ConnectionCoverageSnapshot?
    let rooms: [RoomCursorSnapshot]
}
private struct RealtimeCheckpointReport: Encodable {
    let nonce: UUID
    let requestedAtUnixMilliseconds: Int64
    let samplingStartedAtUnixMilliseconds: Int64
    let samplingCompletedAtUnixMilliseconds: Int64
    let requestedConnections: Int
    let selectedConnectionIndices: [Int]
    let diagnosticFailureCode: String?
    let slots: [RealtimeCheckpointSlot]
}
private final class RealtimeCheckpointStop: Sendable { let closed = Mutex(false) }

/// One optional, owned canary worker. Sampling reads existing handler state on
/// each physical channel's EL, with no protocol traffic or workload mutations.
private struct RealtimeCheckpointWorker: Sendable {
    private let closedPath: String
    private let stop: RealtimeCheckpointStop
    private let task: Task<Void, Never>
    init(slots: [LoadConnectionSlot], requested: Int, requestPath: String, responsePath: String) {
        let stop = RealtimeCheckpointStop(); self.stop = stop
        closedPath = responsePath + ".closed"
        task = Task {
            var lastNonce: UUID?
            var diagnosticFailed = false
            while !stop.closed.withLock({ $0 }) {
                do {
                    if FileManager.default.fileExists(atPath: requestPath) {
                        let attributes = try FileManager.default.attributesOfItem(atPath: requestPath)
                        guard let size = attributes[.size] as? NSNumber, size.intValue > 0,
                              size.intValue <= 4096 else { throw LoadError.invalidArguments }
                        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: requestPath))
                        let data: Data
                        do { data = try file.read(upToCount: 4097) ?? Data(); try file.close() }
                        catch { try? file.close(); throw error }
                        guard data.count <= 4096 else { throw LoadError.invalidArguments }
                        let request = try JSONDecoder().decode(RealtimeCheckpointRequest.self, from: data)
                        guard request.requestedAtUnixMilliseconds > 0 else { throw LoadError.invalidArguments }
                        if request.nonce != lastNonce {
                            let started = Self.wallMilliseconds()
                            let selected = request.selectedIndices(requested: requested)
                            let snapshots = await Self.snapshot(slots: slots, indices: selected ?? [])
                            let report = RealtimeCheckpointReport(nonce: request.nonce,
                                requestedAtUnixMilliseconds: request.requestedAtUnixMilliseconds,
                                samplingStartedAtUnixMilliseconds: started,
                                samplingCompletedAtUnixMilliseconds: Self.wallMilliseconds(),
                                requestedConnections: requested, selectedConnectionIndices: selected ?? [],
                                diagnosticFailureCode: selected == nil ? "invalid_connection_indices" : nil, slots: snapshots)
                            try JSONEncoder.loadReport.encode(report).write(to: URL(fileURLWithPath: responsePath), options: .atomic)
                            lastNonce = request.nonce
                        }
                        diagnosticFailed = false
                    }
                } catch {
                    // Diagnostic failure never replaces the workload's original
                    // outcome; the requesting runner observes a missing response.
                    if !diagnosticFailed { print("checkpoint diagnostic failed type=\(type(of: error))") }
                    diagnosticFailed = true
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
    }
    func stopAndDrain() async {
        stop.closed.withLock { $0 = true }
        await task.value
        // Written before the caller begins its final channel snapshot/closure.
        // It is diagnostic only: a file failure cannot change workload results.
        do {
            let data = try JSONEncoder().encode(["checkpointStoppedAtUnixMilliseconds": Self.wallMilliseconds()])
            try data.write(to: URL(fileURLWithPath: closedPath), options: .atomic)
        } catch {
            print("checkpoint closure diagnostic failed")
            fflush(nil) // Publish the diagnostic before the caller closes channels.
        }
    }
    private static func wallMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
    private static func snapshot(slots: [LoadConnectionSlot], indices: [Int]) async -> [RealtimeCheckpointSlot] {
        let selected = Set(indices)
        let channels = slots.filter { selected.contains($0.connectionIndex) }.compactMap { slot in slot.channel.map { (slot.connectionIndex, $0) } }
        guard let first = channels.first else {
            return indices.map { .init(connectionIndex: $0, state: "missing", physicalConnectionID: nil, coverage: nil, rooms: []) }
        }
        let futures = channels.map { index, channel -> EventLoopFuture<RealtimeCheckpointSlot> in
            let promise = channel.eventLoop.makePromise(of: ConnectionCursorProbeSnapshot?.self)
            channel.eventLoop.execute {
                guard channel.isActive else { promise.succeed(nil); return }
                channel.pipeline.fireUserInboundEventTriggered(RoomCursorProbe(completion: promise))
            }
            return promise.futureResult.map { snapshot in
                .init(connectionIndex: index, state: snapshot == nil ? "inactive" : "active",
                    physicalConnectionID: snapshot?.coverage.physicalConnectionID, coverage: snapshot?.coverage,
                    rooms: snapshot?.rooms ?? [])
            }
        }
        let results = (try? await EventLoopFuture.whenAllComplete(futures, on: first.1.eventLoop).get()) ?? []
        var observed: [Int: RealtimeCheckpointSlot] = [:]
        for (entry, result) in zip(channels, results) {
            if case .success(let snapshot) = result { observed[entry.0] = snapshot }
        }
        // Include every requested slot, even failed bootstrap and absent/inactive
        // channels. The runner must reject missing evidence instead of filtering.
        return indices.map { observed[$0] ?? .init(connectionIndex: $0, state: "missing", physicalConnectionID: nil, coverage: nil, rooms: []) }
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
    // SHA256 of this exact common algorithm source with the hash literal normalized.
    static let algorithmSourceSHA256 = "a594a51032769acc47c66b7a92b85c2dddb8371386a42271224096accd653071"
    static let messageAttemptTimeoutSeconds: Int64 = 20
    static let messageOperationTimeoutSeconds: Int64 = 60
    static let maximumMessageWireAttempts = 5
    static var messageTransportDescription: String {
        """
        {"contractVersion":3,"supportedBenchmarkWireVersions":[45,\(IMV2ProtocolVersion.current)],"defaultWireVersion":\(IMV2ProtocolVersion.current),"algorithmSourceSHA256":"\(algorithmSourceSHA256)","plannedReconnectHandoff":true,"messageTransport":"tcp","messageRecoveryTransport":"tcp_query","messageAttemptTimeoutSeconds":\(messageAttemptTimeoutSeconds),"messageOperationTimeoutSeconds":\(messageOperationTimeoutSeconds),"messageMaximumAttempts":\(maximumMessageWireAttempts)}
        """
    }
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Stage { case awaitingHello, awaitingAuthentication, authenticated }
    private enum PendingRequest {
        case heartbeat(sent: NIODeadline)
        case message(operationID: UInt64)
        case syncPull(sent: NIODeadline)
        case roomEventPull(sent: NIODeadline, roomID: String, afterRoomSequence: UInt64)
        case roomEventSubscribe(roomID: String)
        case readReceipt(sent: NIODeadline, roomID: String, roomSequence: UInt64)
        case recovery(kind: RecoveryBatchKind, sent: NIODeadline, roomIDs: [String])
        case syncAck(hasMore: Bool)
    }

    private let directRoomTasks: DirectRoomHTTPTaskOwner
    private var directRoomTaskIDs: Set<UUID> = []
    private let accountHTTP: V2ToolOperationHTTP
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
    private let roomNotificationLossCanary: Bool
    private let roomLogRecoveryGraceMilliseconds: Int
    private let started: NIODeadline
    private let authenticatedPromise: EventLoopPromise<Void>
    private let statistics: LoadStatistics
    private let benchmarkWireVersion: UInt32
    private let limits: V2FrameLimits
    private var decoder: V2FrameDecoder
    private var negotiatedFrameCompression: V2NegotiatedFrameCompression?
    private var negotiatedMessagePayloadBytes: UInt32?
    private enum MessageWireAction: Equatable { case submit, query, close }

    private final class MessageOperation {
        let command: V2MessageSendOperationCommand
        let identity: V2OperationIdentity
        let fingerprint: V2OperationFingerprint
        let sent: NIODeadline
        let scheduledAt: NIODeadline
        let deadline: NIODeadline
        var attempts = 0
        var restoredAfterReconnect = false
        var wireRequestID: UInt64?
        var lastWireAction: MessageWireAction = .submit
        var timer: Scheduled<Void>?
        init(snapshot: LoadMessageSnapshot) {
            command = snapshot.command; identity = snapshot.identity; fingerprint = snapshot.fingerprint
            sent = snapshot.sent; scheduledAt = snapshot.scheduledAt
            deadline = snapshot.deadline; attempts = snapshot.attempts
            restoredAfterReconnect = true
        }
        init(command: V2MessageSendOperationCommand, sent: NIODeadline, scheduledAt: NIODeadline) throws {
            self.command = command; identity = try command.identity; fingerprint = try command.fingerprint
            self.sent = sent; self.scheduledAt = scheduledAt
            deadline = sent + .seconds(LoadConnectionHandler.messageOperationTimeoutSeconds)
        }
    }
    private let reconnectSlot: LoadConnectionSlot?
    private let reconnectForegroundRoom: String?
    private var holdReceiptForCanary: Bool
    private var handoffPrepared = false
    private var restoredMessagesNeedResume = false
    private var messageOperations: [UInt64: MessageOperation] = [:]
    private var stage: Stage = .awaitingHello
    private var nextRequestID: UInt64 = 3
    private var pendingRequests: [UInt64: PendingRequest] = [:]
    private var heartbeatRequestID: UInt64?
    private var messageRequestIDs: Set<UInt64> = []
    private var queuedScenarioMessageStarts = CircularBuffer<NIODeadline>()
    private var queuedScenarioMessages: Int { queuedScenarioMessageStarts.count }
    private var directRoomIDs: [String] = []
    private var nextRoomIndex = 0
    private var nextSyncToken = ""
    // Bound to this actual handler/physical channel, never transferred on reconnect.
    private let physicalConnectionID = UUID()
    private var localSourcePort: Int?
    private var remoteGatewayPort: Int?
    private var lastHeartbeatRequestID: UInt64?
    private var lastHeartbeatClientTimeMilliseconds: UInt64?
    private var checkpointHeartbeatSent = 0
    private var checkpointHeartbeatAcknowledged = 0
    private var checkpointHeartbeatMissed = 0
    private var requestedAccountCoverage = false
    private var requestedRoomCoverageID: String?
    private var accountAppliedCursor: UInt64 = 0
    private var observedCoverage: [String: ObservedScopeCoverage] = [:]
    private var coverageRevisions: [String: UInt64] = [:]
    private var ignoredCoverageFrames = 0
    // Bounded passive witnesses only. They never authorize a scope or trigger recovery.
    private var ignoredCoverageReasons: [String: Int] = [:]
    private var lastIgnoredCoverageFrame: IgnoredCoverageFrameSnapshot?
    private var lastServerRoomProgress: ServerRoomProgressSnapshot?
    private enum SyncActionKind { case pull, acknowledgement(hasMore: Bool) }
    private final class SyncAttempt {
        let id = UUID()
        let request: IMV2Envelope
        let kind: SyncActionKind
        let started: NIODeadline
        let deadline: NIODeadline
        var attempts = 0
        var wireRequestID: UInt64?
        var timer: Scheduled<Void>?
        init(request: IMV2Envelope, kind: SyncActionKind) {
            self.request = request; self.kind = kind
            started = .now(); deadline = started + .seconds(10)
        }
    }
    private var syncAttempt: SyncAttempt?
    private var pendingSyncAcknowledgement: (IMV2Envelope, Bool)?
    private var syncInFlight = false
    private var syncRequested = false
    private var roomEventCursors: [String: UInt64] = [:]
    private var roomEventLiveSequences: [String: V2LoadRoomLiveSequences] = [:]
    private var roomEventAcceptedSequences: [String: V2LoadRoomAcceptedSequences] = [:]
    private let isRestoredRecovery: Bool
    private var restoredRecoveryTargets: [String: UInt64] = [:]
    private var roomEventAnnouncedHighWatermarks: [String: UInt64] = [:]
    // Diagnostic history is bounded by this handler's opened foreground rooms.
    // It never creates a recovery target or changes an applied cursor.
    private var acceptedRoomHintWitnesses: [String: AcceptedRoomHintWitness] = [:]
    private var acceptedRoomProgressWitnesses: [String: (highWatermark: UInt64, at: Int64)] = [:]
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
    private var heartbeatStopping = false
    private var heartbeatDrain: EventLoopPromise<Void>?
    private var heartbeatDrainTimeout: Scheduled<Void>?
    private var messageTask: RepeatedTask?
    private var authenticationCompleted = false
    private var registered = false
    private var workloadStarted = false

    init(
        credential: LoadCredential,
        benchmarkWireVersion: UInt32,
        accountHTTP: V2ToolOperationHTTP,
        directRoomTasks: DirectRoomHTTPTaskOwner,
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
        roomNotificationLossCanary: Bool = false,
        roomLogRecoveryGraceMilliseconds: Int,
        started: NIODeadline,
        authenticated: EventLoopPromise<Void>,
        statistics: LoadStatistics,
        restoredCursors: [String: UInt64]? = nil,
        reconnectSlot: LoadConnectionSlot? = nil,
        reconnectForegroundRoom: String? = nil,
        holdReceiptForCanary: Bool = false
    ) {
        self.benchmarkWireVersion = benchmarkWireVersion
        limits = try! V2FrameLimits(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(benchmarkWireVersion)])
        self.reconnectSlot = reconnectSlot
        self.reconnectForegroundRoom = reconnectForegroundRoom
        self.holdReceiptForCanary = holdReceiptForCanary
        isRestoredRecovery = restoredCursors != nil
        roomEventCursors = restoredCursors ?? [:]
        self.directRoomTasks = directRoomTasks
        self.accountHTTP = accountHTTP
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
        self.roomNotificationLossCanary = roomNotificationLossCanary
        self.roomLogRecoveryGraceMilliseconds = roomLogRecoveryGraceMilliseconds
        self.started = started
        authenticatedPromise = authenticated
        self.statistics = statistics
        decoder = .init(limits: limits)
    }

    func channelActive(context: ChannelHandlerContext) {
        localSourcePort = context.channel.localAddress?.port
        remoteGatewayPort = context.channel.remoteAddress?.port
        do {
            var hello = IMV2Envelope()
            hello.requestID = 1
            hello.clientHello = .init()
            hello.clientHello.supportedProtocolVersions = [benchmarkWireVersion]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            hello.clientHello.deviceID = credential.deviceID
            hello.clientHello.supportedFrameCompressions = [.zlib]
            hello.clientHello.supportsMessageSendOperations = true
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
                statistics.recordProtocolFailure(error)
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
        if heartbeatDrain != nil {
            statistics.recordHeartbeatMissed()
            checkpointHeartbeatMissed += 1
            finishHeartbeatDrain(.failure(LoadError.connectionClosed))
        }
        for id in directRoomTaskIDs { directRoomTasks.cancel(id: id) }
        directRoomTaskIDs.removeAll()
        for (operationID, operation) in messageOperations {
            operation.timer?.cancel()
            if let requestID = operation.wireRequestID { pendingRequests.removeValue(forKey: requestID) }
            messageRequestIDs.remove(operationID)
            statistics.recordMessageTransportEvent("OUTCOME_UNKNOWN_CONNECTION_CLOSED")
            statistics.recordWorkloadFailure(kind: "message", code: "TCP_OUTCOME_UNKNOWN_CONNECTION_CLOSED")
        }
        messageOperations.removeAll(keepingCapacity: false)
        heartbeatTask?.cancel()
        messageTask?.cancel()
        for task in roomEventPullRetryTasks.values { task.cancel() }
        roomEventPullRetryTasks.removeAll(keepingCapacity: false)
        for task in roomEventRecoveryGraceTasks.values { task.cancel() }
        roomEventRecoveryGraceTasks.removeAll(keepingCapacity: false)
        roomEventLiveSequences.removeAll(keepingCapacity: false)
        statistics.recordScenarioMessageQueueAbandoned(count: queuedScenarioMessages)
        queuedScenarioMessageStarts.removeAll(keepingCapacity: false)
        readReceiptInFlightRooms.removeAll(keepingCapacity: false)
        readReceiptPendingSequences.removeAll(keepingCapacity: false)
        recoveryDeadlineTask?.cancel()
        recoveryDeadlineTask = nil
        recoveryInFlightRequestID = nil
        if syncAttempt != nil { statistics.recordSyncLogicalFailure() }
        syncAttempt?.timer?.cancel()
        syncAttempt = nil
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
        do { try receive(envelope: envelope, frame: frame, context: context) }
        catch {
            guard case .unexpectedResponse? = error as? LoadError else { throw error }
            let code: String?
            if case .error(let rejection)? = envelope.body { code = rejection.code } else { code = nil }
            throw LoadError.unexpectedServerResponse(errorCode: code,
                messageType: loadResponseKind(envelope.body), requestID: frame.requestID)
        }
    }

    private func receive(envelope: IMV2Envelope, frame: V2Frame, context: ChannelHandlerContext) throws {
        if frame.requestID == 0 {
            guard case .authenticated = stage else { return }
            switch envelope.body {
            case .realtimeCoverage(let coverage):
                statistics.recordRealtimeCoverage(coverage)
                observeCoverage(coverage)
                return
            case .syncAvailable:
                guard syncReads, !targetUserIDs.isEmpty else { return }
                syncRequested = true
                try startSyncIfNeeded(context: context)
            case .groupEventAvailable(let hint):
                guard roomLogReads, roomLogReadTrigger == .availabilityHint,
                      hint.roomID == activeRoomLogRoomID
                else { return }
                if roomNotificationLossCanary {
                    // Fault injection drops the actual foreground notification
                    // before either its H or optional body affects this device.
                    statistics.recordRoomNotificationDiscarded()
                    return
                }
                acceptedRoomHintWitnesses[hint.roomID] = .init(highWatermark: hint.highWatermark,
                    roomSequence: hint.roomSequence,
                    atUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000), monotonicAt: .now())
                let previous = roomEventAnnouncedHighWatermarks[hint.roomID, default: 0]
                roomEventAnnouncedHighWatermarks[hint.roomID] = max(previous, hint.highWatermark)
                statistics.recordRoomEventAvailabilityHint()
                if !hint.liveEvents.isEmpty {
                    for event in hint.liveEvents {
                        guard event.roomSequence > 0, event.roomSequence <= hint.highWatermark,
                              event.roomSequence <= UInt64(Int64.max),
                              !event.sourceEventID.isEmpty, !event.projectionKind.isEmpty,
                              !event.payload.isEmpty else { continue }
                        receiveRoomLiveSequence(event.roomSequence, roomID: hint.roomID)
                    }
                } else if hint.roomSequence > 0, hint.roomSequence <= hint.highWatermark,
                          hint.roomSequence <= UInt64(Int64.max),
                          !hint.sourceEventID.isEmpty, !hint.projectionKind.isEmpty,
                          !hint.eventPayload.isEmpty {
                    receiveRoomLiveSequence(hint.roomSequence, roomID: hint.roomID)
                }
                cancelRoomEventRecoveryGraceIfCaughtUp(roomID: hint.roomID)
                try acceptRoomRecoveryTarget(roomID: hint.roomID, highWatermark: hint.highWatermark,
                    context: context, recordMetadataGap: true)
            default:
                break
            }
            return
        }
        switch stage {
        case .awaitingHello:
            guard frame.requestID == 1,
                  case .serverHello(let response)? = envelope.body,
                  response.selectedProtocolVersion == benchmarkWireVersion
            else {
                FileHandle.standardError.write(Data(
                    "protocol mismatch expected=server_hello request_match=\(frame.requestID == 1) actual=\(loadResponseKind(envelope.body))\n".utf8
                ))
                throw LoadError.unexpectedResponse
            }
            guard response.supportsMessageSendOperations, response.maximumMessageSendPayloadBytes > 0,
                  response.maximumMessageSendPayloadBytes >= UInt32(messageText.utf8.count) else {
                throw LoadError.messageSendNegotiationFailed
            }
            negotiatedMessagePayloadBytes = response.maximumMessageSendPayloadBytes
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
            authenticate.protocolVersion = benchmarkWireVersion
            authenticate.authenticate = .init()
            authenticate.authenticate.accessToken = credential.accessToken
            authenticate.authenticate.deviceID = credential.deviceID
            try write(authenticate, frameVersion: UInt8(benchmarkWireVersion), context: context)

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
            guard response.supportsMessageSendOperations,
                  response.maximumMessageSendPayloadBytes == negotiatedMessagePayloadBytes else {
                throw LoadError.messageSendNegotiationFailed
            }
            statistics.recordMessageSendNegotiated(payloadLimit: response.maximumMessageSendPayloadBytes)
            stage = .authenticated
            authenticationCompleted = true
            requestedAccountCoverage = true
            registered = true
            statistics.recordAuthenticated(milliseconds: (NIODeadline.now() - started).millisecondsDouble)
            if let snapshot = reconnectSlot?.takeSnapshot() {
                queuedScenarioMessageStarts = CircularBuffer(snapshot.queuedStarts)
                for _ in 0..<snapshot.queued { statistics.recordMessageTransportEvent("RESTORED_QUEUE") }
                for entry in snapshot.operations {
                    let id = takeRequestID()
                    messageOperations[id] = MessageOperation(snapshot: entry)
                    messageRequestIDs.insert(id)
                    statistics.recordMessageTransportEvent("RESTORED")
                }
                restoredMessagesNeedResume = true
            }
            authenticatedPromise.succeed(())
            scheduleHeartbeat(context: context)

        case .authenticated:
            if holdReceiptForCanary,
               case .message(let id)? = pendingRequests[frame.requestID],
               let operation = messageOperations[id], operation.wireRequestID == frame.requestID,
               case .messageSendOperationResult(let wire)? = envelope.body,
               case .receipt(let receipt) = try V2MessageSendOperationWireCodec.decode(result: wire),
               receipt.validates(identity: operation.identity, fingerprint: operation.fingerprint),
               case .accepted = receipt.outcome {
                // Explicit canary fault: lose one authentic ACK, retain its worklog for reconnection.
                holdReceiptForCanary = false
                statistics.recordMessageTransportEvent("CANARY_RECEIPT_HELD")
                return
            }
            guard let pending = pendingRequests.removeValue(forKey: frame.requestID) else {
                if case .messageSendOperationResult? = envelope.body { statistics.recordMessageTransportEvent("LATE_RESPONSE") }
                return
            }
            if case .error(let error)? = envelope.body {
                try handleRejected(
                    pending,
                    requestID: frame.requestID,
                    code: error.code,
                    retryable: error.retryable,
                    retryAfterSeconds: error.retryAfterSeconds,
                    context: context
                )
                return
            }
            switch pending {
            case .heartbeat(let sent):
                heartbeatRequestID = nil
                guard case .heartbeatAck(let acknowledgement)? = envelope.body else { throw LoadError.unexpectedResponse }
                try receiveRoomProgressStates(acknowledgement.roomSubscriptionStates, context: context)
                checkpointHeartbeatAcknowledged += 1
                statistics.recordHeartbeatAcknowledged(milliseconds: (NIODeadline.now() - sent).millisecondsDouble)
                finishHeartbeatDrain(.success(()))

            case .message(let operationID):
                guard let operation = messageOperations[operationID], operation.wireRequestID == frame.requestID,
                      case .messageSendOperationResult(let wire)? = envelope.body else { throw LoadError.unexpectedResponse }
                operation.timer?.cancel(); operation.timer = nil; operation.wireRequestID = nil
                try receiveMessageResult(V2MessageSendOperationWireCodec.decode(result: wire), operationID: operationID, context: context)

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
                settleSyncWireResponse(frame.requestID)
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
                accountAppliedCursor = max(accountAppliedCursor, highestSequence)
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
                    roomEventCursors[roomID] = drainAcceptedRoomSequences(roomID: roomID, through: page.nextRoomSequence)
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
                guard case .authenticated = stage, context.channel.isActive else { return }
                guard case .groupEventSubscribed(let subscription)? = envelope.body else {
                    FileHandle.standardError.write(Data(
                        "protocol mismatch expected=group_event_subscribed actual=\(loadResponseKind(envelope.body))\n".utf8
                    ))
                    throw LoadError.unexpectedResponse
                }
                guard subscription.roomID == roomID,
                      roomEventCursorSubscriptionInFlightRoom == roomID,
                      requestedRoomCoverageID == roomID
                else {
                    FileHandle.standardError.write(Data(
                        "protocol mismatch expected=group_event_subscribed room_match=\(subscription.roomID == roomID) pending_match=\(roomEventCursorSubscriptionInFlightRoom == roomID)\n".utf8
                    ))
                    throw LoadError.unexpectedResponse
                }
                activeRoomLogRoomID = roomID
                if isRestoredRecovery {
                    if restoredRecoveryTargets[roomID] == nil { restoredRecoveryTargets[roomID] = subscription.highWatermark }
                }
                if roomLogInitialCursor == .tail && !isRestoredRecovery {
                    roomEventCursors[roomID] = drainAcceptedRoomSequences(roomID: roomID, through: max(
                        roomEventCursors[roomID, default: 0], subscription.highWatermark
                    ))
                }
                // A subscription reply can trail a newer hint or accepted ACK.
                // Its snapshot coalesces with this handler's current scope; it
                // cannot revoke an announced target or rewind an applied cursor.
                roomEventAnnouncedHighWatermarks[roomID] = max(
                    roomEventAnnouncedHighWatermarks[roomID, default: 0],
                    max(roomEventCursors[roomID, default: 0], subscription.highWatermark)
                )
                roomEventCursorSubscriptionInFlightRoom = nil
                roomEventCursorSubscriptionRetryCounts.removeValue(forKey: roomID)
                if roomLogInitialCursor == .zero || isRestoredRecovery
                    || roomEventAnnouncedHighWatermarks[roomID, default: 0]
                        > roomEventCursors[roomID, default: 0] {
                    try sendRoomEventPullIfNeeded(roomID: roomID, context: context)
                }
                try sendNextRoomEventCursorSubscriptionOrScheduleMessages(context: context)

            case .syncAck(let hasMore):
                guard case .acknowledged? = envelope.body else { throw LoadError.unexpectedResponse }
                settleSyncWireResponse(frame.requestID)
                pendingSyncAcknowledgement = nil
                statistics.recordSyncAcknowledged()
                syncInFlight = false
                if hasMore || syncRequested { try startSyncIfNeeded(context: context) }
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let stop as StopHeartbeatEvent:
            heartbeatStopping = true
            heartbeatTask?.cancel(); heartbeatTask = nil
            guard let id = heartbeatRequestID, case .heartbeat(let sent)? = pendingRequests[id] else {
                stop.completion.succeed(()); return
            }
            heartbeatDrain = stop.completion
            let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
            heartbeatDrainTimeout = context.eventLoop.scheduleTask(deadline: sent + .seconds(Int64(heartbeatSeconds))) {
                let handler = handler.value
                guard handler.heartbeatDrain != nil else { return }
                handler.statistics.recordHeartbeatMissed()
                handler.checkpointHeartbeatMissed += 1
                handler.finishHeartbeatDrain(.failure(LoadError.connectionClosed))
            }
        case is StartWorkloadEvent:
            guard case .authenticated = stage, !workloadStarted, !handoffPrepared, context.channel.isActive else { return }
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
        case let scheduled as ScenarioSendEvent:
            guard case .authenticated = stage, workloadStarted, context.channel.isActive else { return }
            statistics.recordScenarioMessageScheduled()
            do {
                switch scenarioSendDispatch {
                case .strictPerDevice:
                    try sendMessage(context: context, scheduledAt: scheduled.scheduledAt)
                case .boundedClientQueue:
                    try enqueueScenarioMessage(context: context, scheduledAt: scheduled.scheduledAt)
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
            // All state is read on this handler's event loop in one probe. A
            // retry can reserve a slot without having a wire request in flight.
            let snapshotMonotonic = NIODeadline.now()
            let snapshotWall = Int64(Date().timeIntervalSince1970 * 1_000)
            var pendingPulls: [String: (requestID: UInt64, after: UInt64)] = [:]
            for (requestID, pending) in pendingRequests {
                if case .roomEventPull(_, let roomID, let after) = pending,
                   pendingPulls[roomID].map({ requestID < $0.requestID }) ?? true {
                    pendingPulls[roomID] = (requestID, after)
                }
            }
            let rooms = directRoomIDs.map { roomID in
                let hint = acceptedRoomHintWitnesses[roomID]
                let pull = pendingPulls[roomID]
                return RoomCursorSnapshot(connectionIndex: connectionIndex, roomID: roomID,
                    appliedRoomSequence: roomEventCursors[roomID, default: 0], recoveryTarget: restoredRecoveryTargets[roomID],
                    activeForeground: activeRoomLogRoomID == roomID,
                    announcedHighWatermark: roomEventAnnouncedHighWatermarks[roomID, default: 0],
                    pullInFlight: pull != nil, pullSlotReserved: roomEventPullRooms.contains(roomID),
                    pendingPullRequestID: pull?.requestID, pendingPullRequestedAfter: pull?.after,
                    retryPending: roomEventPullRetryTasks[roomID] != nil,
                    gracePending: roomEventRecoveryGraceTasks[roomID] != nil,
                    lastAcceptedHintHighWatermark: hint?.highWatermark,
                    lastAcceptedHintRoomSequence: hint?.roomSequence,
                    lastAcceptedHintAtUnixMilliseconds: hint?.atUnixMilliseconds,
                    lastAcceptedHintAgeMilliseconds: hint.map { (snapshotMonotonic - $0.monotonicAt).millisecondsDouble },
                    lastAcceptedProgressHighWatermark: acceptedRoomProgressWitnesses[roomID]?.highWatermark,
                    lastAcceptedProgressAtUnixMilliseconds: acceptedRoomProgressWitnesses[roomID]?.at,
                    snapshotAtUnixMilliseconds: snapshotWall,
                    snapshotMonotonicNanoseconds: snapshotMonotonic.uptimeNanoseconds)
            }
            probe.completion.succeed(ConnectionCursorProbeSnapshot(rooms: rooms, coverage: coverageSnapshot(at: snapshotWall)))
        case let transfer as PrepareReconnectEvent:
            guard authenticationCompleted, context.channel.isActive, !handoffPrepared,
                  !transfer.requireInFlight || !messageOperations.isEmpty else {
                transfer.completion.fail(LoadError.unexpectedResponse); return
            }
            handoffPrepared = true
            workloadStarted = false
            messageTask?.cancel(); messageTask = nil
            let operations = messageOperations.values.map { operation in
                operation.timer?.cancel()
                if let wireID = operation.wireRequestID { pendingRequests.removeValue(forKey: wireID) }
                statistics.recordMessageTransportEvent("TRANSFERRED")
                return LoadMessageSnapshot(command: operation.command, identity: operation.identity,
                    fingerprint: operation.fingerprint, sent: operation.sent, scheduledAt: operation.scheduledAt, deadline: operation.deadline,
                    attempts: operation.attempts)
            }
            for _ in 0..<queuedScenarioMessages { statistics.recordMessageTransportEvent("TRANSFERRED_QUEUE") }
            let snapshot = LoadReconnectSnapshot(operations: operations, queuedStarts: Array(queuedScenarioMessageStarts),
                cursors: roomEventCursors, foregroundRoom: activeRoomLogRoomID)
            messageOperations.removeAll(); messageRequestIDs.removeAll(); queuedScenarioMessageStarts.removeAll(keepingCapacity: false)
            transfer.completion.succeed(snapshot)
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

    private func observeCoverage(_ value: IMV2RealtimeCoverage) {
        func reject(_ reason: String) {
            ignoredCoverageFrames += 1
            ignoredCoverageReasons[reason, default: 0] += 1
            lastIgnoredCoverageFrame = .init(rejection: reason, scope: value.scope.rawValue,
                scopeID: value.scopeID, generation: value.scopeGeneration, revision: value.revision,
                state: value.state.rawValue, reason: value.reason.rawValue,
                observedAtUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000))
        }
        guard benchmarkWireVersion >= 46, value.scopeGeneration > 0 else { reject("unsupported_version_or_generation"); return }
        let scope: String
        let expectedID: String
        switch value.scope {
        case .account where requestedAccountCoverage:
            scope = "account"; expectedID = credential.userID
        case .room:
            guard let requestedRoomCoverageID else { reject("room_not_requested"); return }
            scope = "room"; expectedID = requestedRoomCoverageID
        default: reject("scope_not_requested"); return
        }
        guard UUID(uuidString: value.scopeID) != nil,
              UUID(uuidString: value.scopeID) == UUID(uuidString: expectedID) else { reject("scope_id_mismatch"); return }
        guard value.revision > (coverageRevisions[scope] ?? 0) else { reject("stale_revision"); return }
        guard value.scopeGeneration >= (observedCoverage[scope]?.generation ?? 0) else { reject("stale_generation"); return }
        let state: String
        switch value.state {
        case .ready: state = "ready"
        case .recovering: state = "recovering"
        case .ended: state = "ended"
        default: reject("unknown_state"); return
        }
        if let prior = observedCoverage[scope], prior.state == "ended",
           prior.generation == value.scopeGeneration, state != "ended" {
            reject("ended_generation"); return
        }
        // Independent scope writes may cross awaits and arrive out of global
        // revision order. Only this scope's revision/generation orders its proof.
        coverageRevisions[scope] = value.revision
        let wall = Int64(Date().timeIntervalSince1970 * 1_000)
        let prior = observedCoverage[scope]
        observedCoverage[scope] = .init(generation: value.scopeGeneration, revision: value.revision,
            state: state, highWatermark: value.highWatermark, reason: String(describing: value.reason),
            observedAtUnixMilliseconds: wall,
            lastReadyAtUnixMilliseconds: state == "ready" ? wall : prior?.lastReadyAtUnixMilliseconds,
            lastReadyGeneration: state == "ready" ? value.scopeGeneration : prior?.lastReadyGeneration)
    }
    private func coverageSnapshot(at wall: Int64) -> ConnectionCoverageSnapshot {
        var scopes: [RequestedScopeCoverageSnapshot] = []
        func snapshot(_ scope: String, id: String, cursor: UInt64) -> RequestedScopeCoverageSnapshot {
            let observed = observedCoverage[scope]
            return .init(scope: scope, scopeID: id, scopeGeneration: observed?.generation,
                revision: observed?.revision, state: observed?.state ?? "missing",
                highWatermark: observed?.highWatermark, appliedCursor: cursor,
                passed: observed.map { $0.state == "ready" && cursor >= $0.highWatermark } ?? false,
                reason: observed?.reason, observedAtUnixMilliseconds: observed?.observedAtUnixMilliseconds,
                lastReadyAtUnixMilliseconds: observed?.lastReadyAtUnixMilliseconds,
                lastReadyGeneration: observed?.lastReadyGeneration)
        }
        if requestedAccountCoverage { scopes.append(snapshot("account", id: credential.userID, cursor: accountAppliedCursor)) }
        if let room = requestedRoomCoverageID {
            scopes.append(snapshot("room", id: room, cursor: roomEventCursors[room, default: 0]))
        }
        // No coverage is inherited from old handlers, including planned reconnect.
        return .init(connectionIndex: connectionIndex, physicalConnectionID: physicalConnectionID,
            localSourcePort: localSourcePort, remoteGatewayPort: remoteGatewayPort,
            lastHeartbeatRequestID: lastHeartbeatRequestID,
            lastHeartbeatClientTimeMilliseconds: lastHeartbeatClientTimeMilliseconds,
            wireVersion: benchmarkWireVersion, requestedScopes: scopes, ignoredCoverageFrames: ignoredCoverageFrames,
            ignoredCoverageReasons: ignoredCoverageReasons, lastIgnoredCoverageFrame: lastIgnoredCoverageFrame,
            lastServerRoomProgress: lastServerRoomProgress,
            heartbeatSent: checkpointHeartbeatSent, heartbeatAcknowledged: checkpointHeartbeatAcknowledged,
            heartbeatMissed: checkpointHeartbeatMissed,
            snapshotAtUnixMilliseconds: wall,
            passed: authenticationCompleted && requestedAccountCoverage && scopes.allSatisfy(\.passed))
    }

    private func finishHeartbeatDrain(_ result: Result<Void, Error>) {
        guard let promise = heartbeatDrain else { return }
        heartbeatDrain = nil
        heartbeatDrainTimeout?.cancel(); heartbeatDrainTimeout = nil
        promise.completeWith(result)
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
            guard !handler.heartbeatStopping, case .authenticated = handler.stage, context.channel.isActive else { return }
            do { try handler.sendHeartbeat(context: context) }
            catch { handler.failAuthentication(error, context: context) }
        }
    }

    private func receiveRoomProgressStates(_ values: [IMV2GroupEventProgressState], context: ChannelHandlerContext) throws {
        guard values.count <= 1 else {
            statistics.recordRoomProgressState(accepted: false, recovery: false); return
        }
        for value in values {
            if let room = activeRoomLogRoomID, requestedRoomCoverageID == room,
               UUID(uuidString: value.roomID) == UUID(uuidString: room) {
                // Observe the server's claim before the existing acceptance checks.
                // In particular, Ready here cannot replace a missing coverage frame.
                lastServerRoomProgress = .init(ready: value.ready, generation: value.scopeGeneration,
                    highWatermark: value.highWatermark, appliedRoomSequence: value.appliedRoomSequence,
                    observedAtUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000))
            }
            guard roomLogReads, roomLogReadTrigger == .availabilityHint,
                  let room = activeRoomLogRoomID, requestedRoomCoverageID == room,
                  let coverage = observedCoverage["room"], coverage.state == "ready",
                  value.ready, value.scopeGeneration == coverage.generation,
                  UUID(uuidString: value.roomID) == UUID(uuidString: room),
                  value.highWatermark <= UInt64(Int64.max), value.appliedRoomSequence <= value.highWatermark else {
                statistics.recordRoomProgressState(accepted: false, recovery: false); continue
            }
            acceptedRoomProgressWitnesses[room] = (value.highWatermark, Int64(Date().timeIntervalSince1970 * 1_000))
            let behind = value.highWatermark > roomEventCursors[room, default: 0]
            statistics.recordRoomProgressState(accepted: true, recovery: behind)
            // acceptedC acknowledges only our report. It never changes our cursor.
            try acceptRoomRecoveryTarget(roomID: room, highWatermark: value.highWatermark,
                context: context, recordMetadataGap: false)
        }
    }
    private func receiveRoomLiveSequence(_ sequence: UInt64, roomID: String) {
        let cursor = roomEventCursors[roomID, default: 0]
        if cursor < .max, sequence > cursor + 1 {
            statistics.recordRoomEventLiveGap(missingSequences: sequence - cursor - 1)
        }
        var live = roomEventLiveSequences[roomID] ?? .init()
        let through = live.receive(sequence, after: cursor)
        if through > cursor { statistics.recordRoomEventLivePayloadApplied() }
        if live.pendingCount == 0 { roomEventLiveSequences.removeValue(forKey: roomID) }
        else { roomEventLiveSequences[roomID] = live }
        roomEventCursors[roomID] = drainAcceptedRoomSequences(roomID: roomID, through: through)
    }

    private func drainAcceptedRoomSequences(roomID: String, through cursor: UInt64) -> UInt64 {
        var through = cursor
        while true {
            let before = through
            if var known = roomEventAcceptedSequences[roomID] {
                let progress = known.applied(through: through)
                if known.pendingCount == 0 { roomEventAcceptedSequences.removeValue(forKey: roomID) }
                else { roomEventAcceptedSequences[roomID] = known }
                for _ in 0..<progress.appliedAcceptedCount { statistics.recordRoomEventLocalEchoApplied() }
                through = progress.cursor
            }
            if var live = roomEventLiveSequences[roomID] {
                let progress = live.applied(through: through)
                if live.pendingCount == 0 { roomEventLiveSequences.removeValue(forKey: roomID) }
                else { roomEventLiveSequences[roomID] = live }
                for _ in 0..<progress.count { statistics.recordRoomEventLivePayloadApplied() }
                through = progress.cursor
            }
            if before == through { return through }
        }
    }

    private func acceptRoomRecoveryTarget(roomID: String, highWatermark: UInt64,
        context: ChannelHandlerContext, recordMetadataGap: Bool) throws {
        roomEventAnnouncedHighWatermarks[roomID] = max(roomEventAnnouncedHighWatermarks[roomID, default: 0], highWatermark)
        let cursor = roomEventCursors[roomID, default: 0]
        guard highWatermark > cursor else { return }
        if recordMetadataGap { statistics.recordRoomEventMetadataGap(missingSequences: highWatermark - cursor) }
        try scheduleRoomEventRecoveryIfNeeded(roomID: roomID, context: context)
    }

    private func sendHeartbeat(context: ChannelHandlerContext) throws {
        if let heartbeatRequestID {
            pendingRequests.removeValue(forKey: heartbeatRequestID)
            checkpointHeartbeatMissed += 1
            statistics.recordHeartbeatMissed()
        }
        let requestID = takeRequestID()
        var heartbeat = IMV2Envelope()
        heartbeat.requestID = requestID
        heartbeat.protocolVersion = benchmarkWireVersion
        heartbeat.heartbeat = .init()
        heartbeat.heartbeat.clientTimeMs = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        if roomLogReads, let room = activeRoomLogRoomID, requestedRoomCoverageID == room,
           let coverage = observedCoverage["room"], coverage.state == "ready" {
            // This is the loader's simulated applied cursor, not GRDB evidence.
            var report = IMV2GroupEventProgress(); report.roomID = room
            report.scopeGeneration = coverage.generation
            report.appliedRoomSequence = roomEventCursors[room, default: 0]
            heartbeat.heartbeat.roomProgress = [report]
            statistics.recordRoomProgressReport()
        }
        heartbeatRequestID = requestID
        lastHeartbeatRequestID = requestID
        lastHeartbeatClientTimeMilliseconds = heartbeat.heartbeat.clientTimeMs
        pendingRequests[requestID] = .heartbeat(sent: .now())
        checkpointHeartbeatSent += 1
        statistics.recordHeartbeatSent()
        try write(heartbeat, frameVersion: UInt8(benchmarkWireVersion), context: context)
    }

    private func sendOpenDirectRoom(targetUserID:String,context:ChannelHandlerContext) throws {
        let actor=try UserID(credential.userID),target=try UserID(targetUserID),operationID=try DirectRoomOperationID(UUID().uuidString)
        let command=try V2DirectRoomOperationCommand(actorUserID:actor,operationID:operationID,
            targetUserID:target,firstSubmissionDeadlineMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+600_000)
        let credential = self.credential, client = accountHTTP
        let handler=NIOLoopBound(self,eventLoop:context.eventLoop),boundContext=context.loopBound
        let eventLoop=context.eventLoop,taskID=UUID()
        let installed=directRoomTasks.start(id:taskID) {
            do {
                try Task.checkCancellation()
                let opened = try await client.openDirectRoom(command: command, token: credential.accessToken, deviceID: credential.deviceID)
                guard !Task.isCancelled else { return }
                eventLoop.execute {
                    let handler=handler.value,context=boundContext.value
                    handler.directRoomTaskIDs.remove(taskID)
                    guard case .authenticated=handler.stage,handler.workloadStarted,context.channel.isActive else { return }
                    do {
                        let roomID=opened.rawValue
                        if !handler.directRoomIDs.contains(roomID) { handler.directRoomIDs.append(roomID) }
                        handler.statistics.recordDirectRoomOpened()
                        if handler.directRoomIDs.count==handler.targetUserIDs.count {
                            try handler.initializeRoomLogCursorThenScheduleMessages(context:context)
                        }
                    } catch {
                        handler.statistics.recordWorkloadFailure(kind:"direct_room",code:"CURSOR_INITIALIZATION_FAILURE")
                        context.close(promise:nil)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                eventLoop.execute {
                    let handler=handler.value,context=boundContext.value
                    handler.directRoomTaskIDs.remove(taskID)
                    guard case .authenticated=handler.stage,handler.workloadStarted,context.channel.isActive else { return }
                    handler.statistics.recordWorkloadFailure(kind:"direct_room",code:loadHTTPFailureCode(error))
                    context.close(promise:nil)
                }
            }
        }
        guard installed else { throw LoadError.directRoomControlQueueFull }
        directRoomTaskIDs.insert(taskID)
        statistics.recordDirectRoomAttempted()
    }

    private func scheduleMessages(context: ChannelHandlerContext) {
        guard !handoffPrepared else { return }
        if restoredMessagesNeedResume {
            restoredMessagesNeedResume = false
            do {
                for id in Array(messageOperations.keys) { try emitMessageAttempt(operationID: id, action: .query, context: context) }
                try drainQueuedScenarioMessages(context: context)
            } catch { context.close(promise: nil); return }
        }
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
        if isRestoredRecovery {
            if reconnectSlot != nil, roomLogReadTrigger == .availabilityHint {
                roomEventCursorSubscriptionPendingRooms = reconnectForegroundRoom.map { [$0] } ?? Array(directRoomIDs.prefix(1))
            } else {
                roomEventCursorSubscriptionPendingRooms = directRoomIDs.sorted()
            }
        } else { switch roomLogReadTrigger {
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
        request.protocolVersion = benchmarkWireVersion
        request.groupEventSubscribe = .init()
        request.groupEventSubscribe.roomID = roomID
        pendingRequests[requestID] = .roomEventSubscribe(roomID: roomID)
        try write(request, frameVersion: UInt8(benchmarkWireVersion), context: context)
        if requestedRoomCoverageID != roomID {
            observedCoverage.removeValue(forKey: "room")
            lastServerRoomProgress = nil
        }
        requestedRoomCoverageID = roomID
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

    private func sendMessage(context: ChannelHandlerContext, scheduledAt: NIODeadline? = nil) throws {
        guard !directRoomIDs.isEmpty else { return }
        guard messageRequestIDs.count < maximumInFlightMessagesPerConnection else {
            statistics.recordMessageSkipped(); return
        }
        guard negotiatedMessagePayloadBytes != nil else { throw LoadError.messageSendNegotiationFailed }
        let roomID: String
        if roomLogReadTrigger == .availabilityHint, let activeRoomLogRoomID { roomID = activeRoomLogRoomID }
        else { roomID = directRoomIDs[nextRoomIndex % directRoomIDs.count]; nextRoomIndex += 1 }
        // An immutable identity and fingerprint survive every query/retry.
        let command = try V2MessageSendOperationCommand(command: .init(roomID: .init(roomID),
            senderUserID: .init(credential.userID), clientMessageID: .init(UUID().uuidString),
            text: messageText, limits: .init(maxUTF8Bytes: 65_536)),
            firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000) + 86_400_000)
        let operationID = takeRequestID()
        let sent = NIODeadline.now()
        let operation = try MessageOperation(command: command, sent: sent, scheduledAt: scheduledAt ?? sent)
        messageOperations[operationID] = operation; messageRequestIDs.insert(operationID)
        statistics.recordMessageSent(scheduledAt: operation.scheduledAt)
        try emitMessageAttempt(operationID: operationID, action: .submit, context: context)
    }

    private func emitMessageAttempt(operationID: UInt64, action: MessageWireAction, context: ChannelHandlerContext) throws {
        guard let operation = messageOperations[operationID] else { return }
        guard context.channel.isActive, operation.attempts < Self.maximumMessageWireAttempts, NIODeadline.now() < operation.deadline else {
            try finishMessage(operationID, failure: "TCP_OUTCOME_UNKNOWN_RETRY_EXHAUSTED", context: context); return
        }
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID; request.protocolVersion = benchmarkWireVersion
        let expired = Date().timeIntervalSince1970 * 1_000 >= Double(operation.command.firstSubmissionDeadlineMilliseconds)
        let actualAction: MessageWireAction = expired || action == .close ? .query : action
        if actualAction != .submit {
            let query = try V2MessageSendOperationRecoveryRequest(identity: operation.identity,
                fingerprint: operation.fingerprint, domainFingerprint: operation.command.command.fingerprint)
            request.messageSendOperationRecover = V2MessageSendOperationWireCodec.encode(recovery: query)
        } else { request.messageSendOperation = try V2MessageSendOperationWireCodec.encode(command: operation.command) }
        operation.attempts += 1; operation.wireRequestID = requestID; operation.lastWireAction = actualAction
        pendingRequests[requestID] = .message(operationID: operationID)
        statistics.recordMessageTransportEvent(actualAction == .submit ? "WIRE_SUBMIT" : "WIRE_RECOVERY_QUERY")
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop), boundContext = context.loopBound
        let remaining = max(1, min(Self.messageAttemptTimeoutSeconds * 1_000_000_000, (operation.deadline - .now()).nanoseconds))
        operation.timer = context.eventLoop.scheduleTask(in: .nanoseconds(remaining)) {
            let handler = handler.value, context = boundContext.value
            guard let current = handler.messageOperations[operationID], current.wireRequestID == requestID else { return }
            handler.pendingRequests.removeValue(forKey: requestID); current.wireRequestID = nil; current.timer = nil
            handler.statistics.recordMessageTransportEvent("ATTEMPT_TIMEOUT")
            do { try handler.scheduleMessageAttempt(operationID: operationID, action: .query,
                delayMilliseconds: 0, context: context) }
            catch { context.close(promise: nil) }
        }
        do { try write(request, frameVersion: UInt8(benchmarkWireVersion), context: context) }
        catch {
            try finishMessage(operationID, failure: "TCP_OUTCOME_UNKNOWN_WRITE_FAILURE", drain: false, context: context)
            throw error
        }
    }

    private func receiveMessageResult(_ result: V2MessageSendOperationRecoveryResult, operationID: UInt64,
                                      context: ChannelHandlerContext) throws {
        guard let operation = messageOperations[operationID] else { return }
        switch result {
        case .receipt(let receipt):
            guard receipt.validates(identity: operation.identity, fingerprint: operation.fingerprint) else {
                statistics.recordMessageTransportEvent("INVALID_RECEIPT"); throw LoadError.unexpectedResponse
            }
            switch receipt.outcome {
            case .accepted(let accepted):
                // Retire the operation before optional room follow-up can throw;
                // an accepted receipt must never be re-counted as close/unknown.
                try finishMessage(operationID, failure: nil, drain: false, context: context)
                let acknowledgedAt = NIODeadline.now()
                statistics.recordMessageAcknowledged(milliseconds: (acknowledgedAt - operation.sent).millisecondsDouble,
                    endToEndMilliseconds: (acknowledgedAt - operation.scheduledAt).millisecondsDouble, scheduledAt: operation.scheduledAt)
                statistics.recordMessageTransportEvent("ACCEPTED")
                if operation.restoredAfterReconnect { statistics.recordMessageTransportEvent("RECOVERED_AFTER_RECONNECT") }
                let roomID = operation.command.command.roomID.rawValue
                if roomLogReads {
                    let cursor = roomEventCursors[roomID, default: 0]
                    var known = roomEventAcceptedSequences[roomID] ?? .init()
                    let progress = try known.accepted(accepted.roomSequence, after: cursor)
                    if known.pendingCount == 0 { roomEventAcceptedSequences.removeValue(forKey: roomID) }
                    else { roomEventAcceptedSequences[roomID] = known }
                    roomEventCursors[roomID] = drainAcceptedRoomSequences(roomID: roomID, through: progress.cursor)
                    for _ in 0..<progress.appliedAcceptedCount { statistics.recordRoomEventLocalEchoApplied() }
                    cancelRoomEventRecoveryGraceIfCaughtUp(roomID: roomID)
                    if accepted.roomSequence > cursor, cursor < .max, accepted.roomSequence > cursor + 1 {
                        // Retain this validated receipt until its predecessors
                        // arrive. Unknown peer sequences still need recovery.
                        statistics.recordRoomEventLocalEchoGapDetected()
                    }
                }
                if roomLogReads, roomLogReadTrigger == .messageAcknowledgement {
                    try sendRoomEventPullIfNeeded(roomID: roomID, context: context)
                }
                try drainQueuedScenarioMessages(context: context)
            case .rejected(let reason):
                statistics.recordMessageTransportEvent("TERMINAL_REJECTED_" + reason.rawValue)
                try finishMessage(operationID, failure: "TCP_REJECTED_" + reason.rawValue, context: context)
            }
        case .fingerprintConflict:
            statistics.recordMessageTransportEvent("FINGERPRINT_CONFLICT")
            try finishMessage(operationID, failure: "TCP_FINGERPRINT_CONFLICT", context: context)
        case .unresolved:
            statistics.recordMessageTransportEvent("UNRESOLVED")
            let expired = Date().timeIntervalSince1970 * 1_000 >= Double(operation.command.firstSubmissionDeadlineMilliseconds)
            try scheduleMessageAttempt(operationID: operationID, action: expired ? .close : .submit,
                delayMilliseconds: 1_000, context: context)
        case .deferred(let hint):
            guard hint.validates(identity: operation.identity, fingerprint: operation.fingerprint) else {
                statistics.recordMessageTransportEvent("INVALID_DEFERRED_HINT"); throw LoadError.unexpectedResponse
            }
            statistics.recordMessageTransportEvent("DEFERRED_" + hint.reason.rawValue)
            try scheduleMessageAttempt(operationID: operationID, action: operation.lastWireAction,
                delayMilliseconds: Int64(max(1, hint.retryAfterMilliseconds ?? 1_000)), context: context)
        }
    }

    private func scheduleMessageAttempt(operationID: UInt64, action: MessageWireAction, delayMilliseconds: Int64,
                                        context: ChannelHandlerContext) throws {
        guard let operation = messageOperations[operationID] else { return }
        let now = NIODeadline.now()
        let base = now + .milliseconds(max(0, delayMilliseconds))
        let remaining = (operation.deadline - base).nanoseconds
        guard operation.attempts < Self.maximumMessageWireAttempts, remaining > 0 else {
            try finishMessage(operationID, failure: action == .submit ? "TCP_DEFERRED_RETRY_EXHAUSTED" : "TCP_OUTCOME_UNKNOWN_UNRESOLVED", context: context)
            return
        }
        // Match the production policy: the server floor is the base, then
        // apply bounded exponential jitter without restarting the total budget.
        let exponent = min(max(0, operation.attempts - 1), 16)
        let ceilingNanoseconds = min(30, 0.5 * pow(2, Double(exponent))) * 1_000_000_000
        let window = min(ceilingNanoseconds, Double(remaining))
        let next = base + .nanoseconds(Int64(window * Double.random(in: 0...1)))
        guard next < operation.deadline else {
            try finishMessage(operationID, failure: action == .submit ? "TCP_DEFERRED_RETRY_EXHAUSTED" : "TCP_OUTCOME_UNKNOWN_UNRESOLVED", context: context)
            return
        }
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop), boundContext = context.loopBound
        operation.timer = context.eventLoop.scheduleTask(in: .nanoseconds((next - now).nanoseconds)) {
            let handler = handler.value, context = boundContext.value
            handler.messageOperations[operationID]?.timer = nil
            do { try handler.emitMessageAttempt(operationID: operationID, action: action, context: context) }
            catch { context.close(promise: nil) }
        }
    }

    private func finishMessage(_ operationID: UInt64, failure: String?, drain: Bool = true, context: ChannelHandlerContext) throws {
        guard let operation = messageOperations.removeValue(forKey: operationID) else { return }
        operation.timer?.cancel()
        if let requestID = operation.wireRequestID { pendingRequests.removeValue(forKey: requestID) }
        messageRequestIDs.remove(operationID)
        if let failure {
            if failure.hasPrefix("TCP_OUTCOME_UNKNOWN") { statistics.recordMessageTransportEvent("OUTCOME_UNKNOWN") }
            statistics.recordWorkloadFailure(kind: "message", code: failure)
        }
        if drain { try drainQueuedScenarioMessages(context: context) }
    }

    /// 仅当每设备队列存在硬性上限时才保留场景选中的动作。
    ///
    /// 该队列刻意只属于该模拟设备本地：
    /// 这既保留了加权用户行为，又让饱和运行能把服务端积压与先前的立即丢弃模型区分开。
    ///
    /// - Parameter context: 目标通道上下文。
    /// - Throws: 发送或写入失败时抛出。
    private func enqueueScenarioMessage(context: ChannelHandlerContext, scheduledAt: NIODeadline) throws {
        guard !directRoomIDs.isEmpty else { return }
        if messageRequestIDs.count < maximumInFlightMessagesPerConnection {
            try sendMessage(context: context, scheduledAt: scheduledAt)
            return
        }
        guard queuedScenarioMessages < maximumQueuedScenarioMessages else {
            statistics.recordScenarioMessageQueueOverflow()
            return
        }
        queuedScenarioMessageStarts.append(scheduledAt)
        statistics.recordScenarioMessageDeferred()
    }

    /// ACK 与拒绝都会释放一个设备的在途槽位。
    ///
    /// 最多排空所通告的窗口，绝不通过事件循环递归调用，
    /// 并让 `messagesSent` 始终表示实际开始的 TCP 逻辑发送操作数量。
    ///
    /// - Parameter context: 目标通道上下文。
    /// - Throws: 发送或写入失败时抛出。
    private func drainQueuedScenarioMessages(context: ChannelHandlerContext) throws {
        while queuedScenarioMessages > 0,
              messageRequestIDs.count < maximumInFlightMessagesPerConnection,
              context.channel.isActive {
            let scheduledAt = queuedScenarioMessageStarts.removeFirst()
            statistics.recordScenarioMessageDequeued()
            try sendMessage(context: context, scheduledAt: scheduledAt)
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
        request.protocolVersion = benchmarkWireVersion
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
                frameVersion: UInt8(benchmarkWireVersion),
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
        if let pending = pendingSyncAcknowledgement {
            syncAttempt = SyncAttempt(request: pending.0, kind: .acknowledgement(hasMore: pending.1))
        } else {
            var request = IMV2Envelope()
            request.syncPull.syncToken = nextSyncToken
            request.syncPull.maxRecords = 100
            syncAttempt = SyncAttempt(request: request, kind: .pull)
            statistics.recordSyncPullSent()
        }
        try emitSyncAttempt(context: context)
    }

    private func emitSyncAttempt(context: ChannelHandlerContext) throws {
        guard let attempt = syncAttempt, context.channel.isActive else { return }
        guard NIODeadline.now() < attempt.deadline, attempt.attempts < 2 else {
            finishSyncLogicalFailure(); return
        }
        attempt.timer?.cancel()
        attempt.attempts += 1
        let requestID = takeRequestID()
        attempt.wireRequestID = requestID
        var request = attempt.request
        request.requestID = requestID; request.protocolVersion = benchmarkWireVersion
        switch attempt.kind {
        case .pull: pendingRequests[requestID] = .syncPull(sent: attempt.started)
        case .acknowledgement(let hasMore): pendingRequests[requestID] = .syncAck(hasMore: hasMore)
        }
        statistics.recordSyncWireAttempt(retry: attempt.attempts > 1)
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        let id = attempt.id
        attempt.timer = context.eventLoop.scheduleTask(deadline: attempt.deadline) {
            let handler = handler.value, context = boundContext.value
            guard let current = handler.syncAttempt, current.id == id, current.wireRequestID == requestID else { return }
            handler.pendingRequests.removeValue(forKey: requestID)
            handler.statistics.recordWorkloadFailure(kind: "sync", code: "CLIENT_DEADLINE")
            handler.finishSyncLogicalFailure()
            // A dispatched response may still arrive. Retire this physical
            // channel rather than recycling its correlation slot prematurely.
            context.close(promise: nil)
        }
        try write(request, frameVersion: UInt8(benchmarkWireVersion), context: context)
    }

    private func settleSyncWireResponse(_ requestID: UInt64) {
        guard let attempt = syncAttempt, attempt.wireRequestID == requestID else { return }
        attempt.timer?.cancel()
        syncAttempt = nil
    }

    private func finishSyncLogicalFailure() {
        syncAttempt?.timer?.cancel()
        syncAttempt = nil
        syncInFlight = false
        syncRequested = true
        statistics.recordSyncLogicalFailure()
    }

    private func retryRejectedSync(requestID: UInt64, code: String, retryable: Bool,
                                   retryAfterSeconds: UInt32, context: ChannelHandlerContext) {
        guard let attempt = syncAttempt, attempt.wireRequestID == requestID else { return }
        attempt.timer?.cancel(); attempt.wireRequestID = nil
        guard code == "SERVER_BUSY", retryable, attempt.attempts < 2 else { finishSyncLogicalFailure(); return }
        let base = NIODeadline.now() + .seconds(Int64(retryAfterSeconds))
        guard base < attempt.deadline else { finishSyncLogicalFailure(); return }
        let remaining = (attempt.deadline - base).nanoseconds
        let ceiling = min(Int64(500_000_000) << min(attempt.attempts - 1, 16), Int64(30_000_000_000))
        let window = min(ceiling, remaining)
        // A deterministic per-connection jitter preserves reproducible fixture
        // evidence without collapsing all attempts onto the server floor.
        let unit = Double((connectionIndex &* 17 &+ attempt.attempts &* 31) % 997) / 997
        let wake = base + .nanoseconds(Int64(Double(window) * unit))
        guard wake < attempt.deadline else { finishSyncLogicalFailure(); return }
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop), boundContext = context.loopBound
        let id = attempt.id
        attempt.timer = context.eventLoop.scheduleTask(deadline: wake) {
            let handler = handler.value, context = boundContext.value
            guard handler.syncAttempt?.id == id, case .authenticated = handler.stage, context.channel.isActive else { return }
            do { try handler.emitSyncAttempt(context: context) }
            catch {
                handler.statistics.recordWorkloadFailure(kind: "sync", code: "CLIENT_WRITE_FAILURE")
                handler.finishSyncLogicalFailure(); context.close(promise: nil)
            }
        }
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
        request.protocolVersion = benchmarkWireVersion
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
        try write(request, frameVersion: UInt8(benchmarkWireVersion), context: context)
    }

    private func scheduleRoomEventPullRetry(
        roomID: String,
        serverRetryAfterSeconds: UInt32,
        context: ChannelHandlerContext
    ) {
        guard roomEventPullRetryTasks[roomID] == nil else { return }
        let retryCount = roomEventPullRetryCounts[roomID, default: 0] + 1
        roomEventPullRetryCounts[roomID] = retryCount
        let exponent = min(retryCount - 1, 5)
        let baseDelay = 50 * (1 << exponent)
        let jitter = (connectionIndex &* 17 &+ retryCount &* 31) % 50
        // Match V2RoomRecoveryRunner: even a zero server floor means at
        // least one second. Bound only our exponential delay, never the floor.
        let serverFloor = max(Int64(1_000), Int64(serverRetryAfterSeconds) * 1_000)
        let delay = max(serverFloor, Int64(min(2_000, baseDelay))) + Int64(jitter)
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
        request.protocolVersion = benchmarkWireVersion
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
            try write(request, frameVersion: UInt8(benchmarkWireVersion), context: context)
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
        generation: UInt64, highestSequence: UInt64, receipt: String,
        hasMore: Bool, context: ChannelHandlerContext
    ) throws {
        var request = IMV2Envelope()
        request.syncAck.generation = generation
        request.syncAck.highestContiguousSequence = highestSequence
        request.syncAck.syncReceipt = receipt
        pendingSyncAcknowledgement = (request, hasMore)
        syncAttempt = SyncAttempt(request: request, kind: .acknowledgement(hasMore: hasMore))
        try emitSyncAttempt(context: context)
    }

    private func handleRejected(
        _ pending: PendingRequest,
        requestID: UInt64,
        code: String,
        retryable: Bool,
        retryAfterSeconds: UInt32,
        context: ChannelHandlerContext
    ) throws {
        switch pending {
        case .heartbeat:
            heartbeatRequestID = nil
            checkpointHeartbeatMissed += 1
            statistics.recordHeartbeatMissed()
            finishHeartbeatDrain(.failure(LoadError.unexpectedResponse))
        case .message(let operationID):
            guard let operation = messageOperations[operationID], operation.wireRequestID == requestID else { throw LoadError.unexpectedResponse }
            operation.timer?.cancel(); operation.timer = nil; operation.wireRequestID = nil
            statistics.recordMessageTransportEvent("SERVER_REJECTED_" + code)
            if retryable {
                // A rejected query does not establish whether the earlier send
                // committed. Preserve this wire action for pre-dispatch busy;
                // other retryable failures query the same immutable identity.
                try scheduleMessageAttempt(operationID: operationID,
                    action: code == "SERVER_BUSY" ? operation.lastWireAction : .query,
                    delayMilliseconds: max(1_000, Int64(retryAfterSeconds) * 1_000), context: context)
            } else { try finishMessage(operationID, failure: "TCP_SERVER_" + code, context: context) }
        case .syncPull, .syncAck:
            // Every rejected wire action retains the original failure count.
            statistics.recordWorkloadFailure(kind: "sync", code: code, retryable: retryable)
            retryRejectedSync(requestID: requestID, code: code, retryable: retryable,
                retryAfterSeconds: retryAfterSeconds, context: context)
        case .roomEventPull(_, let roomID, _):
            if retryable {
                statistics.recordRoomEventPullRetryableRejection()
                scheduleRoomEventPullRetry(roomID: roomID, serverRetryAfterSeconds: retryAfterSeconds, context: context)
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
            FileHandle.standardError.write(Data("terminal request rejection kind=room_event_subscribe retries=\(retryCount) code=\(code)\n".utf8))
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

        }
    }

    private func takeRequestID() -> UInt64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func write(_ envelope: IMV2Envelope, frameVersion: UInt8, context: ChannelHandlerContext) throws {
        let frame = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: frameVersion)
        if frame.command == .messageSendOperation || frame.command == .messageSendOperationRecover {
            guard let maximum = negotiatedMessagePayloadBytes, frame.payload.count <= Int(maximum) else {
                throw LoadError.messageSendNegotiationFailed
            }
        }
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
    let directRoomHTTPMaximumConcurrent: Int
    let directRoomHTTPMaximumQueued: Int
    let accountHTTPConnectionsPerHostSoftLimit: Int
    let localPortBase: Int?
    let localPortSpan: Int?
    let localPortReuseAddress: Bool
    let localPortReusePort: Bool
    let protocolFailuresByKindAndCode: [String: Int]
    let plannedReconnectInflightCanary: Bool
    let benchmarkWireVersion: UInt32
    let algorithmSourceSHA256: String
    let messageTransport: String
    let messageRecoveryTransport: String
    let messageAttemptTimeoutSeconds: Int64
    let messageOperationTimeoutSeconds: Int64
    let messageMaximumAttempts: Int
    let messageTransportEvents: [String: Int]
    let realtimeCoverageEvents: [String: Int]
    let messageSendNegotiatedConnections: Int
    let messageSendPayloadLimitMinimum: UInt32?
    let messageSendPayloadLimitMaximum: UInt32?
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
    let roomNotificationLossCanary: Bool
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
    let roomProgressReportsSent: Int
    let roomProgressStatesAccepted: Int
    let roomProgressStatesIgnored: Int
    let roomProgressRecoverySignals: Int
    let roomNotificationsDiscarded: Int
    let onlineOnly: Bool
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
    /// Initial logical pull dispatches; BUSY wire retries are separate.
    let syncPullsSent: Int
    let syncWireAttempts: Int
    let syncRetryAttempts: Int
    let syncLogicalFailures: Int
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
    /// 包含计划调度、客户端队列、网络及重试，直到最终 ACK。
    let messageEndToEndLatency: Percentiles
    let syncPullLatency: Percentiles
    let roomEventPullLatency: Percentiles
    let readReceiptLatency: Percentiles
    let eventLoopLag: LoadEventLoopLagReport
    let scenarioName: String?
    let scenarioRateScale: Double?
    let scenarioSchedulerTicksPerSecond: Int?
    let scenarioSendDispatch: String?
    let maximumQueuedScenarioMessagesPerConnection: Int?
    let messageSendCohorts: [String: MessageSendCohortReport]
    let scenarioPhases: [ScenarioPhaseReport]
    let scenarioDrain: ScenarioDrainReport?
    let roomCursorSnapshots: [RoomCursorSnapshot]
    let connectionCoverageSnapshots: [ConnectionCoverageSnapshot]
    let coverageProofRequired: Bool
    let coverageProofPassed: Bool
    let scenarioPostDrainHoldSeconds: Int?
    let terminalError: String?
    let recoveryBurst: RecoveryBurstReport?

    init(configuration: LoadConfiguration, startedAt: Date, endedAt: Date, state: LoadStatistics.State, eventLoopLag: V2RuntimeLatencyHistogramSnapshot, messageSendCohorts: [String: MessageSendCohortReport], scenarioPhases: [ScenarioPhaseReport], scenarioDrain: ScenarioDrainReport?, terminalError: Error?, roomCursorSnapshots: [RoomCursorSnapshot], connectionCoverageSnapshots: [ConnectionCoverageSnapshot], recoveryBurst: RecoveryBurstReport?) {
        self.recoveryBurst = recoveryBurst
        self.connectionCoverageSnapshots = connectionCoverageSnapshots
        let requiresCoverageProof = configuration.benchmarkWireVersion >= 46
        coverageProofRequired = requiresCoverageProof
        coverageProofPassed = !requiresCoverageProof || (
            connectionCoverageSnapshots.count == configuration.connections &&
            Set(connectionCoverageSnapshots.map(\.connectionIndex)).count == configuration.connections &&
            Set(connectionCoverageSnapshots.map(\.physicalConnectionID)).count == configuration.connections &&
            connectionCoverageSnapshots.allSatisfy(\.passed))
        revision = configuration.revision
        host = configuration.host
        port = configuration.port
        requestedConnections = configuration.connections
        rampPerSecond = configuration.rampPerSecond
        rampBatchSize = configuration.rampBatchSize
        workloadRampPerSecond = configuration.workloadRampPerSecond
        directRoomHTTPMaximumConcurrent = DirectRoomHTTPTaskOwner.configuredMaximumConcurrent
        directRoomHTTPMaximumQueued = DirectRoomHTTPTaskOwner.configuredMaximumQueued
        accountHTTPConnectionsPerHostSoftLimit = LoadRun.accountHTTPConnectionsPerHostSoftLimit
        localPortBase = configuration.localPortBase
        localPortSpan = configuration.localPortBase.map { _ in LocalSourcePortAllocator.span }
        localPortReuseAddress = configuration.localPortBase != nil
        localPortReusePort = configuration.localPortBase != nil
        protocolFailuresByKindAndCode = state.protocolFailuresByKindAndCode
        plannedReconnectInflightCanary = configuration.plannedReconnectInflightCanary
        benchmarkWireVersion = configuration.benchmarkWireVersion
        algorithmSourceSHA256 = LoadConnectionHandler.algorithmSourceSHA256
        messageTransport = "tcp"
        messageRecoveryTransport = "tcp_query"
        messageAttemptTimeoutSeconds = LoadConnectionHandler.messageAttemptTimeoutSeconds
        messageOperationTimeoutSeconds = LoadConnectionHandler.messageOperationTimeoutSeconds
        messageMaximumAttempts = LoadConnectionHandler.maximumMessageWireAttempts
        messageTransportEvents = state.messageTransportEvents
        realtimeCoverageEvents = state.realtimeCoverageEvents
        messageSendNegotiatedConnections = state.messageSendNegotiatedConnections
        messageSendPayloadLimitMinimum = state.messageSendPayloadLimitMinimum
        messageSendPayloadLimitMaximum = state.messageSendPayloadLimitMaximum
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
        roomNotificationLossCanary = configuration.roomNotificationLossCanary
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
        roomProgressReportsSent = state.roomProgressReportsSent
        roomProgressStatesAccepted = state.roomProgressStatesAccepted
        roomProgressStatesIgnored = state.roomProgressStatesIgnored
        roomProgressRecoverySignals = state.roomProgressRecoverySignals
        roomNotificationsDiscarded = state.roomNotificationsDiscarded
        directRoomAttempted = state.directRoomAttempted
        onlineOnly = configuration.onlineOnly
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
        syncWireAttempts = state.syncWireAttempts
        syncRetryAttempts = state.syncRetryAttempts
        syncLogicalFailures = state.syncLogicalFailures
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
        messageEndToEndLatency = state.messageEndToEndLatency.percentiles
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
        self.messageSendCohorts = messageSendCohorts
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
    let startedAtUnixMilliseconds: Int64
    let endedAtUnixMilliseconds: Int64
    let completed: Bool
    let requestedMessagesPerSecond: Double
    let requestedRoomLogReadsPerSecond: Double
    let requestedSyncPullsPerSecond: Double
    let requestedReadReceiptsPerSecond: Double
    let requestedRoomSyncStateBatchesPerSecond: Double
    let requestedRoomLatestVisibleBatchesPerSecond: Double
    let messageTransportEvents: [String: Int]
    let realtimeCoverageEvents: [String: Int]
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
    /// Initial logical pull dispatches; BUSY wire retries are separate.
    let syncPullsSent: Int
    let syncWireAttempts: Int
    let syncRetryAttempts: Int
    let syncLogicalFailures: Int
    let syncRecordsReceived: Int
    let workloadFailed: Int
    let heartbeatLatency: Percentiles
    let heartbeatSent: Int
    let heartbeatAcknowledged: Int
    let heartbeatMissed: Int
    let messageLatency: Percentiles
    /// 包含计划调度、客户端队列、网络及重试，直到最终 ACK。
    let messageEndToEndLatency: Percentiles
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
        startedAtUnixMilliseconds: Int64,
        endedAtUnixMilliseconds: Int64,
        completed: Bool,
        started: LoadStatistics.State,
        ended: LoadStatistics.State
    ) {
        name = phase.name
        durationSeconds = phase.durationSeconds
        self.observedDurationSeconds = observedDurationSeconds
        self.startedAtUnixMilliseconds = startedAtUnixMilliseconds
        self.endedAtUnixMilliseconds = endedAtUnixMilliseconds
        self.completed = completed
        requestedMessagesPerSecond = phase.messagesPerSecond * rateScale
        requestedRoomLogReadsPerSecond = phase.roomLogReadsPerSecond * rateScale
        requestedSyncPullsPerSecond = phase.syncPullsPerSecond * rateScale
        requestedReadReceiptsPerSecond = phase.effectiveReadReceiptsPerSecond * rateScale
        requestedRoomSyncStateBatchesPerSecond = phase.effectiveRoomSyncStateBatchesPerSecond * rateScale
        requestedRoomLatestVisibleBatchesPerSecond = phase.effectiveRoomLatestVisibleBatchesPerSecond * rateScale
        messageTransportEvents = ended.messageTransportEvents.reduce(into: [:]) { result, entry in
            let delta = entry.value - started.messageTransportEvents[entry.key, default: 0]
            if delta != 0 { result[entry.key] = delta }
        }
        realtimeCoverageEvents = ended.realtimeCoverageEvents.reduce(into: [:]) { result, entry in
            let delta = entry.value - started.realtimeCoverageEvents[entry.key, default: 0]
            if delta != 0 { result[entry.key] = delta }
        }
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
        syncWireAttempts = ended.syncWireAttempts - started.syncWireAttempts
        syncRetryAttempts = ended.syncRetryAttempts - started.syncRetryAttempts
        syncLogicalFailures = ended.syncLogicalFailures - started.syncLogicalFailures
        syncRecordsReceived = ended.syncRecordsReceived - started.syncRecordsReceived
        workloadFailed = ended.workloadFailed - started.workloadFailed
        heartbeatLatency = ended.heartbeatLatency
            .subtracting(started.heartbeatLatency)
            .percentiles
        heartbeatSent = ended.heartbeatSent - started.heartbeatSent
        heartbeatAcknowledged = ended.heartbeatAcknowledged - started.heartbeatAcknowledged
        heartbeatMissed = ended.heartbeatMissed - started.heartbeatMissed
        messageLatency = ended.messageLatency
            .subtracting(started.messageLatency)
            .percentiles
        messageEndToEndLatency = ended.messageEndToEndLatency
            .subtracting(started.messageEndToEndLatency)
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
    struct Bucket: Encodable {
        let lowerBoundMilliseconds: Int
        let count: Int
    }
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

    /// Export the already-recorded counts only when building a report. Sparse
    /// buckets let independent generators merge their actual distributions;
    /// no additional per-request measurement or retained samples are needed.
    var nonemptyBuckets: [Bucket] {
        buckets.enumerated().compactMap { index, samples in
            samples == 0 ? nil : Bucket(lowerBoundMilliseconds: index, count: samples)
        }
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
    let histogramBuckets: [LatencyHistogram.Bucket]

    init(histogram: LatencyHistogram) {
        count = histogram.count
        p50 = histogram.percentile(0.50)
        p95 = histogram.percentile(0.95)
        p99 = histogram.percentile(0.99)
        maximum = (histogram.maximum * 100).rounded() / 100
        histogramBuckets = histogram.nonemptyBuckets
    }
}

private enum LoadError: Error, CustomStringConvertible {
    case invalidArguments
    case messageSendNegotiationFailed
    case localSourcePortRangeExhausted
    case invalidScenario(String)
    case invalidCredentialFile
    case insufficientCredentials(required: Int, available: Int)
    case unexpectedResponse
    case unexpectedServerResponse(errorCode: String?, messageType: String, requestID: UInt64)
    case unexpectedSyncResponse(String)
    case connectionClosed
    case directRoomControlQueueFull
    case memoryGuardTriggered(megabytes: Int)
    case failureGuardTriggered(failed: Int, attempted: Int)
    case connectionLossGuardTriggered(disconnected: Int, authenticated: Int)
    case workloadFailureGuardTriggered(failed: Int, attempted: Int)
    case roomWarmupTimedOut(opened: Int, required: Int)
    case scenarioStartBarrierFailure(String)
    case scenarioPhaseNotDrained(phase: String, queued: Int, maximumQueued: Int, sent: Int, acknowledged: Int)
    case scenarioCompletionDrainTimedOut(queued: Int, inFlight: Int)

    var description: String {
        switch self {
        case .invalidArguments:
            return "invalid arguments; required: --host --ca-path --credentials --report"
        case .messageSendNegotiationFailed: return "TCP message send operation capability or payload limit was not negotiated"
        case .localSourcePortRangeExhausted: return "local source port range exhausted after 10000 connection attempts"
        case .invalidScenario(let reason): return "invalid scenario: \(reason)"
        case .invalidCredentialFile: return "credential file is empty, duplicated, or malformed"
        case .insufficientCredentials(let required, let available): return "insufficient credentials: required \(required), available \(available)"
        case .unexpectedResponse: return "gateway returned an unexpected protocol response"
        case .unexpectedServerResponse(let errorCode, let messageType, let requestID):
            return "gateway returned an unexpected protocol response errorCode=\(errorCode ?? "NONE") messageType=\(messageType) requestID=\(requestID)"
        case .unexpectedSyncResponse(let reason):
            return "gateway returned an unexpected sync response: \(reason)"
        case .connectionClosed: return "gateway connection closed before authentication"
        case .directRoomControlQueueFull: return "local direct-room HTTP control queue is full"
        case .memoryGuardTriggered(let megabytes): return "local memory guard triggered at \(megabytes) MB"
        case .failureGuardTriggered(let failed, let attempted): return "connection failure guard triggered: \(failed)/\(attempted)"
        case .connectionLossGuardTriggered(let disconnected, let authenticated): return "active connection loss guard triggered: \(disconnected)/\(authenticated)"
        case .workloadFailureGuardTriggered(let failed, let attempted): return "workload failure guard triggered: \(failed)/\(attempted)"
        case .roomWarmupTimedOut(let opened, let required): return "room warmup timed out: opened \(opened)/\(required)"
        case .scenarioStartBarrierFailure(let reason): return "scenario start barrier failed: \(reason)"
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
