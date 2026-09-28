import AsyncKit
import Foundation
import IMV2Core
@testable import IMV2Server
import Synchronization
import Testing

@Suite("V2 gateway domain command handler")
struct V2GatewayDomainCommandHandlerTests {
    @Test("retired domain wire fields cannot invoke a Gateway mutation", arguments: [20, 22, 24, 26, 28, 51, 53, 55, 57, 58, 67, 69, 71, 72, 97, 99, 101, 103, 105, 106])
    func retiredMutationWireIsNotExecutable(field: Int) async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler( sync: fixture.syncService())
        var tag = UInt64(field << 3 | 2), bytes = Data()
        repeat { var byte = UInt8(tag & 0x7f); tag >>= 7; if tag != 0 { byte |= 0x80 }; bytes.append(byte) } while tag != 0
        bytes.append(0)
        let request = try IMV2Envelope(serializedBytes: bytes)
        #expect(request.body == nil)
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "INVALID_ARGUMENT")
        #expect(!response.error.retryable)
    }

    @Test("Account coverage start uses the authenticated origin connection", arguments: [false, true])
    func accountCoverageStart(hasOrigin: Bool) async throws {
        let fixture = try GatewayDomainFixture(), probe = GatewayAccountStartProbe()
        let handler = makeGatewayDomainCommandHandler(
            accountChanges: probe, sync: fixture.syncService())
        let connection = UUID()
        var request = IMV2Envelope(); request.accountRoomChangesStart = .init()
        let response = try await handler.handle(envelope: request, identity: fixture.identity,
            originatingConnectionID: hasOrigin ? connection : nil)
        if hasOrigin {
            #expect(response.accountRoomChangesReady.connectionEpoch == probe.epoch.uuidString)
            #expect(await probe.connectionID == connection)
            #expect(await probe.userID == fixture.userID)
        } else {
            #expect(response.error.code == "UNAVAILABLE")
            #expect(await probe.connectionID == nil)
        }
    }

    @Test("Recovery reads receive the authenticated actor", arguments: [0, 1, 2])
    func recoveryAuthenticatedActor(batch: Int) async throws {
        let fixture = try GatewayDomainFixture()
        let recovery = GatewayRecoveryProbe()
        let handler = makeGatewayDomainCommandHandler(
            roomRecovery: recovery, sync: fixture.syncService())
        var request = IMV2Envelope()
        if batch == 2 { request.roomLatestVisibleBatch.roomIds = [fixture.roomID.rawValue] }
        else if batch == 1 { request.roomSyncStateBatch.roomIds = [fixture.roomID.rawValue] }
        else { request.userRoomDirectoryList.pageSize = 10 }
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(await recovery.actor == fixture.userID)
        if batch == 2 { #expect(response.body == .roomLatestVisibleBatchResult(.init())) }
        else if batch == 1 { #expect(response.body == .roomSyncStateBatchResult(.init())) }
        else { #expect(response.body == .userRoomDirectoryPage(.init())) }
    }

    @Test("Recovery topology errors explicitly request a fresh directory scan")
    func recoveryTopologyReset() async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(
            roomRecovery: GatewayRecoveryProbe(failure: .topologyChanged), sync: fixture.syncService())
        var request = IMV2Envelope()
        request.userRoomDirectoryList.pageSize = 10
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "ROOM_DIRECTORY_RESET_REQUIRED")
        #expect(response.error.retryable)
    }

    @Test("Snapshot preparation preserves bounded retry intervals and recovers from invalid intervals")
    func snapshotPreparationRetryIntervals() async throws {
        let fixture = try GatewayDomainFixture()
        let cases: [(Double, UInt32?)] = [
            (.nan, nil), (.infinity, nil), (-.infinity, nil),
            (.greatestFiniteMagnitude, nil), (-.greatestFiniteMagnitude, nil),
            (-1, nil), (-0.1, nil), (0, 0), (0.001, 1), (0.999, 1),
            (1, 1), (1.001, 2), (2.25, 3),
            (Double(UInt32.max) - 0.25, UInt32.max), (Double(UInt32.max), UInt32.max),
            (Double(UInt32.max) + 0.25, nil)
        ]
        for (interval, expected) in cases {
            let store = GatewaySnapshotClockStore(retryAfter: interval)
            let handler = makeGatewayDomainCommandHandler(
                sync: .init(store: store, now: { fixture.now }))
            var request = IMV2Envelope()
            request.syncPull.requireSnapshot = true
            request.syncPull.maxRecords = 10
            let response = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(response.error.code == (expected == nil ? "UNAVAILABLE" : "RESET_PREPARING"))
            #expect(response.error.retryAfterSeconds == (expected ?? 0))
            #expect(response.error.retryable)

            await store.setRetryAfter(1.25)
            let recovered = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(recovered.error.code == "RESET_PREPARING" && recovered.error.retryable)
            #expect(recovered.error.retryAfterSeconds == 2)
            #expect(await store.calls == 2)
        }
    }

    @Test("Snapshot reset and manifest responses reject invalid expiry and preserve signed milliseconds on retry",
          arguments: [false, true], [Double.nan, .infinity, -.infinity,
              .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
              Double(Int64.max) / 1_000, -Double(Int64.max) / 500])
    func snapshotExpiryResponseBoundary(manifest: Bool, seconds: Double) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewaySnapshotClockStore(expiresAt: Date(timeIntervalSince1970: seconds))
        let handler = makeGatewayDomainCommandHandler(
            sync: .init(store: store, now: { fixture.now }))
        var request = IMV2Envelope()
        if manifest {
            request.syncSnapshot.snapshotID = store.snapshotID.rawValue
            request.syncSnapshot.generation = 1
        } else {
            request.syncPull.requireSnapshot = true
            request.syncPull.maxRecords = 10
        }
        let failed = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(failed.error.code == "UNAVAILABLE" && failed.error.retryable)
        #expect(failed.error.retryAfterSeconds == 0)
        for (dateSeconds, expectedMilliseconds): (Double, Int64) in [(-1.25, -1_250), (0, 0), (1_750_000_000.125, 1_750_000_000_125)] {
            await store.setExpiry(Date(timeIntervalSince1970: dateSeconds))
            let response = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(response.error.code.isEmpty)
            if manifest {
                #expect(response.snapshotManifest.snapshotID == store.snapshotID.rawValue)
                #expect(response.snapshotManifest.expiresAtMs == expectedMilliseconds)
                #expect(response.snapshotManifest.generation == 1)
                #expect(response.snapshotManifest.baseUserSyncSequence == 7)
            } else {
                #expect(response.resetRequired.snapshotID == store.snapshotID.rawValue)
                #expect(response.resetRequired.expiresAtMs == expectedMilliseconds)
                #expect(response.resetRequired.generation == 1)
                #expect(response.resetRequired.baseUserSyncSequence == 7)
            }
        }
        #expect(await store.calls == 4)
    }

    @Test("Out-of-range receipt sequences are nonretryable request errors before storage or replay",
          arguments: [UInt64(0), UInt64(Int64.max) + 1, UInt64.max])
    func receiptSequenceRangeIsARequestError(_ invalid: UInt64) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayReadReceiptSequenceStore()
        let handler = makeGatewayDomainCommandHandler(
            readReceipt: .init(store: store, now: { fixture.now }), sync: fixture.syncService())
        var request = IMV2Envelope()
        request.recordReadReceipt.roomID = fixture.roomID.rawValue
        request.recordReadReceipt.operationID = UUID().uuidString
        for expectedCalls in 0...1 {
            request.recordReadReceipt.readThroughRoomSequence = invalid
            let rejected = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(rejected.error.code == "INVALID_ARGUMENT" && !rejected.error.retryable)
            #expect(await store.calls == expectedCalls)
            request.recordReadReceipt.readThroughRoomSequence = UInt64(Int64.max)
            let valid = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(valid.readReceiptRecorded.readThroughRoomSequence == UInt64(Int64.max))
            #expect(valid.readReceiptRecorded.recordedAtMs == 1_750_000_000_000)
        }
        #expect(await store.calls == 2)
    }

    @Test("Domain timestamp responses reject unencodable dates and recover on retry",
          arguments: [false, true], ["receipt", "live-get", "presence", "conversation", "conversation-mute", "favorite"])
    func remainingResponseTimestampBoundaries(replay: Bool, path: String) async throws {
        let fixture = try GatewayDomainFixture()
        let profile = try V2CapacityProfile(id: "standard", limits: fixture.profile)
        let target = UUID().uuidString, operation = UUID().uuidString, message = UUID().uuidString
        let valid = Date(timeIntervalSince1970: 1_750_000_000.125)
        var request = IMV2Envelope()
        switch path {
        case "conversation", "conversation-mute":
            request.setConversationState.roomID = fixture.roomID.rawValue
            request.setConversationState.firstSubmissionDeadlineMs=UInt64(Int64.max)
            request.setConversationState.operationID = operation
        case "favorite":
            request.setMessageFavorite.roomID = fixture.roomID.rawValue
            request.setMessageFavorite.firstSubmissionDeadlineMs=UInt64(Int64.max)
            request.setMessageFavorite.operationID = operation
            request.setMessageFavorite.messageID = message
            request.setMessageFavorite.isFavorited = true
        case "receipt":
            request.recordReadReceipt.operationID = operation; request.recordReadReceipt.roomID = fixture.roomID.rawValue; request.recordReadReceipt.readThroughRoomSequence = 3
        case "live-get": request.getLiveActivityPreferences = .init()
        default: request.subscribePresence.roomID = fixture.roomID.rawValue
        }
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, Double(Int64.max) / 1_000, -Double(Int64.max) / 500] {
            let store = GatewayResponseClockStore(date: Date(timeIntervalSince1970: seconds), replay: replay,
                muteExpiryOnly: path == "conversation-mute")
            let handler = makeGatewayDomainCommandHandler(
                readReceipt: .init(store: store, now: { fixture.now }), liveActivity: .init(store: store),
                conversationCapabilities: .init(store: store, now: { fixture.now }),
                sync: fixture.syncService())
            let failed = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(failed.error.code == "UNAVAILABLE" && failed.error.retryable && failed.error.retryAfterSeconds == 0)
            for (recoveredDate, expectedMilliseconds) in [(valid, Int64(1_750_000_000_125)), (Date(timeIntervalSince1970: 0), 0), (Date(timeIntervalSince1970: -1.25), -1_250)] {
                await store.recover(at: recoveredDate)
                let response = try await handler.handle(envelope: request, identity: fixture.identity)
                let milliseconds: Int64
                switch path {
                case "conversation": milliseconds = response.personalPreferenceReceipt.conversationState.updatedAtMs
                case "conversation-mute": milliseconds = response.personalPreferenceReceipt.conversationState.muteUntilMs
                case "favorite": milliseconds = response.personalPreferenceReceipt.messageFavorite.updatedAtMs
                case "receipt": milliseconds = response.readReceiptRecorded.recordedAtMs
                case "live-get": milliseconds = response.liveActivityPreferences.updatedAtMs
                default: milliseconds = response.presenceSubscribed.expiresAtMs
                }
                #expect(milliseconds == expectedMilliseconds)
            }
            #expect(await store.calls == 4)
        }
    }

    @Test("invalid unsubscribe room IDs return argument errors without closing or removing subscriptions",
          arguments: ["group", "presence", "typing"])
    func unsubscribeRoomValidation(kind: String) async throws {
        let fixture = try GatewayDomainFixture()
        let registry = V2DeviceConnectionRegistry(), connectionID = UUID()
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])
        let handler = makeGatewayDomainCommandHandler( sync: fixture.syncService())
        let stream = V2GatewayByteStream(frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 1),
                authenticator: GatewayResponseAuthenticator(userID: fixture.userID),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: handler, connectionID: connectionID, registry: registry)
        func exchange(_ request: IMV2Envelope, version: UInt8) async throws -> IMV2Envelope {
            let frame = try V2ServerProtobufFrameCodec.encode(request, frameVersion: version)
            let responses = try await stream.receive(V2FrameCodec.encode(frame, limits: limits))
            #expect(responses.count == 1)
            return try V2ServerProtobufFrameCodec.decode(V2FrameCodec.decodeExactlyOne(#require(responses.first), limits: limits))
        }
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        hello.clientHello.deviceID = fixture.deviceID.rawValue
        _ = try await exchange(hello, version: 0)
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "local-fixture"; auth.authenticate.deviceID = fixture.deviceID.rawValue
        _ = try await exchange(auth, version: version)
        let delivered = Mutex<[Data]>([])
        await stream.setOutboundWriter { data in delivered.withLock { $0.append(data) } }
        let room = fixture.roomID, subject = UserID(uuid: UUID())
        switch kind {
        case "group": await registry.subscribeForegroundGroup(stream, connectionID: connectionID, roomID: room)
        case "presence": await registry.subscribePresence(stream, connectionID: connectionID, roomID: room, targetUserID: subject)
        default: await registry.subscribeTyping(stream, connectionID: connectionID, roomID: room)
        }
        func publish() async {
            let expiry = fixture.now.addingTimeInterval(6)
            switch kind {
            case "group": await registry.notifyForegroundGroupAvailable(roomID: room, highWatermark: 9)
            case "presence": await registry.receivePresence(targetUserID: subject, isOnline: true, expiresAt: expiry)
            default: await registry.receiveTyping(.init(roomID: room, userID: subject, isTyping: true, expiresAt: expiry))
            }
        }
        func request(roomID: String) -> IMV2Envelope {
            var request = IMV2Envelope(); request.requestID = 3; request.protocolVersion = UInt32(version)
            switch kind {
            case "group": request.groupEventUnsubscribe.roomID = roomID
            case "presence": request.unsubscribePresence.roomID = roomID
            default: request.unsubscribeTyping.roomID = roomID
            }
            return request
        }
        var expectedNotifications = 0
        for invalidRoom in ["", " ", "room/invalid", String(repeating: "a", count: 129)] {
            let rejected = try await exchange(request(roomID: invalidRoom), version: version)
            #expect(rejected.requestID == 3)
            #expect(rejected.error.code == "INVALID_ARGUMENT" && !rejected.error.retryable)
            #expect(await stream.isAuthenticated())
            await publish()
            expectedNotifications += 1
            #expect(delivered.withLock { $0.count } == expectedNotifications)
        }
        // Reusing the completed request ID also verifies the in-flight slot
        // was released after each argument error. Repeated cleanup is harmless.
        for _ in 0..<2 {
            let accepted = try await exchange(request(roomID: room.rawValue), version: version)
            guard case .acknowledged? = accepted.body else {
                Issue.record("Expected successful unsubscribe acknowledgement")
                return
            }
            await publish()
            #expect(delivered.withLock { $0.count } == expectedNotifications)
        }
        #expect(await stream.isAuthenticated())
        try await stream.finish()
    }

    @Test("Personal timestamp validation distinguishes unsupported input from an unavailable server clock",
          arguments: [V2ConversationCapabilitiesStoreError.invalidTimestamp, .corruptPersistenceState])
    func personalTimestampErrorMapping(error: V2ConversationCapabilitiesStoreError) async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(
            conversationCapabilities: .init(store: GatewayPersonalTimestampFailure(error: error)), sync: fixture.syncService())
        var request = IMV2Envelope()
        request.setConversationState.roomID = fixture.roomID.rawValue
        request.setConversationState.firstSubmissionDeadlineMs=UInt64(Int64.max)
            request.setConversationState.operationID = UUID().uuidString
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == (error == .invalidTimestamp ? "INVALID_ARGUMENT" : "UNAVAILABLE"))
        #expect(response.error.retryable == (error == .corruptPersistenceState))
    }





    @Test("database admission rejects overload with a stable retryable protocol error")
    func databaseAdmissionReturnsServerBusy() async throws {
        let fixture = try GatewayDomainFixture()
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 1,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            timeout: .milliseconds(5)
        ))
        #expect(await admission.acquire(.foregroundWrite) == .admitted)
        #expect(await admission.acquire(.interactiveRead) == .admitted)
        let telemetry = V2InMemoryTelemetrySink()
        let handler = makeGatewayDomainCommandHandler(
            sync: fixture.syncService(),
            telemetry: telemetry,
            databaseWorkAdmission: admission
        )
        var request = IMV2Envelope()
        request.getGroupRolePolicyBaseline.roomID = fixture.roomID.rawValue

        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "SERVER_BUSY")
        #expect(response.error.retryable)
        var baseline = IMV2Envelope(); baseline.getGroupRolePolicyBaseline.roomID = fixture.roomID.rawValue
        #expect(try await handler.handle(envelope: baseline, identity: fixture.identity).error.code == "SERVER_BUSY")
        var latest = IMV2Envelope(); latest.roomLatestVisibleBatch.roomIds = [fixture.roomID.rawValue]
        let latestBusy = try await handler.handle(envelope: latest, identity: fixture.identity)
        #expect(latestBusy.error.code == "SERVER_BUSY" && latestBusy.error.retryable)
        guard case .gatewayCommand(_, .getGroupRolePolicyBaseline, .rejected, .serverBusy, _) =
            await telemetry.events().first
        else {
            Issue.record("expected a privacy-safe server-busy metric")
            await admission.release(.foregroundWrite)
            await admission.release(.interactiveRead)
            return
        }
        await admission.release(.foregroundWrite)
        await admission.release(.interactiveRead)
    }

    @Test("room-log pulls use the interactive-read reservation instead of send capacity")
    func groupEventPullUsesInteractiveReadAdmission() async throws {
        let fixture = try GatewayDomainFixture()
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 1,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            // The queued reader must remain queued while the handler is
            // constructed and called, even under a loaded parallel test run.
            timeout: .seconds(5)
        ))
        #expect(await admission.acquire(.foregroundWrite) == .admitted)
        #expect(await admission.acquire(.interactiveRead) == .admitted)
        let queuedRead = Task { await admission.acquire(.interactiveRead) }
        while await admission.snapshot().interactiveReadQueued == 0 {
            await Task.yield()
        }
        let telemetry = V2InMemoryTelemetrySink()
        let handler = makeGatewayDomainCommandHandler(
            sync: fixture.syncService(),
            telemetry: telemetry,
            databaseWorkAdmission: admission
        )
        var request = IMV2Envelope()
        request.groupEventPull = .init()
        request.groupEventPull.roomID = fixture.roomID.rawValue
        request.groupEventPull.pageSize = 100

        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "SERVER_BUSY")
        guard case .gatewayCommand(_, .groupEventPull, .rejected, .serverBusy, _) =
            await telemetry.events().first
        else {
            Issue.record("expected room-log pull telemetry instead of unsupported")
            await admission.release(.interactiveRead)
            if await queuedRead.value == .admitted {
                await admission.release(.interactiveRead)
            }
            await admission.release(.foregroundWrite)
            return
        }
        let snapshot = await admission.snapshot()
        #expect(snapshot.interactiveRead.queueFullRejections == 1)
        #expect(snapshot.foregroundWrite.rejectedRequests == 0)
        await admission.release(.interactiveRead)
        let queuedResult = await queuedRead.value
        #expect(queuedResult == .admitted)
        if queuedResult == .admitted {
            await admission.release(.interactiveRead)
        }
        await admission.release(.foregroundWrite)
    }

    @Test("cancelling admission wait propagates cancellation instead of server busy")
    func databaseAdmissionCancellationPropagates() async throws {
        let fixture = try GatewayDomainFixture()
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 1,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            timeout: .seconds(1)
        ))
        #expect(await admission.acquire(.foregroundWrite) == .admitted)
        #expect(await admission.acquire(.interactiveRead) == .admitted)
        let handler = makeGatewayDomainCommandHandler(
            sync: fixture.syncService(),
            databaseWorkAdmission: admission
        )
        var request = IMV2Envelope()
        request.getGroupRolePolicyBaseline.roomID = fixture.roomID.rawValue

        let waiting = Task {
            try await handler.handle(envelope: request, identity: fixture.identity)
        }
        while await admission.snapshot().interactiveReadQueued == 0 {
            await Task.yield()
        }
        waiting.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
        #expect(await admission.snapshot().interactiveRead.cancelledRequests == 1)
        await admission.release(.foregroundWrite)
        await admission.release(.interactiveRead)
    }

    @Test("process-local unsubscribe remains available during database overload", arguments: ["group", "presence", "typing"])
    func databaseAdmissionBypassesUnsubscribe(kind: String) async throws {
        let fixture = try GatewayDomainFixture()
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 1,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            timeout: .milliseconds(5)
        ))
        #expect(await admission.acquire(.foregroundWrite) == .admitted)
        let handler = makeGatewayDomainCommandHandler(
            sync: fixture.syncService(),
            databaseWorkAdmission: admission
        )
        var request = IMV2Envelope()
        switch kind {
        case "group": request.groupEventUnsubscribe.roomID = fixture.roomID.rawValue
        case "presence": request.unsubscribePresence.roomID = fixture.roomID.rawValue
        default: request.unsubscribeTyping.roomID = fixture.roomID.rawValue
        }

        let response = try await handler.handle(
            envelope: request,
            identity: fixture.identity
        )
        guard case .some(.acknowledged) = response.body else {
            Issue.record("expected process-local unsubscribe success")
            await admission.release(.foregroundWrite)
            return
        }
        #expect(await admission.snapshot().foregroundWriteQueued == 0)
        await admission.release(.foregroundWrite)
    }

    @Test("snapshot rebuild reaches the sync store with the authenticated device")
    func forwardsSnapshotRebuild() async throws {
        let fixture = try GatewayDomainFixture()
        let received = Mutex<(UserID, DeviceID, Bool)?>(nil)
        let store = GatewayRejectingSyncStore(onPull: { userID, deviceID, requireSnapshot in
            received.withLock { $0 = (userID, deviceID, requireSnapshot) }
        })
        let handler = makeGatewayDomainCommandHandler(
            sync: .init(store: store)
        )
        var pull = IMV2Envelope()
        pull.syncPull.requireSnapshot = true
        let response = try await handler.handle(envelope: pull, identity: fixture.identity)
        #expect(response.error.code == "SYNC_TOKEN_INVALID")
        let request = try #require(received.withLock { $0 })
        #expect(request.0 == fixture.userID)
        #expect(request.1 == fixture.deviceID)
        #expect(request.2)
    }

    @Test("invalid sync state is returned as a stable protocol error")
    func syncStateErrors() async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(
            sync: .init(store: GatewayRejectingSyncStore())
        )
        var pull = IMV2Envelope()
        pull.syncPull = .init()
        pull.syncPull.syncToken = "expired-token"
        #expect(try await handler.handle(envelope: pull, identity: fixture.identity).error.code == "SYNC_TOKEN_INVALID")

        var acknowledge = IMV2Envelope()
        acknowledge.syncAck = .init()
        acknowledge.syncAck.generation = 1
        acknowledge.syncAck.highestContiguousSequence = 4
        acknowledge.syncAck.syncReceipt = "expired-receipt"
        #expect(try await handler.handle(envelope: acknowledge, identity: fixture.identity).error.code == "SYNC_RECEIPT_INVALID")
    }

    @Test("Sync generations and sequences reject unsupported integers before storage and preserve valid boundaries",
          arguments: ["ack-generation", "ack-sequence", "manifest", "page", "snapshot-generation", "snapshot-sequence"])
    func syncRequestIntegerBoundaries(path: String) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewaySyncBoundaryStore()
        let handler = makeGatewayDomainCommandHandler(
            sync: .init(store: store, now: { fixture.now }))
        let sequencePath = path.hasSuffix("sequence")
        func request(_ value: UInt64) -> IMV2Envelope {
            let generation: UInt64 = sequencePath ? 1 : value
            let sequence: UInt64 = sequencePath ? value : 0
            var result = IMV2Envelope()
            switch path {
            case "ack-generation", "ack-sequence":
                result.syncAck.generation = generation
                result.syncAck.highestContiguousSequence = sequence
                result.syncAck.syncReceipt = "boundary-receipt"
            case "manifest":
                result.syncSnapshot.generation = generation
                result.syncSnapshot.snapshotID = store.snapshotID.rawValue
            case "page":
                result.snapshotPagePull.generation = generation
                result.snapshotPagePull.snapshotID = store.snapshotID.rawValue
                result.snapshotPagePull.rootDigest = "boundary-root"
            default:
                result.snapshotAck.generation = generation
                result.snapshotAck.baseUserSyncSequence = sequence
                result.snapshotAck.snapshotID = store.snapshotID.rawValue
                result.snapshotAck.snapshotReceipt = "boundary-receipt"
            }
            return result
        }
        let invalid: [UInt64] = (sequencePath ? [] : [0]) + [UInt64(Int64.max) + 1, UInt64.max]
        let valid: [UInt64] = (sequencePath ? [0] : []) + [1, UInt64(Int64.max)]
        var expectedCalls = 0
        for value in valid {
            // Repeat invalid inputs before each valid boundary to cover the
            // same service instance both before and after successful calls.
            for bad in invalid {
                let response = try await handler.handle(envelope: request(bad), identity: fixture.identity)
                #expect(response.error.code == "INVALID_ARGUMENT" && !response.error.retryable)
                #expect(await store.calls == expectedCalls)
            }
            let response = try await handler.handle(envelope: request(value), identity: fixture.identity)
            #expect(response.error.code.isEmpty)
            expectedCalls += 1
            #expect(await store.calls == expectedCalls)
            #expect(await store.lastGeneration == (sequencePath ? 1 : value))
            if sequencePath { #expect(await store.lastSequence == value) }
        }
    }

    @Test("Sync response failures use stable protocol errors and recover after storage becomes available",
          arguments: [V2SyncStoreError.syncLogSequenceGap, .snapshotCheckpointUnavailable, .syncRecordTooLarge])
    func syncResponseFailureRecovery(error: V2SyncStoreError) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayRecoveringSyncStore(failure: error)
        let handler = makeGatewayDomainCommandHandler(
            sync: .init(store: store, now: { fixture.now }))
        var request = IMV2Envelope()
        request.syncPull.maxRecords = 10
        request.syncPull.requireSnapshot = error == .snapshotCheckpointUnavailable
        for _ in 0..<2 {
            let response = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(response.error.code == (error == .syncRecordTooLarge ? "SYNC_RECORD_TOO_LARGE" : "UNAVAILABLE"))
            #expect(response.error.retryable == (error != .syncRecordTooLarge))
            #expect(response.error.retryAfterSeconds == 0)
            #expect(response.body == .error(response.error))
        }
        await store.recover()
        let recovered = try await handler.handle(envelope: request, identity: fixture.identity)
        if request.syncPull.requireSnapshot {
            #expect(recovered.error.code == "RESET_PREPARING" && recovered.error.retryable)
            #expect(recovered.error.retryAfterSeconds == 1)
        } else {
            #expect(recovered.body == .syncBatch(recovered.syncBatch) && recovered.error.code.isEmpty)
            #expect(recovered.syncBatch.generation == 1 && recovered.syncBatch.records.isEmpty)
            #expect(recovered.syncBatch.nextSyncToken == "recovered-token")
            #expect(recovered.syncBatch.syncReceipt == "recovered-receipt" && !recovered.syncBatch.hasMore_p)
        }
        #expect(await store.calls == 3)
    }

    @Test("room-log pulls trim a valid page to the exact gateway payload budget")
    func groupEventPullRespectsGatewayPayloadBudget() async throws {
        let fixture = try GatewayDomainFixture()
        let roomID = fixture.roomID
        let entries = try (1...8).map { sequence in
            try V2GroupEventLogEntry(
                sourceEventID: try .init(String(format: "00000000-0000-0000-0000-%012d", sequence)),
                roomSequence: UInt64(sequence),
                projectionKind: "message.accepted",
                payload: Data(repeating: 0x78, count: 700)
            )
        }
        let handler = makeGatewayDomainCommandHandler(
            groupEventLog: .init(store: GatewaySizedGroupEventLogStore(
                page: try .init(roomID: roomID, events: entries, nextRoomSequence: 8, hasMore: false)
            )),
            sync: fixture.syncService(),
            maximumGroupEventPagePayloadBytes: 2_048
        )
        var request = IMV2Envelope()
        request.groupEventPull = .init()
        request.groupEventPull.roomID = roomID.rawValue
        request.groupEventPull.pageSize = 8

        var response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.groupEventPage.events.count > 0)
        #expect(response.groupEventPage.events.count < entries.count)
        #expect(response.groupEventPage.hasMore_p)
        #expect(response.groupEventPage.nextRoomSequence == response.groupEventPage.events.last?.roomSequence)

        response.requestID = .max
        response.protocolVersion = IMV2ProtocolVersion.current
        let payload = try V2ServerProtobufFrameCodec.encode(
            response,
            frameVersion: UInt8(IMV2ProtocolVersion.current)
        ).payload
        #expect(payload.count <= 2_048)
    }

    @Test("room-log pulls surface an unencodable durable event as a stable error")
    func groupEventPullReportsUnencodableEvent() async throws {
        let fixture = try GatewayDomainFixture()
        let oversizedEvent = try V2GroupEventLogEntry(
            sourceEventID: try .init("00000000-0000-0000-0000-000000000001"),
            roomSequence: 1,
            projectionKind: "message.accepted",
            payload: Data(repeating: 0x78, count: 2_500)
        )
        let handler = makeGatewayDomainCommandHandler(
            groupEventLog: .init(store: GatewaySizedGroupEventLogStore(
                page: try .init(roomID: fixture.roomID, events: [oversizedEvent], nextRoomSequence: 1, hasMore: false)
            )),
            sync: fixture.syncService(),
            maximumGroupEventPagePayloadBytes: 2_048
        )
        var request = IMV2Envelope()
        request.groupEventPull = .init()
        request.groupEventPull.roomID = fixture.roomID.rawValue
        request.groupEventPull.pageSize = 1

        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "GROUP_EVENT_TOO_LARGE")
        #expect(!response.error.retryable)
    }

    @Test("Hybrid room subscription verifies the session actor and returns only its waterline")
    func groupEventSubscriptionUsesAuthenticatedActor() async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayGroupEventLogStore()
        let handler = makeGatewayDomainCommandHandler(
            groupEventLog: .init(store: store),
            sync: fixture.syncService()
        )
        var request = IMV2Envelope(); request.groupEventSubscribe = .init()
        request.groupEventSubscribe.roomID = fixture.roomID.rawValue
        request.groupEventSubscribe.afterRoomSequence = 77

        let response = try await handler.handle(envelope: request, identity: fixture.identity)

        #expect(response.groupEventSubscribed.roomID == fixture.roomID.rawValue)
        #expect(response.groupEventSubscribed.highWatermark == 91)
        #expect(await store.actor() == fixture.userID)
    }

    @Test("member directory owner changes request a fresh page")
    func membershipDirectoryOwnerChangeRestartsPagination() async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(
            membershipDirectory: .init(store: GatewayMovedMembershipDirectory()), sync: fixture.syncService())
        var request = IMV2Envelope(); request.listRoomMembers = .init()
        request.listRoomMembers.roomID = fixture.roomID.rawValue
        request.listRoomMembers.pageSize = 100
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "REVISION_CONFLICT")
        #expect(response.error.retryable)
    }

    @Test("member directory takes its requester only from the authenticated session")
    func membershipDirectoryUsesAuthenticatedActor() async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayMembershipDirectoryStore()
        let handler = makeGatewayDomainCommandHandler(
            membershipDirectory: .init(store: store),
            sync: fixture.syncService()
        )
        var request = IMV2Envelope(); request.listRoomMembers = .init()
        request.listRoomMembers.roomID = fixture.roomID.rawValue
        request.listRoomMembers.pageSize = 100

        let response = try await handler.handle(envelope: request, identity: fixture.identity)

        #expect(response.roomMembersPage.roomID == fixture.roomID.rawValue)
        #expect(response.roomMembersPage.actorRole == .owner)
        #expect(response.roomMembersPage.members.count == 1)
        #expect(response.roomMembersPage.members.first?.userID == fixture.userID.rawValue)
        let member = try #require(response.roomMembersPage.members.first)
        let serialized = try #require(JSONSerialization.jsonObject(with: member.jsonUTF8Data()) as? [String: Any])
        #expect(Set(serialized.keys) == ["userId", "role"])
        #expect(await store.actor() == fixture.userID)
    }







    @Test("receipt owner change returns retryable unavailability", arguments: ["record", "readers"])
    func readReceiptOwnerChangeIsRetryable(_ kind: String) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayOwnerChangedReadReceiptStore()
        let handler = makeGatewayDomainCommandHandler(
            readReceipt: .init(store: store), sync: fixture.syncService())
        var request = IMV2Envelope()
        if kind == "record" {
            request.recordReadReceipt.roomID = fixture.roomID.rawValue
            request.recordReadReceipt.operationID = "00000000-0000-0000-0000-000000000027"
            request.recordReadReceipt.readThroughRoomSequence = 1
        } else {
            request.listReadReceiptReaders.roomID = fixture.roomID.rawValue
            request.listReadReceiptReaders.messageID = "00000000-0000-0000-0000-000000000028"
            request.listReadReceiptReaders.pageSize = 10
        }
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "UNAVAILABLE" && response.error.retryable)
        #expect(await store.calls() == [kind])
    }







}

