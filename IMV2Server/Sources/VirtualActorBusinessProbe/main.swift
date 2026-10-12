import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import IMV2ActorApplication
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import IMV2Server
import IMV2ServerInfrastructure
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

/// Fault injection belongs only to this executable. The production observer
/// remains nonblocking; here _exit deliberately removes the entire Host after
/// SQL commit and before the send result can leave its process.
private struct CrashAfterCommit: V2CommittedMessageBatchObserving {
    let directory: URL
    func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome], activation: V2RoomActivationToken) {
        guard !outcomes.isEmpty else { return }
        do {
            try JSONEncoder().encode(activation).write(to: directory.appendingPathComponent("crash-committed-token.json"), options: .atomic)
        } catch { _exit(138) }
        _exit(137)
    }
}

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
    let staleActivationRejected: Bool
    let wrongDataOwnerRejected: Bool
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

private struct NoopProjectionShadow: V2UserShardProjectionDelivering {
    func deliverToCurrentShard(userID: UserID, sourceEventID: EventID,
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
            case "realtime-receiver": try await RealtimeCallbackProbe.run(receiver: true)
            case "realtime-sender": try await RealtimeCallbackProbe.run(receiver: false)
            case "host": try await host()
            case "client": try await client()
            case "host-crash-after-commit": try await host(crashAfterCommit: true)
            case "client-crash-replay": try await crashReplayClient()
            case "database-edge-host": try await DatabaseEdgeProbe.run(host: true)
            case "database-edge-client": try await DatabaseEdgeProbe.run(host: false)
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

    private static func databaseResources(host: V2ActorHostIdentity? = nil) throws -> (V2DatabaseResources, any Database,
                                                        any SQLDatabase) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let resources = V2DatabaseResources(eventLoopGroup: group,
                                            logger: Logger(label: "imv2.va.g4.database"),
                                            ownsEventLoopGroup: true)
        var postgres = try SQLPostgresConfiguration(url: required("VA_G4_DATABASE_URL"))
        if let host {
            postgres.coreConfiguration.options.additionalStartupParameters.removeAll { $0.0 == "application_name" }
            postgres.coreConfiguration.options.additionalStartupParameters.append(("application_name", V2ActorPostgresSessionIdentity.applicationName(host)))
        }
        resources.databases.use(.postgres(configuration: postgres,
                                               maxConnectionsPerEventLoop: 4),
                                as: .psql, isDefault: true)
        if host != nil {
            resources.databases.use(.postgres(configuration: postgres, maxConnectionsPerEventLoop: 1),
                as: .init(string: "message-write"), isDefault: false)
        }
        let database = try V2EventLoopBalancedDatabase(databases: [resources.database(.psql)],
            loanPolicy: .init(maximumConnections: 4, reservedRenewalConnections: 1,
                              maximumQueued: 32, maximumWait: .seconds(5)))
        guard let sql = database as? any SQLDatabase else {
            throw ProbeError.unexpectedResponse("PostgreSQL driver has no SQLDatabase")
        }
        return (resources, database, sql)
    }

    private static func configuration(hostsRooms: Bool) throws -> V2RoomActorApplicationConfiguration {
        try .init(environment: ProcessEnvironment(), hostsRooms: hostsRooms,
                  configuredShardIDs: ["room-a"])
    }

