import Foundation
import Network

struct Options {
    var profile = "local-smoke"
    var baseURL = URL(string: "http://127.0.0.1:8080")!
    var tcpHost = "127.0.0.1"
    var tcpPort: UInt16 = 9001
    var email = ProcessInfo.processInfo.environment["IM_EMAIL"] ?? "demo@example.com"
    var password = ProcessInfo.processInfo.environment["IM_PASSWORD"] ?? "password1234"
    var conversationID = ProcessInfo.processInfo.environment["IM_CONVERSATION_ID"] ?? ""
    var connections = 100
    var devicesPerUser = 1
    var messagesPerConnection = 1
    var sendIntervalMillis = 0
    var timeoutSeconds = 20
}

struct LoginResponse: Decodable {
    struct User: Decodable {
        let id: String
    }

    let accessToken: String
    let user: User
}

struct ConnectionResult: Sendable {
    let success: Bool
    let sent: Int
    let acknowledgements: Int
    let canonicalMessages: Int
    let fanoutMessages: Int
    let reconnects: Int
    let serverErrors: Int
    let ackLatenciesMillis: [Double]
    let canonicalLatenciesMillis: [Double]
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
        case "--timeout-seconds":
            options.timeoutSeconds = max(1, Int(value) ?? options.timeoutSeconds)
        default:
            continue
        }
    }

    switch options.profile {
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

func login(options: Options, deviceIndex: Int) async throws -> LoginResponse {
    var request = URLRequest(url: options.baseURL.appending(path: "/api/auth/login"))
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "email": options.email,
        "password": options.password,
        "device": [
            "deviceID": "tcp-load-driver-\(deviceIndex)",
            "deviceName": "tcp-load-driver-\(deviceIndex)",
            "platform": "load-test",
            "appVersion": "load-test"
        ]
    ])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw NSError(domain: "IMTCPLoadDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: "login failed"])
    }
    return try JSONDecoder().decode(LoginResponse.self, from: data)
}

func packet(type: String, payload: [String: Any], requestID: String = UUID().uuidString) throws -> Data {
    let envelope: [String: Any] = [
        "type": type,
        "requestID": requestID,
        "timestamp": ISO8601DateFormatter().string(from: Date()),
        "payload": payload
    ]
    var data = try JSONSerialization.data(withJSONObject: envelope)
    data.append(0x0A)
    return data
}

final class ConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var sentClientIDsByRequestID: [String: String] = [:]
    private var sentAtByClientID: [String: Date] = [:]
    private var acknowledgedClientIDs: Set<String> = []
    private var canonicalClientIDs: Set<String> = []
    private var ackLatenciesMillis: [Double] = []
    private var canonicalLatenciesMillis: [Double] = []
    private var fanoutMessages = 0
    private var serverErrors = 0
    private var reconnects = 0
    private let expectedOwnMessages: Int
    private let continuation: CheckedContinuation<ConnectionResult, Never>
    private let connection: NWConnection

    init(
        expectedOwnMessages: Int,
        continuation: CheckedContinuation<ConnectionResult, Never>,
        connection: NWConnection
    ) {
        self.expectedOwnMessages = expectedOwnMessages
        self.continuation = continuation
        self.connection = connection
    }

    func recordSent(clientMessageID: String, requestID: String, at date: Date) {
        lock.lock()
        sentClientIDsByRequestID[requestID] = clientMessageID
        sentAtByClientID[clientMessageID] = date
        lock.unlock()
    }

    func recordReconnect() {
        lock.lock()
        reconnects += 1
        lock.unlock()
    }

    func recordPacketLine(_ line: String) {
        guard
            let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else {
            return
        }

        let requestID = json["requestID"] as? String
        let payload = json["payload"] as? [String: Any]

        lock.lock()
        switch type {
        case "ack":
            if let requestID, let clientID = sentClientIDsByRequestID[requestID], !acknowledgedClientIDs.contains(clientID) {
                acknowledgedClientIDs.insert(clientID)
                if let sentAt = sentAtByClientID[clientID] {
                    ackLatenciesMillis.append(Date().timeIntervalSince(sentAt) * 1_000)
                }
            }
            if let status = payload?["status"] as? String, status != "accepted" {
                serverErrors += 1
            }
        case "message":
            fanoutMessages += 1
            if let clientID = payload?["clientMessageID"] as? String,
               sentAtByClientID[clientID] != nil,
               !canonicalClientIDs.contains(clientID) {
                canonicalClientIDs.insert(clientID)
                if let sentAt = sentAtByClientID[clientID] {
                    canonicalLatenciesMillis.append(Date().timeIntervalSince(sentAt) * 1_000)
                }
            }
        case "auth_error", "kick":
            serverErrors += 1
        default:
            break
        }
        let shouldFinish = acknowledgedClientIDs.count >= expectedOwnMessages
            && canonicalClientIDs.count >= expectedOwnMessages
        lock.unlock()

        if shouldFinish {
            finish(success: true)
        }
    }

    func finish(success: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let result = ConnectionResult(
            success: success,
            sent: sentAtByClientID.count,
            acknowledgements: acknowledgedClientIDs.count,
            canonicalMessages: canonicalClientIDs.count,
            fanoutMessages: fanoutMessages,
            reconnects: reconnects,
            serverErrors: serverErrors,
            ackLatenciesMillis: ackLatenciesMillis,
            canonicalLatenciesMillis: canonicalLatenciesMillis
        )
        lock.unlock()

        connection.cancel()
        continuation.resume(returning: result)
    }
}