extension V2GatewayDomainCommandHandlerTests {
    @Test("read receipt transport contains only reader IDs and preserves the authenticated actor")
    func receiptDirectoryContainsNoProfileContent() async throws {
        let fixture = try GatewayDomainFixture(), source = GatewayReceiptIDStore()
        let handler = makeGatewayDomainCommandHandler(
            readReceipt: .init(store: source), sync: fixture.syncService())
        var request = IMV2Envelope(); request.listReadReceiptReaders = .init()
        request.listReadReceiptReaders.roomID = fixture.roomID.rawValue
        request.listReadReceiptReaders.messageID = UUID().uuidString
        request.listReadReceiptReaders.pageSize = 50
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        let reader = try #require(response.readReceiptReadersPage.readers.first)
        let fields = try #require(JSONSerialization.jsonObject(with: reader.jsonUTF8Data()) as? [String: Any])
        #expect(Set(fields.keys) == ["userId"])
        #expect(await source.actor == fixture.userID)
        request.listReadReceiptReaders.cursor = String(repeating: "a", count: 513)
        let invalid = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(invalid.error.code == "INVALID_ARGUMENT")
        #expect(await source.calls == 1)
    }
}

private actor GatewayReceiptIDStore: V2ReadReceiptStore {
    private(set) var actor: UserID?
    private(set) var calls = 0
    func record(command: V2RecordReadReceiptCommand, now: Date) throws -> V2ReadReceiptOutcome { throw CancellationError() }
    func setPreferences(command: V2SetReadReceiptPreferencesCommand, now: Date) throws -> V2SetReadReceiptPreferencesOutcome { throw CancellationError() }
    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) throws -> V2ReadReceiptReadersPage {
        actor = actorUserID; calls += 1
        return try .init(roomID: roomID, messageID: messageID, readers: [.init(userID: .init(uuid: UUID()))], nextCursor: nil)
    }
}

