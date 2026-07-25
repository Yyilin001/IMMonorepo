import Foundation
import Network

struct Options: Sendable {
    var profile = "local-smoke"
    var baseURL = URL(string: "http://127.0.0.1:8080")!
    var tcpHost = "127.0.0.1"
    var tcpPort: UInt16 = 9001
    var email = ProcessInfo.processInfo.environment["IM_EMAIL"] ?? "demo@example.com"
    var password = ProcessInfo.processInfo.environment["IM_PASSWORD"] ?? "password1234"
    var accountFile: String?
    var accountDevicesPerUser = ProcessInfo.processInfo.environment["IM_TCP_ACCOUNT_DEVICES_PER_USER"].flatMap(Int.init(_:)) ?? 1
    var conversationID = ProcessInfo.processInfo.environment["IM_CONVERSATION_ID"] ?? ""
    var connections = 100
    var devicesPerUser = 1
    var messagesPerConnection = 1
    var sendIntervalMillis = 0
    var messageProfile = ProcessInfo.processInfo.environment["IM_TCP_MESSAGE_PROFILE"] ?? "per-connection"
    var messageCompletionMode = ProcessInfo.processInfo.environment["IM_TCP_MESSAGE_COMPLETION_MODE"] ?? "full"
    var messageRatePerSecond = ProcessInfo.processInfo.environment["IM_TCP_MESSAGE_RATE_PER_SECOND"]
        .flatMap(Double.init(_:)) ?? 0
    var messageSenderEvery = ProcessInfo.processInfo.environment["IM_TCP_MESSAGE_SENDER_EVERY"].flatMap(Int.init(_:)) ?? 1
    var messageReceiverOffset = ProcessInfo.processInfo.environment["IM_TCP_MESSAGE_RECEIVER_OFFSET"].flatMap(Int.init(_:)) ?? 1
    var activeConversationUsers = ProcessInfo.processInfo.environment["IM_TCP_ACTIVE_CONVERSATION_USERS"].flatMap(Int.init(_:)) ?? 0
    var holdSeconds = 0
    var connectRampSeconds = 0
    var loginConcurrency = ProcessInfo.processInfo.environment["IM_TCP_LOGIN_CONCURRENCY"].flatMap(Int.init(_:)) ?? 5
    var timeoutSeconds = 20
    var protocolVersion = ProcessInfo.processInfo.environment["IM_TCP_PROTOCOL_VERSION"].flatMap(UInt64.init(_:)) ?? 12
    var connectionLogFile: String?
    var heartbeatIntervalSeconds = ProcessInfo.processInfo.environment["IM_TCP_HEARTBEAT_INTERVAL"].flatMap(Int.init(_:)) ?? 0
    var heartbeatJitterSeconds = ProcessInfo.processInfo.environment["IM_TCP_HEARTBEAT_JITTER_SECONDS"].flatMap(Int.init(_:)) ?? -1
    var heartbeatLogMode = ProcessInfo.processInfo.environment["IM_TCP_HEARTBEAT_LOG_MODE"] ?? "errors"
    var heartbeatLogSampleRate = ProcessInfo.processInfo.environment["IM_TCP_HEARTBEAT_LOG_SAMPLE_RATE"].flatMap(Int.init(_:)) ?? 100
    var loginCacheFile: String?
    var loginOnly = false
    var loginMode = ProcessInfo.processInfo.environment["IM_TCP_LOGIN_MODE"] ?? "upfront"
    var requireLoginCache = ["1", "true", "yes", "y"]
        .contains((ProcessInfo.processInfo.environment["IM_TCP_REQUIRE_LOGIN_CACHE"] ?? "false").lowercased())
    var loginCacheTTLGuardSeconds = ProcessInfo.processInfo.environment["IM_TCP_LOGIN_CACHE_TTL_GUARD_SECONDS"]
        .flatMap(Int.init(_:)) ?? 60
    var connectionQueuePoolSize = ProcessInfo.processInfo.environment["IM_TCP_CONNECTION_QUEUE_POOL_SIZE"]
        .flatMap(Int.init(_:)) ?? max(8, min(64, ProcessInfo.processInfo.activeProcessorCount * 4))
    var maxReconnects = ProcessInfo.processInfo.environment["IM_TCP_MAX_RECONNECTS"].flatMap(Int.init(_:)) ?? 0
    var minReconnects = ProcessInfo.processInfo.environment["IM_TCP_MIN_RECONNECTS"].flatMap(Int.init(_:)) ?? 0
    var reconnectDelayMillis = ProcessInfo.processInfo.environment["IM_TCP_RECONNECT_DELAY_MS"].flatMap(Int.init(_:)) ?? 1_000
    var loginRetries = ProcessInfo.processInfo.environment["IM_TCP_LOGIN_RETRIES"].flatMap(Int.init(_:)) ?? 2
    var loginRetryDelayMillis = ProcessInfo.processInfo.environment["IM_TCP_LOGIN_RETRY_DELAY_MS"].flatMap(Int.init(_:)) ?? 1_000
    var globalHoldBarrierMinRatio = ProcessInfo.processInfo.environment["IM_TCP_GLOBAL_HOLD_BARRIER_MIN_RATIO"]
        .flatMap(Double.init(_:)) ?? 1.0
}

struct LoginResponse: Codable, Sendable {
    struct User: Codable, Sendable {
        let id: String
    }

    let accessToken: String
    let expiresIn: Int
    let user: User
}

struct AccountCredential: Sendable {
    let email: String
    let password: String
}

struct ConnectionLogin: Sendable {
    let auth: LoginResponse
    let loginIndex: Int
    let email: String
    let deviceID: String
    let deviceName: String
}

struct LoginCacheRecord: Codable, Sendable {
    let loginIndex: Int
    let email: String
    let deviceID: String
    let deviceName: String
    let userID: String
    let accessToken: String
    let expiresAtMs: Int64
}

struct LoginCacheLoadResult: Sendable {
    let logins: [ConnectionLogin]
    let records: Int
    let validForSeconds: Int
}

struct ConnectionResult: Sendable {
    let success: Bool
    let failureReason: String?
    let sent: Int
    let acknowledgements: Int
    let canonicalMessages: Int
    let duplicateCanonicalMessages: Int
    let deliveredMessages: Int
    let duplicateDeliveredMessages: Int
    let fanoutMessages: Int
    let activityHints: Int
    let reconnects: Int
    let serverErrors: Int
    let heartbeatSends: Int
    let heartbeatAcks: Int
    let heartbeatSendCompletionMillis: [Double]
    let ackLatenciesMillis: [Double]
    let canonicalLatenciesMillis: [Double]
    let deliveryLatenciesMillis: [Double]
}

final class ConnectionEventLogger: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = Date()
    private let fileHandle: FileHandle?
    let path: String?

    init(path: String?) throws {
        self.path = path
        guard let path, !path.isEmpty else {
            self.fileHandle = nil
            return
        }

        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: url)
    }

    deinit {
        fileHandle?.closeFile()
    }

    func log(
        _ event: String,
        connectionIndex: Int? = nil,
        loginIndex: Int? = nil,
        fields: [String: String] = [:]
    ) {
        guard let fileHandle else {
            return
        }

        var object: [String: Any] = [
            "event": event,
            "timestampMs": Int64(Date().timeIntervalSince1970 * 1_000),
            "elapsedMs": Int(Date().timeIntervalSince(startedAt) * 1_000)
        ]
        if let connectionIndex {
            object["connectionIndex"] = connectionIndex
        }
        if let loginIndex {
            object["loginIndex"] = loginIndex
        }
        for (key, value) in fields {
            object[key] = value
        }

        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return
        }

        lock.lock()
        fileHandle.write(data)
        fileHandle.write(Data("\n".utf8))
        lock.unlock()
    }
}

actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        self.available = max(1, permits)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class ConnectionQueuePool: @unchecked Sendable {
    private let queues: [DispatchQueue]

    init(size: Int) {
        let count = max(1, size)
        self.queues = (0..<count).map { index in
            DispatchQueue(label: "im.tcp.load.pool.\(index)")
        }
    }

    var size: Int {
        queues.count
    }

    func queue(for connectionIndex: Int) -> DispatchQueue {
        queues[connectionIndex % queues.count]
    }
}

struct GlobalHoldBarrierRelease: Sendable {
    let success: Bool
    let reason: String
    let authenticated: Int
    let target: Int
    let elapsedMillis: Int
}

final class GlobalHoldBarrier: @unchecked Sendable {
    typealias Waiter = @Sendable (GlobalHoldBarrierRelease) -> Void

    private let lock = NSLock()
    private let target: Int
    private let logger: ConnectionEventLogger
    private let startedAt = Date()
    private var authenticated = 0
    private var waiters: [Waiter] = []
    private var release: GlobalHoldBarrierRelease?

    init(target: Int, logger: ConnectionEventLogger) {
        self.target = max(1, target)
        self.logger = logger
    }

    func scheduleTimeout(seconds: Int, queue: DispatchQueue) {
        let timeoutSeconds = max(1, seconds)
        logger.log(
            "global_hold_barrier_timeout_scheduled",
            fields: [
                "target": String(target),
                "timeoutSeconds": String(timeoutSeconds)
            ]
        )
        queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
            self.releaseIfNeeded(success: false, reason: "global_hold_barrier_timeout")
        }
    }

    func arriveAndWait(
        connectionIndex: Int,
        loginIndex: Int,
        queue: DispatchQueue,
        onRelease: @escaping Waiter
    ) {
        let callback: Waiter = { release in
            queue.async {
                onRelease(release)
            }
        }

        let releaseToDeliver: GlobalHoldBarrierRelease?
        let callbacksToDeliver: [Waiter]
        let currentAuthenticated: Int
        lock.lock()
        if let release {
            lock.unlock()
            logger.log(
                "global_hold_barrier_already_released",
                connectionIndex: connectionIndex,
                loginIndex: loginIndex,
                fields: [
                    "success": String(release.success),
                    "reason": release.reason,
                    "authenticated": String(release.authenticated),
                    "target": String(release.target)
                ]
            )
            callback(release)
            return
        }

        authenticated += 1
        currentAuthenticated = authenticated
        waiters.append(callback)
        if authenticated >= target {
            releaseToDeliver = makeReleaseLocked(success: true, reason: "all_authenticated")
            callbacksToDeliver = waiters
            waiters.removeAll()
        } else {
            releaseToDeliver = nil
            callbacksToDeliver = []
        }
        lock.unlock()

        logger.log(
            "global_hold_barrier_auth_ok",
            connectionIndex: connectionIndex,
            loginIndex: loginIndex,
            fields: [
                "authenticated": String(currentAuthenticated),
                "target": String(target)
            ]
        )

        if let releaseToDeliver {
            logRelease(releaseToDeliver)
            callbacksToDeliver.forEach { $0(releaseToDeliver) }
        }
    }

    private func releaseIfNeeded(success: Bool, reason: String) {
        let releaseToDeliver: GlobalHoldBarrierRelease?
        let callbacksToDeliver: [Waiter]
        lock.lock()
        if release != nil {
            lock.unlock()
            return
        }
        releaseToDeliver = makeReleaseLocked(success: success, reason: reason)
        callbacksToDeliver = waiters
        waiters.removeAll()
        lock.unlock()

        if let releaseToDeliver {
            logRelease(releaseToDeliver)
            callbacksToDeliver.forEach { $0(releaseToDeliver) }
        }
    }

    private func makeReleaseLocked(success: Bool, reason: String) -> GlobalHoldBarrierRelease {
        let value = GlobalHoldBarrierRelease(
            success: success,
            reason: reason,
            authenticated: authenticated,
            target: target,
            elapsedMillis: Int(Date().timeIntervalSince(startedAt) * 1_000)
        )
        release = value
        return value
    }

    private func logRelease(_ release: GlobalHoldBarrierRelease) {
        logger.log(
            "global_hold_barrier_released",
            fields: [
                "success": String(release.success),
                "reason": release.reason,
                "authenticated": String(release.authenticated),
                "target": String(release.target),
                "elapsedMs": String(release.elapsedMillis)
            ]
        )
    }
}