    private static func invitationSecretIssuer() throws -> V2GroupInviteSecretIssuer {
        try .init(rawKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    }

    private static func host(crashAfterCommit: Bool = false) async throws {
        let actorConfiguration = try configuration(hostsRooms: true)
        try await actorConfiguration.awaitSupervisedStartup()
        let (resources, database, sql) = try databaseResources(host: actorConfiguration.hostIdentity)
        V2ProcessTerminationSignal.install()
        var startedApplication: V2RoomActorApplication?
        var startedOwner: V2RoomServerOwnerResources?
        do {
        guard try await sql.raw("SELECT 1 AS value").first(decoding: CountRow.self)?.value == 1 else {
            throw ProbeError.unexpectedResponse("PostgreSQL unavailable")
        }
        let policyOwners = PostgresV2PolicyOwnerDirectory(journal: .init(database: database),
            dispatcher: .init(database: database, projectionDelivery: NoopProjectionShadow()))
        let policyAuthorizations = V2RoomPolicyAuthorizationService(roomDatabase: database,
            policyOwners: policyOwners, endpoint: "room-a", maximumRooms: 1)
        let writes = PostgresV2RoomWriteStore(database: database,
            strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
            contentReviewMode: .disabled).usingPolicyAuthorizations(policyAuthorizations)
        let capacity = try V2CapacityProfile(id: "standard", limits: .init(
            maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 3))
        let sendDatabase = try V2EventLoopBalancedDatabase(
            databases: [resources.database(.init(string: "message-write"))],
            loanPolicy: .init(maximumConnections: 1, reservedRenewalConnections: 0,
                maximumQueued: 32, maximumWait: .seconds(5)))
        let owner = try V2RoomServerOwnerResources(database: database, sendDatabase: sendDatabase, writes: writes,
            membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
            invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
            invitationSecretIssuer: try invitationSecretIssuer(),
            receiptProjectionDelivery: NoopProjectionShadow(), capacityProfile: capacity,
            messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
            contentReviewMode: .disabled, queryBatchConfiguration: .init(),
            committedMessageObserver: crashAfterCommit ? CrashAfterCommit(directory: try evidence(".").standardizedFileURL) : nil)
            .usingPolicyAuthorizations(policyAuthorizations)
        startedOwner = owner
        let factory = try V2RoomServerActivationFactory(owners: ["room-a": owner],
                                                        safetyActorUserID: senderID)
        let application = try await V2RoomActorApplication.start(
            configuration: actorConfiguration,
            ownerRouter: V2PostgresRoomShardRouter(database: database),
            roomDatabases: ["room-a": database], factory: factory, qualification: .standalone())
        startedApplication = application
        guard await application.readiness() else {
            throw ProbeError.unexpectedResponse("host not ready")
        }
        let prefix = ProcessInfo.processInfo.environment["VA_G4_HOST_MARKER_PREFIX"] ?? "host"
        try marker(prefix + "-ready")
        print("G4_HOST_READY")
        // Planned replacement requires the real physical drain and durable
        // retirement. Process death or elapsed time cannot grant a successor.
        await V2ProcessTerminationSignal.wait()
        guard try await application.stop(deadline: .now + .seconds(30)) else {
            throw V2RoomActorApplicationError.incompleteShutdown
        }
        startedApplication = nil
        await owner.shutdownDurableSendOperations()
        try await resources.shutdown()
        try marker(prefix + "-stopped")
        print("G4_NATIVE_HOST_RETIRED")
        } catch {
            if let startedApplication {
                guard (try? await startedApplication.stop(deadline: .now + .seconds(30))) == true else {
                    // Do not dispose databases under still-owned physical jobs.
                    throw V2RoomActorApplicationError.incompleteShutdown
                }
            }
            await startedOwner?.shutdownDurableSendOperations()
            try? await resources.shutdown()
            throw error
        }
    }

    /// Keep the same caller/Directory alive through an unknown send outcome.
    /// The harness resumes the supervisor only after the first call ends, so
    /// a quickly recovered ACK cannot make this an ordinary successful send.
    private static func crashReplayClient() async throws {
        let (resources, database, sql) = try databaseResources()
        let application = try await V2RoomActorApplication.start(configuration: configuration(hostsRooms: false),
            ownerRouter: V2PostgresRoomShardRouter(database: database), roomDatabases: ["room-a": database])
        do {
            let ref = application.directory.room(roomID)
            _ = try await callUntilAvailable(ref, request: .roomLog(.subscribe(.init(roomID: roomID, actorUserID: senderID))), seconds: 30)
            let original = try await application.directory.resolve(roomID, deadline: .now + .seconds(10))
            try marker("crash-client-ready", data: JSONEncoder().encode(original))
            try await waitFor("crash-send", seconds: 90)
            let request = try V2RoomRequest.messaging(.sendOperation(.init(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: clientID, text: "crash after commit",
                media: [], limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: frozenSendDeadline())))
            var unknown = false
            do { _ = try await ref.call(request, principal: .user(senderID), deadline: .now + .seconds(5)) }
            catch { unknown = true }
            guard unknown else { throw ProbeError.unexpectedResponse("send received an ACK before recovery") }
            struct MessageRow: Decodable { let id: UUID }
            guard let durable = try await sql.raw("SELECT message_id AS id FROM im_v2.messages WHERE room_id = \(bind: roomID.uuidValue!) AND client_message_id = \(bind: clientID.uuidValue!)")
                .first(decoding: MessageRow.self),
                try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.messages").first(decoding: CountRow.self)?.value == 1 else {
                throw ProbeError.unexpectedResponse("unknown result has no committed message")
            }
            try marker("crash-unknown")
            try await waitFor("crash-recover", seconds: 90)
            let replay = try await ref.call(request, principal: .user(senderID), deadline: .now + .seconds(45))
            guard case .messaging(.sendOperation(.receipt(let proof))) = replay,
                  case .accepted(let accepted) = proof.outcome, accepted.messageID.uuidValue == durable.id else {
                throw ProbeError.unexpectedResponse("replay did not recover committed message")
            }
            let replacement = try await application.directory.resolve(roomID, deadline: .now + .seconds(10))
            guard replacement.host != original.host, replacement.activationEpoch.rawValue > original.activationEpoch.rawValue,
                  try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.messages").first(decoding: CountRow.self)?.value == 1 else {
                throw ProbeError.unexpectedResponse("recovery did not replace the owner exactly once")
            }
            struct Result: Encodable {
                let original: V2RoomActivationToken; let replacement: V2RoomActivationToken
                let messageID: UUID; let messageRows: Int; let originalResultUnknown: Bool
            }
            try marker("crash-result.json", data: JSONEncoder().encode(Result(original: original, replacement: replacement,
                messageID: durable.id, messageRows: 1, originalResultUnknown: true)))
            guard try await application.stop(deadline: .now + .seconds(30)) else { throw ProbeError.incompleteShutdown }
            try await resources.shutdown()
        } catch {
            let failure = error
            guard (try? await application.stop(deadline: .now + .seconds(30))) == true else { throw ProbeError.incompleteShutdown }
            try? await resources.shutdown(); throw failure
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
            let request = try V2RoomRequest.messaging(.sendOperation(try .init(command: try .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: clientID, text: "G4 real room send",
                media: [], mentions: [], entities: [], replyTo: nil, limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: frozenSendDeadline())))
            try marker("client-started")
            let first = try await callUntilAvailable(ref, request: request, seconds: 35)
            guard case .messaging(.sendOperation(.receipt(let acceptedProof))) = first, case .accepted(let accepted) = acceptedProof.outcome,
                  acceptedProof.identity.operation == .sendMessage(clientID) else {
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
            // The Directory owns recovery after host replacement. One logical
            // call must recover the original receipt without an outer retry loop.
            let replayStarted = ContinuousClock.now
            let replay: V2RoomResponse
            do {
                replay = try await ref.call(request, principal: .user(senderID),
                    deadline: .now + .seconds(45))
            } catch {
                let metrics = await application.roomRuntimeMetricsSnapshot()
                FileHandle.standardError.write(Data(
                    "G4_REPLAY_FAILURE elapsed=\(ContinuousClock.now - replayStarted) directory=\(metrics.directoryCalls) transport=\(metrics.transportCalls)\n".utf8))
                throw error
            }
            guard case .messaging(.sendOperation(.receipt(let recoveredProof))) = replay, case .accepted(let recovered) = recoveredProof.outcome,
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
            let staleRequest = try V2RoomRequest.messaging(.sendOperation(.init(command: staleCommand,
                firstSubmissionDeadlineMilliseconds: frozenSendDeadline())))
            try await rejectOldActivation(firstToken, replacement: replacement, request: staleRequest)
            // Physical incarnation is fenced by the native Actor, not SQL.
            // SQL retains its separate data-owner epoch boundary.
            let wrongOwnerToken = V2RoomActivationToken(roomID: roomID,
                owner: try .init(shardID: firstToken.owner.shardID, epoch: firstToken.owner.epoch + 1),
                activationEpoch: firstToken.activationEpoch, host: firstToken.host)
            let readReceipts = PostgresV2ReadReceiptStore(database: database,
                projectionDelivery: NoopProjectionShadow())
            let wrongOwnerReceipt = try V2RecordReadReceiptCommand(roomID: roomID,
                actorUserID: senderID, operationID: .init(uuid: UUID()),
                readThroughRoomSequence: accepted.roomSequence)
            do {
                _ = try await readReceipts.recordActivationValidated(command: wrongOwnerReceipt,
                    token: wrongOwnerToken, now: Date())
                throw ProbeError.staleBusinessFenceAccepted
            } catch V2ReadReceiptStoreError.ownerChanged {
                // SQL rejects the wrong data owner independently of Host placement.
            }
            guard try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.read_receipt_operations")
                .first(decoding: CountRow.self)?.value == 0 else {
                throw ProbeError.unexpectedResponse("wrong data owner persisted a read receipt")
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
                messageRows: finalCount, staleActivationRejected: true, wrongDataOwnerRejected: true)))
            try marker("client-done")
            print("G4_NATIVE_REPLAY_AND_OWNER_FENCE_OK epoch=\(replacement.activationEpoch.rawValue)")
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