private struct GatewayResponseAuthenticator: V2GatewayAuthenticator {
    let userID: UserID
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) -> V2GatewayAuthentication {
        .init(userID: userID, expiresAt: nil)
    }
}

private actor GatewayAccountStartProbe: V2AccountRoomChangesStarting {
    let epoch = UUID()
    private(set) var connectionID: UUID?
    private(set) var userID: UserID?
    func startAccountRoomChanges(connectionID: UUID, userID: UserID) async throws -> String {
        self.connectionID = connectionID
        self.userID = userID
        return epoch.uuidString
    }
}

private actor GatewayRecoveryProbe: V2RoomRecoveryCommandHandling {
    private(set) var actor: UserID?
    let failure: V2RoomRecoveryReadError?
    init(failure: V2RoomRecoveryReadError? = nil) { self.failure = failure }
    func list(_ request: IMV2UserRoomDirectoryList, actorUserID: UserID) async throws -> IMV2Envelope {
        actor = actorUserID
        if let failure { throw failure }
        var response = IMV2Envelope()
        response.userRoomDirectoryPage = .init()
        return response
    }
    func batch(_ request: IMV2RoomLatestVisibleBatch, actorUserID: UserID) async throws -> IMV2Envelope {
        actor = actorUserID
        if let failure { throw failure }
        var response = IMV2Envelope()
        response.roomLatestVisibleBatchResult = .init()
        return response
    }
    func batch(_ request: IMV2RoomSyncStateBatch, actorUserID: UserID) async throws -> IMV2Envelope {
        actor = actorUserID
        if let failure { throw failure }
        var response = IMV2Envelope()
        response.roomSyncStateBatchResult = .init()
        return response
    }
}