struct ScheduledMessage: Sendable {
    let messageIndex: Int
    let delayMillis: Int
    let receiverIndex: Int?
}

struct MessageDeliveryRecord {
    let senderIndex: Int
    let receiverIndex: Int
    let sentAt: Date
    var deliveredTo: Set<Int> = []
}

final class MessageDeliveryTracker: @unchecked Sendable {
    struct DeliveryResult: Sendable {
        let accepted: Bool
        let duplicate: Bool
        let latencyMillis: Double
        let senderIndex: Int
    }

    private let lock = NSLock()
    private var records: [String: MessageDeliveryRecord] = [:]
    private var clientMessageIDsByServerMessageID: [String: String] = [:]

    func register(clientMessageID: String, senderIndex: Int, receiverIndex: Int, sentAt: Date) {
        lock.lock()
        records[clientMessageID] = MessageDeliveryRecord(
            senderIndex: senderIndex,
            receiverIndex: receiverIndex,
            sentAt: sentAt
        )
        lock.unlock()
    }

    func registerServerMessageID(_ serverMessageID: String, forClientMessageID clientMessageID: String) {
        guard !serverMessageID.isEmpty else {
            return
        }
        lock.lock()
        clientMessageIDsByServerMessageID[serverMessageID] = clientMessageID
        lock.unlock()
    }

    func recordDelivery(clientMessageID: String, receiverIndex: Int, at date: Date = Date()) -> DeliveryResult? {
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[clientMessageID], record.receiverIndex == receiverIndex else {
            return nil
        }
        let duplicate = record.deliveredTo.contains(receiverIndex)
        if !duplicate {
            record.deliveredTo.insert(receiverIndex)
            records[clientMessageID] = record
        }
        return DeliveryResult(
            accepted: !duplicate,
            duplicate: duplicate,
            latencyMillis: date.timeIntervalSince(record.sentAt) * 1_000,
            senderIndex: record.senderIndex
        )
    }

    func recordHintDelivery(serverMessageID: String, receiverIndex: Int, at date: Date = Date()) -> DeliveryResult? {
        lock.lock()
        guard let clientMessageID = clientMessageIDsByServerMessageID[serverMessageID],
              var record = records[clientMessageID],
              record.receiverIndex == receiverIndex
        else {
            lock.unlock()
            return nil
        }
        let duplicate = record.deliveredTo.contains(receiverIndex)
        if !duplicate {
            record.deliveredTo.insert(receiverIndex)
            records[clientMessageID] = record
        }
        lock.unlock()
        return DeliveryResult(
            accepted: !duplicate,
            duplicate: duplicate,
            latencyMillis: date.timeIntervalSince(record.sentAt) * 1_000,
            senderIndex: record.senderIndex
        )
    }
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let key = args.removeFirst()
        guard !args.isEmpty else { break }
        let value = args.removeFirst()
        switch key {
        case "--profile":
            options.profile = value
        case "--base-url":
            options.baseURL = URL(string: value)!
        case "--tcp-host":
            options.tcpHost = value
        case "--tcp-port":
            options.tcpPort = UInt16(value) ?? options.tcpPort
        case "--email":
            options.email = value
        case "--password":
            options.password = value
        case "--account-file":
            options.accountFile = value
        case "--account-devices-per-user":
            options.accountDevicesPerUser = max(1, Int(value) ?? options.accountDevicesPerUser)
        case "--conversation-id":
            options.conversationID = value
        case "--connections":
            options.connections = Int(value) ?? options.connections
        case "--devices-per-user":
            options.devicesPerUser = max(1, Int(value) ?? options.devicesPerUser)
        case "--messages":
            options.messagesPerConnection = Int(value) ?? options.messagesPerConnection
        case "--send-interval-ms":
            options.sendIntervalMillis = max(0, Int(value) ?? options.sendIntervalMillis)
        case "--message-profile":
            options.messageProfile = value
        case "--message-completion-mode":
            options.messageCompletionMode = value
        case "--message-rate-per-second":
            options.messageRatePerSecond = max(0, Double(value) ?? options.messageRatePerSecond)
        case "--message-sender-every":
            options.messageSenderEvery = max(1, Int(value) ?? options.messageSenderEvery)
        case "--message-receiver-offset":
            options.messageReceiverOffset = Int(value) ?? options.messageReceiverOffset
        case "--active-conversation-users":
            options.activeConversationUsers = max(0, Int(value) ?? options.activeConversationUsers)
        case "--hold-seconds":
            options.holdSeconds = max(0, Int(value) ?? options.holdSeconds)
        case "--connect-ramp-seconds":
            options.connectRampSeconds = max(0, Int(value) ?? options.connectRampSeconds)
        case "--login-concurrency":
            options.loginConcurrency = max(1, Int(value) ?? options.loginConcurrency)
        case "--timeout-seconds":
            options.timeoutSeconds = max(1, Int(value) ?? options.timeoutSeconds)
        case "--protocol-version":
            options.protocolVersion = UInt64(value) ?? options.protocolVersion
        case "--connection-log-file":
            options.connectionLogFile = value
        case "--heartbeat-interval-seconds":
            options.heartbeatIntervalSeconds = max(0, Int(value) ?? options.heartbeatIntervalSeconds)
        case "--heartbeat-jitter-seconds":
            options.heartbeatJitterSeconds = max(0, Int(value) ?? options.heartbeatJitterSeconds)
        case "--heartbeat-log-mode":
            options.heartbeatLogMode = value
        case "--heartbeat-log-sample-rate":
            options.heartbeatLogSampleRate = max(1, Int(value) ?? options.heartbeatLogSampleRate)
        case "--login-cache-file":
            options.loginCacheFile = value
        case "--login-only":
            options.loginOnly = ["1", "true", "yes", "y"].contains(value.lowercased())
        case "--login-mode":
            options.loginMode = value
        case "--require-login-cache":
            options.requireLoginCache = ["1", "true", "yes", "y"].contains(value.lowercased())
        case "--login-cache-ttl-guard-seconds":
            options.loginCacheTTLGuardSeconds = max(0, Int(value) ?? options.loginCacheTTLGuardSeconds)
        case "--connection-queue-pool-size":
            options.connectionQueuePoolSize = max(1, Int(value) ?? options.connectionQueuePoolSize)
        case "--max-reconnects":
            options.maxReconnects = max(0, Int(value) ?? options.maxReconnects)
        case "--min-reconnects":
            options.minReconnects = max(0, Int(value) ?? options.minReconnects)
        case "--reconnect-delay-ms":
            options.reconnectDelayMillis = max(0, Int(value) ?? options.reconnectDelayMillis)
        case "--login-retries":
            options.loginRetries = max(0, Int(value) ?? options.loginRetries)
        case "--login-retry-delay-ms":
            options.loginRetryDelayMillis = max(0, Int(value) ?? options.loginRetryDelayMillis)
        case "--global-hold-barrier-min-ratio":
            options.globalHoldBarrierMinRatio = Double(value) ?? options.globalHoldBarrierMinRatio
        default:
            continue
        }
    }
    options.globalHoldBarrierMinRatio = min(1.0, max(0.0, options.globalHoldBarrierMinRatio))
    options.accountDevicesPerUser = max(1, options.accountDevicesPerUser)
    options.activeConversationUsers = min(options.connections, max(0, options.activeConversationUsers))
    options.messageProfile = options.messageProfile.lowercased()
    if !["per-connection", "pair-delivery"].contains(options.messageProfile) {
        options.messageProfile = "per-connection"
    }
    options.messageCompletionMode = options.messageCompletionMode.lowercased()
    if !["full", "ack-only", "hint"].contains(options.messageCompletionMode) {
        options.messageCompletionMode = "full"
    }
    options.messageSenderEvery = max(1, options.messageSenderEvery)
    if options.connections > 0 {
        options.messageReceiverOffset = ((options.messageReceiverOffset % options.connections) + options.connections) % options.connections
        if options.messageReceiverOffset == 0 && options.connections > 1 {
            options.messageReceiverOffset = 1
        }
    }

    switch options.profile {
    case "custom":
        options.connections = max(options.connections, 1)
        options.messagesPerConnection = max(options.messagesPerConnection, 0)
    case "staging-baseline":
        options.connections = max(options.connections, 10_000)
        options.devicesPerUser = max(options.devicesPerUser, 2)
        options.messagesPerConnection = max(options.messagesPerConnection, 3)
    case "capacity-target":
        options.connections = max(options.connections, 50_000)
        options.devicesPerUser = max(options.devicesPerUser, 2)
        options.messagesPerConnection = max(options.messagesPerConnection, 3)
    default:
        options.connections = min(options.connections, 100)
        options.messagesPerConnection = max(options.messagesPerConnection, 1)
    }
    return options
}

func loadAccountCredentials(options: Options) throws -> [AccountCredential] {
    guard let accountFile = options.accountFile else {
        return [AccountCredential(email: options.email, password: options.password)]
    }

    let contents = try String(contentsOfFile: accountFile, encoding: .utf8)
    let credentials = contents
        .split(whereSeparator: \.isNewline)
        .compactMap { line -> AccountCredential? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                return nil
            }

            let columns = trimmed
                .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard columns.count == 2, !columns[0].isEmpty, !columns[1].isEmpty else {
                return nil
            }
            return AccountCredential(email: columns[0], password: columns[1])
        }

    guard !credentials.isEmpty else {
        throw NSError(
            domain: "IMTCPLoadDriver",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "account file has no usable email,password rows"]
        )
    }
    return credentials
}

func makeLoginURLSession(options: Options) -> URLSession {
    let configuration = URLSessionConfiguration.default
    configuration.httpMaximumConnectionsPerHost = max(options.loginConcurrency, 6)
    configuration.timeoutIntervalForRequest = TimeInterval(options.timeoutSeconds)
    configuration.timeoutIntervalForResource = TimeInterval(options.timeoutSeconds)
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
}

func login(
    options: Options,
    credential: AccountCredential,
    deviceID: String,
    deviceName: String,
    urlSession: URLSession
) async throws -> LoginResponse {
    var request = URLRequest(url: options.baseURL.appending(path: "/api/auth/login"))
    request.httpMethod = "POST"
    request.timeoutInterval = TimeInterval(options.timeoutSeconds)
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "email": credential.email,
        "password": credential.password,
        "device": [
            "deviceID": deviceID,
            "deviceName": deviceName,
            "platform": "load-test",
            "appVersion": "load-test"
        ]
    ])

    let (data, response) = try await urlSession.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        throw NSError(
            domain: "IMTCPLoadDriver",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "login failed status=\(status) body=\(body)"]
        )
    }
    return try JSONDecoder().decode(LoginResponse.self, from: data)
}

func nowEpochMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
}

