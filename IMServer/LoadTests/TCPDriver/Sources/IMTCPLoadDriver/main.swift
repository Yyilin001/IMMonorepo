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
    var messagesPerConnection = 1
}

struct LoginResponse: Decodable {
    struct User: Decodable {
        let id: String
    }

    let accessToken: String
    let user: User
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
        case "--messages":
            options.messagesPerConnection = Int(value) ?? options.messagesPerConnection
        default:
            continue
        }
    }

    switch options.profile {
    case "staging-baseline":
        options.connections = max(options.connections, 10_000)
        options.messagesPerConnection = max(options.messagesPerConnection, 3)
    case "capacity-target":
        options.connections = max(options.connections, 50_000)
        options.messagesPerConnection = max(options.messagesPerConnection, 3)
    default:
        options.connections = min(options.connections, 100)
        options.messagesPerConnection = max(options.messagesPerConnection, 1)
    }
    return options
}

func login(options: Options) async throws -> LoginResponse {
    var request = URLRequest(url: options.baseURL.appending(path: "/api/auth/login"))
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "email": options.email,
        "password": options.password,
        "deviceID": "tcp-load-driver",
        "deviceName": "tcp-load-driver",
        "platform": "load-test"
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

final class ConnectionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<Bool, Never>
    private let connection: NWConnection

    init(continuation: CheckedContinuation<Bool, Never>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func finish(_ ok: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()

        connection.cancel()
        continuation.resume(returning: ok)
    }
}

func runConnection(index: Int, options: Options, auth: LoginResponse) async -> Bool {
    await withCheckedContinuation { continuation in
        let connection = NWConnection(
            host: NWEndpoint.Host(options.tcpHost),
            port: NWEndpoint.Port(rawValue: options.tcpPort)!,
            using: .tcp
        )
        let queue = DispatchQueue(label: "im.tcp.load.\(index)")
        let completion = ConnectionCompletion(continuation: continuation, connection: connection)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                do {
                    let authPacket = try packet(type: "auth", payload: [
                        "accessToken": auth.accessToken,
                        "deviceID": "tcp-load-\(index)",
                        "deviceName": "tcp-load",
                        "platform": "load-test",
                        "appVersion": "load-test",
                        "protocolVersion": 1
                    ])
                    connection.send(content: authPacket, completion: .contentProcessed { error in
                        if error != nil {
                            completion.finish(false)
                            return
                        }
                        for messageIndex in 0..<options.messagesPerConnection {
                            let messagePacket = try? packet(type: "message", payload: [
                                "clientMessageID": "tcp-\(index)-\(messageIndex)-\(UUID().uuidString)",
                                "messageID": NSNull(),
                                "conversationID": options.conversationID,
                                "senderUserID": NSNull(),
                                "serverSequence": NSNull(),
                                "serverTimestamp": NSNull(),
                                "content": ["type": "text", "text": "tcp load \(index)/\(messageIndex)"],
                                "derivedState": ["reactions": [], "editedAt": NSNull(), "recalledAt": NSNull()]
                            ])
                            if let messagePacket {
                                connection.send(content: messagePacket, completion: .contentProcessed { _ in })
                            }
                        }
                        completion.finish(true)
                    })
                } catch {
                    completion.finish(false)
                }
            case .failed, .cancelled:
                completion.finish(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

let options = parseOptions()
guard !options.conversationID.isEmpty else {
    fputs("Missing --conversation-id or IM_CONVERSATION_ID\n", stderr)
    exit(2)
}

let auth = try await login(options: options)
let startedAt = Date()
let successes = await withTaskGroup(of: Bool.self) { group in
    for index in 0..<options.connections {
        group.addTask {
            await runConnection(index: index, options: options, auth: auth)
        }
    }
    var count = 0
    for await ok in group where ok {
        count += 1
    }
    return count
}

let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
print("profile=\(options.profile) connections=\(options.connections) successes=\(successes) elapsed=\(String(format: "%.2f", elapsed))s")