private struct GatewayDomainFixture: Sendable {
    let roomID = try! RoomID("00000000-0000-0000-0000-000000000011")
    let userID = try! UserID("00000000-0000-0000-0000-000000000012")
    let deviceID = try! DeviceID("00000000-0000-0000-0000-000000000013")
    let clientMessageID = try! ClientMessageID("00000000-0000-0000-0000-000000000014")
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let profile: RoomCapacityProfile
    let roomState: V2RoomCommandState
    let shardState: ShardAdmissionState

    init() throws {
        profile = try .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 7)
        roomState = try .init(roomID: roomID, nextRoomSequence: 1, admission: .init(eligibleMemberCount: 3, commandWindow: .init(limit: 10)))
        shardState = try .init(lease: .init(id: try .init("00000000-0000-0000-0000-000000000015"), generation: 1, validUntil: now.addingTimeInterval(60), commandWindow: .init(limit: 10)))
    }

    var identity: V2AuthenticatedConnection { .init(userID: userID, deviceID: deviceID, capabilityProfile: "base") }

    func sendService(store: any V2RoomWriteStore) -> V2SendMessageService {
        V2SendMessageService(store: store, capacityProfile: try! .init(id: "standard", limits: profile), limits: try! .init(maxUTF8Bytes: 16), now: { now })
    }

    func syncService() -> V2SyncService { .init(store: GatewayRejectingSyncStore()) }
}