func requiredLoginCacheValiditySeconds(options: Options) -> Int {
    max(
        options.connectRampSeconds
            + options.holdSeconds
            + options.timeoutSeconds
            + options.loginCacheTTLGuardSeconds,
        60
    )
}

func cachedLogins(options: Options, loginCount: Int, logger: ConnectionEventLogger) throws -> LoginCacheLoadResult? {
    guard let path = options.loginCacheFile, !path.isEmpty else {
        return nil
    }

    guard FileManager.default.fileExists(atPath: path) else {
        logger.log("login_cache_miss", fields: ["path": path, "reason": "file_missing"])
        return nil
    }

    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let records = try JSONDecoder().decode([LoginCacheRecord].self, from: data)
    guard records.count >= loginCount else {
        logger.log(
            "login_cache_miss",
            fields: [
                "path": path,
                "reason": "record_count",
                "records": String(records.count),
                "required": String(loginCount)
            ]
        )
        return nil
    }

    let requiredValidForSeconds = requiredLoginCacheValiditySeconds(options: options)
    let validUntilMs = nowEpochMillis() + Int64(requiredValidForSeconds * 1_000)
    let selected = Array(records.prefix(loginCount))
    let nowMs = nowEpochMillis()
    let validForSeconds = selected
        .map { Int(($0.expiresAtMs - nowMs) / 1_000) }
        .min() ?? 0
    guard selected.allSatisfy({ $0.expiresAtMs > validUntilMs }) else {
        logger.log(
            "login_cache_miss",
            fields: [
                "path": path,
                "reason": "expired_or_too_close",
                "requiredValidForSeconds": String(requiredValidForSeconds),
                "validForSeconds": String(validForSeconds)
            ]
        )
        return nil
    }

    logger.log(
        "login_cache_hit",
        fields: [
            "path": path,
            "records": String(selected.count),
            "validForSeconds": String(validForSeconds),
            "requiredValidForSeconds": String(requiredValidForSeconds)
        ]
    )
    let logins = selected.map { record in
        ConnectionLogin(
            auth: LoginResponse(
                accessToken: record.accessToken,
                expiresIn: max(0, Int((record.expiresAtMs - nowMs) / 1_000)),
                user: LoginResponse.User(id: record.userID)
            ),
            loginIndex: record.loginIndex,
            email: record.email,
            deviceID: record.deviceID,
            deviceName: record.deviceName
        )
    }
    return LoginCacheLoadResult(
        logins: logins,
        records: selected.count,
        validForSeconds: validForSeconds
    )
}

func writeLoginCache(path: String?, logins: [ConnectionLogin], logger: ConnectionEventLogger) throws {
    guard let path, !path.isEmpty else {
        return
    }

    let issuedAtMs = nowEpochMillis()
    let records = logins.map { login in
        LoginCacheRecord(
            loginIndex: login.loginIndex,
            email: login.email,
            deviceID: login.deviceID,
            deviceName: login.deviceName,
            userID: login.auth.user.id,
            accessToken: login.auth.accessToken,
            expiresAtMs: issuedAtMs + Int64(login.auth.expiresIn * 1_000)
        )
    }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(records).write(to: url, options: [.atomic])
    logger.log(
        "login_cache_written",
        fields: [
            "path": path,
            "records": String(records.count)
        ]
    )
}

func loginForConnection(
    options: Options,
    credential: AccountCredential,
    loginIndex: Int,
    logger: ConnectionEventLogger,
    urlSession: URLSession
) async throws -> ConnectionLogin {
    let deviceID = "tcp-load-driver-\(loginIndex)"
    let deviceName = "tcp-load-driver-\(loginIndex)"
    let loginStartedAt = Date()
    let maxAttempts = max(1, options.loginRetries + 1)
    logger.log(
        "login_start",
        loginIndex: loginIndex,
        fields: [
            "email": credential.email,
            "deviceID": deviceID,
            "maxAttempts": String(maxAttempts)
        ]
    )

    var lastError: Error?
    for attempt in 1...maxAttempts {
        let attemptStartedAt = Date()
        logger.log(
            "login_attempt_start",
            loginIndex: loginIndex,
            fields: [
                "email": credential.email,
                "deviceID": deviceID,
                "attempt": String(attempt),
                "maxAttempts": String(maxAttempts)
            ]
        )
        do {
            let auth = try await login(
                options: options,
                credential: credential,
                deviceID: deviceID,
                deviceName: deviceName,
                urlSession: urlSession
            )
            logger.log(
                "login_ok",
                loginIndex: loginIndex,
                fields: [
                    "email": credential.email,
                    "deviceID": deviceID,
                    "userID": auth.user.id,
                    "attempt": String(attempt),
                    "attemptDurationMs": String(Int(Date().timeIntervalSince(attemptStartedAt) * 1_000)),
                    "durationMs": String(Int(Date().timeIntervalSince(loginStartedAt) * 1_000))
                ]
            )
            return ConnectionLogin(
                auth: auth,
                loginIndex: loginIndex,
                email: credential.email,
                deviceID: deviceID,
                deviceName: deviceName
            )
        } catch {
            lastError = error
            logger.log(
                "login_attempt_failed",
                loginIndex: loginIndex,
                fields: [
                    "email": credential.email,
                    "deviceID": deviceID,
                    "attempt": String(attempt),
                    "maxAttempts": String(maxAttempts),
                    "attemptDurationMs": String(Int(Date().timeIntervalSince(attemptStartedAt) * 1_000)),
                    "error": String(describing: error)
                ]
            )
            guard attempt < maxAttempts else {
                break
            }
            logger.log(
                "login_retry_scheduled",
                loginIndex: loginIndex,
                fields: [
                    "email": credential.email,
                    "deviceID": deviceID,
                    "nextAttempt": String(attempt + 1),
                    "delayMs": String(options.loginRetryDelayMillis)
                ]
            )
            try? await Task.sleep(nanoseconds: UInt64(options.loginRetryDelayMillis) * 1_000_000)
        }
    }

    logger.log(
        "login_failed",
        loginIndex: loginIndex,
        fields: [
            "email": credential.email,
            "deviceID": deviceID,
            "durationMs": String(Int(Date().timeIntervalSince(loginStartedAt) * 1_000)),
            "error": lastError.map(String.init(describing:)) ?? "unknown"
        ]
    )
    throw lastError ?? NSError(
        domain: "IMTCPLoadDriver",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "login failed without captured error"]
    )
}

enum RealtimePacketType {
    case auth
    case authOK
    case authError
    case heartbeat
    case heartbeatAck
    case message
    case activityHint
    case ack
    case kick
}

extension RealtimePacketType {
    var logName: String {
        switch self {
        case .auth:
            return "auth"
        case .authOK:
            return "authOK"
        case .authError:
            return "authError"
        case .heartbeat:
            return "heartbeat"
        case .heartbeatAck:
            return "heartbeatAck"
        case .message:
            return "message"
        case .activityHint:
            return "activityHint"
        case .ack:
            return "ack"
        case .kick:
            return "kick"
        }
    }
}

struct DecodedRealtimePacket {
    let type: RealtimePacketType
    let requestID: String?
    let payload: [String: String]
}

enum ProtoWire {
    static func authFrame(
        accessToken: String,
        deviceID: String,
        deviceName: String,
        platform: String,
        appVersion: String,
        protocolVersion: UInt64,
        requestID: String = UUID().uuidString
    ) -> Data {
        var auth = Data()
        auth.writeString(field: 1, accessToken)
        auth.writeString(field: 2, deviceID)
        auth.writeString(field: 3, deviceName)
        auth.writeString(field: 4, platform)
        auth.writeString(field: 5, appVersion)

        var packet = packetBase(requestID: requestID, protocolVersion: protocolVersion)
        packet.writeMessage(field: 10, auth)
        return frame(packet)
    }

    static func messageFrame(
        conversationID: String,
        clientMessageID: String,
        text: String,
        requestID: String,
        protocolVersion: UInt64
    ) -> Data {
        var textContent = Data()
        textContent.writeString(field: 1, text)
        var content = Data()
        content.writeMessage(field: 1, textContent)

        var message = Data()
        message.writeString(field: 1, clientMessageID)
        message.writeString(field: 3, conversationID)
        message.writeMessage(field: 7, content)
        message.writeMessage(field: 8, Data())

        var packet = packetBase(requestID: requestID, protocolVersion: protocolVersion)
        packet.writeMessage(field: 30, message)
        return frame(packet)
    }

    static func heartbeatFrame(sequence: Int, requestID: String, protocolVersion: UInt64) -> Data {
        var heartbeat = Data()
        heartbeat.writeVarint(field: 1, UInt64(sequence))

        var packet = packetBase(requestID: requestID, protocolVersion: protocolVersion)
        packet.writeMessage(field: 20, heartbeat)
        return frame(packet)
    }

    static func conversationActivityFrame(
        conversationID: String,
        isActive: Bool,
        requestID: String,
        protocolVersion: UInt64
    ) -> Data {
        var activity = Data()
        activity.writeString(field: 1, conversationID)
        activity.writeVarint(field: 2, isActive ? 1 : 0)

        var packet = packetBase(requestID: requestID, protocolVersion: protocolVersion)
        packet.writeMessage(field: 60, activity)
        return frame(packet)
    }

    static func decodePacket(_ frame: Data) -> DecodedRealtimePacket? {
        var requestID: String?
        var type: RealtimePacketType?
        var payload: [String: String] = [:]
        for field in fields(in: frame) {
            switch field.number {
            case 1:
                requestID = field.stringValue
            case 11:
                type = .authOK
            case 12:
                type = .authError
            case 20:
                type = .heartbeat
            case 21:
                type = .heartbeatAck
            case 30:
                type = .message
                payload.merge(decodeMessagePayload(field.value)) { current, _ in current }
            case 31:
                type = .ack
                payload.merge(decodeAckPayload(field.value)) { current, _ in current }
            case 40:
                let domainEvent = decodeDomainEventPayload(field.value)
                type = domainEvent["eventKind"] == "activityHint" ? .activityHint : .message
                payload.merge(domainEvent) { current, _ in current }
            case 50:
                type = .kick
            default:
                continue
            }
        }
        guard let type else { return nil }
        return DecodedRealtimePacket(type: type, requestID: requestID, payload: payload)
    }

