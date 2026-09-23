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

private struct MultiRaceResult: Encodable {
    let slot: String
    let token: V2RoomActivationToken
    let messageID: String
    let outcome: String
}

private struct MultiRecoveryResult: Encodable {
    let token: V2RoomActivationToken
    let messageID: String
    let messageRows: Int64
}

private struct MultiStaleResult: Encodable {
    let renewRejected: Bool
    let releaseRejected: Bool
    let businessWriteRejected: Bool
    let messageRows: Int64
}

private struct MultiLeaseRaceResult: Encodable {
    let slot: String
    let outcome: String
    let token: V2RoomActivationToken
}

private struct MultiPartitionOwnerResult: Encodable {
    let databaseReachable: Bool
    let originalTokenRenewed: Bool
    let activationEpoch: Int64
}

private struct MultiPartitionClientResult: Encodable {
    let healthyRoomToken: V2RoomActivationToken
    let healthyMessageID: String
    let isolatedRoomRejected: Bool
}

private struct MultiPartitionRejoinResult: Encodable {
    let token: V2RoomActivationToken
    let messageID: String
    let primaryMessageRows: Int64
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
    private static let leaseRaceRoomID = RoomID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
    private static let healthyRoomID = RoomID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!)
    private static let healthyClientID = ClientMessageID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!)

    static func main() async {
        do {
            guard let mode = CommandLine.arguments.dropFirst().first else {
                throw ProbeError.missingEnvironment("host|client mode")
            }
            switch mode {
            case "host": try await host()
            case "client": try await client()
            case "multi-host": try await multiHost()
            case "multi-race": try await multiRace()
            case "multi-replay": try await multiReplay()
            case "multi-partition-client": try await multiPartitionClient()
            case "multi-partition-rejoin": try await multiPartitionRejoin()
            default: throw ProbeError.missingEnvironment("host|client mode")
            }
        } catch {
            FileHandle.standardError.write(Data("G4_PROBE_FAILURE \(error)\n".utf8))
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

    private static func multiEvidence(_ name: String) throws -> URL {
        URL(fileURLWithPath: try required("VA_G6_EVIDENCE_DIR"), isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func multiMarker(_ name: String, data: Data = Data("ready".utf8)) throws {
        try data.write(to: multiEvidence(name), options: .atomic)
    }

    private static func multiWaitFor(_ name: String, seconds: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        let path = try multiEvidence(name).path
        while !FileManager.default.fileExists(atPath: path) {
            guard ContinuousClock.now < deadline else { throw ProbeError.markerTimeout(name) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func multiDatabaseResources() throws -> (V2DatabaseResources, any Database,
                                                              any SQLDatabase) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let resources = V2DatabaseResources(eventLoopGroup: group,
                                            logger: Logger(label: "imv2.va.g6.database"),
                                            ownsEventLoopGroup: true)
        resources.databases.use(try .postgres(url: required("VA_G6_DATABASE_URL"),
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
            try marker("client-started")
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

    private static func multiHost() async throws {
        let slot = try required("VA_G6_SLOT")
        guard slot == "a" || slot == "b" else {
            throw ProbeError.unexpectedResponse("invalid host slot")
        }
        let (resources, database, sql) = try multiDatabaseResources()
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
        let hostConfiguration = try configuration(hostsRooms: true)
        let application = try await V2RoomActorApplication.start(
            configuration: hostConfiguration,
            ownerRouter: V2PostgresRoomShardRouter(database: database),
            roomDatabases: ["room-a": database], factory: factory)
        guard await application.readiness() else {
            throw ProbeError.unexpectedResponse("multi-host \(slot) not ready")
        }
        try multiMarker("host-\(slot)-ready")
        print("G6_HOST_READY slot=\(slot)")
        try await multiWaitFor("lease-race-start", seconds: 80)
        guard let identity = hostConfiguration.hostIdentity else {
            throw ProbeError.unexpectedResponse("host identity missing")
        }
        let leaseStore = PostgresV2RoomActivationStore(database: database,
            timeouts: try .init(lockMilliseconds: 8_000,
                                statementMilliseconds: 10_000,
                                idleTransactionMilliseconds: 10_000))
        let acquisition = try await leaseStore.acquire(roomID: leaseRaceRoomID,
            owner: try .init(shardID: "room-a", epoch: 0), host: identity,
            duration: try .init(30_000))
        let raceResult: MultiLeaseRaceResult
        switch acquisition {
        case .acquired(let lease):
            raceResult = .init(slot: slot, outcome: "acquired", token: lease.token)
        case .occupied(let lease):
            raceResult = .init(slot: slot, outcome: "occupied", token: lease.token)
        }
        try multiMarker("host-\(slot)-lease-race.json", data: JSONEncoder().encode(raceResult))
        print("G6_LEASE_RACE slot=\(slot) outcome=\(raceResult.outcome)")
        // The harness SIGSTOPs the owner without closing its DB or transport.
        // After resumption, this very same process exercises all three stale
        // paths using the token it originally owned.
        let checkPath = try multiEvidence("host-\(slot)-check-stale").path
        let partitionPath = try multiEvidence("host-\(slot)-check-partition").path
        var partitionChecked = false
        while !FileManager.default.fileExists(atPath: checkPath) {
            if !partitionChecked && FileManager.default.fileExists(atPath: partitionPath) {
                let original = try JSONDecoder().decode(V2RoomActivationToken.self,
                    from: Data(contentsOf: multiEvidence("partition-token.json")))
                guard original.host == hostConfiguration.hostIdentity else {
                    throw ProbeError.unexpectedResponse("partition token belongs to another Host")
                }
                guard try await sql.raw("SELECT 1 AS value")
                    .first(decoding: CountRow.self)?.value == 1 else {
                    throw ProbeError.unexpectedResponse("partitioned owner cannot access PG")
                }
                let renewed = try await PostgresV2RoomActivationStore(database: database)
                    .renew(token: original, duration: try .init(30_000))
                try multiMarker("host-\(slot)-partition.json", data: JSONEncoder().encode(
                    MultiPartitionOwnerResult(databaseReachable: true,
                        originalTokenRenewed: renewed.token == original,
                        activationEpoch: renewed.token.activationEpoch.rawValue)))
                partitionChecked = true
            }
            try await Task.sleep(for: .milliseconds(100))
            withExtendedLifetime(resources) {}
        }
        let oldToken = try JSONDecoder().decode(V2RoomActivationToken.self,
            from: Data(contentsOf: multiEvidence("old-token.json")))
        let lease = PostgresV2RoomActivationStore(database: database)
        var renewRejected = false
        do {
            _ = try await lease.renew(token: oldToken, duration: try .init(30_000))
        } catch V2RoomActivationLeaseError.activationChanged {
            renewRejected = true
        }
        let releaseRejected = try await !lease.release(token: oldToken)
        let staleCommand = try V2SendMessageCommand(roomID: roomID,
            senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
            text: "stale owner must fail", media: [], limits: .init(maxUTF8Bytes: 64))
        let staleStore = writes.usingActivationScope(try .init(tokens: [oldToken]))
        var businessWriteRejected = false
        do {
            _ = try await staleStore.accept(command: staleCommand,
                capacityProfile: capacity,
                identifiers: V2AcceptanceIDFactory().make(at: Date()), now: Date())
        } catch V2RoomActivationLeaseError.activationChanged {
            businessWriteRejected = true
        }
        guard renewRejected && releaseRejected && businessWriteRejected,
              let rows = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.messages WHERE room_id = \(bind: roomID.uuidValue!)")
                .first(decoding: CountRow.self)?.value, rows == 1 else {
            throw ProbeError.unexpectedResponse("stale host changed lease or business state")
        }
        try multiMarker("host-\(slot)-stale.json", data: JSONEncoder().encode(MultiStaleResult(
            renewRejected: renewRejected, releaseRejected: releaseRejected,
            businessWriteRejected: businessWriteRejected, messageRows: rows)))
        print("G6_STALE_REJECTED slot=\(slot)")
        while true {
            try await Task.sleep(for: .seconds(1))
            withExtendedLifetime(resources) {}
        }
    }

    private static func multiRace() async throws {
        let slot = try required("VA_G6_SLOT")
        guard slot == "a" || slot == "b" else {
            throw ProbeError.unexpectedResponse("invalid race slot")
        }
        let (resources, database, _) = try multiDatabaseResources()
        let application = try await V2RoomActorApplication.start(
            configuration: configuration(hostsRooms: false),
            ownerRouter: V2PostgresRoomShardRouter(database: database),
            roomDatabases: ["room-a": database])
        do {
            let ref = application.directory.room(roomID)
            let request = multiSendRequest()
            try multiMarker("race-\(slot)-ready")
            try await multiWaitFor("race-start", seconds: 60)
            let response = try await callUntilAvailable(ref, request: request, seconds: 55)
            let messageID: String
            let outcome: String
            switch response {
            case .messaging(.send(.accepted(let accepted))):
                messageID = accepted.messageID.rawValue; outcome = "accepted"
            case .messaging(.send(.idempotent(let replay))):
                messageID = replay.messageID.rawValue; outcome = "idempotent"
            default:
                throw ProbeError.unexpectedResponse("multi-race send result")
            }
            let token = try await application.directory.resolve(roomID,
                deadline: .now + .seconds(10))
            try multiMarker("race-\(slot)-result.json", data: JSONEncoder().encode(
                MultiRaceResult(slot: slot, token: token, messageID: messageID, outcome: outcome)))
            print("G6_RACE_OK slot=\(slot) outcome=\(outcome) epoch=\(token.activationEpoch.rawValue)")
            guard try await application.stop(deadline: .now + .seconds(30)) else {
                throw ProbeError.incompleteShutdown
            }
            try await resources.shutdown()
        } catch {
            _ = try? await application.stop(deadline: .now + .seconds(10))
            try? await resources.shutdown()
            throw error
        }
    }

    private static func multiReplay() async throws {
        let (resources, database, sql) = try multiDatabaseResources()
        let application = try await V2RoomActorApplication.start(
            configuration: configuration(hostsRooms: false),
            ownerRouter: V2PostgresRoomShardRouter(database: database),
            roomDatabases: ["room-a": database])
        do {
            let ref = application.directory.room(roomID)
            let response = try await callUntilAvailable(ref, request: multiSendRequest(), seconds: 55)
            guard case .messaging(.send(.idempotent(let recovered))) = response else {
                throw ProbeError.unexpectedResponse("takeover replay was not idempotent")
            }
            let token = try await application.directory.resolve(roomID,
                deadline: .now + .seconds(10))
            guard let rows = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.messages WHERE room_id = \(bind: roomID.uuidValue!)")
                .first(decoding: CountRow.self)?.value, rows == 1 else {
                throw ProbeError.unexpectedResponse("takeover replay inserted duplicate")
            }
            try multiMarker("replay-result.json", data: JSONEncoder().encode(
                MultiRecoveryResult(token: token, messageID: recovered.messageID.rawValue,
                                    messageRows: rows)))
            print("G6_REPLAY_OK epoch=\(token.activationEpoch.rawValue)")
            guard try await application.stop(deadline: .now + .seconds(30)) else {
                throw ProbeError.incompleteShutdown
            }
            try await resources.shutdown()
        } catch {
            _ = try? await application.stop(deadline: .now + .seconds(10))
            try? await resources.shutdown()
            throw error
        }
    }

    private static func multiSendRequest() -> V2RoomRequest {
        .messaging(.send(.init(roomID: roomID, actorUserID: senderID,
            clientMessageID: clientID, text: "G6 multi-host send",
            media: [], mentions: [], entities: [], replyTo: nil)))
    }

    private static func multiPartitionClient() async throws {
        let (resources, database, _) = try multiDatabaseResources()
        let application = try await V2RoomActorApplication.start(
            configuration: configuration(hostsRooms: false),
            ownerRouter: V2PostgresRoomShardRouter(database: database),
            roomDatabases: ["room-a": database])
        do {
            let healthyRequest = V2RoomRequest.messaging(.send(.init(
                roomID: healthyRoomID, actorUserID: senderID,
                clientMessageID: healthyClientID, text: "G6 healthy peer room",
                media: [], mentions: [], entities: [], replyTo: nil)))
            let response = try await callUntilAvailable(
                application.directory.room(healthyRoomID), request: healthyRequest, seconds: 30)
            guard case .messaging(.send(.accepted(let accepted))) = response else {
                throw ProbeError.unexpectedResponse("survivor did not serve healthy room")
            }
            let healthyToken = try await application.directory.resolve(healthyRoomID,
                deadline: .now + .seconds(10))
            // A fresh client has no cached route. The live DB lease still
            // points at the isolated owner; absence of peer transport must
            // never make the survivor a second writer for this room.
            var isolatedRoomRejected = false
            do {
                _ = try await application.directory.room(roomID).call(
                    multiSendRequest(), principal: .user(senderID),
                    deadline: .now + .seconds(10))
            } catch {
                isolatedRoomRejected = true
            }
            guard isolatedRoomRejected else {
                throw ProbeError.unexpectedResponse("isolated owner's room unexpectedly reachable")
            }
            try multiMarker("partition-client-result.json", data: JSONEncoder().encode(
                MultiPartitionClientResult(healthyRoomToken: healthyToken,
                    healthyMessageID: accepted.messageID.rawValue,
                    isolatedRoomRejected: isolatedRoomRejected)))
            guard try await application.stop(deadline: .now + .seconds(30)) else {
                throw ProbeError.incompleteShutdown
            }
            try await resources.shutdown()
        } catch {
            _ = try? await application.stop(deadline: .now + .seconds(10))
            try? await resources.shutdown()
            throw error
        }
    }

    private static func multiPartitionRejoin() async throws {
        let (resources, database, sql) = try multiDatabaseResources()
        let application = try await V2RoomActorApplication.start(
            configuration: configuration(hostsRooms: false),
            ownerRouter: V2PostgresRoomShardRouter(database: database),
            roomDatabases: ["room-a": database])
        do {
            let response = try await callUntilAvailable(
                application.directory.room(roomID), request: multiSendRequest(), seconds: 45)
            guard case .messaging(.send(.idempotent(let replay))) = response else {
                throw ProbeError.unexpectedResponse("network rejoin lost idempotent result")
            }
            let token = try await application.directory.resolve(roomID,
                deadline: .now + .seconds(10))
            guard let rows = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.messages WHERE room_id = \(bind: roomID.uuidValue!)")
                .first(decoding: CountRow.self)?.value, rows == 1 else {
                throw ProbeError.unexpectedResponse("network rejoin duplicated business result")
            }
            try multiMarker("partition-rejoin-result.json", data: JSONEncoder().encode(
                MultiPartitionRejoinResult(token: token,
                    messageID: replay.messageID.rawValue, primaryMessageRows: rows)))
            guard try await application.stop(deadline: .now + .seconds(30)) else {
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