private actor GatewaySnapshotClockStore: V2SyncStore {
    let snapshotID = SnapshotID(uuid: UUID())
    var calls = 0
    private var retryAfter: Double?
    private var expiresAt: Date

    init(retryAfter: Double? = nil, expiresAt: Date = Date(timeIntervalSince1970: 0)) {
        self.retryAfter = retryAfter
        self.expiresAt = expiresAt
    }

    func setRetryAfter(_ value: Double) { retryAfter = value }
    func setExpiry(_ value: Date) { expiresAt = value }

    func pull(userID _: UserID, deviceID _: DeviceID, syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot _: Bool, now _: Date) -> V2SyncPullResult {
        calls += 1
        if let retryAfter { return .resetPreparing(snapshotID: snapshotID, generation: 1, retryAfter: retryAfter) }
        return .resetRequired(snapshotID: snapshotID, generation: 1, baseSequence: 7, expiresAt: expiresAt)
    }

    func fetchSnapshotManifest(userID _: UserID, deviceID _: DeviceID, snapshotID: SnapshotID, generation: UInt64, now _: Date) throws -> V2SnapshotManifest {
        calls += 1
        return try .init(snapshotID: snapshotID, generation: generation, baseSequence: 7,
            rootDigest: "fixture-digest", schemaVersion: 1, capabilityProfile: "base",
            pageCount: 0, totalItems: 0, totalBytes: 0,
            nextSyncToken: .init("fixture-sync-token"), receipt: .init("fixture-sync-receipt"), expiresAt: expiresAt)
    }

    func acknowledge(userID _: UserID, deviceID _: DeviceID, generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) throws {
        throw CancellationError()
    }
    func fetchSnapshotPage(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, rootDigest _: String, index _: UInt32, now _: Date) throws -> V2SnapshotPage {
        throw CancellationError()
    }
    func acknowledgeSnapshot(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, baseSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) throws {
        throw CancellationError()
    }
}

