import FluentKit
import FluentPostgresDriver
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import IMV2ActorApplication
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import IMV2Server
import Logging
import NIOPosix
import SQLKit

private enum ProbeError: Error {
    case missingEnvironment(String)
    case unexpectedResponse(String)
    case markerTimeout(String)
    case staleBusinessFenceAccepted
    case incompleteShutdown
}

private struct ProcessEnvironment: V2RuntimeEnvironment {
    func value(for key: String) -> String? { ProcessInfo.processInfo.environment[key] }
}

private struct CountRow: Decodable { let value: Int64 }

private struct ProbeResult: Encodable {
    let roomID: String
    let clientMessageID: String
    let messageID: String
    let firstActivationEpoch: Int64
    let replacementActivationEpoch: Int64
    let firstHostIncarnation: UUID
    let replacementHostIncarnation: UUID
    let subscriptionMembershipRevision: UInt64
    let subscriptionHighWatermark: UInt64
    let messageRows: Int64
    let staleBusinessWriteRejected: Bool
}

private struct NoopProjectionShadow: V2UserShardProjectionShadowing {
    func shadowIfForwarding(userID: UserID, sourceEventID: EventID,
                            projectionKinds: Set<String>) async throws -> UInt64? { nil }
}

@main
enum VirtualActorBusinessProbe {
    private static let roomID = RoomID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
    private static let senderID = UserID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
    private static let clientID = ClientMessageID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!)

    static func main() async {
        do {
            guard let mode = CommandLine.arguments.dropFirst().first else {
                throw ProbeError.missingEnvironment("host|client mode")
            }
            switch mode {
            case "host": try await host()
            case "client": try await client()
            default: throw ProbeError.missingEnvironment("host|client mode")
            }
        } catch {
            fputs("G4_PROBE_FAILURE \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func required(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw ProbeError.missingEnvironment(name)
        }
        return value
    }

    private static func evidence(_ name: String) throws -> URL {
        URL(fileURLWithPath: try required("VA_G4_EVIDENCE_DIR"), isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func marker(_ name: String, data: Data = Data("ready".utf8)) throws {
        try data.write(to: evidence(name), options: .atomic)
    }

    private static func waitFor(_ name: String, seconds: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        let path = try evidence(name).path
        while !FileManager.default.fileExists(atPath: path) {
            guard ContinuousClock.now < deadline else { throw ProbeError.markerTimeout(name) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func databaseResources() throws -> (V2DatabaseResources, any Database,
                                                        any SQLDatabase) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let resources = V2DatabaseResources(eventLoopGroup: group,
                                            logger: Logger(label: "imv2.va.g4.database"),
                                            ownsEventLoopGroup: true)
        resources.databases.use(try .postgres(url: required("VA_G4_DATABASE_URL"),
                                               maxConnectionsPerEventLoop: 4),
                                as: .psql, isDefault: true)
        let database = resources.database(.psql)
        guard let sql = database as? any SQLDatabase else {
            throw ProbeError.unexpectedResponse("PostgreSQL driver has no SQLDatabase")
        }
        return (resources, database, sql)
    }

    private static func configuration(hostsRooms: Bool) throws -> V2RoomActorApplicationConfiguration {
        try .init(environment: ProcessEnvironment(), hostsRooms: hostsRooms,
                  configuredShardIDs: ["room-a"])
    }

    private static func host() async throws {
        let (resources, database, sql) = try databaseResources()
        guard try await sql.raw("SELECT 1 AS value").first(decoding: CountRow.self)?.value == 1 else {
            throw ProbeError.unexpectedResponse("PostgreSQL unavailable")
        }
        let writes = PostgresV2RoomWriteStore(database: database,
            strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
            contentReviewMode: .disabled)
        let sends = V2SendMessageAdmissionBatcher(store: writes,
            configuration: .init(maximumBatchSize: 16, maximumDelay: .milliseconds(2)),
            actorGrantedStore: writes)
        let capacity = try V2CapacityProfile(id: "standard", limits: .init(
            maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 3))
        let owner = try V2RoomServerOwnerResources(database: database, writes: writes,
            sendBatcher: sends,
            membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
            invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
            receiptShadowForwarder: NoopProjectionShadow(), capacityProfile: capacity,
            messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
            contentReviewMode: .disabled, queryBatchConfiguration: .init())
        let factory = try V2RoomServerActivationFactory(owners: ["room-a": owner],
                                                        safetyActorUserID: senderID)
        let application = try await V2RoomActorApplication.start(
            configuration: configuration(hostsRooms: true),
            ownerRouter: V2PostgresRoomShardRouter(database: database),
            roomDatabases: ["room-a": database], factory: factory)
        guard await application.readiness() else {
            throw ProbeError.unexpectedResponse("host not ready")
        }
        try marker("host-ready")
        print("G4_HOST_READY")
        // Orchestration SIGKILLs this process; lease expiry, not release, must
        // let the replacement incarnation acquire this room.
        while true {
            try await Task.sleep(for: .seconds(1))
            withExtendedLifetime(resources) {}
        }
    }

    private static func client() async throws {
        let (resources, database, sql) = try databaseResources()
        let application = try await V2RoomActorApplication.start(
            configuration: configuration(hostsRooms: false),
            ownerRouter: V2PostgresRoomShardRouter(database: database),
            roomDatabases: ["room-a": database])
        do {
            let ref = application.directory.room(roomID)
            let request = V2RoomRequest.messaging(.send(.init(roomID: roomID,
                actorUserID: senderID, clientMessageID: clientID, text: "G4 real room send",
                media: [], mentions: [], entities: [], replyTo: nil)))
            let first = try await callUntilAvailable(ref, request: request, seconds: 35)
            guard case .messaging(.send(.accepted(let accepted))) = first,
                  accepted.clientMessageID == clientID else {
                throw ProbeError.unexpectedResponse("first send was not accepted")
            }
            let firstToken = try await application.directory.resolve(roomID,
                deadline: .now + .seconds(10))
            try marker("old-token.json", data: JSONEncoder().encode(firstToken))
            let log = V2RoomRequest.roomLog(.pull(try .init(roomID: roomID,
                actorUserID: senderID, afterRoomSequence: 0, pageSize: 20)))
            let logResponse = try await callUntilAvailable(ref, request: log, seconds: 15)
            guard case .roomLog(.page(let page)) = logResponse,
                  page.events.contains(where: { $0.roomSequence == accepted.roomSequence }) else {
                throw ProbeError.unexpectedResponse("room log did not return accepted send")
            }
            let subscribe = V2RoomRequest.roomLog(.subscribe(.init(
                roomID: roomID, actorUserID: senderID)))
            let before = try await callUntilAvailable(ref, request: subscribe, seconds: 15)
            guard case .roomLog(.subscription(let firstSubscription)) = before,
                  firstSubscription.membershipRevision == 1,
                  firstSubscription.highWatermark >= accepted.roomSequence else {
                throw ProbeError.unexpectedResponse("pre-restart subscription eligibility")
            }
            try marker("client-stage1")
            print("G4_SEND_AND_LOG_OK epoch=\(firstToken.activationEpoch.rawValue)")

            try await waitFor("continue-after-restart", seconds: 90)
            let replay = try await callUntilAvailable(ref, request: request, seconds: 45)
            guard case .messaging(.send(.idempotent(let recovered))) = replay,
                  recovered.messageID == accepted.messageID else {
                throw ProbeError.unexpectedResponse("same client ID did not recover original message")
            }
            let replacement = try await application.directory.resolve(roomID,
                deadline: .now + .seconds(10))
            guard replacement.activationEpoch.rawValue > firstToken.activationEpoch.rawValue,
                  replacement.host.incarnationID != firstToken.host.incarnationID else {
                throw ProbeError.unexpectedResponse("activation epoch/incarnation did not advance")
            }
            let after = try await callUntilAvailable(ref, request: subscribe, seconds: 15)
            guard case .roomLog(.subscription(let secondSubscription)) = after,
                  secondSubscription.membershipRevision == firstSubscription.membershipRevision,
                  secondSubscription.highWatermark == firstSubscription.highWatermark else {
                throw ProbeError.unexpectedResponse("logical room subscription changed after restart")
            }
            guard try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.messages")
                .first(decoding: CountRow.self)?.value == 1 else {
                throw ProbeError.unexpectedResponse("replay inserted another message")
            }
            let staleCommand = try V2SendMessageCommand(roomID: roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
                text: "must be fenced", media: [], limits: .init(maxUTF8Bytes: 64))
            let staleStore = PostgresV2RoomWriteStore(database: database,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                contentReviewMode: .disabled).usingActivationScope(
                try .init(tokens: [firstToken]))
            do {
                _ = try await staleStore.accept(command: staleCommand,
                    capacityProfile: try .init(id: "standard", limits: .init(
                        maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 3)),
                    identifiers: V2AcceptanceIDFactory().make(at: Date()), now: Date())
                throw ProbeError.staleBusinessFenceAccepted
            } catch V2RoomActivationLeaseError.activationChanged {
                // The business write's in-transaction SQL fence rejected it.
            }
            guard let finalCount = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.messages")
                .first(decoding: CountRow.self)?.value, finalCount == 1 else {
                throw ProbeError.unexpectedResponse("stale token changed message count")
            }
            try marker("result.json", data: JSONEncoder().encode(ProbeResult(
                roomID: roomID.rawValue, clientMessageID: clientID.rawValue,
                messageID: accepted.messageID.rawValue,
                firstActivationEpoch: firstToken.activationEpoch.rawValue,
                replacementActivationEpoch: replacement.activationEpoch.rawValue,
                firstHostIncarnation: firstToken.host.incarnationID,
                replacementHostIncarnation: replacement.host.incarnationID,
                subscriptionMembershipRevision: secondSubscription.membershipRevision,
                subscriptionHighWatermark: secondSubscription.highWatermark,
                messageRows: finalCount, staleBusinessWriteRejected: true)))
            try marker("client-done")
            print("G4_REPLAY_AND_SQL_FENCE_OK epoch=\(replacement.activationEpoch.rawValue)")
            guard try await application.stop(deadline: .now + .seconds(60)) else {
                throw ProbeError.incompleteShutdown
            }
            try await resources.shutdown()
        } catch {
            _ = try? await application.stop(deadline: .now + .seconds(10))
            try? await resources.shutdown()
            throw error
        }
    }

    private static func callUntilAvailable(_ ref: V2RoomRef, request: V2RoomRequest,
                                           seconds: Int) async throws -> V2RoomResponse {
        let deadline = ContinuousClock.now + .seconds(seconds)
        var lastError: any Error = V2RoomCallFailure.notAccepted(.unavailable)
        while ContinuousClock.now < deadline {
            do {
                return try await ref.call(request, principal: .user(senderID),
                                          deadline: min(deadline, .now + .seconds(12)))
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError
    }
}