    static func frames(from buffer: inout Data) -> [Data] {
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let frameLength = Int(length)
            guard buffer.count >= 4 + frameLength else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(frameLength)))
            buffer.removeSubrange(0..<(4 + frameLength))
        }
        return frames
    }

    private static func packetBase(requestID: String, protocolVersion: UInt64) -> Data {
        var packet = Data()
        packet.writeString(field: 1, requestID)
        packet.writeVarint(field: 2, UInt64(Date().timeIntervalSince1970 * 1000))
        packet.writeVarint(field: 3, protocolVersion)
        return packet
    }

    private static func frame(_ packet: Data) -> Data {
        var framed = Data()
        let length = UInt32(packet.count)
        framed.append(UInt8((length >> 24) & 0xff))
        framed.append(UInt8((length >> 16) & 0xff))
        framed.append(UInt8((length >> 8) & 0xff))
        framed.append(UInt8(length & 0xff))
        framed.append(packet)
        return framed
    }

    private static func decodeAckPayload(_ data: Data) -> [String: String] {
        var payload: [String: String] = [:]
        for field in fields(in: data) {
            switch field.number {
            case 1:
                payload["messageID"] = field.stringValue
            case 2:
                payload["conversationID"] = field.stringValue
            case 3:
                payload["status"] = field.stringValue
            default:
                continue
            }
        }
        return payload
    }

    private static func decodeMessagePayload(_ data: Data) -> [String: String] {
        var payload: [String: String] = [:]
        for field in fields(in: data) {
            switch field.number {
            case 1:
                payload["clientMessageID"] = field.stringValue
            case 2:
                payload["messageID"] = field.stringValue
            case 3:
                payload["conversationID"] = field.stringValue
            default:
                continue
            }
        }
        return payload
    }

    private static func decodeDomainEventPayload(_ data: Data) -> [String: String] {
        var payload: [String: String] = [:]
        for field in fields(in: data) {
            switch field.number {
            case 10:
                payload.merge(decodeMessageCreatedEvent(field.value)) { current, _ in current }
            case 35:
                payload["eventKind"] = "activityHint"
                payload.merge(decodeConversationActivityHint(field.value)) { current, _ in current }
            default:
                continue
            }
        }
        return payload
    }

    private static func decodeMessageCreatedEvent(_ data: Data) -> [String: String] {
        var payload: [String: String] = [:]
        for field in fields(in: data) {
            switch field.number {
            case 2:
                payload["clientMessageID"] = field.stringValue
            default:
                continue
            }
        }
        return payload
    }

    private static func decodeConversationActivityHint(_ data: Data) -> [String: String] {
        var payload: [String: String] = [:]
        for field in fields(in: data) {
            switch field.number {
            case 1:
                payload["messageID"] = field.stringValue
            case 4:
                payload["timelineSequence"] = String(field.varint ?? 0)
            default:
                continue
            }
        }
        return payload
    }

    private static func fields(in data: Data) -> [ProtoField] {
        var fields: [ProtoField] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard let key = data.readVarint(index: &index) else { break }
            let number = Int(key >> 3)
            let wireType = Int(key & 0x7)
            switch wireType {
            case 0:
                guard let value = data.readVarint(index: &index) else { return fields }
                fields.append(ProtoField(number: number, value: Data(), varint: value))
            case 2:
                guard let length = data.readVarint(index: &index) else { return fields }
                let count = Int(length)
                guard index + count <= data.endIndex else { return fields }
                fields.append(ProtoField(number: number, value: Data(data[index..<(index + count)]), varint: nil))
                index += count
            default:
                return fields
            }
        }
        return fields
    }
}

struct ProtoField {
    let number: Int
    let value: Data
    let varint: UInt64?

    var stringValue: String? {
        String(data: value, encoding: .utf8)
    }
}

private extension Data {
    mutating func writeVarint(field: Int, _ value: UInt64) {
        writeRawVarint(UInt64(field << 3))
        writeRawVarint(value)
    }

    mutating func writeString(field: Int, _ value: String) {
        writeLengthDelimited(field: field, Data(value.utf8))
    }

    mutating func writeMessage(field: Int, _ value: Data) {
        writeLengthDelimited(field: field, value)
    }

    mutating func writeLengthDelimited(field: Int, _ value: Data) {
        writeRawVarint(UInt64((field << 3) | 2))
        writeRawVarint(UInt64(value.count))
        append(value)
    }

    mutating func writeRawVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        append(UInt8(value))
    }

    func readVarint(index: inout Index) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < endIndex {
            let byte = self[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift > 63 {
                return nil
            }
        }
        return nil
    }
}

final class ConnectionState: @unchecked Sendable {
    enum DisconnectDecision {
        case reconnect(nextGeneration: Int, attempt: Int, connectionToCancel: NWConnection?)
        case fail
        case ignore
    }

    private let lock = NSLock()
    private var completed = false
    private var sentClientIDsByRequestID: [String: String] = [:]
    private var sentAtByClientID: [String: Date] = [:]
    private var acknowledgedClientIDs: Set<String> = []
    private var canonicalClientIDs: Set<String> = []
    private var deliveredClientIDs: Set<String> = []
    private var duplicateCanonicalMessages = 0
    private var duplicateDeliveredMessages = 0
    private var ackLatenciesMillis: [Double] = []
    private var canonicalLatenciesMillis: [Double] = []
    private var deliveryLatenciesMillis: [Double] = []
    private var fanoutMessages = 0
    private var activityHints = 0
    private var serverErrors = 0
    private var reconnects = 0
    private var heartbeatSends = 0
    private var heartbeatAcks = 0
    private var heartbeatSendCompletionMillis: [Double] = []
    private var didStartMessages = false
    private var didAuthenticate = false
    private var didReachReady = false
    private var reconnectInProgress = false
    private var currentGeneration = 0
    private var activeConnection: NWConnection?
    private let expectedAcks: Int
    private let expectedCanonicalMessages: Int
    private let expectedDeliveries: Int
    private let messageDeliveryTracker: MessageDeliveryTracker?
    private let continuation: CheckedContinuation<ConnectionResult, Never>
    private let logger: ConnectionEventLogger
    private let connectionIndex: Int

    init(
        expectedAcks: Int,
        expectedCanonicalMessages: Int,
        expectedDeliveries: Int,
        messageDeliveryTracker: MessageDeliveryTracker?,
        continuation: CheckedContinuation<ConnectionResult, Never>,
        logger: ConnectionEventLogger,
        connectionIndex: Int
    ) {
        self.expectedAcks = expectedAcks
        self.expectedCanonicalMessages = expectedCanonicalMessages
        self.expectedDeliveries = expectedDeliveries
        self.messageDeliveryTracker = messageDeliveryTracker
        self.continuation = continuation
        self.logger = logger
        self.connectionIndex = connectionIndex
    }

    func recordSent(clientMessageID: String, requestID: String, at date: Date) {
        lock.lock()
        sentClientIDsByRequestID[requestID] = clientMessageID
        sentAtByClientID[clientMessageID] = date
        lock.unlock()
    }

    func attachConnection(_ connection: NWConnection, generation: Int) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            connection.cancel()
            return false
        }
        currentGeneration = generation
        didAuthenticate = false
        didReachReady = false
        reconnectInProgress = false
        activeConnection = connection
        lock.unlock()
        return true
    }

    func recordHeartbeatSend() {
        lock.lock()
        heartbeatSends += 1
        lock.unlock()
    }

    func recordHeartbeatSendCompletion(milliseconds: Double) {
        lock.lock()
        heartbeatSendCompletionMillis.append(milliseconds)
        lock.unlock()
    }

    func isActive(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !completed && !reconnectInProgress && generation == currentGeneration
    }

    func hasAuthenticated(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == currentGeneration && didAuthenticate
    }

    func markReady(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed, !reconnectInProgress, generation == currentGeneration else {
            return false
        }
        didReachReady = true
        return true
    }

    func shouldFailConnectTimeout(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !completed
            && !reconnectInProgress
            && generation == currentGeneration
            && !didReachReady
    }

    func shouldFailPreauthTimeout(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !completed
            && !reconnectInProgress
            && generation == currentGeneration
            && !didAuthenticate
    }

    func recordPacket(_ packet: DecodedRealtimePacket) {
        lock.lock()
        switch packet.type {
        case .ack:
            let requestID = packet.requestID
            if let requestID, let clientID = sentClientIDsByRequestID[requestID], !acknowledgedClientIDs.contains(clientID) {
                acknowledgedClientIDs.insert(clientID)
                if let messageID = packet.payload["messageID"] {
                    messageDeliveryTracker?.registerServerMessageID(messageID, forClientMessageID: clientID)
                }
                if let sentAt = sentAtByClientID[clientID] {
                    ackLatenciesMillis.append(Date().timeIntervalSince(sentAt) * 1_000)
                }
            }
            if let status = packet.payload["status"], status != "accepted" {
                serverErrors += 1
            }
        case .message:
            fanoutMessages += 1
            if let clientID = packet.payload["clientMessageID"],
               sentAtByClientID[clientID] != nil {
                if canonicalClientIDs.contains(clientID) {
                    duplicateCanonicalMessages += 1
                } else {
                    canonicalClientIDs.insert(clientID)
                    if let sentAt = sentAtByClientID[clientID] {
                        canonicalLatenciesMillis.append(Date().timeIntervalSince(sentAt) * 1_000)
                    }
                }
            }
            if let clientID = packet.payload["clientMessageID"],
               let delivery = messageDeliveryTracker?.recordDelivery(
                clientMessageID: clientID,
                receiverIndex: connectionIndex
               ) {
                if delivery.duplicate {
                    duplicateDeliveredMessages += 1
                } else {
                    deliveredClientIDs.insert(clientID)
                    deliveryLatenciesMillis.append(delivery.latencyMillis)
                    logger.log(
                        "message_delivery_received",
                        connectionIndex: connectionIndex,
                        fields: [
                            "clientMessageID": clientID,
                            "senderIndex": String(delivery.senderIndex),
                            "latencyMs": String(Int(delivery.latencyMillis))
                        ]
                    )
                }
            }
        case .activityHint:
            activityHints += 1
            if let messageID = packet.payload["messageID"],
               let delivery = messageDeliveryTracker?.recordHintDelivery(
                serverMessageID: messageID,
                receiverIndex: connectionIndex
               ) {
                if delivery.duplicate {
                    duplicateDeliveredMessages += 1
                } else {
                    deliveredClientIDs.insert(messageID)
                    deliveryLatenciesMillis.append(delivery.latencyMillis)
                    logger.log(
                        "activity_hint_received",
                        connectionIndex: connectionIndex,
                        fields: [
                            "messageID": messageID,
                            "senderIndex": String(delivery.senderIndex),
                            "latencyMs": String(Int(delivery.latencyMillis))
                        ]
                    )
                }
            }
        case .authError, .kick:
            serverErrors += 1
        case .heartbeatAck:
            heartbeatAcks += 1
        case .auth, .authOK, .heartbeat:
            break
        }
        let shouldFinish = hasMetExpectedWork()
        lock.unlock()

        if shouldFinish {
            finish(success: true)
        }
    }

    func recordAuthOK(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed, generation == currentGeneration else {
            return false
        }
        didAuthenticate = true
        guard !didStartMessages else {
            return false
        }
        didStartMessages = true
        return true
    }

    func handleDisconnect(generation: Int, maxReconnects: Int) -> DisconnectDecision {
        lock.lock()
        guard !completed, generation == currentGeneration else {
            lock.unlock()
            return .ignore
        }
        guard !reconnectInProgress else {
            lock.unlock()
            return .ignore
        }
        guard expectedAcks == 0, expectedCanonicalMessages == 0, expectedDeliveries == 0, reconnects < maxReconnects else {
            lock.unlock()
            return .fail
        }

        reconnectInProgress = true
        reconnects += 1
        let attempt = reconnects
        let nextGeneration = currentGeneration + 1
        let connectionToCancel = activeConnection
        activeConnection = nil
        lock.unlock()
        return .reconnect(nextGeneration: nextGeneration, attempt: attempt, connectionToCancel: connectionToCancel)
    }

    @discardableResult
    func finish(success: Bool, reason: String? = nil) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        let result = ConnectionResult(
            success: success,
            failureReason: success ? nil : reason,
            sent: sentAtByClientID.count,
            acknowledgements: acknowledgedClientIDs.count,
            canonicalMessages: canonicalClientIDs.count,
            duplicateCanonicalMessages: duplicateCanonicalMessages,
            deliveredMessages: deliveredClientIDs.count,
            duplicateDeliveredMessages: duplicateDeliveredMessages,
            fanoutMessages: fanoutMessages,
            activityHints: activityHints,
            reconnects: reconnects,
            serverErrors: serverErrors,
            heartbeatSends: heartbeatSends,
            heartbeatAcks: heartbeatAcks,
            heartbeatSendCompletionMillis: heartbeatSendCompletionMillis,
            ackLatenciesMillis: ackLatenciesMillis,
            canonicalLatenciesMillis: canonicalLatenciesMillis,
            deliveryLatenciesMillis: deliveryLatenciesMillis
        )
        lock.unlock()

        logger.log(
            "connection_finish",
            connectionIndex: connectionIndex,
            fields: [
                "success": String(success),
                "reason": result.failureReason ?? "",
                "sent": String(result.sent),
                "ack": String(result.acknowledgements),
                "canonical": String(result.canonicalMessages),
                "delivered": String(result.deliveredMessages),
                "activityHints": String(result.activityHints),
                "serverErrors": String(result.serverErrors),
                "reconnects": String(result.reconnects),
                "heartbeatSends": String(result.heartbeatSends),
                "heartbeatAcks": String(result.heartbeatAcks)
            ]
        )
        activeConnection?.cancel()
        continuation.resume(returning: result)
        return true
    }

    private func hasMetExpectedWork() -> Bool {
        let expectsWork = expectedAcks > 0 || expectedCanonicalMessages > 0 || expectedDeliveries > 0
        guard expectsWork else {
            return false
        }
        return acknowledgedClientIDs.count >= expectedAcks
            && canonicalClientIDs.count >= expectedCanonicalMessages
            && deliveredClientIDs.count >= expectedDeliveries
    }
}

