import Foundation
import GRDB
import Synchronization
import Testing
import IMV2Core
@testable import IMV2ClientKit
@testable import IMApp

@Suite("Real App decoded room notification loss", .enabled(if: ProcessInfo.processInfo.environment["IMV2_LOCAL_ACCOUNT_E2E"] == "1" && ProcessInfo.processInfo.environment["IMV2_APP_ROOM_PROGRESS_E2E"] == "1"))
@MainActor
struct V2RoomProgressNotificationLossIntegrationTests {
    @Test
    func decodedRoomNotificationLossRecoversThroughHeartbeat() async throws {
        try await unopenedRoomReconnect()
        let nonce = try #require(ProcessInfo.processInfo.environment["IMV2_APP_ROOM_PROGRESS_NONCE"])
        _ = try #require(UUID(uuidString: nonce))
        let sender = try await registerLocalAccount(displayName: "Progress sender")
        let receiver = try await registerLocalAccount(displayName: "Progress receiver")
        let room = try await localOpenDirectRoom(account: sender, target: receiver.userID).roomID
        let configuration = try V2AppConfiguration()
        let limits = try V2FrameLimits(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        let senderWire = V2TLSFrameConnection(endpoint: configuration.realtimeEndpoint, frameLimits: limits)
        let baselineWire = V2TLSFrameConnection(endpoint: configuration.realtimeEndpoint, frameLimits: limits)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("room-progress-\(UUID())")
        let database = root.appendingPathComponent("receiver.sqlite")
        let binding = LocalE2EInstallationBindingStore()
        let store = try await V2LocalStoreBootstrapper(bindingStore: binding).open(databaseURL: database, userID: receiver.userID)
        let witness = RoomProgressLossWitness(room: room)
        let auth = V2AuthSession(credentialStore: ProgressCredentials(receiver.credentials), transport: ProgressNoRefresh(), revocationScheduler: ProgressNoRevocation())
        let credentials = try await auth.realtimeCredentials()
        let epoch = try #require(credentials.sessionEpoch)
        let realtime = try await V2AppRealtimeRuntime(configuration: configuration, actorUserID: receiver.userID,
            deviceID: receiver.deviceID, authSession: auth, authEpoch: epoch, localStore: store,
            resourceCenter: try await makeResourceCenter(store: store, root: root, user: receiver.userID),
            testRoomNotificationInterceptor: { witness.discard(room: $0, head: $1, bodies: $2) },
            testRoomProgressObserver: { room, head in
                let cursor = try await store.groupEventCursor(roomID: room)
                witness.heartbeat(room: room, head: head, beforeCursor: cursor)
            }, testRoomRecoveryObserver: { witness.recovery($0) })
        let recovery = realtime.roomRecovery
        let dataSource = V2GRDBConversationDataSource(localStore: store, requestLatestVisible: { try await recovery.requestLatestVisible(roomIDs: $0) })
        let detail = V2ConversationDetailStore(environment: .init(userID: receiver.userID.rawValue,
            projections: .init(dataSource: dataSource), runtime: .init(projectionChangeNotifier: realtime.projectionChangeNotifier,
                activeHybridGroupSynchronizer: RoomProgressObservedSynchronizer(base: realtime.activeHybridGroupSynchronizer, store: store, witness: witness), roomSubscriptions: realtime.roomSubscriptions)),
            context: .init(roomID: room.rawValue, kind: .direct(accountKind: .regular)))
        var runtimeTask: Task<Void, Error>?
        var detailTask: Task<Void, Never>?
        do {
            _ = try await senderWire.connectAndAuthenticate(accessToken: sender.accessToken, deviceID: sender.deviceID, supportedCapabilityProfiles: ["base"])
            _ = try await baselineWire.connectAndAuthenticate(accessToken: receiver.accessToken, deviceID: receiver.deviceID, supportedCapabilityProfiles: ["base"])
            // The actual reciprocal TCP fact establishes bilateral direct-room visibility.
            _ = try await send(receiver, room: room, wire: baselineWire)
            await baselineWire.disconnect()
            let initial = try await send(sender, room: room, wire: senderWire)
            runtimeTask = Task { try await realtime.accountRuntime.runRealtime(realtime.runtime) }
            detailTask = Task { await detail.pollVisibleHybridGroupEvents() }
            try await eventually {
                guard let ready = realtime.realtimeCoverage.scopes[.room], ready.subscriptionInstalled,
                      ready.scopeID.lowercased() == room.rawValue.lowercased(), ready.isCaughtUp(appliedThrough: initial.roomSequence),
                      try await store.groupEventCursor(roomID: room) == initial.roomSequence else { return false }
                return try await store.databasePool.read { db in
                    let complete = try Bool.fetchOne(db, sql: "SELECT directory_complete FROM v2_room_recovery_scan WHERE singleton=1") == true
                    let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM v2_room_recovery_work")
                    return complete && count == 0
                }
            }
            let ready = try #require(realtime.realtimeCoverage.scopes[.room])
            witness.arm(cursor: initial.roomSequence)
            var final: V2MessageOperationAcceptance = initial
            var identities: [[String: Any]] = []
            for _ in 0..<3 {
                let command = try command(sender, room: room)
                final = try await submit(command, wire: senderWire)
                identities.append(["clientMessageID": command.command.clientMessageID.rawValue,
                    "messageID": final.messageID.rawValue, "roomSequence": final.roomSequence,
                    "operationIdentity": try command.identity.storageKey,
                    "fingerprintVersion": Int(try command.fingerprint.version),
                    "fingerprintHex": try command.fingerprint.digest.map { String(format: "%02x", $0) }.joined()])
            }
            try await eventually {
                guard witness.snapshot().higherHeartbeats > 0 else { return false }
                return try await store.groupEventCursor(roomID: room) == final.roomSequence
            }
            let proof = witness.snapshot()
            print("IMV2_APP_ACCOUNT_RECOVERY_TRACE " + String(describing: proof.recoveryEvents.sorted { $0.key < $1.key }))
            #expect(proof.discardedNotifications > 0 && proof.discardedBodies > 0)
            print("IMV2_APP_RECOVERY_TRIGGER_TRACE detailPulls=\(proof.detailPullsAfterArm) detailAdvanced=\(proof.detailAdvancedAfterArm) firstDetailBefore=\(String(describing: proof.firstDetailBefore)) firstDetailAfter=\(String(describing: proof.firstDetailAfter))")
            #expect(proof.firstHigherBeforeCursor == initial.roomSequence)
            let firstBeforeCursor = try #require(proof.firstHigherBeforeCursor)
            #expect(proof.maximumHeartbeatHead == final.roomSequence)
            let current = try #require(realtime.realtimeCoverage.scopes[.room])
            #expect(current.connectionGeneration == ready.connectionGeneration && current.scopeGeneration == ready.scopeGeneration)
            detailTask?.cancel(); _ = await detailTask?.result
            runtimeTask?.cancel(); await realtime.accountRuntime.close(); _ = await runtimeTask?.result
            await senderWire.disconnect()
            try await store.close()
            let reopened = try await V2LocalStoreBootstrapper(bindingStore: binding).open(databaseURL: database, userID: receiver.userID)
            let reopenedC = try await reopened.groupEventCursor(roomID: room)
            #expect(reopenedC == final.roomSequence)
            #expect(try await reopened.roomProgressAppliedSequence(roomID: room) == reopenedC)
            let messages = try await reopened.messages(in: room)
            #expect(messages.contains { $0.messageID == final.messageID })
            try await reopened.close()
            let result: [String: Any] = ["nonce": nonce, "accountID": receiver.userID.rawValue,
                "senderAccountID": sender.userID.rawValue, "deviceID": receiver.deviceID.rawValue,
                "roomID": room.rawValue, "connectionGeneration": ready.connectionGeneration.uuidString,
                "finalConnectionGeneration": current.connectionGeneration.uuidString, "scopeGeneration": ready.scopeGeneration,
                "finalScopeGeneration": current.scopeGeneration, "armCursor": initial.roomSequence,
                "firstHeartbeatBeforeCursor": firstBeforeCursor, "heartbeatHighWatermark": proof.maximumHeartbeatHead,
                "heartbeatRecoveries": proof.higherHeartbeats, "discardedNotifications": proof.discardedNotifications,
                "discardedBodies": proof.discardedBodies, "reopenedSQLiteCursor": reopenedC, "finalRoomSequence": final.roomSequence,
                "operations": identities, "manualPullCount": 0, "realAppRuntime": true, "realDetailRecoveryLoop": true,
                "directoryCompleteBeforeArm": true, "samePhysicalConnection": true, "unresolvedHistoryGap": false]
            print("IMV2_APP_ROOM_PROGRESS_PROOF " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            detailTask?.cancel(); _ = await detailTask?.result
            runtimeTask?.cancel(); await realtime.accountRuntime.close(); _ = await runtimeTask?.result
            await senderWire.disconnect(); await baselineWire.disconnect(); try? await store.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func unopenedRoomReconnect() async throws {
        let sender = try await registerLocalAccount(displayName: "Reconnect sender")
        let receiver = try await registerLocalAccount(displayName: "Reconnect receiver")
        let room = try await localOpenDirectRoom(account: sender, target: receiver.userID).roomID
        let configuration = try V2AppConfiguration()
        let limits = try V2FrameLimits(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        let secondaryPort = try #require(ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_SECONDARY_PORT"].flatMap(UInt16.init))
        let senderConfiguration = try V2AppConfiguration(localE2ERealtimePort: secondaryPort)
        let wire = V2TLSFrameConnection(endpoint: senderConfiguration.realtimeEndpoint, frameLimits: limits)
        let reciprocal = V2TLSFrameConnection(endpoint: configuration.realtimeEndpoint, frameLimits: limits)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unopened-reconnect-\(UUID())")
        let database = root.appendingPathComponent("receiver.sqlite")
        let binding = LocalE2EInstallationBindingStore()
        var store = try await V2LocalStoreBootstrapper(bindingStore: binding).open(databaseURL: database, userID: receiver.userID)
        let auth = V2AuthSession(credentialStore: ProgressCredentials(receiver.credentials), transport: ProgressNoRefresh(), revocationScheduler: ProgressNoRevocation())
        let credentials = try await auth.realtimeCredentials()
        let epoch = try #require(credentials.sessionEpoch)
        let activeWire = Mutex<V2TLSFrameConnection?>(nil)
        func makeRuntime(_ local: GRDBV2LocalSyncStore) async throws -> V2AppRealtimeRuntime {
            try await V2AppRealtimeRuntime(configuration: configuration, actorUserID: receiver.userID,
                deviceID: receiver.deviceID, authSession: auth, authEpoch: epoch, localStore: local,
                resourceCenter: try await makeResourceCenter(store: local, root: root, user: receiver.userID),
                testConnectionObserver: { connection in activeWire.withLock { $0 = connection } })
        }
        var runtime = try await makeRuntime(store)
        var task: Task<Void, Error>?
        do {
            _ = try await wire.connectAndAuthenticate(accessToken: sender.accessToken, deviceID: sender.deviceID, supportedCapabilityProfiles: ["base"])
            _ = try await reciprocal.connectAndAuthenticate(accessToken: receiver.accessToken, deviceID: receiver.deviceID, supportedCapabilityProfiles: ["base"])
            print("IMV2_APP_UNOPENED_STAGE authenticated")
            _ = try await send(receiver, room: room, wire: reciprocal)
            print("IMV2_APP_UNOPENED_STAGE reciprocal_committed")
            await reciprocal.disconnect()
            let initial = try await send(sender, room: room, wire: wire)
            print("IMV2_APP_UNOPENED_STAGE initial_committed")
            let first = runtime
            task = Task { try await first.accountRuntime.runRealtime(first.runtime) }
            try await eventually {
                if let failure = await runtime.runtime.lastBackgroundFailure() {
                    print("IMV2_APP_RECOVERY_FAILURE_LOOP \(String(describing: await runtime.runtime.lastBackgroundFailureLoop()))")
                    print("IMV2_APP_TIMEOUT_COMMAND \(String(describing: await runtime.lastTimedOutRealtimeCommand()))")
                    throw failure
                }
                let cursor = try await store.groupEventCursor(roomID: room)
                return runtime.realtimeCoverage.scopes[.directory]?.subscriptionInstalled == true && cursor == initial.roomSequence
            }
            #expect(runtime.realtimeCoverage.scopes[.room] == nil)
            try await onlineMembershipChanges(runtime: runtime, store: store, owner: sender,
                receiver: receiver, wire: wire)
            let generation = try #require(runtime.realtimeCoverage.scopes[.directory]?.connectionGeneration)
            task?.cancel(); await runtime.accountRuntime.close(); _ = await task?.result
            try await store.close()
            var receipts: [V2MessageOperationAcceptance] = []
            for _ in 0..<3 { receipts.append(try await send(sender, room: room, wire: wire)) }
            var final = try #require(receipts.last)
            store = try await V2LocalStoreBootstrapper(bindingStore: binding).open(databaseURL: database, userID: receiver.userID)
            #expect(try await store.groupEventCursor(roomID: room) == initial.roomSequence)
            runtime = try await makeRuntime(store)
            let replacement = runtime
            task = Task { try await replacement.accountRuntime.runRealtime(replacement.runtime) }
            try await eventually {
                if let failure = await runtime.runtime.lastBackgroundFailure() {
                    print("IMV2_APP_RECOVERY_FAILURE_LOOP \(String(describing: await runtime.runtime.lastBackgroundFailureLoop()))")
                    print("IMV2_APP_TIMEOUT_COMMAND \(String(describing: await runtime.lastTimedOutRealtimeCommand()))")
                    throw failure
                }
                let cursor = try await store.groupEventCursor(roomID: room)
                return runtime.realtimeCoverage.scopes[.directory]?.subscriptionInstalled == true && cursor == final.roomSequence
            }
            #expect(runtime.realtimeCoverage.scopes[.room] == nil)
            #expect(runtime.realtimeCoverage.scopes[.directory]?.connectionGeneration != generation)
            let recoveredGeneration = try #require(runtime.realtimeCoverage.scopes[.directory]?.connectionGeneration)
            let interruptedWire = try #require(activeWire.withLock { $0 })
            let gatewayCrash = ProcessInfo.processInfo.environment["IMV2_APP_GATEWAY_CRASH_E2E"] == "1"
            if gatewayCrash {
                print("IMV2_APP_GATEWAY_CRASH_REQUESTED")
                try await eventually { await interruptedWire.authenticatedConnectionID() == nil }
            } else {
                await interruptedWire.disconnect()
            }
            await wire.disconnect()
            let afterInterruption = try await sendDurably(sender, room: room, configuration: senderConfiguration,
                database: root.appendingPathComponent("sender.sqlite"))
            receipts.append(afterInterruption)
            final = afterInterruption
            print("IMV2_APP_AUTOMATIC_TCP_RECONNECT_STARTED")
            do {
                try await eventually {
                    let cursor = try await store.groupEventCursor(roomID: room)
                    return runtime.realtimeCoverage.scopes[.directory]?.subscriptionInstalled == true
                        && (runtime.realtimeCoverage.scopes[.directory]?.connectionGeneration).map { $0 != recoveredGeneration } == true
                        && cursor == afterInterruption.roomSequence
                }
            } catch {
                let cursor = try await store.groupEventCursor(roomID: room)
                let installed = runtime.realtimeCoverage.scopes[.directory]?.subscriptionInstalled == true
                let changed = (runtime.realtimeCoverage.scopes[.directory]?.connectionGeneration).map { $0 != recoveredGeneration } == true
                let authenticated = await interruptedWire.authenticatedConnectionID() != nil
                let coverageState = String(describing: runtime.realtimeCoverage.state)
                let directoryStatus = runtime.realtimeCoverage.scopes[.directory].map { String(describing: $0.status) } ?? "absent"
                print("IMV2_APP_AUTOMATIC_TCP_RECONNECT_FAILED cursor=\(cursor) expected=\(afterInterruption.roomSequence) installed=\(installed) generationChanged=\(changed) authenticated=\(authenticated) coverage=\(coverageState) directory=\(directoryStatus)")
                print("IMV2_APP_AUTOMATIC_TCP_RECONNECT_FAILURE_LOOP \(String(describing: await runtime.runtime.lastBackgroundFailureLoop()))")
                throw error
            }
            #expect(runtime.realtimeCoverage.scopes[.room] == nil)
            print("IMV2_APP_AUTOMATIC_TCP_RECONNECT_PASSED")
            if gatewayCrash { print("IMV2_APP_GATEWAY_CRASH_RECOVERY_PASSED") }
            let messages = try await store.messages(in: room)
            #expect(receipts.allSatisfy { receipt in messages.contains { $0.messageID == receipt.messageID } })
            task?.cancel(); await runtime.accountRuntime.close(); _ = await task?.result
            try await store.close()
            store = try await V2LocalStoreBootstrapper(bindingStore: binding).open(databaseURL: database, userID: receiver.userID)
            #expect(try await store.groupEventCursor(roomID: room) == final.roomSequence)
            #expect(try await store.roomProgressAppliedSequence(roomID: room) == final.roomSequence)
            try await store.close()
            await wire.disconnect()
            print("IMV2_APP_UNOPENED_ROOM_RECONNECT_PASSED")
        } catch {
            task?.cancel(); await runtime.accountRuntime.close(); _ = await task?.result
            await wire.disconnect(); await reciprocal.disconnect(); try? await store.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func onlineMembershipChanges(runtime: V2AppRealtimeRuntime, store: GRDBV2LocalSyncStore,
        owner: LocalE2EAccountCredentials, receiver: LocalE2EAccountCredentials,
        wire: V2TLSFrameConnection) async throws {
        let sibling = try await registerSiblingLocalDevice(receiver)
        let secondaryPort = try #require(ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_SECONDARY_PORT"].flatMap(UInt16.init))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("membership-sibling-\(UUID())")
        let siblingStore = try await V2LocalStoreBootstrapper(bindingStore: LocalE2EInstallationBindingStore())
            .open(databaseURL: root.appendingPathComponent("receiver.sqlite"), userID: sibling.userID)
        let auth = V2AuthSession(credentialStore: ProgressCredentials(sibling.credentials),
            transport: ProgressNoRefresh(), revocationScheduler: ProgressNoRevocation())
        let credentials = try await auth.realtimeCredentials()
        let siblingRuntime = try await V2AppRealtimeRuntime(configuration: .init(localE2ERealtimePort: secondaryPort),
            actorUserID: sibling.userID, deviceID: sibling.deviceID, authSession: auth,
            authEpoch: #require(credentials.sessionEpoch), localStore: siblingStore,
            resourceCenter: try await makeResourceCenter(store: siblingStore, root: root.appending(path: "sibling"), user: sibling.userID))
        let task = Task { try await siblingRuntime.accountRuntime.runRealtime(siblingRuntime.runtime) }
        let stores = [store, siblingStore], runtimes = [runtime, siblingRuntime]
        do {
            for (index, local) in stores.enumerated() {
                try await eventually {
                    let complete = try await local.databasePool.read { db in
                        try Bool.fetchOne(db, sql: "SELECT directory_complete FROM v2_room_recovery_scan WHERE singleton=1") == true
                    }
                    return complete && runtimes[index].realtimeCoverage.scopes[.directory]?.subscriptionInstalled == true
                }
            }
            let generations = try runtimes.map { try #require($0.realtimeCoverage.scopes[.directory]?.connectionGeneration) }
            #expect(generations[0] != generations[1])
            let other = try await registerLocalAccount(displayName: "Membership seed")
            let group = try await localCreateGroup(account: owner, title: "Online membership", members: [other.userID])
            let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
            let members = try await transport.listRoomMembers(roomID: group.roomID, cursor: nil, pageSize: 10)
            let joined = try await localChangeMembership(account: owner, roomID: group.roomID,
                target: receiver.userID, action: .add, revision: members.membershipRevision)
            let first = try await send(owner, room: group.roomID, wire: wire)
            for local in stores {
                try await eventually { try await local.messages(in: group.roomID).contains { $0.messageID == first.messageID } }
                #expect(try await local.groupEventAccess(roomID: group.roomID)?.isAuthorized == true)
            }
            let removed = try await localChangeMembership(account: owner, roomID: group.roomID,
                target: receiver.userID, action: .remove, revision: joined.membershipRevision)
            for local in stores {
                try await eventually { try await local.groupEventAccess(roomID: group.roomID)?.isAuthorized != true }
            }
            let gap = try await send(owner, room: group.roomID, wire: wire)
            _ = try await localChangeMembership(account: owner, roomID: group.roomID,
                target: receiver.userID, action: .add, revision: removed.membershipRevision)
            let final = try await send(owner, room: group.roomID, wire: wire)
            for (index, local) in stores.enumerated() {
                try await eventually { try await local.messages(in: group.roomID).contains { $0.messageID == final.messageID } }
                let messages = try await local.messages(in: group.roomID)
                #expect(!messages.contains { $0.messageID == gap.messageID })
                #expect(try await local.groupEventAccess(roomID: group.roomID)?.isAuthorized == true)
                #expect(runtimes[index].realtimeCoverage.scopes[.room] == nil)
                #expect(runtimes[index].realtimeCoverage.scopes[.directory]?.connectionGeneration == generations[index])
            }
            print("IMV2_APP_CROSS_GATEWAY_MEMBERSHIP_PASSED")
            print("IMV2_APP_ONLINE_MEMBERSHIP_CHANGES_PASSED")
        } catch {
            task.cancel(); await siblingRuntime.accountRuntime.close(); _ = await task.result
            try? await siblingStore.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
        task.cancel(); await siblingRuntime.accountRuntime.close(); _ = await task.result
        try await siblingStore.close(); try? FileManager.default.removeItem(at: root)
    }

    private func eventually(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw ProgressFailure.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private func command(_ account: LocalE2EAccountCredentials, room: RoomID) throws -> V2MessageSendOperationCommand {
        try .init(command: .init(roomID: room, senderUserID: account.userID, clientMessageID: .init(UUID().uuidString), text: "progress-loss-\(UUID())", limits: .init(maxUTF8Bytes: 65_536)),
            firstSubmissionDeadlineMilliseconds: UInt64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000))
    }
    private func send(_ account: LocalE2EAccountCredentials, room: RoomID, wire: V2TLSFrameConnection) async throws -> V2MessageOperationAcceptance {
        try await submit(command(account, room: room), wire: wire)
    }
    private func sendDurably(_ account: LocalE2EAccountCredentials, room: RoomID,
        configuration: V2AppConfiguration, database: URL) async throws -> V2MessageOperationAcceptance {
        let local = try await V2LocalStoreBootstrapper(bindingStore: LocalE2EInstallationBindingStore())
            .open(databaseURL: database, userID: account.userID)
        let auth = V2AuthSession(credentialStore: ProgressCredentials(account.credentials),
            transport: ProgressNoRefresh(), revocationScheduler: ProgressNoRevocation())
        let credentials = try await auth.realtimeCredentials()
        let epoch = try #require(credentials.sessionEpoch)
        let activeWire = Mutex<V2TLSFrameConnection?>(nil)
        var senderRuntime: V2AppRealtimeRuntime?
        var senderTask: Task<Void, Error>?
        do {
            let runtime = try await V2AppRealtimeRuntime(configuration: configuration, actorUserID: account.userID,
                deviceID: account.deviceID, authSession: auth, authEpoch: epoch, localStore: local,
                resourceCenter: try await makeResourceCenter(store: local, root: database.deletingLastPathComponent().appending(path: "sender"), user: account.userID),
                testConnectionObserver: { connection in activeWire.withLock { $0 = connection } })
            senderRuntime = runtime
            let wire = try #require(activeWire.withLock { $0 })
            senderTask = Task { try await runtime.accountRuntime.runRealtime(runtime.runtime) }
            try await eventually { await wire.authenticatedConnectionID() != nil }
            let transport = V2ProtobufSyncTransport(wire: ProgressObservedWire(connection: wire),
                protocolVersion: UInt8(IMV2ProtocolVersion.current))
            let observed = ProgressDurableSendClient(client: V2ProtobufMessageSendOperationClient(transport: transport, connection: wire), connection: wire)
            let service = V2MessageSendOperationService(accountID: account.userID, store: local, client: observed)
            let intent = try await service.enqueueMessage(roomID: room, text: "durable-crash-send")
            _ = try await local.handOffSendIntent(intent)
            let work = try #require(try await local.dueOperationWork(now: Date(), kinds: [.sendMessage]).first)
            let frozen = try await local.messageSendCommand(workID: work.id)
            try await eventually {
                let current = try #require(try await local.operationWork(id: work.id))
                if current.execution == .committed { return true }
                if current.scheduling == .needsAttention {
                    let knownCodes: Set<String> = ["MESSAGE_SEND_TRANSPORT_UNAVAILABLE", "MESSAGE_SEND_OUTCOME_UNKNOWN",
                        "MESSAGE_SEND_CONFIRMATION_REQUIRED", "MESSAGE_SEND_FINGERPRINT_CONFLICT", "RATE_LIMITED", "ADMISSION_UNAVAILABLE"]
                    let code = current.lastErrorCode.flatMap { knownCodes.contains($0) ? $0 : nil } ?? "other"
                    print("IMV2_APP_DURABLE_SEND_STOPPED action=\(current.nextAction.rawValue) submissionAttempts=\(current.submissionRoundAttempts) reconciliationAttempts=\(current.reconciliationRoundAttempts) code=\(code)")
                    throw ProgressFailure.noReceipt
                }
                guard current.nextActionAt <= Date() else { return false }
                guard case .claimed(let claim) = try await local.claimOperationWork(id: work.id,
                    ownerID: UUID(), action: current.nextAction, now: Date()) else { return false }
                #expect(try await local.messageSendCommand(workID: work.id) == frozen)
                try await service.execute(claim)
                return try await local.operationWork(id: work.id)?.execution == .committed
            }
            #expect(await observed.recoveries > 0)
            #expect(await observed.reconnected)
            let receipt = try #require(await observed.receipt)
            #expect(receipt.validates(identity: try frozen.identity, fingerprint: try frozen.fingerprint))
            guard case .accepted(let accepted) = receipt.outcome else { throw ProgressFailure.noReceipt }
            #expect(try await local.messageSendCommand(workID: work.id) == frozen)
            senderTask?.cancel()
            await runtime.accountRuntime.close()
            _ = await senderTask?.result
            try await local.close()
            return accepted
        } catch {
            senderTask?.cancel()
            await senderRuntime?.accountRuntime.close()
            _ = await senderTask?.result
            try? await local.close()
            throw error
        }
    }

    private func submit(_ command: V2MessageSendOperationCommand, wire: V2TLSFrameConnection) async throws -> V2MessageOperationAcceptance {
        let transport = V2ProtobufSyncTransport(wire: ProgressObservedWire(connection: wire), protocolVersion: UInt8(IMV2ProtocolVersion.current))
        guard case .receipt(let receipt) = try await V2ProtobufMessageSendOperationClient(transport: transport, connection: wire).submit(command),
              receipt.validates(identity: try command.identity, fingerprint: try command.fingerprint), case .accepted(let accepted) = receipt.outcome else { throw ProgressFailure.noReceipt }
        return accepted
    }
}


private struct ProgressObservedWire: V2AuthenticatedFrameTransport {
    let connection: V2TLSFrameConnection
    func request(_ frame: V2Frame) async throws -> V2Frame {
        do { return try await connection.request(frame) }
        catch let error as V2TLSFrameConnectionError {
            print("IMV2_APP_REQUEST_FAILURE command=\(frame.command.rawValue) reason=\(error)")
            throw error
        } catch {
            print("IMV2_APP_REQUEST_FAILURE command=\(frame.command.rawValue) type=\(String(reflecting: type(of: error)))")
            throw error
        }
    }
    func negotiatedProtocolVersion() async -> UInt8? { await connection.negotiatedProtocolVersion() }
    func authenticatedConnectionID() async -> UUID? { await connection.authenticatedConnectionID() }
}

private final class RoomProgressLossWitness: Sendable {
    struct State: Sendable {
        var recoveryEvents: [String: Int] = [:]
        var detailPullsAfterArm = 0
        var detailAdvancedAfterArm = 0
        var firstDetailBefore: UInt64?
        var firstDetailAfter: UInt64?
        var armCursor: UInt64?
        var discardedNotifications = 0
        var discardedBodies = 0
        var higherHeartbeats = 0
        var firstHigherBeforeCursor: UInt64?
        var maximumHeartbeatHead: UInt64 = 0
    }
    let room: RoomID
    let state = Mutex(State())
    init(room: RoomID) { self.room = room }
    func recovery(_ event: V2RoomRecoveryObservation) {
        state.withLock { value in
            guard value.armCursor != nil else { return }
            let key = String(describing: event)
            if value.recoveryEvents[key] != nil || value.recoveryEvents.count < 32 {
                value.recoveryEvents[key, default: 0] += 1
            }
        }
    }
    func detailPull(before: UInt64, after: UInt64) {
        state.withLock { value in
            guard value.armCursor != nil else { return }
            value.detailPullsAfterArm += 1
            if after > before {
                value.detailAdvancedAfterArm += 1
                if value.firstDetailBefore == nil {
                    value.firstDetailBefore = before; value.firstDetailAfter = after
                }
            }
        }
    }
    func arm(cursor: UInt64) { state.withLock { $0.armCursor = cursor } }
    func discard(room incoming: String, head: UInt64, bodies: Int) -> Bool {
        guard incoming.lowercased() == room.rawValue.lowercased() else { return false }
        return state.withLock { value in
            guard let cursor = value.armCursor, head > cursor else { return false }
            value.discardedNotifications += 1; value.discardedBodies += bodies
            return true
        }
    }
    func heartbeat(room incoming: RoomID, head: UInt64, beforeCursor: UInt64) {
        guard incoming == room else { return }
        state.withLock { value in
            guard let cursor = value.armCursor, head > cursor else { return }
            if value.firstHigherBeforeCursor == nil { value.firstHigherBeforeCursor = beforeCursor }
            value.higherHeartbeats += 1; value.maximumHeartbeatHead = max(value.maximumHeartbeatHead, head)
        }
    }
    func snapshot() -> State { state.withLock { $0 } }
}
private enum ProgressFailure: Error { case timeout, noReceipt }
private actor ProgressCredentials: V2CredentialStore {
    var record: V2AuthCredentialRecord?
    init(_ credentials: V2AuthCredentials) { record = .init(credentials: credentials) }
    func load() -> V2AuthCredentialRecord? { record }
    func save(_ value: V2AuthCredentialRecord) { record = value }
    func delete() { record = nil }
}
private struct ProgressNoRefresh: V2AuthTransport {
    func refresh(_ request: V2RefreshRequest) throws -> V2AuthCredentials { throw ProgressFailure.noReceipt }
}
private struct ProgressNoRevocation: V2DeviceRevocationScheduling {
    func enqueue(_ intent: V2DeviceRevocationIntent) throws { throw ProgressFailure.noReceipt }
}

private struct RoomProgressObservedSynchronizer: V2ActiveHybridGroupSynchronizing {
    let base: any V2ActiveHybridGroupSynchronizing
    let store: GRDBV2LocalSyncStore
    let witness: RoomProgressLossWitness
    var usesRuntimeRecoveryClock: Bool { base.usesRuntimeRecoveryClock }
    func synchronizeOnePage(roomID: String) async throws -> V2ActiveHybridGroupSyncOutcome {
        let room = try RoomID(roomID)
        let before = try await store.groupEventCursor(roomID: room)
        let result = try await base.synchronizeOnePage(roomID: roomID)
        witness.detailPull(before: before, after: try await store.groupEventCursor(roomID: room))
        return result
    }
    func subscribe(roomID: String) async throws -> V2ActiveHybridGroupSubscriptionOutcome {
        try await base.subscribe(roomID: roomID)
    }
    func applyLiveEvent(_ wake: V2ActiveHybridGroupWake) async throws -> Bool { try await base.applyLiveEvent(wake) }
    func nextWake() async throws -> V2ActiveHybridGroupWake { try await base.nextWake() }
    func unsubscribe(roomID: String) async { await base.unsubscribe(roomID: roomID) }
}

private actor ProgressDurableSendClient: V2MessageSendOperationClient {
    let client: V2ProtobufMessageSendOperationClient
    private(set) var receipt: V2MessageSendOperationReceipt?
    private(set) var recoveries = 0
    private var droppedAcceptance = false
    private let connection: V2TLSFrameConnection
    private var interruptedGeneration: UUID?
    private(set) var reconnected = false
    init(client: V2ProtobufMessageSendOperationClient, connection: V2TLSFrameConnection) {
        self.client = client; self.connection = connection
    }
    func submit(_ command: V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
        let result = try await client.submit(command)
        if case .receipt(let value) = result {
            if case .accepted = value.outcome, !droppedAcceptance {
                // Discard an actual decoded TCP acceptance before durable work sees it.
                droppedAcceptance = true
                interruptedGeneration = try #require(await connection.authenticatedConnectionID())
                await connection.disconnect()
                print("IMV2_APP_DURABLE_SEND_ACCEPTANCE_DROPPED")
                throw V2MessageSendTransportError.outcomeUnknown
            }
            receipt = value
        }
        return result
    }
    func recover(_ request: V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult {
        recoveries += 1
        let result = try await client.recover(request)
        if case .receipt(let value) = result {
            let generation = try #require(await connection.authenticatedConnectionID())
            #expect(interruptedGeneration != nil && generation != interruptedGeneration)
            reconnected = interruptedGeneration != nil && generation != interruptedGeneration
            receipt = value
            print("IMV2_APP_DURABLE_SEND_TCP_RECONNECT_PASSED")
        }
        return result
    }
}

private func makeResourceCenter(store: GRDBV2LocalSyncStore, root: URL, user: UserID) async throws -> V2ResourceCenter {
    try await .make(scope: .init(incarnation: UUID(), accountID: user, directory: root, cacheDirectory: root.appending(path: "cache-scope")), store: store)
}