func receiveLines(connection: NWConnection, state: ConnectionState, buffer: Data = Data()) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
        if error != nil || isComplete {
            state.finish(success: false)
            return
        }

        var nextBuffer = buffer
        if let data {
            nextBuffer.append(data)
            while let newline = nextBuffer.firstIndex(of: 0x0A) {
                let lineData = nextBuffer[..<newline]
                nextBuffer.removeSubrange(...newline)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    state.recordPacketLine(line)
                }
            }
        }

        receiveLines(connection: connection, state: state, buffer: nextBuffer)
    }
}

func runConnection(index: Int, options: Options, auth: LoginResponse, deviceIndex: Int) async -> ConnectionResult {
    await withCheckedContinuation { continuation in
        let connection = NWConnection(
            host: NWEndpoint.Host(options.tcpHost),
            port: NWEndpoint.Port(rawValue: options.tcpPort)!,
            using: .tcp
        )
        let queue = DispatchQueue(label: "im.tcp.load.\(index)")
        let state = ConnectionState(
            expectedOwnMessages: options.messagesPerConnection,
            continuation: continuation,
            connection: connection
        )

        connection.stateUpdateHandler = { nwState in
            switch nwState {
            case .ready:
                receiveLines(connection: connection, state: state)
                do {
                    let authPacket = try packet(type: "auth", payload: [
                        "accessToken": auth.accessToken,
                        "deviceID": "tcp-load-driver-\(deviceIndex)",
                        "deviceName": "tcp-load-driver-\(deviceIndex)",
                        "platform": "load-test",
                        "appVersion": "load-test",
                        "protocolVersion": 1
                    ])
                    connection.send(content: authPacket, completion: .contentProcessed { error in
                        if error != nil {
                            state.finish(success: false)
                            return
                        }
                        for messageIndex in 0..<options.messagesPerConnection {
                            let delay = DispatchTime.now() + .milliseconds(options.sendIntervalMillis * messageIndex)
                            queue.asyncAfter(deadline: delay) {
                                let requestID = UUID().uuidString
                                let clientMessageID = "tcp-\(index)-\(messageIndex)-\(UUID().uuidString)"
                                let messagePacket = try? packet(type: "message", payload: [
                                    "clientMessageID": clientMessageID,
                                    "messageID": NSNull(),
                                    "conversationID": options.conversationID,
                                    "senderUserID": NSNull(),
                                    "serverSequence": NSNull(),
                                    "serverTimestamp": NSNull(),
                                    "content": ["type": "text", "text": "tcp load \(index)/\(messageIndex)"],
                                    "derivedState": ["reactions": [], "editedAt": NSNull(), "recalledAt": NSNull()]
                                ], requestID: requestID)
                                if let messagePacket {
                                    state.recordSent(clientMessageID: clientMessageID, requestID: requestID, at: Date())
                                    connection.send(content: messagePacket, completion: .contentProcessed { error in
                                        if error != nil {
                                            state.finish(success: false)
                                        }
                                    })
                                }
                            }
                        }
                    })
                } catch {
                    state.finish(success: false)
                }
            case .waiting:
                state.recordReconnect()
            case .failed, .cancelled:
                state.finish(success: false)
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + .seconds(options.timeoutSeconds)) {
            state.finish(success: false)
        }
        connection.start(queue: queue)
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
    return sorted[index]
}

let options = parseOptions()
guard !options.conversationID.isEmpty else {
    fputs("Missing --conversation-id or IM_CONVERSATION_ID\n", stderr)
    exit(2)
}

let auths = try await (0..<options.devicesPerUser).asyncMap { deviceIndex in
    try await login(options: options, deviceIndex: deviceIndex)
}
let startedAt = Date()
let results = await withTaskGroup(of: ConnectionResult.self) { group in
    for index in 0..<options.connections {
        let deviceIndex = index % options.devicesPerUser
        group.addTask {
            await runConnection(index: index, options: options, auth: auths[deviceIndex], deviceIndex: deviceIndex)
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
let fanoutMessages = results.reduce(0) { $0 + $1.fanoutMessages }
let reconnects = results.reduce(0) { $0 + $1.reconnects }
let serverErrors = results.reduce(0) { $0 + $1.serverErrors }
let ackLatencies = results.flatMap(\.ackLatenciesMillis)
let canonicalLatencies = results.flatMap(\.canonicalLatenciesMillis)
let ackSuccessRate = sent == 0 ? 0 : Double(acknowledgements) / Double(sent)
let canonicalSuccessRate = sent == 0 ? 0 : Double(canonicalMessages) / Double(sent)

print("profile=\(options.profile) connections=\(options.connections) devicesPerUser=\(options.devicesPerUser) successes=\(successes) elapsed=\(String(format: "%.2f", elapsed))s")
print("sent=\(sent) ack=\(acknowledgements) canonical=\(canonicalMessages) fanout=\(fanoutMessages) reconnects=\(reconnects) serverErrors=\(serverErrors)")
print("ackSuccessRate=\(String(format: "%.4f", ackSuccessRate)) canonicalSuccessRate=\(String(format: "%.4f", canonicalSuccessRate))")
print("ackLatencyMs p50=\(String(format: "%.1f", percentile(ackLatencies, 0.50))) p95=\(String(format: "%.1f", percentile(ackLatencies, 0.95))) p99=\(String(format: "%.1f", percentile(ackLatencies, 0.99)))")
print("canonicalLatencyMs p50=\(String(format: "%.1f", percentile(canonicalLatencies, 0.50))) p95=\(String(format: "%.1f", percentile(canonicalLatencies, 0.95))) p99=\(String(format: "%.1f", percentile(canonicalLatencies, 0.99)))")

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