func shouldLogHeartbeat(options: Options, connectionIndex: Int) -> Bool {
    switch options.heartbeatLogMode.lowercased() {
    case "all", "verbose":
        return true
    case "sample", "sampled":
        return connectionIndex % max(1, options.heartbeatLogSampleRate) == 0
    case "none", "off", "errors", "error":
        return false
    default:
        return false
    }
}

func heartbeatInitialJitterNanoseconds(options: Options, connectionIndex: Int, loginIndex: Int) -> UInt64 {
    guard options.heartbeatIntervalSeconds > 0 else {
        return 0
    }

    let jitterSeconds = options.heartbeatJitterSeconds >= 0
        ? options.heartbeatJitterSeconds
        : options.heartbeatIntervalSeconds
    let cappedJitterSeconds = max(0, min(jitterSeconds, options.heartbeatIntervalSeconds))
    guard cappedJitterSeconds > 0 else {
        return 0
    }

    let jitterMillisRange = UInt64(cappedJitterSeconds * 1_000)
    let stableValue = UInt64(bitPattern: Int64(connectionIndex &* 1_103_515_245) ^ Int64(loginIndex &* 12_345))
    return (stableValue % jitterMillisRange) * 1_000_000
}

func senderIndices(options: Options) -> [Int] {
    guard options.messageProfile == "pair-delivery" else {
        return Array(0..<options.connections)
    }
    return (0..<options.connections).filter { $0 % max(1, options.messageSenderEvery) == 0 }
}

func scheduledMessagesForConnection(index: Int, options: Options, senders: [Int]) -> [ScheduledMessage] {
    guard options.messageProfile == "pair-delivery" else {
        return (0..<options.messagesPerConnection).map { messageIndex in
            ScheduledMessage(
                messageIndex: messageIndex,
                delayMillis: options.sendIntervalMillis * messageIndex,
                receiverIndex: nil
            )
        }
    }

    guard let senderOrdinal = senders.firstIndex(of: index), !senders.isEmpty else {
        return []
    }
    let receiverIndex = (index + options.messageReceiverOffset) % options.connections
    let intervalMillis = options.messageRatePerSecond > 0
        ? max(1, Int((1_000 / options.messageRatePerSecond).rounded()))
        : max(0, options.sendIntervalMillis)

    if options.messageRatePerSecond > 0 {
        let durationSeconds = max(1, options.holdSeconds)
        let totalMessages = max(1, Int((options.messageRatePerSecond * Double(durationSeconds)).rounded()))
        var scheduled: [ScheduledMessage] = []
        var globalIndex = senderOrdinal
        var localMessageIndex = 0
        while globalIndex < totalMessages {
            scheduled.append(
                ScheduledMessage(
                    messageIndex: localMessageIndex,
                    delayMillis: globalIndex * intervalMillis,
                    receiverIndex: receiverIndex
                )
            )
            localMessageIndex += 1
            globalIndex += senders.count
        }
        return scheduled
    }

    return (0..<options.messagesPerConnection).map { messageIndex in
        ScheduledMessage(
            messageIndex: messageIndex,
            delayMillis: intervalMillis * messageIndex,
            receiverIndex: receiverIndex
        )
    }
}

func expectedDeliveryCounts(options: Options, senders: [Int]) -> [Int] {
    var counts = Array(repeating: 0, count: options.connections)
    guard options.messageProfile == "pair-delivery" else {
        return counts
    }
    for senderIndex in senders {
        let receiverIndex = (senderIndex + options.messageReceiverOffset) % options.connections
        if options.activeConversationUsers > 0,
           !isActiveConversationConnection(index: receiverIndex, options: options) {
            continue
        }
        counts[receiverIndex] += scheduledMessagesForConnection(index: senderIndex, options: options, senders: senders).count
    }
    return counts
}

func isActiveConversationConnection(index: Int, options: Options) -> Bool {
    options.activeConversationUsers > 0 && index < options.activeConversationUsers
}

func receiveFrames(
    connection: NWConnection,
    state: ConnectionState,
    logger: ConnectionEventLogger,
    options: Options,
    connectionIndex: Int,
    generation: Int,
    buffer: Data = Data(),
    onAuthenticated: @escaping @Sendable (Bool) -> Void,
    onDisconnected: @escaping @Sendable (String) -> Void
) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
        if error != nil || isComplete {
            let reason = error.map { "receive_error:\($0)" } ?? "receive_complete"
            logger.log(
                error == nil ? "receive_complete" : "receive_error",
                connectionIndex: connectionIndex,
                fields: [
                    "generation": String(generation),
                    "error": error.map(String.init(describing:)) ?? "",
                    "isComplete": String(isComplete)
                ]
            )
            onDisconnected(reason)
            return
        }

        var nextBuffer = buffer
        if let data {
            nextBuffer.append(data)
            for frame in ProtoWire.frames(from: &nextBuffer) {
                guard let packet = ProtoWire.decodePacket(frame) else { continue }
                let isHighFrequencyHeartbeat = packet.type == .heartbeatAck || packet.type == .heartbeat
                if !isHighFrequencyHeartbeat || shouldLogHeartbeat(options: options, connectionIndex: connectionIndex) {
                    logger.log(
                        "packet_received",
                        connectionIndex: connectionIndex,
                        fields: [
                            "generation": String(generation),
                            "type": packet.type.logName,
                            "requestID": packet.requestID ?? "",
                            "status": packet.payload["status"] ?? "",
                            "clientMessageID": packet.payload["clientMessageID"] ?? ""
                        ]
                    )
                }
                state.recordPacket(packet)
                if packet.type == .heartbeatAck && shouldLogHeartbeat(options: options, connectionIndex: connectionIndex) {
                    logger.log("heartbeat_ack_received", connectionIndex: connectionIndex)
                }
                if packet.type == .authOK {
                    let shouldStartMessages = state.recordAuthOK(generation: generation)
                    logger.log(
                        "auth_ok_received",
                        connectionIndex: connectionIndex,
                        fields: [
                            "generation": String(generation),
                            "startMessages": String(shouldStartMessages)
                        ]
                    )
                    onAuthenticated(shouldStartMessages)
                }
            }
        }

        receiveFrames(
            connection: connection,
            state: state,
            logger: logger,
            options: options,
            connectionIndex: connectionIndex,
            generation: generation,
            buffer: nextBuffer,
            onAuthenticated: onAuthenticated,
            onDisconnected: onDisconnected
        )
    }
}

func scheduleHeartbeatLoop(
    connection: NWConnection,
    state: ConnectionState,
    logger: ConnectionEventLogger,
    connectionIndex: Int,
    loginIndex: Int,
    options: Options,
    queue: DispatchQueue,
    generation: Int,
    sequence: Int = 1,
    onDisconnected: @escaping @Sendable (String) -> Void
) {
    guard options.heartbeatIntervalSeconds > 0 else {
        return
    }

    let intervalNanos = UInt64(options.heartbeatIntervalSeconds) * 1_000_000_000
    let delayNanos = sequence == 1
        ? heartbeatInitialJitterNanoseconds(options: options, connectionIndex: connectionIndex, loginIndex: loginIndex)
        : intervalNanos
    let scheduledDeadline = DispatchTime.now() + .nanoseconds(Int(delayNanos))

    queue.asyncAfter(deadline: scheduledDeadline) {
        guard state.isActive(generation: generation) else {
            return
        }

        let firedAt = DispatchTime.now()
        let driftMillis = Int64(firedAt.uptimeNanoseconds)
            - Int64(scheduledDeadline.uptimeNanoseconds)
        let sendStartedAt = Date()
        let requestID = UUID().uuidString
        let heartbeatPacket = ProtoWire.heartbeatFrame(
            sequence: sequence,
            requestID: requestID,
            protocolVersion: options.protocolVersion
        )
        state.recordHeartbeatSend()
        if shouldLogHeartbeat(options: options, connectionIndex: connectionIndex) {
            logger.log(
                "heartbeat_send_start",
                connectionIndex: connectionIndex,
                loginIndex: loginIndex,
                fields: [
                    "sequence": String(sequence),
                    "requestID": requestID,
                    "generation": String(generation),
                    "scheduleDriftMs": String(max(0, driftMillis / 1_000_000))
                ]
            )
        }
        connection.send(content: heartbeatPacket, completion: .contentProcessed { error in
            if error != nil {
                logger.log(
                    "heartbeat_send_error",
                    connectionIndex: connectionIndex,
                    loginIndex: loginIndex,
                    fields: [
                        "sequence": String(sequence),
                        "generation": String(generation),
                        "error": String(describing: error!)
                    ]
                )
                onDisconnected("send_heartbeat_error:\(error!)")
                return
            }

            let sendCompletionMillis = Date().timeIntervalSince(sendStartedAt) * 1_000
            state.recordHeartbeatSendCompletion(milliseconds: sendCompletionMillis)
            if shouldLogHeartbeat(options: options, connectionIndex: connectionIndex) {
                logger.log(
                    "heartbeat_send_ok",
                    connectionIndex: connectionIndex,
                    loginIndex: loginIndex,
                    fields: [
                        "sequence": String(sequence),
                        "generation": String(generation),
                        "sendCompletionMs": String(Int(sendCompletionMillis))
                    ]
                )
            }
            scheduleHeartbeatLoop(
                connection: connection,
                state: state,
                logger: logger,
                connectionIndex: connectionIndex,
                loginIndex: loginIndex,
                options: options,
                queue: queue,
                generation: generation,
                sequence: sequence + 1,
                onDisconnected: onDisconnected
            )
        })
    }
}

