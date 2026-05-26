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
    let duplicateCanonicalMessages: Int
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

enum RealtimePacketType {
    case auth
    case authError
    case message
    case ack
    case kick
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
        requestID: String = UUID().uuidString
    ) -> Data {
        var auth = Data()
        auth.writeString(field: 1, accessToken)
        auth.writeString(field: 2, deviceID)
        auth.writeString(field: 3, deviceName)
        auth.writeString(field: 4, platform)
        auth.writeString(field: 5, appVersion)
        auth.writeVarint(field: 6, 2)

        var packet = packetBase(requestID: requestID)
        packet.writeMessage(field: 10, auth)
        return frame(packet)
    }

    static func messageFrame(
        conversationID: String,
        clientMessageID: String,
        text: String,
        requestID: String
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

        var packet = packetBase(requestID: requestID)
        packet.writeMessage(field: 30, message)
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
                type = type ?? nil
            case 12:
                type = .authError
            case 30:
                type = .message
                payload.merge(decodeMessagePayload(field.value)) { current, _ in current }
            case 31:
                type = .ack
                payload.merge(decodeAckPayload(field.value)) { current, _ in current }
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

    private static func packetBase(requestID: String) -> Data {
        var packet = Data()
        packet.writeString(field: 1, requestID)
        packet.writeVarint(field: 2, UInt64(Date().timeIntervalSince1970 * 1000))
        packet.writeVarint(field: 3, 2)
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
    private let lock = NSLock()
    private var completed = false
    private var sentClientIDsByRequestID: [String: String] = [:]
    private var sentAtByClientID: [String: Date] = [:]
    private var acknowledgedClientIDs: Set<String> = []
    private var canonicalClientIDs: Set<String> = []
    private var duplicateCanonicalMessages = 0
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

    func recordPacket(_ packet: DecodedRealtimePacket) {
        lock.lock()
        switch packet.type {
        case .ack:
            let requestID = packet.requestID
            if let requestID, let clientID = sentClientIDsByRequestID[requestID], !acknowledgedClientIDs.contains(clientID) {
                acknowledgedClientIDs.insert(clientID)
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
        case .authError, .kick:
            serverErrors += 1
        case .auth:
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
            duplicateCanonicalMessages: duplicateCanonicalMessages,
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

func receiveFrames(connection: NWConnection, state: ConnectionState, buffer: Data = Data()) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
        if error != nil || isComplete {
            state.finish(success: false)
            return
        }

        var nextBuffer = buffer
        if let data {
            nextBuffer.append(data)
            for frame in ProtoWire.frames(from: &nextBuffer) {
                guard let packet = ProtoWire.decodePacket(frame) else { continue }
                state.recordPacket(packet)
            }
        }

        receiveFrames(connection: connection, state: state, buffer: nextBuffer)
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
                receiveFrames(connection: connection, state: state)
                let authPacket = ProtoWire.authFrame(
                    accessToken: auth.accessToken,
                    deviceID: "tcp-load-driver-\(deviceIndex)",
                    deviceName: "tcp-load-driver-\(deviceIndex)",
                    platform: "load-test",
                    appVersion: "load-test"
                )
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
                            let messagePacket = ProtoWire.messageFrame(
                                conversationID: options.conversationID,
                                clientMessageID: clientMessageID,
                                text: "tcp load \(index)/\(messageIndex)",
                                requestID: requestID
                            )
                            state.recordSent(clientMessageID: clientMessageID, requestID: requestID, at: Date())
                            connection.send(content: messagePacket, completion: .contentProcessed { error in
                                if error != nil {
                                    state.finish(success: false)
                                }
                            })
                        }
                    }
                })
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
let duplicateCanonicalMessages = results.reduce(0) { $0 + $1.duplicateCanonicalMessages }
let fanoutMessages = results.reduce(0) { $0 + $1.fanoutMessages }
let reconnects = results.reduce(0) { $0 + $1.reconnects }
let serverErrors = results.reduce(0) { $0 + $1.serverErrors }
let ackLatencies = results.flatMap(\.ackLatenciesMillis)
let canonicalLatencies = results.flatMap(\.canonicalLatenciesMillis)
let ackSuccessRate = sent == 0 ? 0 : Double(acknowledgements) / Double(sent)
let canonicalSuccessRate = sent == 0 ? 0 : Double(canonicalMessages) / Double(sent)

print("profile=\(options.profile) connections=\(options.connections) devicesPerUser=\(options.devicesPerUser) successes=\(successes) elapsed=\(String(format: "%.2f", elapsed))s")
print("sent=\(sent) ack=\(acknowledgements) canonical=\(canonicalMessages) duplicateCanonical=\(duplicateCanonicalMessages) fanout=\(fanoutMessages) reconnects=\(reconnects) serverErrors=\(serverErrors)")
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