    private static func rejectOldActivation(_ token: V2RoomActivationToken,
        replacement: V2RoomActivationToken, request: V2RoomRequest) async throws {
        let config = try configuration(hostsRooms: false)
        guard let port = Int(try required("VA_G4_STALE_CALLER_PORT")) else {
            throw ProbeError.missingEnvironment("VA_G4_STALE_CALLER_PORT")
        }
        let node = V2RoomClusterClientNode(configuration: try .init(name: config.name + "-stale-probe",
            host: config.address, port: port, tls: config.tls, threadPoolSize: 1),
            signer: config.signer, trust: config.trust, authenticationLimits: config.authentication,
            runtimeConfiguration: config.runtime)
        do {
            let transport = try await node.start(discovery: config.discovery)
            let deadline = ContinuousClock.now + .seconds(15)
            while true {
                let candidates = try await transport.candidates(for: replacement.owner)
                if candidates.contains(where: { $0.identity == replacement.host && $0.isHealthy }) { break }
                guard ContinuousClock.now < deadline else { throw ProbeError.markerTimeout("replacement discovery") }
                try await Task.sleep(for: .milliseconds(50))
            }
            do {
                _ = try await transport.invoke(token, request: request, principal: .user(senderID),
                    deadline: .now + .seconds(5))
                throw ProbeError.staleBusinessFenceAccepted
            } catch V2RoomCallFailure.notAccepted(let reason) {
                guard reason == .staleActivation || reason == .notReady || reason == .unavailable else {
                    throw V2RoomCallFailure.notAccepted(reason)
                }
            }
        } catch {
            let failure = error
            guard try await node.stop(deadline: .now + .seconds(30)) else {
                throw V2RoomActorApplicationError.incompleteShutdown
            }
            throw failure
        }
        guard try await node.stop(deadline: .now + .seconds(30)) else {
            throw V2RoomActorApplicationError.incompleteShutdown
        }
    }