private struct GatewayRejectingSyncStore: V2SyncStore {
    var onPull: @Sendable (UserID, DeviceID, Bool) -> Void = { _, _, _ in }

    func pull(userID: UserID, deviceID: DeviceID, syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot: Bool, now _: Date) async throws -> V2SyncPullResult {
        onPull(userID, deviceID, requireSnapshot)
        throw V2SyncStoreError.invalidOrExpiredSyncToken
    }

    func acknowledge(userID _: UserID, deviceID _: DeviceID, generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) async throws {
        throw V2SyncStoreError.invalidOrExpiredSyncReceipt
    }

    func fetchSnapshotManifest(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, now _: Date) async throws -> V2SnapshotManifest {
        throw V2SyncStoreError.snapshotExpiredOrInvalid
    }
    func fetchSnapshotPage(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, rootDigest _: String, index _: UInt32, now _: Date) async throws -> V2SnapshotPage {
        throw V2SyncStoreError.snapshotExpiredOrInvalid
    }
    func acknowledgeSnapshot(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, baseSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) async throws {}
}

private actor GatewaySyncBoundaryStore: V2SyncStore {
    let snapshotID = SnapshotID(uuid: UUID())
    var calls = 0
    var lastGeneration: UInt64?
    var lastSequence: UInt64?

    private func record(generation: UInt64, sequence: UInt64? = nil) throws {
        calls += 1
        lastGeneration = generation
        lastSequence = sequence
        // Mirror the persistence range so the test also catches a request
        // error being misreported as a retryable server failure.
        guard Int64(exactly: generation) != nil,
              sequence.map({ Int64(exactly: $0) != nil }) ?? true else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard generation > 0 else { throw V2SyncStoreError.generationMismatch }
    }
    func pull(userID _: UserID, deviceID _: DeviceID, syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot _: Bool, now _: Date) throws -> V2SyncPullResult { throw CancellationError() }
    func acknowledge(userID _: UserID, deviceID _: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt _: V2SyncReceipt, now _: Date) throws {
        try record(generation: generation, sequence: highestContiguousSequence)
    }
    func fetchSnapshotManifest(userID _: UserID, deviceID _: DeviceID, snapshotID: SnapshotID, generation: UInt64, now: Date) throws -> V2SnapshotManifest {
        try record(generation: generation)
        return try .init(snapshotID: snapshotID, generation: generation, baseSequence: 0, rootDigest: "boundary-root",
            schemaVersion: V2SnapshotProjectionV3Codec.schemaVersion, capabilityProfile: "base", pageCount: 1,
            totalItems: 1, totalBytes: 4, nextSyncToken: .init("boundary-token"), receipt: .init("boundary-receipt"),
            expiresAt: now.addingTimeInterval(60))
    }
    func fetchSnapshotPage(userID _: UserID, deviceID _: DeviceID, snapshotID: SnapshotID, generation: UInt64, rootDigest: String, index: UInt32, now _: Date) throws -> V2SnapshotPage {
        try record(generation: generation)
        let key = try V2SnapshotProjectionKey(projectionKind: "relationship", entityKey: "boundary-peer")
        return .init(snapshotID: snapshotID, generation: generation, rootDigest: rootDigest, index: index,
            firstKey: key, lastKey: key, itemCount: 1, digest: "page-digest", payload: Data("page".utf8))
    }
    func acknowledgeSnapshot(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt _: V2SyncReceipt, now _: Date) throws {
        try record(generation: generation, sequence: baseSequence)
    }
}

private actor GatewayRecoveringSyncStore: V2SyncStore {
    private var failure: V2SyncStoreError?
    var calls = 0

    init(failure: V2SyncStoreError) { self.failure = failure }
    func recover() { failure = nil }

    func pull(userID _: UserID, deviceID _: DeviceID, syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot: Bool, now _: Date) throws -> V2SyncPullResult {
        calls += 1
        if let failure { throw failure }
        if requireSnapshot { return .resetPreparing(snapshotID: .init(uuid: UUID()), generation: 2, retryAfter: 1) }
        return try .ready(generation: 1, records: [], nextSyncToken: .init("recovered-token"), receipt: .init("recovered-receipt"), hasMore: false)
    }
    func acknowledge(userID _: UserID, deviceID _: DeviceID, generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) throws {
        throw CancellationError()
    }
    func fetchSnapshotManifest(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, now _: Date) throws -> V2SnapshotManifest {
        throw CancellationError()
    }
    func fetchSnapshotPage(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, rootDigest _: String, index _: UInt32, now _: Date) throws -> V2SnapshotPage {
        throw CancellationError()
    }
    func acknowledgeSnapshot(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, baseSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) throws {
        throw CancellationError()
    }
}

private struct GatewayPersonalTimestampFailure: V2ConversationCapabilitiesStore {
    let error: V2ConversationCapabilitiesStoreError
    func recover(actorUserID:UserID,request:V2PersonalPreferenceRecoveryRequest,now:Date) async throws -> V2PersonalPreferenceRecoveryResult { throw error }
    func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand, now: Date) async throws -> V2PersonalPreferenceReceipt { throw error }
    func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand, now: Date) async throws -> V2PersonalPreferenceReceipt { throw error }
}

/// 会话摘要假存储：记录调用者与游标，按构造时给定的单行摘要回答。
///
/// 只要给出水位就返回 `hasMore`，用于验证网关确实把下一页游标发了出去。


private actor GatewayMembershipDirectoryStore: V2RoomMembershipDirectoryStore {
    private var capturedActor: UserID?

    func list(_ request: V2RoomMembershipDirectoryRequest) throws -> V2RoomMembershipDirectoryPage {
        capturedActor = request.actorUserID
        return .init(
            roomID: request.roomID,
            membershipRevision: 4,
            actorRole: .owner,
            entries: [
                .init(
                    userID: request.actorUserID,
                    role: .owner,
                    publicIdentity: try! .init(userID: request.actorUserID, handle: .init("owner_1"), displayName: "群主", accountKind: .regular)
                )
            ],
            nextCursor: nil
        )
    }

    func actor() -> UserID? { capturedActor }
}





private actor GatewayGroupEventLogStore: V2GroupEventLogStore {
    private var capturedActor: UserID?

    func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) throws -> V2GroupEventLogPage {
        try .init(roomID: roomID, events: [], nextRoomSequence: afterRoomSequence, hasMore: false)
    }

    func subscribe(roomID: RoomID, actorUserID: UserID) throws -> V2GroupEventSubscription {
        capturedActor = actorUserID
        return try .init(roomID: roomID, highWatermark: 91)
    }

    func actor() -> UserID? { capturedActor }
}

private struct GatewaySizedGroupEventLogStore: V2GroupEventLogStore {
    let page: V2GroupEventLogPage

