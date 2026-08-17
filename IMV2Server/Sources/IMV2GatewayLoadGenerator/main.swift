#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
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
            let configuration = try LoadConfiguration(arguments: Array(CommandLine.arguments.dropFirst()))
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
            #elseif canImport(Glibc)
            Glibc.exit(1)
            #endif
        }
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
    let heartbeatSeconds: Int
    let maximumRSSMegabytes: Int
    let maximumFailurePercent: Double

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
        connections = try Self.integer(values["--connections"] ?? "100", range: 1...5_000)
        rampPerSecond = try Self.integer(values["--ramp-per-second"] ?? "50", range: 1...1_000)
        rampBatchSize = try Self.integer(
            values["--ramp-batch-size"] ?? String(min(rampPerSecond, 100)),
            range: 1...1_000
        )
        workloadRampPerSecond = try Self.integer(
            values["--workload-ramp-per-second"] ?? String(rampPerSecond),
            range: 1...1_000
        )
        holdSeconds = try Self.integer(values["--hold-seconds"] ?? "60", range: 10...600)
        eventLoops = try Self.integer(values["--event-loops"] ?? "2", range: 1...4)
        heartbeatSeconds = try Self.integer(values["--heartbeat-seconds"] ?? "30", range: 10...50)
        messagesPerSecond = try Self.integer(values["--messages-per-second"] ?? "0", range: 0...1_000)
        maximumInFlightMessagesPerConnection = try Self.integer(
            values["--max-inflight-messages-per-connection"] ?? "1",
            range: 1...32
        )
        messageBytes = try Self.integer(values["--message-bytes"] ?? "128", range: 1...4_096)
        targetsPerConnection = try Self.integer(values["--targets-per-connection"] ?? "3", range: 1...32)
        targetOffset = try Self.integer(values["--target-offset"] ?? "1", range: 1...4_999)
        syncReads = try Self.integer(values["--sync-reads"] ?? "1", range: 0...1) == 1
        maximumRSSMegabytes = try Self.integer(values["--max-rss-mb"] ?? "2048", range: 256...8_192)
        guard let maximumFailurePercent = Double(values["--max-failure-percent"] ?? "1"),
              maximumFailurePercent >= 0, maximumFailurePercent <= 100
        else { throw LoadError.invalidArguments }
        self.maximumFailurePercent = maximumFailurePercent
        guard messagesPerSecond == 0 || targetOffset + targetsPerConnection - 1 < connections else {
            throw LoadError.invalidArguments
        }
    }

    private static func integer(_ raw: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(raw), range.contains(value) else { throw LoadError.invalidArguments }
        return value
    }
}

private struct LoadCredential: Decodable, Sendable {
    let userID: String
    let deviceID: String
    let accessToken: String
    let accessTokenExpiresAtMilliseconds: Int64