func runConnection(
    index: Int,
    options: Options,
    login: ConnectionLogin,
    scheduledMessages: [ScheduledMessage],
    expectedDeliveries: Int,
    messageResultTimeoutDelayMillis: Int,
    messageDeliveryTracker: MessageDeliveryTracker?,
    logger: ConnectionEventLogger,
    queue: DispatchQueue,
    globalHoldBarrier: GlobalHoldBarrier?
) async -> ConnectionResult {
    await withCheckedContinuation { continuation in
        let expectedCanonicalMessages = options.messageCompletionMode != "full" || options.messageProfile == "pair-delivery"
            ? 0
            : scheduledMessages.count
        let state = ConnectionState(
            expectedAcks: scheduledMessages.count,
            expectedCanonicalMessages: expectedCanonicalMessages,
            expectedDeliveries: expectedDeliveries,
            messageDeliveryTracker: messageDeliveryTracker,
            continuation: continuation,
            logger: logger,
            connectionIndex: index
        )

        @Sendable func handleDisconnected(generation: Int, reason: String) {
            switch state.handleDisconnect(generation: generation, maxReconnects: options.maxReconnects) {
            case .reconnect(let nextGeneration, let attempt, let connectionToCancel):
                logger.log(
                    "connection_disconnected",
                    connectionIndex: index,
                    loginIndex: login.loginIndex,
                    fields: [
                        "generation": String(generation),
                        "reason": reason,
                        "decision": "reconnect"
                    ]
                )
                logger.log(
                    "reconnect_scheduled",
                    connectionIndex: index,
                    loginIndex: login.loginIndex,
                    fields: [
                        "fromGeneration": String(generation),
                        "nextGeneration": String(nextGeneration),
                        "attempt": String(attempt),
                        "delayMs": String(options.reconnectDelayMillis),
                        "reason": reason
                    ]
                )
                connectionToCancel?.cancel()
                queue.asyncAfter(deadline: .now() + .milliseconds(options.reconnectDelayMillis)) {
                    startAttempt(generation: nextGeneration)
                }
            case .fail:
                logger.log(
                    "connection_disconnected",
                    connectionIndex: index,
                    loginIndex: login.loginIndex,
                    fields: [
                        "generation": String(generation),
                        "reason": reason,
                        "decision": "fail"
                    ]
                )
                state.finish(success: false, reason: reason)
            case .ignore:
                break
            }
        }

        @Sendable func scheduleWorkAfterAuth(connection: NWConnection, generation: Int, shouldStartMessages: Bool) {
            if isActiveConversationConnection(index: index, options: options) {
                let requestID = UUID().uuidString
                let activityPacket = ProtoWire.conversationActivityFrame(
                    conversationID: options.conversationID,
                    isActive: true,
                    requestID: requestID,
                    protocolVersion: options.protocolVersion
                )
                logger.log(
                    "conversation_activity_send_start",
                    connectionIndex: index,
                    loginIndex: login.loginIndex,
                    fields: [
                        "generation": String(generation),
                        "requestID": requestID,
                        "conversationID": options.conversationID,
                        "isActive": "true"
                    ]
                )
                connection.send(content: activityPacket, completion: .contentProcessed { error in
                    if let error {
                        logger.log(
                            "conversation_activity_send_error",
                            connectionIndex: index,
                            loginIndex: login.loginIndex,
                            fields: [
                                "generation": String(generation),
                                "error": String(describing: error)
                            ]
                        )
                        handleDisconnected(generation: generation, reason: "send_conversation_activity_error:\(error)")
                        return
                    }
                    logger.log(
                        "conversation_activity_send_ok",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: ["generation": String(generation)]
                    )
                })
            }
            scheduleHeartbeatLoop(
                connection: connection,
                state: state,
                logger: logger,
                connectionIndex: index,
                loginIndex: login.loginIndex,
                options: options,
                queue: queue,
                generation: generation,
                onDisconnected: { reason in
                    handleDisconnected(generation: generation, reason: reason)
                }
            )
            guard shouldStartMessages else {
                return
            }
            if scheduledMessages.isEmpty && expectedDeliveries == 0 {
                @Sendable func scheduleHold() {
                    logger.log(
                        "hold_scheduled",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: [
                            "generation": String(generation),
                            "holdSeconds": String(options.holdSeconds),
                            "globalHoldBarrier": String(globalHoldBarrier != nil)
                        ]
                    )
                    queue.asyncAfter(deadline: .now() + .seconds(options.holdSeconds)) {
                        logger.log("hold_complete", connectionIndex: index, loginIndex: login.loginIndex)
                        state.finish(success: true)
                    }
                    queue.asyncAfter(deadline: .now() + .seconds(options.holdSeconds + options.timeoutSeconds)) {
                        if state.finish(success: false, reason: "hold_timeout") {
                            logger.log("hold_timeout_fired", connectionIndex: index, loginIndex: login.loginIndex)
                        }
                    }
                }

                if let globalHoldBarrier {
                    logger.log(
                        "global_hold_barrier_wait",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: [
                            "generation": String(generation),
                            "holdSeconds": String(options.holdSeconds)
                        ]
                    )
                    globalHoldBarrier.arriveAndWait(
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        queue: queue
                    ) { release in
                        guard state.isActive(generation: generation) else {
                            return
                        }
                        logger.log(
                            "global_hold_barrier_done",
                            connectionIndex: index,
                            loginIndex: login.loginIndex,
                            fields: [
                                "generation": String(generation),
                                "success": String(release.success),
                                "reason": release.reason,
                                "authenticated": String(release.authenticated),
                                "target": String(release.target),
                                "barrierElapsedMs": String(release.elapsedMillis)
                            ]
                        )
                        if release.success {
                            scheduleHold()
                        } else {
                            state.finish(success: false, reason: release.reason)
                        }
                    }
                    return
                }

                scheduleHold()
                return
            }

            @Sendable func scheduleMessageWork() {
                if scheduledMessages.isEmpty {
                    logger.log(
                        "message_delivery_wait",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: [
                            "generation": String(generation),
                            "expectedDeliveries": String(expectedDeliveries),
                            "timeoutDelayMs": String(messageResultTimeoutDelayMillis)
                        ]
                    )
                    queue.asyncAfter(deadline: .now() + .milliseconds(messageResultTimeoutDelayMillis)) {
                        if state.finish(success: false, reason: "message_delivery_timeout") {
                            logger.log(
                                "message_delivery_timeout_fired",
                                connectionIndex: index,
                                loginIndex: login.loginIndex,
                                fields: [
                                    "generation": String(generation),
                                    "timeoutDelayMs": String(messageResultTimeoutDelayMillis)
                                ]
                            )
                        }
                    }
                    return
                }

                logger.log(
                    "messages_scheduled",
                    connectionIndex: index,
                    loginIndex: login.loginIndex,
                    fields: [
                        "generation": String(generation),
                        "messages": String(scheduledMessages.count),
                        "messageProfile": options.messageProfile,
                        "messageRatePerSecond": String(options.messageRatePerSecond),
                        "sendIntervalMillis": String(options.sendIntervalMillis),
                        "expectedDeliveries": String(expectedDeliveries),
                        "globalHoldBarrier": String(globalHoldBarrier != nil),
                        "timeoutDelayMs": String(messageResultTimeoutDelayMillis)
                    ]
                )
                let lastMessageDelayMillis = scheduledMessages.map(\.delayMillis).max() ?? 0
                queue.asyncAfter(deadline: .now() + .milliseconds(messageResultTimeoutDelayMillis)) {
                    if state.finish(success: false, reason: "message_result_timeout") {
                        logger.log(
                            "message_result_timeout_fired",
                            connectionIndex: index,
                            loginIndex: login.loginIndex,
                            fields: [
                                "generation": String(generation),
                                "lastMessageDelayMs": String(lastMessageDelayMillis),
                                "timeoutDelayMs": String(messageResultTimeoutDelayMillis),
                                "timeoutSeconds": String(options.timeoutSeconds)
                            ]
                        )
                    }
                }
                for scheduledMessage in scheduledMessages {
                    let delay = DispatchTime.now() + .milliseconds(scheduledMessage.delayMillis)
                    queue.asyncAfter(deadline: delay) {
                        let requestID = UUID().uuidString
                        let clientMessageID = "tcp-\(index)-\(scheduledMessage.messageIndex)-\(UUID().uuidString)"
                        let messagePacket = ProtoWire.messageFrame(
                            conversationID: options.conversationID,
                            clientMessageID: clientMessageID,
                            text: "tcp load \(index)/\(scheduledMessage.messageIndex)",
                            requestID: requestID,
                            protocolVersion: options.protocolVersion
                        )
                        let sentAt = Date()
                        state.recordSent(clientMessageID: clientMessageID, requestID: requestID, at: sentAt)
                        if let receiverIndex = scheduledMessage.receiverIndex {
                            messageDeliveryTracker?.register(
                                clientMessageID: clientMessageID,
                                senderIndex: index,
                                receiverIndex: receiverIndex,
                                sentAt: sentAt
                            )
                        }
                        logger.log(
                            "message_send_start",
                            connectionIndex: index,
                            loginIndex: login.loginIndex,
                            fields: [
                                "generation": String(generation),
                                "messageIndex": String(scheduledMessage.messageIndex),
                                "requestID": requestID,
                                "clientMessageID": clientMessageID,
                                "receiverIndex": scheduledMessage.receiverIndex.map(String.init) ?? ""
                            ]
                        )
                        connection.send(content: messagePacket, completion: .contentProcessed { error in
                            if error != nil {
                                logger.log(
                                    "message_send_error",
                                    connectionIndex: index,
                                    loginIndex: login.loginIndex,
                                    fields: [
                                        "generation": String(generation),
                                        "messageIndex": String(scheduledMessage.messageIndex),
                                        "error": String(describing: error!)
                                    ]
                                )
                                state.finish(success: false, reason: "send_message_error:\(error!)")
                            } else {
                                logger.log(
                                    "message_send_ok",
                                    connectionIndex: index,
                                    loginIndex: login.loginIndex,
                                    fields: [
                                        "generation": String(generation),
                                        "messageIndex": String(scheduledMessage.messageIndex)
                                    ]
                                )
                            }
                        })
                    }
                }
            }

            if let globalHoldBarrier {
                logger.log(
                    "global_hold_barrier_wait",
                    connectionIndex: index,
                    loginIndex: login.loginIndex,
                    fields: [
                        "generation": String(generation),
                        "messages": String(scheduledMessages.count),
                        "expectedDeliveries": String(expectedDeliveries)
                    ]
                )
                globalHoldBarrier.arriveAndWait(
                    connectionIndex: index,
                    loginIndex: login.loginIndex,
                    queue: queue
                ) { release in
                    guard state.isActive(generation: generation) else {
                        return
                    }
                    logger.log(
                        "global_hold_barrier_done",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: [
                            "generation": String(generation),
                            "success": String(release.success),
                            "reason": release.reason,
                            "authenticated": String(release.authenticated),
                            "target": String(release.target),
                            "barrierElapsedMs": String(release.elapsedMillis),
                            "work": "messages"
                        ]
                    )
                    if release.success {
                        scheduleMessageWork()
                    } else {
                        state.finish(success: false, reason: release.reason)
                    }
                }
                return
            }

            scheduleMessageWork()
        }

        @Sendable func startAttempt(generation: Int) {
            logger.log(
                generation == 0 ? "connection_create" : "reconnect_start",
                connectionIndex: index,
                loginIndex: login.loginIndex,
                fields: [
                    "generation": String(generation),
                    "email": login.email,
                    "userID": login.auth.user.id,
                    "deviceID": login.deviceID,
                    "tcpHost": options.tcpHost,
                    "tcpPort": String(options.tcpPort)
                ]
            )
            let connection = NWConnection(
                host: NWEndpoint.Host(options.tcpHost),
                port: NWEndpoint.Port(rawValue: options.tcpPort)!,
                using: .tcp
            )
            guard state.attachConnection(connection, generation: generation) else {
                return
            }

            connection.stateUpdateHandler = { nwState in
                switch nwState {
                case .setup:
                    logger.log(
                        "nw_setup",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: ["generation": String(generation)]
                    )
                case .preparing:
                    logger.log(
                        "nw_preparing",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: ["generation": String(generation)]
                    )
                case .ready:
                    guard state.markReady(generation: generation) else {
                        return
                    }
                    logger.log(
                        "nw_ready",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: ["generation": String(generation)]
                    )
                    receiveFrames(
                        connection: connection,
                        state: state,
                        logger: logger,
                        options: options,
                        connectionIndex: index,
                        generation: generation,
                        onAuthenticated: { shouldStartMessages in
                            scheduleWorkAfterAuth(
                                connection: connection,
                                generation: generation,
                                shouldStartMessages: shouldStartMessages
                            )
                        },
                        onDisconnected: { reason in
                            handleDisconnected(generation: generation, reason: reason)
                        }
                    )
                    let authPacket = ProtoWire.authFrame(
                        accessToken: login.auth.accessToken,
                        deviceID: login.deviceID,
                        deviceName: login.deviceName,
                        platform: "load-test",
                        appVersion: "load-test",
                        protocolVersion: options.protocolVersion
                    )
                    logger.log(
                        "auth_send_start",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: ["generation": String(generation)]
                    )
                    logger.log(
                        "preauth_timeout_scheduled",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: [
                            "generation": String(generation),
                            "timeoutSeconds": String(options.timeoutSeconds)
                        ]
                    )
                    queue.asyncAfter(deadline: .now() + .seconds(options.timeoutSeconds)) {
                        guard !state.hasAuthenticated(generation: generation) else {
                            return
                        }
                        if state.shouldFailPreauthTimeout(generation: generation),
                           state.finish(success: false, reason: "preauth_timeout") {
                            logger.log(
                                "preauth_timeout_fired",
                                connectionIndex: index,
                                loginIndex: login.loginIndex,
                                fields: ["generation": String(generation)]
                            )
                        }
                    }
                    connection.send(content: authPacket, completion: .contentProcessed { error in
                        if error != nil {
                            logger.log(
                                "auth_send_error",
                                connectionIndex: index,
                                loginIndex: login.loginIndex,
                                fields: [
                                    "generation": String(generation),
                                    "error": String(describing: error!)
                                ]
                            )
                            handleDisconnected(generation: generation, reason: "send_auth_error:\(error!)")
                        } else {
                            logger.log(
                                "auth_send_ok",
                                connectionIndex: index,
                                loginIndex: login.loginIndex,
                                fields: ["generation": String(generation)]
                            )
                        }
                    })
                case .waiting:
                    logger.log(
                        "nw_waiting",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: ["generation": String(generation)]
                    )
                case .failed(let error):
                    logger.log(
                        "nw_failed",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: [
                            "generation": String(generation),
                            "error": String(describing: error)
                        ]
                    )
                    handleDisconnected(generation: generation, reason: "nw_failed:\(error)")
                case .cancelled:
                    logger.log(
                        "nw_cancelled",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: ["generation": String(generation)]
                    )
                    handleDisconnected(generation: generation, reason: "nw_cancelled")
                default:
                    break
                }
            }
            logger.log(
                "connect_timeout_scheduled",
                connectionIndex: index,
                loginIndex: login.loginIndex,
                fields: [
                    "generation": String(generation),
                    "timeoutSeconds": String(options.timeoutSeconds)
                ]
            )
            queue.asyncAfter(deadline: .now() + .seconds(options.timeoutSeconds)) {
                if state.shouldFailConnectTimeout(generation: generation),
                   state.finish(success: false, reason: "connect_timeout") {
                    logger.log(
                        "connect_timeout_fired",
                        connectionIndex: index,
                        loginIndex: login.loginIndex,
                        fields: ["generation": String(generation)]
                    )
                }
            }
            logger.log(
                "connection_start",
                connectionIndex: index,
                loginIndex: login.loginIndex,
                fields: ["generation": String(generation)]
            )
            connection.start(queue: queue)
        }

        startAttempt(generation: 0)
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
    return sorted[index]
}

let options = parseOptions()
guard options.loginOnly || !options.conversationID.isEmpty else {
    fputs("Missing --conversation-id or IM_CONVERSATION_ID\n", stderr)
    exit(2)
}

let connectionLogger = try ConnectionEventLogger(path: options.connectionLogFile)
connectionLogger.log(
    "run_start",
    fields: [
        "profile": options.profile,
        "connections": String(options.connections),
        "baseURL": options.baseURL.absoluteString,
        "tcpHost": options.tcpHost,
        "tcpPort": String(options.tcpPort),
        "messagesPerConnection": String(options.messagesPerConnection),
        "messageProfile": options.messageProfile,
        "messageRatePerSecond": String(options.messageRatePerSecond),
        "messageSenderEvery": String(options.messageSenderEvery),
        "messageReceiverOffset": String(options.messageReceiverOffset),
        "activeConversationUsers": String(options.activeConversationUsers),
        "holdSeconds": String(options.holdSeconds),
        "connectRampSeconds": String(options.connectRampSeconds),
        "loginConcurrency": String(options.loginConcurrency),
        "timeoutSeconds": String(options.timeoutSeconds),
        "protocolVersion": String(options.protocolVersion),
        "heartbeatIntervalSeconds": String(options.heartbeatIntervalSeconds),
        "heartbeatJitterSeconds": String(options.heartbeatJitterSeconds),
        "heartbeatLogMode": options.heartbeatLogMode,
        "heartbeatLogSampleRate": String(options.heartbeatLogSampleRate),
        "connectionQueuePoolSize": String(options.connectionQueuePoolSize),
        "maxReconnects": String(options.maxReconnects),
        "minReconnects": String(options.minReconnects),
        "reconnectDelayMillis": String(options.reconnectDelayMillis),
        "loginRetries": String(options.loginRetries),
        "loginRetryDelayMillis": String(options.loginRetryDelayMillis),
        "accountDevicesPerUser": String(options.accountDevicesPerUser),
        "loginCacheFile": options.loginCacheFile ?? "",
        "requireLoginCache": String(options.requireLoginCache),
        "loginCacheTTLGuardSeconds": String(options.loginCacheTTLGuardSeconds),
        "loginOnly": String(options.loginOnly),
        "loginMode": options.loginMode,
        "globalHoldBarrierMinRatio": String(options.globalHoldBarrierMinRatio)
    ]
)
let accountCredentials = try loadAccountCredentials(options: options)
let loginCount = options.accountFile == nil ? options.devicesPerUser : options.connections
let justInTimeLogin = options.loginMode == "just-in-time" && !options.loginOnly
let loginURLSession = makeLoginURLSession(options: options)
let connectionLogins: [ConnectionLogin]
var loginCacheHit = false
var loginCacheRecords = 0
var loginCacheValidForSeconds = 0
if justInTimeLogin {
    connectionLogger.log("login_phase_deferred", fields: ["loginMode": options.loginMode])
    connectionLogins = []
} else if let cached = try cachedLogins(options: options, loginCount: loginCount, logger: connectionLogger) {
    loginCacheHit = true
    loginCacheRecords = cached.records
    loginCacheValidForSeconds = cached.validForSeconds
    connectionLogins = cached.logins
} else {
    if options.requireLoginCache && !options.loginOnly {
        fputs(
            "required login cache is missing, too small, or expires too soon; run --login-only true with the same --login-cache-file first\n",
            stderr
        )
        exit(4)
    }
    connectionLogins = try await concurrentMap(Array(0..<loginCount), concurrency: options.loginConcurrency) { loginIndex in
        let credentialIndex = options.accountFile == nil
            ? loginIndex % accountCredentials.count
            : (loginIndex / options.accountDevicesPerUser) % accountCredentials.count
        let credential = accountCredentials[credentialIndex]
        return try await loginForConnection(
            options: options,
            credential: credential,
            loginIndex: loginIndex,
            logger: connectionLogger,
            urlSession: loginURLSession
        )
    }
    try writeLoginCache(path: options.loginCacheFile, logins: connectionLogins, logger: connectionLogger)
    loginCacheRecords = connectionLogins.count
    loginCacheValidForSeconds = connectionLogins.map(\.auth.expiresIn).min() ?? 0
}
connectionLogger.log(
    "login_phase_complete",
    fields: [
        "loginCount": String(connectionLogins.count),
        "loginCacheHit": String(loginCacheHit),
        "loginCacheRecords": String(loginCacheRecords),
        "loginCacheValidForSeconds": String(loginCacheValidForSeconds)
    ]
)
if options.loginOnly {
    print("login-only complete logins=\(connectionLogins.count) cacheFile=\(options.loginCacheFile ?? "<none>") loginCacheHit=\(loginCacheHit) loginCacheRecords=\(loginCacheRecords) loginCacheValidForSeconds=\(loginCacheValidForSeconds)")
    exit(0)
}
let startedAt = Date()
let loginLimiter = AsyncLimiter(permits: options.loginConcurrency)
let connectionQueuePool = ConnectionQueuePool(size: options.connectionQueuePoolSize)
let messageSenderIndices = senderIndices(options: options)
let expectedDeliveriesByConnection = options.messageCompletionMode == "ack-only"
    ? Array(repeating: 0, count: options.connections)
    : expectedDeliveryCounts(options: options, senders: messageSenderIndices)
let scheduledMessagesByConnection = (0..<options.connections).map {
    scheduledMessagesForConnection(index: $0, options: options, senders: messageSenderIndices)
}
let globalLastMessageDelayMillis = scheduledMessagesByConnection.flatMap { $0 }.map(\.delayMillis).max() ?? 0
let messageResultTimeoutDelayMillis = globalLastMessageDelayMillis + options.timeoutSeconds * 1_000
let messageDeliveryTracker = options.messageProfile == "pair-delivery" ? MessageDeliveryTracker() : nil
let usesGlobalStartBarrier = options.messagesPerConnection == 0 || options.messageProfile == "pair-delivery"
let globalHoldBarrierTarget = max(1, Int(ceil(Double(options.connections) * options.globalHoldBarrierMinRatio)))
let globalHoldBarrier = usesGlobalStartBarrier
    ? GlobalHoldBarrier(target: globalHoldBarrierTarget, logger: connectionLogger)
    : nil
if let globalHoldBarrier {
    let barrierTimeoutSeconds = options.connectRampSeconds + options.timeoutSeconds + 5
    globalHoldBarrier.scheduleTimeout(seconds: barrierTimeoutSeconds, queue: DispatchQueue.global())
    connectionLogger.log(
        "global_hold_barrier_enabled",
        fields: [
            "target": String(globalHoldBarrierTarget),
            "connections": String(options.connections),
            "minRatio": String(options.globalHoldBarrierMinRatio),
            "messageProfile": options.messageProfile,
            "messageCompletionMode": options.messageCompletionMode,
            "timeoutSeconds": String(barrierTimeoutSeconds)
        ]
    )
}
connectionLogger.log(
    "connection_queue_pool_ready",
    fields: ["connectionQueuePoolSize": String(connectionQueuePool.size)]
)
connectionLogger.log(
    "message_plan_ready",
    fields: [
        "messageProfile": options.messageProfile,
        "messageCompletionMode": options.messageCompletionMode,
        "senderCount": String(messageSenderIndices.count),
        "totalScheduledMessages": String(scheduledMessagesByConnection.reduce(0) { $0 + $1.count }),
        "totalExpectedDeliveries": String(expectedDeliveriesByConnection.reduce(0, +)),
        "globalLastMessageDelayMs": String(globalLastMessageDelayMillis),
        "messageResultTimeoutDelayMs": String(messageResultTimeoutDelayMillis),
        "messageRatePerSecond": String(options.messageRatePerSecond)
    ]
)
let results = await withTaskGroup(of: ConnectionResult.self) { group in
    for index in 0..<options.connections {
        let loginIndex = options.accountFile == nil ? index % options.devicesPerUser : index
        group.addTask {
            if options.connectRampSeconds > 0 {
                let delay = Double(index) / Double(max(options.connections, 1)) * Double(options.connectRampSeconds)
                connectionLogger.log(
                    "ramp_sleep",
                    connectionIndex: index,
                    loginIndex: loginIndex,
                    fields: ["delayMs": String(Int(delay * 1_000))]
                )
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            let login: ConnectionLogin
            if justInTimeLogin {
                await loginLimiter.acquire()
                do {
                    let credential = accountCredentials[loginIndex % accountCredentials.count]
                    login = try await loginForConnection(
                        options: options,
                        credential: credential,
                        loginIndex: loginIndex,
                        logger: connectionLogger,
                        urlSession: loginURLSession
                    )
                    await loginLimiter.release()
                } catch {
                    await loginLimiter.release()
                    return ConnectionResult(
                        success: false,
                        failureReason: "login_failed:\(error)",
                        sent: 0,
                        acknowledgements: 0,
                        canonicalMessages: 0,
                        duplicateCanonicalMessages: 0,
                        deliveredMessages: 0,
                        duplicateDeliveredMessages: 0,
                        fanoutMessages: 0,
                        activityHints: 0,
                        reconnects: 0,
                        serverErrors: 0,
                        heartbeatSends: 0,
                        heartbeatAcks: 0,
                        heartbeatSendCompletionMillis: [],
                        ackLatenciesMillis: [],
                        canonicalLatenciesMillis: [],
                        deliveryLatenciesMillis: []
                    )
                }
            } else {
                login = connectionLogins[loginIndex]
            }
            return await runConnection(
                index: index,
                options: options,
                login: login,
                scheduledMessages: scheduledMessagesByConnection[index],
                expectedDeliveries: expectedDeliveriesByConnection[index],
                messageResultTimeoutDelayMillis: messageResultTimeoutDelayMillis,
                messageDeliveryTracker: messageDeliveryTracker,
                logger: connectionLogger,
                queue: connectionQueuePool.queue(for: index),
                globalHoldBarrier: globalHoldBarrier
            )
        }
    }
    var values: [ConnectionResult] = []
    for await result in group {
        values.append(result)
    }
    return values
}

let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
let successes = results.filter(\.success).count
let sent = results.reduce(0) { $0 + $1.sent }
let acknowledgements = results.reduce(0) { $0 + $1.acknowledgements }
let canonicalMessages = results.reduce(0) { $0 + $1.canonicalMessages }
let duplicateCanonicalMessages = results.reduce(0) { $0 + $1.duplicateCanonicalMessages }
let deliveredMessages = results.reduce(0) { $0 + $1.deliveredMessages }
let duplicateDeliveredMessages = results.reduce(0) { $0 + $1.duplicateDeliveredMessages }
let fanoutMessages = results.reduce(0) { $0 + $1.fanoutMessages }
let activityHints = results.reduce(0) { $0 + $1.activityHints }
let reconnects = results.reduce(0) { $0 + $1.reconnects }
let serverErrors = results.reduce(0) { $0 + $1.serverErrors }
let heartbeatSends = results.reduce(0) { $0 + $1.heartbeatSends }
let heartbeatAcks = results.reduce(0) { $0 + $1.heartbeatAcks }
let heartbeatSendCompletionMillis = results.flatMap(\.heartbeatSendCompletionMillis)
let ackLatencies = results.flatMap(\.ackLatenciesMillis)
let canonicalLatencies = results.flatMap(\.canonicalLatenciesMillis)
let deliveryLatencies = results.flatMap(\.deliveryLatenciesMillis)
let failureReasons = results.reduce(into: [String: Int]()) { counts, result in
    guard !result.success else { return }
    counts[result.failureReason ?? "unknown", default: 0] += 1
}
let expectedCanonicalMessages = options.messageCompletionMode != "full" || options.messageProfile == "pair-delivery"
    ? 0
    : sent
let ackSuccessRate = sent == 0 ? Double(successes) / Double(max(options.connections, 1)) : Double(acknowledgements) / Double(sent)
let canonicalSuccessRate = expectedCanonicalMessages == 0 ? 1.0 : Double(canonicalMessages) / Double(expectedCanonicalMessages)
let expectedDeliveries = expectedDeliveriesByConnection.reduce(0, +)
let deliverySuccessRate = expectedDeliveries == 0 ? 0 : Double(deliveredMessages) / Double(expectedDeliveries)

print("profile=\(options.profile) connections=\(options.connections) accounts=\(accountCredentials.count) devicesPerUser=\(options.devicesPerUser) accountDevicesPerUser=\(options.accountDevicesPerUser) queuePoolSize=\(connectionQueuePool.size) maxReconnects=\(options.maxReconnects) successes=\(successes) elapsed=\(String(format: "%.2f", elapsed))s")
print("loginCacheHit=\(loginCacheHit) loginCacheRecords=\(loginCacheRecords) loginCacheValidForSeconds=\(loginCacheValidForSeconds) requireLoginCache=\(options.requireLoginCache)")
print("globalHoldBarrier=\(globalHoldBarrier != nil) globalHoldBarrierTarget=\(globalHoldBarrierTarget) globalHoldBarrierMinRatio=\(options.globalHoldBarrierMinRatio) messageProfile=\(options.messageProfile) messageCompletionMode=\(options.messageCompletionMode) messageRatePerSecond=\(options.messageRatePerSecond) activeConversationUsers=\(options.activeConversationUsers) expectedCanonical=\(expectedCanonicalMessages) expectedDeliveries=\(expectedDeliveries)")
print("sent=\(sent) ack=\(acknowledgements) canonical=\(canonicalMessages) duplicateCanonical=\(duplicateCanonicalMessages) delivered=\(deliveredMessages) duplicateDelivered=\(duplicateDeliveredMessages) fanout=\(fanoutMessages) activityHints=\(activityHints) reconnects=\(reconnects) serverErrors=\(serverErrors)")
print("heartbeat sent=\(heartbeatSends) ack=\(heartbeatAcks) intervalSeconds=\(options.heartbeatIntervalSeconds)")
print("heartbeatSendCompletionMs p50=\(String(format: "%.1f", percentile(heartbeatSendCompletionMillis, 0.50))) p95=\(String(format: "%.1f", percentile(heartbeatSendCompletionMillis, 0.95))) p99=\(String(format: "%.1f", percentile(heartbeatSendCompletionMillis, 0.99)))")
print("ackSuccessRate=\(String(format: "%.4f", ackSuccessRate)) canonicalSuccessRate=\(String(format: "%.4f", canonicalSuccessRate)) deliverySuccessRate=\(String(format: "%.4f", deliverySuccessRate))")
if !failureReasons.isEmpty {
    let summary = failureReasons
        .sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value > rhs.value
        }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ", ")
    print("failureReasons \(summary)")
}
print("ackLatencyMs p50=\(String(format: "%.1f", percentile(ackLatencies, 0.50))) p95=\(String(format: "%.1f", percentile(ackLatencies, 0.95))) p99=\(String(format: "%.1f", percentile(ackLatencies, 0.99)))")
print("canonicalLatencyMs p50=\(String(format: "%.1f", percentile(canonicalLatencies, 0.50))) p95=\(String(format: "%.1f", percentile(canonicalLatencies, 0.95))) p99=\(String(format: "%.1f", percentile(canonicalLatencies, 0.99)))")
print("deliveryLatencyMs p50=\(String(format: "%.1f", percentile(deliveryLatencies, 0.50))) p95=\(String(format: "%.1f", percentile(deliveryLatencies, 0.95))) p99=\(String(format: "%.1f", percentile(deliveryLatencies, 0.99)))")
if let connectionLogFile = options.connectionLogFile {
    print("connectionLogFile=\(connectionLogFile)")
}
connectionLogger.log(
    "run_finish",
    fields: [
        "successes": String(successes),
        "connections": String(options.connections),
        "sent": String(sent),
        "ack": String(acknowledgements),
        "canonical": String(canonicalMessages),
        "expectedCanonical": String(expectedCanonicalMessages),
        "delivered": String(deliveredMessages),
        "expectedDeliveries": String(expectedDeliveries),
        "deliverySuccessRate": String(deliverySuccessRate),
        "activityHints": String(activityHints),
        "serverErrors": String(serverErrors),
        "reconnects": String(reconnects),
        "heartbeatSends": String(heartbeatSends),
        "heartbeatAcks": String(heartbeatAcks),
        "heartbeatSendCompletionP95Ms": String(Int(percentile(heartbeatSendCompletionMillis, 0.95))),
        "heartbeatSendCompletionP99Ms": String(Int(percentile(heartbeatSendCompletionMillis, 0.99))),
        "deliveryP95Ms": String(Int(percentile(deliveryLatencies, 0.95))),
        "deliveryP99Ms": String(Int(percentile(deliveryLatencies, 0.99))),
        "messageProfile": options.messageProfile,
        "messageCompletionMode": options.messageCompletionMode,
        "messageRatePerSecond": String(options.messageRatePerSecond),
        "activeConversationUsers": String(options.activeConversationUsers),
        "accountDevicesPerUser": String(options.accountDevicesPerUser),
        "loginCacheHit": String(loginCacheHit),
        "loginCacheRecords": String(loginCacheRecords),
        "loginCacheValidForSeconds": String(loginCacheValidForSeconds),
        "globalHoldBarrierTarget": String(globalHoldBarrierTarget),
        "globalHoldBarrierMinRatio": String(options.globalHoldBarrierMinRatio),
        "elapsedMs": String(Int(elapsed * 1_000))
    ]
)

if reconnects < options.minReconnects {
    fputs(
        "minimum reconnects not reached: reconnects=\(reconnects) minReconnects=\(options.minReconnects)\n",
        stderr
    )
    exit(5)
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var values: [T] = []
        for element in self {
            let value = try await transform(element)
            values.append(value)
        }
        return values
    }
}

func concurrentMap<Element: Sendable, T: Sendable>(
    _ elements: [Element],
    concurrency: Int,
    transform: @escaping @Sendable (Element) async throws -> T
) async throws -> [T] {
    var iterator = elements.enumerated().makeIterator()
    let workerCount = min(max(concurrency, 1), elements.count)
    return try await withThrowingTaskGroup(of: (Int, T).self) { group in
        var results = Array<T?>(repeating: nil, count: elements.count)

        for _ in 0..<workerCount {
            guard let (index, element) = iterator.next() else { break }
            group.addTask {
                (index, try await transform(element))
            }
        }

        while let (index, value) = try await group.next() {
            results[index] = value
            if let (nextIndex, nextElement) = iterator.next() {
                group.addTask {
                    (nextIndex, try await transform(nextElement))
                }
            }
        }

        return results.map { $0! }
    }
}