    func pull(roomID _: RoomID, actorUserID _: UserID, afterRoomSequence _: UInt64, pageSize _: Int) async throws -> V2GroupEventLogPage {
        page
    }

    func subscribe(roomID: RoomID, actorUserID _: UserID) async throws -> V2GroupEventSubscription {
        try .init(roomID: roomID, highWatermark: page.nextRoomSequence)
    }
}





extension V2GatewayDomainCommandHandlerTests {
    @Test("RoomRef Gateway call leaves the sole read permit for Host SQL")
    func roomRefGatewayAndHostShareControllerWithoutDeadlock() async throws {
        let fixture = try GatewayDomainFixture()
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 1,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            timeout: .milliseconds(40)))
        // Fill the other foreground reservation: a Gateway read permit would
        // consume the sole remaining slot and strand its own Host SQL call.
        #expect(await admission.acquire(.foregroundWrite) == .admitted)
        let reader = GatewayHostAdmittedPolicyReader(admission: admission)
        let handler = makeGatewayDomainCommandHandler(
            groupRolePolicyBaseline: reader, sync: fixture.syncService(),
            databaseWorkAdmission: admission, roomCommandsHostAdmitted: true)
        var request = IMV2Envelope()
        request.getGroupRolePolicyBaseline.roomID = fixture.roomID.rawValue
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.groupRolePolicyBaseline.roomID == fixture.roomID.rawValue)
        #expect(await reader.calls == 1)
        let snapshot = await admission.snapshot()
        #expect(snapshot.interactiveRead.admittedRequests == 1)
        #expect(snapshot.interactiveRead.inFlight == 0)
        await admission.release(.foregroundWrite)
    }

    @Test("production Gateway still admits local user-directory control reads")
    func hostAdmittedRoomModeKeepsControlAdmission() async throws {
        let fixture = try GatewayDomainFixture()
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1, maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1, maximumForegroundWriteQueued: 1,
            maximumInteractiveReadQueued: 1, maximumSyncQueued: 1,
            timeout: .milliseconds(20)))
        #expect(await admission.acquire(.foregroundWrite) == .admitted)
        #expect(await admission.acquire(.interactiveRead) == .admitted)
        let handler = makeGatewayDomainCommandHandler(
            sync: fixture.syncService(), databaseWorkAdmission: admission,
            roomCommandsHostAdmitted: true)
        var request = IMV2Envelope()
        request.userRoomDirectoryList.pageSize = 10
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "SERVER_BUSY")
        await admission.release(.interactiveRead)
        await admission.release(.foregroundWrite)
    }

    @Test("policy baseline uses authenticated identity and emits both roles including empty")
    func groupRolePolicyBaselineWire() async throws {
        let fixture = try GatewayDomainFixture()
        let reader = GatewayPolicyBaselineReader(scenario: "valid")
        let handler = makeGatewayDomainCommandHandler( groupRolePolicyBaseline: reader, sync: fixture.syncService())
        var request = IMV2Envelope(); request.requestID = 10; request.protocolVersion = IMV2ProtocolVersion.current
        request.getGroupRolePolicyBaseline.roomID = fixture.roomID.rawValue
        let decoded = try V2ServerProtobufFrameCodec.decode(V2ServerProtobufFrameCodec.encode(request, frameVersion: UInt8(IMV2ProtocolVersion.current)))
        let response = try await handler.handle(envelope: decoded, identity: fixture.identity)
        #expect(response.groupRolePolicyBaseline.roomID == fixture.roomID.rawValue)
        #expect(response.groupRolePolicyBaseline.permissionRevision == 4)
        #expect(response.groupRolePolicyBaseline.membershipRevision == 0)
        #expect(response.groupRolePolicyBaseline.policies.map(\.role) == ["admin", "member"])
        #expect(response.groupRolePolicyBaseline.policies[0].permissions.map(\.permission) == ["invite_members"])
        #expect(response.groupRolePolicyBaseline.policies[1].permissions.isEmpty)
        #expect(await reader.calls() == [.init(room: fixture.roomID, actor: fixture.userID)])
    }

    @Test("policy baseline failures have stable protocol errors", arguments: ["forbidden", "notFound", "ownerChanged", "unavailable", "wrongRoom", "invalid"])
    func groupRolePolicyBaselineErrors(scenario: String) async throws {
        let fixture = try GatewayDomainFixture()
        let reader = GatewayPolicyBaselineReader(scenario: scenario)
        let handler = makeGatewayDomainCommandHandler( groupRolePolicyBaseline: reader, sync: fixture.syncService())
        var request = IMV2Envelope(); request.getGroupRolePolicyBaseline.roomID = scenario == "invalid" ? "invalid" : fixture.roomID.rawValue
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        let code = switch scenario { case "forbidden": "FORBIDDEN"; case "notFound": "NOT_FOUND"; case "ownerChanged": "ROOM_OWNER_CHANGED"; case "invalid": "INVALID_ARGUMENT"; default: "UNAVAILABLE" }
        #expect(response.error.code == code)
        #expect(response.error.retryable == ["ownerChanged", "unavailable", "wrongRoom"].contains(scenario))
        if scenario == "invalid" { #expect(await reader.calls().isEmpty) }
    }
}

private actor GatewayHostAdmittedPolicyReader: V2GroupRolePolicyBaselineReading {
    let admission: V2DatabaseWorkAdmissionController
    private(set) var calls = 0
    init(admission: V2DatabaseWorkAdmissionController) { self.admission = admission }

    func readRolePolicyBaseline(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupRolePolicyBaseline {
        try await v2WithAdmittedRoomDatabaseWork(admission, workClass: .interactiveRead,
            callerDeadline: .now + .milliseconds(200)) {
            await self.recordCall()
            return try V2GroupRolePolicyBaseline(roomID: roomID, permissionRevision: 4,
                membershipRevision: 0, roomSequence: 9,
                adminPermissions: [.inviteMembers], memberPermissions: [])
        }
    }

    private func recordCall() { calls += 1 }
}

private actor GatewayPolicyBaselineReader: V2GroupRolePolicyBaselineReading {
    struct Call: Equatable { let room: RoomID; let actor: UserID }
    let scenario: String
    private var values: [Call] = []
    init(scenario: String) { self.scenario = scenario }
    func calls() -> [Call] { values }
    func readRolePolicyBaseline(roomID: RoomID, actorUserID: UserID) throws -> V2GroupRolePolicyBaseline {
        values.append(.init(room: roomID, actor: actorUserID))
        switch scenario {
        case "forbidden": throw V2GroupRolePolicyBaselineError.actorNotMember
        case "notFound": throw V2GroupRolePolicyBaselineError.roomNotFound
        case "ownerChanged": throw V2RoomShardRouteError.routeConflict
        case "unavailable": throw V2GroupRolePolicyBaselineError.corruptPersistenceState
        default: break
        }
        return try .init(roomID: scenario == "wrongRoom" ? .init("00000000-0000-0000-0000-000000ABCDEF") : roomID, permissionRevision: 4, membershipRevision: 0, roomSequence: 9, adminPermissions: [.inviteMembers], memberPermissions: [])
    }
}

private actor GatewayOwnerChangedReadReceiptStore: V2ReadReceiptStore {
    private var received: [String] = []
    func record(command: V2RecordReadReceiptCommand, now: Date) throws -> V2ReadReceiptOutcome { received.append("record"); throw V2ReadReceiptStoreError.ownerChanged }
    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) throws -> V2ReadReceiptReadersPage { received.append("readers"); throw V2ReadReceiptStoreError.ownerChanged }
    func setPreferences(command: V2SetReadReceiptPreferencesCommand, now: Date) throws -> V2SetReadReceiptPreferencesOutcome { throw V2ReadReceiptStoreError.ownerChanged }
    func calls() -> [String] { received }
}