    static func load(from path: String) throws -> [Self] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let decoder = JSONDecoder()
        var credentials: [Self] = []
        var devices = Set<String>()
        for line in content.split(whereSeparator: \ .isNewline) {
            let credential = try decoder.decode(Self.self, from: Data(line.utf8))
            guard !credential.userID.isEmpty,
                  !credential.deviceID.isEmpty,
                  !credential.accessToken.isEmpty,
                  devices.insert(credential.deviceID).inserted
            else { throw LoadError.invalidCredentialFile }
            credentials.append(credential)
        }
        guard !credentials.isEmpty else { throw LoadError.invalidCredentialFile }
        return credentials
    }
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
        var heartbeatSent = 0
        var heartbeatAcknowledged = 0
        var heartbeatMissed = 0
        var directRoomAttempted = 0
        var directRoomOpened = 0
        var workloadFailed = 0
        var workloadFailuresByKindAndCode: [String: Int] = [:]
        var messagesSent = 0
        var messagesAcknowledged = 0
        var messagesSkipped = 0
        var syncPullsSent = 0
        var syncBatchesReceived = 0
        var syncRecordsReceived = 0
        var syncAcknowledged = 0
        var authenticationMilliseconds: [Double] = []
        var heartbeatMilliseconds: [Double] = []
        var messageMilliseconds: [Double] = []
        var syncPullMilliseconds: [Double] = []
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
            state.authenticationMilliseconds.append(milliseconds)
        }
    }
    func recordDisconnected() {
        lock.withLock {
            state.disconnected += 1
            state.active = max(0, state.active - 1)
        }
    }
    func recordHeartbeatSent() { lock.withLock { state.heartbeatSent += 1 } }
    func recordHeartbeatAcknowledged(milliseconds: Double) {
        lock.withLock {
            state.heartbeatAcknowledged += 1
            state.heartbeatMilliseconds.append(milliseconds)
        }
    }
    func recordHeartbeatMissed() { lock.withLock { state.heartbeatMissed += 1 } }
    func recordDirectRoomAttempted() { lock.withLock { state.directRoomAttempted += 1 } }
    func recordDirectRoomOpened() { lock.withLock { state.directRoomOpened += 1 } }
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
            state.messageMilliseconds.append(milliseconds)
        }
    }
    func recordMessageSkipped() { lock.withLock { state.messagesSkipped += 1 } }
    func recordSyncPullSent() { lock.withLock { state.syncPullsSent += 1 } }
    func recordSyncBatch(milliseconds: Double, records: Int) {
        lock.withLock {
            state.syncBatchesReceived += 1
            state.syncRecordsReceived += records
            state.syncPullMilliseconds.append(milliseconds)
        }
    }
    func recordSyncAcknowledged() { lock.withLock { state.syncAcknowledged += 1 } }
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
        let statistics = LoadStatistics()
        let startedAt = Date()
        var channels: [Channel] = []
        var terminalError: Error?

        do {
            var offset = 0
            while offset < credentials.count {
                let upperBound = min(credentials.count, offset + configuration.rampBatchSize)
                let batch = credentials[offset..<upperBound]
                let batchStart = NIODeadline.now()
                let futures = batch.enumerated().map { localIndex, credential in
                    let connectionIndex = offset + localIndex
                    let targetUserIDs = configuration.messagesPerSecond > 0
                        ? (configuration.targetOffset..<(configuration.targetOffset + configuration.targetsPerConnection)).map {
                            credentials[(connectionIndex + $0) % credentials.count].userID
                        }
                        : []
                    return connect(
                        credential: credential,
                        targetUserIDs: targetUserIDs,
                        connectionIndex: connectionIndex,
                        group: group,
                        sslContext: sslContext,
                        statistics: statistics
                    )
                }
                let results = try await EventLoopFuture.whenAllComplete(futures, on: group.next()).get()
                for result in results {
                    switch result {
                    case .success(let channel): channels.append(channel)
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

            if configuration.messagesPerSecond > 0 {
                try await startWorkloads(channels: channels)
            }

            for second in 1...configuration.holdSeconds {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try enforceGuards(statistics: statistics)
                if second.isMultiple(of: 10) || second == configuration.holdSeconds {
                    let snapshot = statistics.snapshot()
                    print("hold second=\(second) active=\(snapshot.active) heartbeat_ack=\(snapshot.heartbeatAcknowledged) missed=\(snapshot.heartbeatMissed) messages_ack=\(snapshot.messagesAcknowledged) sync_records=\(snapshot.syncRecordsReceived) workload_failed=\(snapshot.workloadFailed) rss_mb=\(snapshot.maximumRSSBytes / 1_048_576)")
                }
            }
        } catch {
            terminalError = error
        }

        await close(channels: channels)
        try await group.shutdownGracefully()
        let report = LoadReport(configuration: configuration, startedAt: startedAt, endedAt: Date(), state: statistics.snapshot(), terminalError: terminalError)
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
        return ClientBootstrap(group: eventLoop)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
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
                            messagesPerSecond: configuration.messagesPerSecond,
                            totalConnections: configuration.connections,
                            maximumInFlightMessagesPerConnection: configuration.maximumInFlightMessagesPerConnection,
                            messageBytes: configuration.messageBytes,
                            syncReads: configuration.syncReads,
                            started: started,
                            authenticated: authenticated,
                            statistics: statistics
                        )
                    )
                }
            }
            .connect(host: configuration.host, port: configuration.port)
            .flatMap { channel in authenticated.futureResult.map { channel } }
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
        let unexpectedDisconnects = max(0, snapshot.authenticated - snapshot.active)
        guard snapshot.authenticated == 0 || Double(unexpectedDisconnects) / Double(snapshot.authenticated) * 100 <= configuration.maximumFailurePercent else {
            throw LoadError.connectionLossGuardTriggered(
                disconnected: unexpectedDisconnects,
                authenticated: snapshot.authenticated
            )
        }
        let workloadAttempted = snapshot.directRoomAttempted + snapshot.messagesSent + snapshot.syncPullsSent
        guard workloadAttempted == 0 || Double(snapshot.workloadFailed) / Double(workloadAttempted) * 100 <= configuration.maximumFailurePercent else {
            throw LoadError.workloadFailureGuardTriggered(failed: snapshot.workloadFailed, attempted: workloadAttempted)
        }
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

