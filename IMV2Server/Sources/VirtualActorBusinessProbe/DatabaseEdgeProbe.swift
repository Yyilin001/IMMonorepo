import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorApplication
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import IMV2Server
import Logging
import NIOPosix
import SQLKit

/// Test-only executable composition. The Python driver cuts one private DB
/// network at a time and optionally restarts owner-a PostgreSQL; these
/// processes retain their real Cluster connections throughout each fault.
enum DatabaseEdgeProbe {
    private enum Failure: Error { case invalid(String) }
    private struct Environment: V2RuntimeEnvironment {
        func value(for key: String) -> String? { ProcessInfo.processInfo.environment[key] }
    }
    private struct Row: Decodable { let value: Int64 }
    private struct Shadow: V2UserShardProjectionDelivering {
        func deliverToCurrentShard(userID: UserID, sourceEventID: EventID,
                                projectionKinds: Set<String>) async throws -> UInt64? { nil }
    }
    private static let user = UserID(uuid: id(12))
    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", suffix))!
    }
    private static func room(_ slot: Int) -> RoomID { RoomID(uuid: id(10 + slot)) }
    private static func required(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw Failure.invalid("missing \(key)")
        }
        return value
    }
    private static func path(_ name: String) throws -> URL {
        URL(fileURLWithPath: try required("VA_DB_EDGE_EVIDENCE"), isDirectory: true)
            .appendingPathComponent(name)
    }
    private static func exists(_ name: String) throws -> Bool {
        FileManager.default.fileExists(atPath: try path(name).path)
    }
    private static func marker<T: Encodable>(_ name: String, _ value: T) throws {
        try JSONEncoder().encode(value).write(to: path(name), options: .atomic)
    }
    private static func wait(_ name: String) async throws {
        let end = ContinuousClock.now + .seconds(180)
        while try !exists(name) {
            guard ContinuousClock.now < end else { throw Failure.invalid("timeout \(name)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private static func sql(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw Failure.invalid("SQL driver") }
        return sql
    }
    private static func reachable(_ database: any Database) async throws {
        guard try await sql(database).raw("SELECT 1 AS value").first(decoding: Row.self)?.value == 1 else {
            throw Failure.invalid("healthy DB unavailable")
        }
    }

    static func run(host: Bool) async throws {
        let name = try required("VA_DB_EDGE_NODE")
        let resources = V2DatabaseResources(eventLoopGroup: MultiThreadedEventLoopGroup(numberOfThreads: 1),
            logger: Logger(label: "imv2.va.database-edge.\(name)"), ownsEventLoopGroup: true)
        let controlID = DatabaseID(string: "control")
        resources.databases.use(try .postgres(url: required("VA_DB_EDGE_CONTROL_URL"),
            maxConnectionsPerEventLoop: 4), as: controlID, isDefault: true)
        let control = resources.database(controlID)
        var databases: [String: any Database] = [:]
        var owners: [String: V2RoomServerOwnerResources] = [:]
        for slot in ["a", "b"] where !host || name == "host-\(slot)" {
            let identifier = DatabaseID(string: "owner-\(slot)")
            resources.databases.use(try .postgres(url: required("VA_DB_EDGE_OWNER_\(slot.uppercased())_URL"),
                maxConnectionsPerEventLoop: 4), as: identifier)
            let database = resources.database(identifier)
            databases["room-\(slot)"] = database
            if host {
                let writes = PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 1000, window: 86_400),
                    contentReviewMode: .disabled)
                    .usingControlDatabase(control, authorizationResolutionDatabase: control)
                let batcher = V2SendMessageAdmissionBatcher(store: writes,
                    configuration: .init(maximumBatchSize: 16, maximumDelay: .milliseconds(2)),
                    actorGrantedStore: writes)
                owners["room-\(slot)"] = try .init(database: database, writes: writes,
                    sendBatcher: batcher,
                    membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: control),
                    invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: control),
                    invitationSecretIssuer: try .init(base64EncodedKey: required("IM_V2_GROUP_INVITE_TOKEN_HMAC_KEY_BASE64")),
                    receiptProjectionDelivery: Shadow(),
                    capacityProfile: .init(id: "standard", limits: .init(
                        maxEligibleMembers: 10, maxCommandsPerWindow: 1000, retryAfterSeconds: 3)),
                    messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                    contentReviewMode: .disabled, queryBatchConfiguration: .init())
            }
        }
        let configuration = try V2RoomActorApplicationConfiguration(environment: Environment(),
            hostsRooms: host, configuredShardIDs: ["room-a", "room-b"])
        let factory = host ? try V2RoomServerActivationFactory(owners: owners, safetyActorUserID: user) : nil
        let application = try await V2RoomActorApplication.start(configuration: configuration,
            ownerRouter: V2PostgresRoomShardRouter(database: control), roomDatabases: databases, factory: factory)
        do {
            if host {
                guard await application.readiness() else { throw Failure.invalid("host readiness") }
                try marker("\(name)-ready.json", true)
                var checked = Set<String>()
                while try !exists("stop-hosts") {
                    for phase in ["control-cut", "owner-cut"] where !checked.contains(phase) {
                        if try exists("\(name)-check-\(phase)") {
                            // The affected Host proves its other DB edge still
                            // works. The healthy Host proves both SQL handles.
                            if name != "host-a" || phase == "owner-cut" { try await reachable(control) }
                            if name != "host-a" || phase == "control-cut" {
                                for database in databases.values { try await reachable(database) }
                            }
                            try marker("\(name)-\(phase)-healthy-edge.json", true)
                            checked.insert(phase)
                        }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } else {
                try await client(application)
            }
            guard try await application.stop(deadline: .now + .seconds(60)) else {
                throw Failure.invalid("incomplete drain")
            }
            try await resources.shutdown()
            try marker("\(name)-stopped.json", true)
        } catch {
            _ = try? await application.stop(deadline: .now + .seconds(10))
            try? await resources.shutdown()
            throw error
        }
    }

    // One immutable admission timestamp for this probe process, including replays.
    private static let operationDeadline = UInt64(Date().timeIntervalSince1970 * 1_000) + 600_000
    private static func send(_ slot: Int, operation: Int) throws -> V2RoomRequest {
        .messaging(.sendOperation(try .init(command: try .init(roomID: room(slot), senderUserID: user,
            clientMessageID: .init(uuid: id(operation)), text: "database edge probe",
            limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: operationDeadline)))
    }
    private static func edit(_ slot: Int, message: MessageID, operation: Int,
                             expected: UInt64) throws -> V2RoomRequest {
        .messaging(.editOperation(try .init(command: try .init(roomID: room(slot), actorUserID: user,
            operationID: .init(uuid: id(operation)), messageID: message,
            expectedMessageRevision: expected, text: "edit \(operation)", maximumUTF8Bytes: 64), firstSubmissionDeadlineMilliseconds: operationDeadline)))
    }
    private static func call(_ application: V2RoomActorApplication, _ request: V2RoomRequest,
                             seconds: Int = 10) async throws -> V2RoomResponse {
        let response = try await application.directory.room(request.roomID).call(request,
            principal: .user(user), deadline: .now + .seconds(seconds))
        switch response {
        case .messaging(.sendOperation(.receipt)), .messaging(.mutation(.receipt)):
            try validateProof(response, request: request)
        default: break
        }
        return response
    }
    private static func eventually(_ application: V2RoomActorApplication,
                                   _ request: V2RoomRequest) async throws -> V2RoomResponse {
        let end = ContinuousClock.now + .seconds(65)
        var failure: any Error = Failure.invalid("no attempt")
        while ContinuousClock.now < end {
            do {
                let response = try await call(application, request)
                switch response {
                case .messaging(.sendOperation(.unresolved)), .messaging(.mutation(.unresolved)),
                     .messaging(.sendOperation(.deferred)), .messaging(.mutation(.deferred)):
                    failure = Failure.invalid("temporarily unavailable")
                    try await Task.sleep(for: .milliseconds(250))
                default:
                    try validateProof(response, request: request)
                    return response
                }
            }
            catch { failure = error; try await Task.sleep(for: .milliseconds(250)) }
        }
        throw failure
    }
    private static func validateProof(_ response: V2RoomResponse, request: V2RoomRequest) throws {
        switch (request, response) {
        case (.messaging(.sendOperation(let command)), .messaging(.sendOperation(.receipt(let proof)))):
            guard proof.identity == (try command.identity), proof.fingerprint == (try command.fingerprint) else {
                throw Failure.invalid("send proof binding")
            }
        case (.messaging(.editOperation(let command)), .messaging(.mutation(.receipt(let proof)))):
            guard proof.identity == (try command.identity), proof.fingerprint == (try command.fingerprint) else {
                throw Failure.invalid("edit proof binding")
            }
        default: throw Failure.invalid("missing original operation proof")
        }
    }
    private static func message(_ response: V2RoomResponse) throws -> MessageID {
        switch response {
        case .messaging(.sendOperation(.receipt(let proof))):
            guard case .accepted(let value) = proof.outcome else { throw Failure.invalid("send was not accepted") }
            return value.messageID
        default: throw Failure.invalid("send was not accepted")
        }
    }
    private static func edited(_ response: V2RoomResponse, revision: UInt64) throws {
        switch response {
        case .messaging(.mutation(.receipt(let proof))):
            guard case .committed(let value) = proof.outcome, value.messageRevision == revision else { throw Failure.invalid("edit revision") }
        default: throw Failure.invalid("edit was not accepted")
        }
    }
    private static func rejected(_ application: V2RoomActorApplication, _ request: V2RoomRequest) async throws -> String {
        do {
            let response = try await call(application, request, seconds: 8)
            // An ordinary business denial is not proof of a DB-edge failure.
            switch response {
            case .messaging(.sendOperation(.unresolved)), .messaging(.mutation(.unresolved)): return "originalOperationUnresolved"
            default: throw Failure.invalid("fault call returned a non-unavailable business result")
            }
        } catch let failure as V2RoomCallFailure {
            switch failure {
            case .outcomeUnknown: return "outcomeUnknown"
            case .notAccepted(let reason), .rolledBack(let reason):
                switch reason {
                case .unavailable, .deadlineExceeded, .leaseLost, .staleActivation, .notReady, .retired:
                    return String(describing: failure)
                default: throw failure
                }
            }
        }
    }
    private static func client(_ application: V2RoomActorApplication) async throws {
        let firstA = try message(await eventually(application, send(1, operation: 101)))
        let firstB = try message(await eventually(application, send(2, operation: 102)))
        try edited(await eventually(application, edit(1, message: firstA, operation: 201, expected: 1)), revision: 2)
        try edited(await eventually(application, edit(2, message: firstB, operation: 202, expected: 1)), revision: 2)
        let token = try await application.directory.resolve(room(1), deadline: .now + .seconds(10))
        try marker("initial-token.json", token)
        try marker("warm.json", ["a": firstA.rawValue, "b": firstB.rawValue])

        let faultEdit = try edit(1, message: firstA, operation: 301, expected: 2)
        try await wait("control-cut-start")
        let controlFailure = try await rejected(application, faultEdit)
        try edited(await call(application, edit(2, message: firstB, operation: 302, expected: 2)), revision: 3)
        try marker("control-cut-result.json", ["affectedFailure": controlFailure, "healthyEdit": "accepted"])
        try await wait("control-restored")
        try edited(await eventually(application, faultEdit), revision: 3)
        try edited(await call(application, faultEdit), revision: 3)
        // A failed control read may finish after its caller deadline. The
        // production domain completion deliberately retires driver failures as
        // uncertain, so recovery can replace this epoch even though no edit
        // committed. Use the recovered token as the next fault's baseline.
        let controlRecovered = try await application.directory.resolve(room(1), deadline: .now + .seconds(10))
        try marker("control-recovered-token.json", controlRecovered)
        try marker("control-recovered.json", true)

        let faultSend = try send(1, operation: 401)
        try await wait("owner-cut-expired")
        let ownerFailure = try await rejected(application, faultSend)
        _ = try message(await call(application, send(2, operation: 402)))
        try marker("owner-cut-result.json", ["affectedFailure": ownerFailure, "healthySend": "accepted"])
        try await wait("owner-restored")
        let recovered = try message(await eventually(application, faultSend))
        guard try message(await call(application, faultSend)) == recovered else {
            throw Failure.invalid("replay identity changed")
        }
        let replacement = try await application.directory.resolve(room(1), deadline: .now + .seconds(10))
        guard replacement.activationEpoch.rawValue > controlRecovered.activationEpoch.rawValue else {
            throw Failure.invalid("expired lease did not get a new epoch")
        }
        try marker("replacement-token.json", replacement)
        try marker("owner-recovered.json", true)
        let restartDatabase = ProcessInfo.processInfo.environment["VA_DB_EDGE_RESTART"] == "1"
        if restartDatabase {
            try await wait("owner-restart-down")
            let restartSend = try send(1, operation: 501)
            let restartFailure = try await rejected(application, restartSend)
            _ = try message(await call(application, send(2, operation: 502)))
            try marker("owner-restart-down-result.json", [
                "affectedFailure": restartFailure, "healthySend": "accepted",
            ])
            try await wait("owner-restart-ready")
            let restarted = try message(await eventually(application, restartSend))
            guard try message(await call(application, restartSend)) == restarted else {
                throw Failure.invalid("database restart replay identity changed")
            }
            try marker("owner-restart-token.json",
                await application.directory.resolve(room(1), deadline: .now + .seconds(10)))
            try marker("owner-restart-recovered.json", ["messageID": restarted.rawValue])
            try await wait("owner-restart-verified")
        }
        try marker("client-result.json", ["controlRecoveredExactlyOnce": true,
            "ownerRecoveredExactlyOnce": true, "databaseRestartTested": restartDatabase])
    }
}