// Returns domain outputs directly so response encoding is exercised independently of storage validation.
private actor GatewayResponseClockStore: V2ReadReceiptStore, V2LiveActivityStore, V2MessageEditStore, V2MessageWithdrawalStore, V2MessageReactionStore,
    V2ConversationCapabilitiesStore, V2GroupCapabilitiesStore {
    private var date: Date
    private var replay: Bool
    private let muteExpiryOnly: Bool
    private(set) var calls = 0
    init(date: Date, replay: Bool, muteExpiryOnly: Bool) { self.date = date; self.replay = replay; self.muteExpiryOnly = muteExpiryOnly }
    func recover(at date: Date) { self.date = date; replay = true }
    func setConversationState(actorUserID:UserID,command:V2ConversationStateCommand,now:Date) throws -> V2PersonalPreferenceReceipt {
        calls += 1
        let value=V2ConversationState(roomID:command.roomID,isPinned:command.isPinned,isArchived:command.isArchived,muteUntil:muteExpiryOnly ? date:nil,updatedAt:muteExpiryOnly ? now:date,revision:.init(rawValue:1)!)
        return try .init(identity:command.identity(actorUserID:actorUserID),fingerprint:command.fingerprint(actorUserID:actorUserID),outcome:.committed(.conversationState(value)),resolvedAtMilliseconds:1)
    }
    func setMessageFavorite(actorUserID:UserID,command:V2MessageFavoriteCommand,now:Date) throws -> V2PersonalPreferenceReceipt {
        calls += 1
        let value=V2MessageFavorite(roomID:command.roomID,messageID:command.messageID,isFavorited:command.isFavorited,updatedAt:date,revision:.init(rawValue:1)!)
        return try .init(identity:command.identity(actorUserID:actorUserID),fingerprint:command.fingerprint(actorUserID:actorUserID),outcome:.committed(.messageFavorite(value)),resolvedAtMilliseconds:1)
    }
    func recover(actorUserID:UserID,request:V2PersonalPreferenceRecoveryRequest,now:Date) -> V2PersonalPreferenceRecoveryResult { .unresolved }
    func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> {
        calls += 1
        let value = try V2PinnedMessage(roomID: command.roomID, messageID: command.messageID, isPinned: command.isPinned, roomSequence: 3, updatedAt: date)
        return replay ? .idempotent(value) : .applied(value)
    }
    func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> {
        calls += 1
        let value = try V2GroupAnnouncement(roomID: command.roomID, body: command.body, revision: 2, roomSequence: 3, updatedAt: date)
        return replay ? .idempotent(value) : .applied(value)
    }
    func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange> { throw CancellationError() }
    func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> { throw CancellationError() }

    func edit(command: V2EditMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2MessageEditOutcome {
        calls += 1
        let value = try V2MessageEdit(roomID: command.roomID, messageID: command.messageID, text: command.text,
            messageRevision: 2, roomSequence: 3, eventID: eventID, createdAt: date)
        return replay ? .idempotent(value) : .edited(value)
    }
    func withdraw(command: V2WithdrawMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2MessageWithdrawalOutcome {
        calls += 1
        let value = try V2MessageWithdrawal(roomID: command.roomID, messageID: command.messageID,
            messageRevision: 2, roomSequence: 3, eventID: eventID, createdAt: date)
        return replay ? .idempotent(value) : .withdrawn(value)
    }
    func change(command: V2ChangeMessageReactionCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2MessageReactionOutcome {
        calls += 1
        let value = try V2MessageReactionChange(roomID: command.roomID, messageID: command.messageID, actorUserID: command.actorUserID,
            reaction: command.reaction, action: command.action, roomSequence: 3, eventID: eventID, createdAt: date)
        return replay ? .idempotent(value) : .changed(value)
    }
    func change(command: V2ChangeRoomMembershipCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2RoomMembershipChangeOutcome {
        calls += 1
        let value = try V2RoomMembershipChange(roomID: command.roomID, targetUserID: command.targetUserID, action: command.action,
            membershipRevision: 2, roomSequence: 3, eventID: eventID, createdAt: date)
        return replay ? .idempotent(value) : .changed(value)
    }
    func apply(command: V2ModerationCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2ModerationOutcome {
        calls += 1
        let value = try V2ModerationResult(roomID: command.roomID, operationID: command.operationID, action: command.action,
            targetUserID: command.targetUserID, messageID: command.messageID, messageRevision: command.action == .redactMessage ? 2 : nil,
            membershipRevision: command.action == .removeMember ? 2 : nil, muteUntil: muteExpiryOnly ? date : command.muteUntil,
            roomSequence: 3, eventID: eventID, createdAt: muteExpiryOnly ? now : date)
        return replay ? .idempotent(value) : .applied(value)
    }


    func record(command: V2RecordReadReceiptCommand, now: Date) throws -> V2ReadReceiptOutcome {
        calls += 1
        let value = try V2ReadReceipt(roomID: command.roomID, userID: command.actorUserID, readThroughRoomSequence: command.readThroughRoomSequence, recordedAt: date)
        return replay ? .idempotent(value) : .recorded(value)
    }
    func setPreferences(command: V2SetReadReceiptPreferencesCommand, now: Date) -> V2SetReadReceiptPreferencesOutcome {
        calls += 1
        let value = V2ReadReceiptPreferences(allowsDirectReadReceipts: command.allowsDirectReadReceipts, allowsGroupReadReceipts: command.allowsGroupReadReceipts, updatedAt: date)
        return replay ? .idempotent(value) : .updated(value)
    }
    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) throws -> V2ReadReceiptReadersPage { throw CancellationError() }



    func setPreferences(command: V2SetLiveActivityPreferencesCommand, now: Date) -> V2SetLiveActivityPreferencesOutcome {
        calls += 1
        let value = V2LiveActivityPreferences(allowsOnlinePresence: command.allowsOnlinePresence, allowsTypingIndicators: command.allowsTypingIndicators, updatedAt: date)
        return replay ? .idempotent(value) : .updated(value)
    }
    func preferences(userID: UserID, now: Date) -> V2LiveActivityPreferences {
        calls += 1
        return .init(allowsOnlinePresence: true, allowsTypingIndicators: true, updatedAt: date)
    }
    func presence(roomID: RoomID, viewerUserID: UserID, now: Date) -> V2PresenceState {
        calls += 1
        return .init(roomID: roomID, targetUserID: .init(uuid: UUID()), isOnline: true, expiresAt: date)
    }
    func authorizeTyping(roomID: RoomID, actorUserID: UserID, now: Date) throws { throw CancellationError() }
    func authorizeObservation(roomID: RoomID, viewerUserID: UserID, subjectUserID: UserID, now: Date) throws { throw CancellationError() }
    func allowsOnlinePresence(userID: UserID) throws -> Bool { throw CancellationError() }
}

private actor GatewayReadReceiptSequenceStore: V2ReadReceiptStore {
    private(set) var calls = 0
    private var receipt: V2ReadReceipt?
    func record(command: V2RecordReadReceiptCommand, now: Date) throws -> V2ReadReceiptOutcome {
        calls += 1
        // Model the PostgreSQL adapter's existing signed binding boundary.
        guard Int64(exactly: command.readThroughRoomSequence) != nil else { throw V2ReadReceiptStoreError.corruptPersistenceState }
        if let receipt { return .idempotent(receipt) }
        let value = try V2ReadReceipt(roomID: command.roomID, userID: command.actorUserID,
            readThroughRoomSequence: command.readThroughRoomSequence, recordedAt: now)
        receipt = value
        return .recorded(value)
    }
    func setPreferences(command: V2SetReadReceiptPreferencesCommand, now: Date) throws -> V2SetReadReceiptPreferencesOutcome { throw CancellationError() }
    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) throws -> V2ReadReceiptReadersPage { throw CancellationError() }
}

private struct GatewayMovedMembershipDirectory: V2RoomMembershipDirectoryStore {
    func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage {
        throw V2RoomMembershipDirectoryError.ownerChanged
    }
}