private final class LoadConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Stage { case awaitingHello, awaitingAuthentication, authenticated }
    private enum PendingRequest {
        case heartbeat(sent: NIODeadline)
        case directRoom(targetUserID: String, sent: NIODeadline)
        case message(sent: NIODeadline, roomID: String)
        case syncPull(sent: NIODeadline)
        case syncAck(hasMore: Bool)
    }

    private let credential: LoadCredential
    private let targetUserIDs: [String]
    private let connectionIndex: Int
    private let heartbeatSeconds: Int
    private let messageIntervalMilliseconds: Int64?
    private let messageInitialDelayMilliseconds: Int64
    private let maximumInFlightMessagesPerConnection: Int
    private let messageText: String
    private let syncReads: Bool
    private let started: NIODeadline
    private let authenticatedPromise: EventLoopPromise<Void>
    private let statistics: LoadStatistics
    private let limits = try! V2FrameLimits(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
    private var decoder: V2FrameDecoder
    private var stage: Stage = .awaitingHello
    private var nextRequestID: UInt64 = 3
    private var pendingRequests: [UInt64: PendingRequest] = [:]
    private var heartbeatRequestID: UInt64?
    private var messageRequestIDs: Set<UInt64> = []
    private var directRoomIDs: [String] = []
    private var nextRoomIndex = 0
    private var nextSyncToken = ""
    private var syncInFlight = false
    private var syncRequested = false
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
        messagesPerSecond: Int,
        totalConnections: Int,
        maximumInFlightMessagesPerConnection: Int,
        messageBytes: Int,
        syncReads: Bool,
        started: NIODeadline,
        authenticated: EventLoopPromise<Void>,
        statistics: LoadStatistics
    ) {
        self.credential = credential
        self.targetUserIDs = targetUserIDs
        self.connectionIndex = connectionIndex
        self.heartbeatSeconds = heartbeatSeconds
        self.maximumInFlightMessagesPerConnection = maximumInFlightMessagesPerConnection
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
            try write(hello, frameVersion: 0, context: context)
        } catch {
            failAuthentication(error, context: context)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do {
            let bytes = Data(unwrapInboundIn(data).readableBytesView)
            for frame in try decoder.append(bytes) { try receive(frame, context: context) }
        } catch {
            failAuthentication(error, context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        heartbeatTask?.cancel()
        messageTask?.cancel()
        if registered { statistics.recordDisconnected() }
        if !authenticationCompleted { failAuthentication(LoadError.connectionClosed, context: context, close: false) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAuthentication(error, context: context)
    }

    private func receive(_ frame: V2Frame, context: ChannelHandlerContext) throws {
        let envelope = try V2ServerProtobufFrameCodec.decode(frame)
        if frame.requestID == 0 {
            if case .authenticated = stage, case .syncAvailable? = envelope.body, syncReads, !targetUserIDs.isEmpty {
                syncRequested = true
                try startSyncIfNeeded(context: context)
            }
            return
        }
        switch stage {
        case .awaitingHello:
            guard frame.requestID == 1,
                  case .serverHello(let response)? = envelope.body,
                  response.selectedProtocolVersion == IMV2ProtocolVersion.current
            else { throw LoadError.unexpectedResponse }
            stage = .awaitingAuthentication
            var authenticate = IMV2Envelope()
            authenticate.requestID = 2
            authenticate.protocolVersion = IMV2ProtocolVersion.current
            authenticate.authenticate = .init()
            authenticate.authenticate.accessToken = credential.accessToken
            authenticate.authenticate.deviceID = credential.deviceID
            try write(authenticate, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)

        case .awaitingAuthentication:
            guard frame.requestID == 2,
                  case .authenticated(let response)? = envelope.body,
                  response.deviceID == credential.deviceID
            else { throw LoadError.unexpectedResponse }
            stage = .authenticated
            authenticationCompleted = true
            registered = true
            statistics.recordAuthenticated(milliseconds: (NIODeadline.now() - started).millisecondsDouble)
            authenticatedPromise.succeed(())
            scheduleHeartbeat(context: context)

        case .authenticated:
            guard let pending = pendingRequests.removeValue(forKey: frame.requestID) else { return }
            if case .error(let error)? = envelope.body {
                handleRejected(
                    pending,
                    requestID: frame.requestID,
                    code: error.code,
                    retryable: error.retryable
                )
                return
            }
            switch pending {
            case .heartbeat(let sent):
                heartbeatRequestID = nil
                guard case .heartbeatAck? = envelope.body else { throw LoadError.unexpectedResponse }
                statistics.recordHeartbeatAcknowledged(milliseconds: (NIODeadline.now() - sent).millisecondsDouble)

            case .directRoom(let targetUserID, _):
                guard case .directRoomOpened(let response)? = envelope.body,
                      response.targetUserID == targetUserID,
                      !response.roomID.isEmpty
                else { throw LoadError.unexpectedResponse }
                if !directRoomIDs.contains(response.roomID) { directRoomIDs.append(response.roomID) }
                statistics.recordDirectRoomOpened()
                if directRoomIDs.count == targetUserIDs.count { scheduleMessages(context: context) }

            case .message(let sent, let roomID):
                messageRequestIDs.remove(frame.requestID)
                guard case .messageAccepted(let response)? = envelope.body,
                      response.roomID == roomID,
                      response.roomSequence > 0
                else { throw LoadError.unexpectedResponse }
                statistics.recordMessageAcknowledged(milliseconds: (NIODeadline.now() - sent).millisecondsDouble)

            case .syncPull(let sent):
                guard case .syncBatch(let batch)? = envelope.body,
                      batch.generation > 0,
                      !batch.nextSyncToken.isEmpty,
                      !batch.syncReceipt.isEmpty
                else { throw LoadError.unexpectedResponse }
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

            case .syncAck(let hasMore):
                guard case .acknowledged? = envelope.body else { throw LoadError.unexpectedResponse }
                statistics.recordSyncAcknowledged()
                syncInFlight = false
                if hasMore || syncRequested { try startSyncIfNeeded(context: context) }
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard event is StartWorkloadEvent else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        guard case .authenticated = stage, !workloadStarted, context.channel.isActive else { return }
        workloadStarted = true
        do {
            for targetUserID in targetUserIDs {
                try sendOpenDirectRoom(targetUserID: targetUserID, context: context)
            }
        } catch {
            failAuthentication(error, context: context)
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

    private func sendOpenDirectRoom(targetUserID: String, context: ChannelHandlerContext) throws {
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.openDirectRoom = .init()
        request.openDirectRoom.operationID = UUID().uuidString
        request.openDirectRoom.targetUserID = targetUserID
        pendingRequests[requestID] = .directRoom(targetUserID: targetUserID, sent: .now())
        statistics.recordDirectRoomAttempted()
        try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    private func scheduleMessages(context: ChannelHandlerContext) {
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

    private func sendMessage(context: ChannelHandlerContext) throws {
        guard !directRoomIDs.isEmpty else { return }
        guard messageRequestIDs.count < maximumInFlightMessagesPerConnection else {
            statistics.recordMessageSkipped()
            return
        }
        let directRoomID = directRoomIDs[nextRoomIndex % directRoomIDs.count]
        nextRoomIndex += 1
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
        retryable: Bool
    ) {
        switch pending {
        case .heartbeat:
            heartbeatRequestID = nil
            statistics.recordHeartbeatMissed()
        case .message:
            messageRequestIDs.remove(requestID)
            statistics.recordWorkloadFailure(kind: "message", code: code, retryable: retryable)
        case .syncPull, .syncAck:
            syncInFlight = false
            statistics.recordWorkloadFailure(kind: "sync", code: code, retryable: retryable)
        case .directRoom:
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
        if !authenticationCompleted {
            authenticationCompleted = true
            authenticatedPromise.fail(error)
        }
        if close { context.close(promise: nil) }
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
    let startedAt: Date
    let endedAt: Date
    let attempted: Int
    let authenticated: Int
    let failed: Int
    let connectionFailuresByError: [String: Int]
    let peakActive: Int
    let disconnected: Int
    let heartbeatSent: Int
    let heartbeatAcknowledged: Int
    let heartbeatMissed: Int
    let directRoomAttempted: Int
    let directRoomOpened: Int
    let workloadFailed: Int
    let workloadFailuresByKindAndCode: [String: Int]
    let messagesSent: Int
    let messagesAcknowledged: Int
    let messagesSkipped: Int
    let syncPullsSent: Int
    let syncBatchesReceived: Int
    let syncRecordsReceived: Int
    let syncAcknowledged: Int
    let maximumRSSMegabytes: Double
    let authenticationLatency: Percentiles
    let heartbeatLatency: Percentiles
    let messageLatency: Percentiles
    let syncPullLatency: Percentiles
    let terminalError: String?

    init(configuration: LoadConfiguration, startedAt: Date, endedAt: Date, state: LoadStatistics.State, terminalError: Error?) {
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
        self.startedAt = startedAt
        self.endedAt = endedAt
        attempted = state.attempted
        authenticated = state.authenticated
        failed = state.failed
        connectionFailuresByError = state.connectionFailuresByError
        peakActive = state.peakActive
        disconnected = state.disconnected
        heartbeatSent = state.heartbeatSent
        heartbeatAcknowledged = state.heartbeatAcknowledged
        heartbeatMissed = state.heartbeatMissed
        directRoomAttempted = state.directRoomAttempted
        directRoomOpened = state.directRoomOpened
        workloadFailed = state.workloadFailed
        workloadFailuresByKindAndCode = state.workloadFailuresByKindAndCode
        messagesSent = state.messagesSent
        messagesAcknowledged = state.messagesAcknowledged
        messagesSkipped = state.messagesSkipped
        syncPullsSent = state.syncPullsSent
        syncBatchesReceived = state.syncBatchesReceived
        syncRecordsReceived = state.syncRecordsReceived
        syncAcknowledged = state.syncAcknowledged
        maximumRSSMegabytes = Double(state.maximumRSSBytes) / 1_048_576
        authenticationLatency = .init(samples: state.authenticationMilliseconds)
        heartbeatLatency = .init(samples: state.heartbeatMilliseconds)
        messageLatency = .init(samples: state.messageMilliseconds)
        syncPullLatency = .init(samples: state.syncPullMilliseconds)
        self.terminalError = terminalError.map(String.init(describing:))
    }

    var summary: String {
        "load complete requested=\(requestedConnections) authenticated=\(authenticated) failed=\(failed) peak_active=\(peakActive) messages_ack=\(messagesAcknowledged) sync_records=\(syncRecordsReceived) workload_failed=\(workloadFailed) auth_p95_ms=\(authenticationLatency.p95) heartbeat_p95_ms=\(heartbeatLatency.p95) message_p95_ms=\(messageLatency.p95) sync_p95_ms=\(syncPullLatency.p95) max_rss_mb=\(String(format: "%.1f", maximumRSSMegabytes))"
    }
}

private struct Percentiles: Encodable {
    let count: Int
    let p50: Double
    let p95: Double
    let p99: Double
    let maximum: Double

    init(samples: [Double]) {
        let sorted = samples.sorted()
        count = sorted.count
        p50 = Self.value(sorted, percentile: 0.50)
        p95 = Self.value(sorted, percentile: 0.95)
        p99 = Self.value(sorted, percentile: 0.99)
        maximum = sorted.last ?? 0
    }

    private static func value(_ sorted: [Double], percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded(.up)))
        return (sorted[index] * 100).rounded() / 100
    }
}

private enum LoadError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidCredentialFile
    case insufficientCredentials(required: Int, available: Int)
    case unexpectedResponse
    case connectionClosed
    case memoryGuardTriggered(megabytes: Int)
    case failureGuardTriggered(failed: Int, attempted: Int)
    case connectionLossGuardTriggered(disconnected: Int, authenticated: Int)
    case workloadFailureGuardTriggered(failed: Int, attempted: Int)

    var description: String {
        switch self {
        case .invalidArguments:
            return "invalid arguments; required: --host --ca-path --credentials --report"
        case .invalidCredentialFile: return "credential file is empty, duplicated, or malformed"
        case .insufficientCredentials(let required, let available): return "insufficient credentials: required \(required), available \(available)"
        case .unexpectedResponse: return "gateway returned an unexpected protocol response"
        case .connectionClosed: return "gateway connection closed before authentication"
        case .memoryGuardTriggered(let megabytes): return "local memory guard triggered at \(megabytes) MB"
        case .failureGuardTriggered(let failed, let attempted): return "connection failure guard triggered: \(failed)/\(attempted)"
        case .connectionLossGuardTriggered(let disconnected, let authenticated): return "active connection loss guard triggered: \(disconnected)/\(authenticated)"
        case .workloadFailureGuardTriggered(let failed, let attempted): return "message workload failure guard triggered: \(failed)/\(attempted)"
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
    #elseif canImport(Glibc)
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