    private static func frozenSendDeadline() throws -> UInt64 {
        let directory = try required("VA_G4_EVIDENCE_DIR")
        let path = URL(fileURLWithPath: directory).appendingPathComponent("send-admission-deadline-ms")
        if !FileManager.default.fileExists(atPath: path.path) {
            let temporary = path.appendingPathExtension(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let value = UInt64(Date().timeIntervalSince1970 * 1_000) + 600_000
            try Data(String(value).utf8).write(to: temporary, options: .atomic)
            // Publish a complete frozen value once across concurrent probe processes.
            guard link(temporary.path, path.path) == 0 || errno == EEXIST else {
                throw ProbeError.unexpectedResponse("cannot persist send admission")
            }
        }
        guard let value = UInt64(try String(contentsOf: path, encoding: .utf8)), value > 0 else {
            throw ProbeError.unexpectedResponse("invalid persisted send admission")
        }
        return value
    }

    private static func callUntilAvailable(_ ref: V2RoomRef, request: V2RoomRequest,
                                           seconds: Int) async throws -> V2RoomResponse {
        let deadline = ContinuousClock.now + .seconds(seconds)
        var lastError: any Error = V2RoomCallFailure.notAccepted(.unavailable)
        while ContinuousClock.now < deadline {
            do {
                let response = try await ref.call(request, principal: .user(senderID),
                                          deadline: min(deadline, .now + .seconds(12)))
                if case .messaging(.sendOperation(let command)) = request {
                    guard case .messaging(.sendOperation(.receipt(let proof))) = response,
                          proof.identity == (try command.identity),
                          proof.fingerprint == (try command.fingerprint) else {
                        throw ProbeError.unexpectedResponse("missing bound original send proof")
                    }
                }
                return response
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError
    }
}
