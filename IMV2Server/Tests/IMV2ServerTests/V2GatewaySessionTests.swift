import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

struct V2GatewaySessionTests {
    private let protocolVersion = UInt8(IMV2ProtocolVersion.current)

    @Test("zlib is negotiated explicitly and only group pages use the compressed response path")
    func negotiatesBoundedGroupPageCompression() async throws {
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: GatewayAuthFake(userID: try .init("user-a")),
            capabilityProfile: "base",
            supportedFrameCompression: .zlib,
            compressionThresholdBytes: 1,
            maximumCompressionExpansionRatio: 1_024,
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { Date(timeIntervalSince1970: 0) }
        )
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        hello.clientHello.supportedFrameCompressions = [.zlib]
        let helloResponse = try await session.receiveBootstrap(
            try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0)
        )
        #expect(helloResponse.flags.isEmpty)
        #expect(
            try V2ServerProtobufFrameCodec.decode(helloResponse)
                .serverHello.selectedFrameCompression == .zlib
        )

        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "device-a"
        let authenticated = try await session.receiveBootstrap(
            try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion)
        )
        #expect(authenticated.flags.isEmpty)
        #expect(
            try V2ServerProtobufFrameCodec.decode(authenticated)
                .authenticated.selectedFrameCompression == .zlib
        )

        var request = IMV2Envelope()
        request.requestID = 3
        request.protocolVersion = UInt32(protocolVersion)
        request.groupEventPull = .init()
        request.groupEventPull.roomID = "group-compression-test"
        let response = try await session.receiveAuthenticated(
            try V2ServerProtobufFrameCodec.encode(request, frameVersion: protocolVersion),
            handler: GroupPageCommandFake()
        )
        #expect(response.flags == [.compressed])
        #expect(
            try V2ServerProtobufFrameCodec.decode(
                response,
                compression: .zlib,
                maximumExpansionRatio: 1_024
            )
                .groupEventPage.events.count == 1
        )
    }

    @Test("authenticated group-page responses reuse the prepared payload without caching authorization")
    func reusesPreparedGroupPagePayload() async throws {
        let cache = V2PreparedGroupEventPageCache(configuration: .init(
            maximumEntries: 8,
            maximumBytes: 1_048_576,
            shardCount: 4
        ))
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: GatewayAuthFake(userID: try .init("user-a")),
            capabilityProfile: "base",
            preparedGroupEventPageCache: cache,
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { Date(timeIntervalSince1970: 0) }
        )
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await session.receiveBootstrap(
            try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0)
        )
        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "device-a"
        _ = try await session.receiveBootstrap(
            try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion)
        )

        func pull(_ requestID: UInt64) async throws -> V2Frame {
            var request = IMV2Envelope()
            request.requestID = requestID
            request.protocolVersion = UInt32(protocolVersion)
            request.groupEventPull = .init()
            request.groupEventPull.roomID = "group-compression-test"
            return try await session.receiveAuthenticated(
                try V2ServerProtobufFrameCodec.encode(request, frameVersion: protocolVersion),
                handler: GroupPageCommandFake()
            )
        }

        let first = try await pull(3)
        let second = try await pull(4)
        #expect(first.payload == second.payload)
        #expect(first.flags == [.headerBoundRequestID])
        #expect(second.flags == [.headerBoundRequestID])
        #expect(try V2ServerProtobufFrameCodec.decode(first).requestID == 3)
        #expect(try V2ServerProtobufFrameCodec.decode(second).requestID == 4)
        #expect(cache.snapshot().hits == 1)
        #expect(cache.snapshot().misses == 1)
    }

    @Test("protocol v21 dispatches authorized prepared pages without rebuilding the ordinary envelope")
    func dispatchesPreparedGroupPageHandler() async throws {
        let cache = V2PreparedGroupEventPageCache(configuration: .init(
            maximumEntries: 8,
            maximumBytes: 1_048_576,
            shardCount: 1
        ))
        let handler = PreparedGroupPageCommandFake()
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: GatewayAuthFake(userID: try .init("user-a")),
            capabilityProfile: "base",
            preparedGroupEventPageCache: cache,
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { Date(timeIntervalSince1970: 0) }
        )
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await session.receiveBootstrap(
            try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0)
        )
        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "device-a"
        _ = try await session.receiveBootstrap(
            try V2ServerProtobufFrameCodec.encode(
                authenticate,
                frameVersion: protocolVersion
            )
        )

        func pull(_ requestID: UInt64) async throws -> V2Frame {
            var request = IMV2Envelope()
            request.requestID = requestID
            request.protocolVersion = UInt32(protocolVersion)
            request.groupEventPull = .init()
            request.groupEventPull.roomID = PreparedGroupPageCommandFake.roomID.rawValue
            request.groupEventPull.pageSize = 100
            return try await session.receiveAuthenticated(
                try V2ServerProtobufFrameCodec.encode(
                    request,
                    frameVersion: protocolVersion
                ),
                handler: handler
            )
        }

        let first = try await pull(3)
        let second = try await pull(4)
        let decoded = try V2ServerProtobufFrameCodec.decode(second)

        #expect(first.payload == second.payload)
        #expect(decoded.requestID == 4)
        #expect(decoded.groupEventPage.events.map(\.roomSequence) == [1])
        #expect(await handler.preparedCalls == 2)
        #expect(await handler.ordinaryCalls == 0)
        #expect(cache.snapshot().misses == 1)
        #expect(cache.snapshot().hits == 1)
    }

    @Test("hello then authenticated device identity is the only session identity")
    func bootstrapAuthentication() async throws {
        let auth = GatewayAuthFake(userID: try .init("user-a"))
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: auth,
            capabilityProfile: "base",
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { Date(timeIntervalSince1970: 0) }
        )
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        let helloResponse = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0))
        #expect(try V2ServerProtobufFrameCodec.decode(helloResponse).serverHello.selectedProtocolVersion == UInt32(protocolVersion))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion))
        #expect(await session.authenticatedIdentity() == .init(userID: try .init("user-a"), deviceID: try .init("device-a"), capabilityProfile: "base"))

        var request = IMV2Envelope(); request.requestID = 3; request.protocolVersion = UInt32(protocolVersion); request.syncPull = .init()
        let response = try await session.receiveAuthenticated(try V2ServerProtobufFrameCodec.encode(request, frameVersion: protocolVersion), handler: GatewayCommandFake())
        #expect(try V2ServerProtobufFrameCodec.decode(response).error.code == "UNAVAILABLE")
    }

    @Test("hello device identity must match authentication")
    func rejectsHelloAuthenticationDeviceMismatch() async throws {
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: GatewayAuthFake(userID: try .init("user-a")),
            capabilityProfile: "base",
            commandAdmission: V2AllowingGatewayCommandAdmission()
        )
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        hello.clientHello.deviceID = "device-a"
        _ = try await session.receiveBootstrap(
            try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0)
        )

        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "device-b"
        await #expect(throws: V2GatewaySessionError.invalidAuthenticatePayload) {
            _ = try await session.receiveBootstrap(
                try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion)
            )
        }
    }

    @Test("gateway admission charges commands by bounded work amplification")
    func chargesAuthenticatedCommandsByWorkAmplification() async throws {
        let admission = RecordingGatewayCommandAdmission()
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: GatewayAuthFake(userID: try .init("user-a")),
            capabilityProfile: "base",
            commandAdmission: admission,
            now: { Date(timeIntervalSince1970: 0) }
        )

        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        hello.clientHello.deviceID = "device-a"
        _ = try await session.receiveBootstrap(
            try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0)
        )

        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "device-a"
        _ = try await session.receiveBootstrap(
            try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion)
        )

        func send(_ request: IMV2Envelope) async throws {
            _ = try await session.receiveAuthenticated(
                try V2ServerProtobufFrameCodec.encode(request, frameVersion: protocolVersion),
                handler: GatewayCommandFake()
            )
        }

        var heartbeat = IMV2Envelope()
        heartbeat.requestID = 3
        heartbeat.protocolVersion = UInt32(protocolVersion)
        heartbeat.heartbeat = .init()
        try await send(heartbeat)

        var syncPull = IMV2Envelope()
        syncPull.requestID = 4
        syncPull.protocolVersion = UInt32(protocolVersion)
        syncPull.syncPull = .init()
        syncPull.syncPull.maxRecords = 500
        try await send(syncPull)

        var groupPull = IMV2Envelope()
        groupPull.requestID = 5
        groupPull.protocolVersion = UInt32(protocolVersion)
        groupPull.groupEventPull = .init()
        groupPull.groupEventPull.pageSize = 500
        try await send(groupPull)

        var forward = IMV2Envelope()
        forward.requestID = 6
        forward.protocolVersion = UInt32(protocolVersion)
        forward.forwardMessages = .init()
        forward.forwardMessages.sourceMessageIds = (0..<10).map { "source-\($0)" }
        forward.forwardMessages.targetRoomIds = (0..<10).map { "target-\($0)" }
        try await send(forward)

        var appendMembers = IMV2Envelope()
        appendMembers.requestID = 7
        appendMembers.protocolVersion = UInt32(protocolVersion)
        appendMembers.appendGroupRoomCreationMembers = .init()
        appendMembers.appendGroupRoomCreationMembers.memberUserIds = (0..<64).map { "user-\($0)" }
        try await send(appendMembers)

        #expect(await admission.recordedCosts() == [0, 6, 6, 5, 3])
    }

    @Test("production receive returns the same validated request used for dispatch")
    func productionReceiveReturnsValidatedRequest() async throws {
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: GatewayAuthFake(userID: try .init("user-a")),
            capabilityProfile: "base",
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { Date(timeIntervalSince1970: 0) }
        )
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        let helloExchange = try await session.receive(
            try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0),
            handler: GatewayCommandFake()
        )
        #expect(helloExchange.request == hello)
        #expect(
            try V2ServerProtobufFrameCodec.decode(helloExchange.response)
                .serverHello.selectedCapabilityProfile == "base"
        )

        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "device-a"
        let authenticationExchange = try await session.receive(
            try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion),
            handler: GatewayCommandFake()
        )
        #expect(authenticationExchange.request == authenticate)

        var request = IMV2Envelope()
        request.requestID = 3
        request.protocolVersion = UInt32(protocolVersion)
        request.syncPull = .init()
        let exchange = try await session.receive(
            try V2ServerProtobufFrameCodec.encode(request, frameVersion: protocolVersion),
            handler: GatewayCommandFake()
        )
        #expect(exchange.request == request)
        #expect(exchange.responseEnvelope.requestID == request.requestID)
        #expect(try V2ServerProtobufFrameCodec.decode(exchange.response) == exchange.responseEnvelope)
    }

    @Test("bootstrap uses the authenticator's one combined identity and expiry read")
    func usesCombinedAuthenticationRead() async throws {
        let auth = CombinedGatewayAuthFake()
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 1),
            authenticator: auth,
            capabilityProfile: "base",
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { Date(timeIntervalSince1970: 10) }
        )
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion))

        #expect(await auth.readCount == 1)
    }

    @Test("gateway session enforces its configured protobuf nesting limit")
    func enforcesConfiguredProtobufNestingLimit() async throws {
        let auth = GatewayAuthFake(userID: try .init("user-a"))
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: auth,
            capabilityProfile: "base",
            maximumProtobufMessageDepth: 2,
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { Date(timeIntervalSince1970: 0) }
        )
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion))

        var nested = IMV2Envelope(); nested.requestID = 3; nested.protocolVersion = UInt32(protocolVersion); nested.syncBatch = .init(); nested.syncBatch.records = [.init()]
        let frame = try V2ServerProtobufFrameCodec.encode(nested, frameVersion: protocolVersion)
        await #expect(throws: V2ServerProtobufFrameCodecError.payloadDecodeFailed) {
            _ = try await session.receiveAuthenticated(frame, handler: GatewayCommandFake())
        }
    }

    @Test("an access-token lease expires an otherwise active session")
    func expiresAuthenticatedSessionLease() async throws {
        let clock = SessionClock(Date(timeIntervalSince1970: 10))
        let auth = GatewayAuthFake(userID: try .init("user-a"), expiresAt: Date(timeIntervalSince1970: 11))
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: auth,
            capabilityProfile: "base",
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { clock.now }
        )
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion))
        clock.now = Date(timeIntervalSince1970: 11)
        var request = IMV2Envelope(); request.requestID = 3; request.protocolVersion = UInt32(protocolVersion); request.heartbeat = .init()
        await #expect(throws: V2GatewaySessionError.sessionExpired) {
            _ = try await session.receiveAuthenticated(try V2ServerProtobufFrameCodec.encode(request, frameVersion: protocolVersion), handler: GatewayCommandFake())
        }
    }
}

private actor GatewayAuthFake: V2GatewayAuthenticator {
    let userID: UserID
    let expiresAt: Date?
    init(userID: UserID, expiresAt: Date? = nil) { self.userID = userID; self.expiresAt = expiresAt }
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) -> V2GatewayAuthentication {
        .init(userID: userID, expiresAt: expiresAt)
    }
}

private actor CombinedGatewayAuthFake: V2GatewayAuthenticator {
    private(set) var readCount = 0

    func authenticateSession(accessToken _: String, deviceID _: DeviceID) throws -> V2GatewayAuthentication {
        readCount += 1
        return try .init(
            userID: .init("combined-user"),
            expiresAt: Date(timeIntervalSince1970: 20)
        )
    }
}

private actor RecordingGatewayCommandAdmission: V2AuthenticatedGatewayCommandAdmitting {
    private var costs: [Int] = []

    func admit(identity _: V2AuthenticatedConnection, cost: Int, now _: Date) -> Bool {
        costs.append(cost)
        return true
    }

    func recordedCosts() -> [Int] { costs }
}

private final class SessionClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private struct GatewayCommandFake: V2GatewayCommandHandler {
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        var response = IMV2Envelope(); response.error = .init(); response.error.code = "UNAVAILABLE"; response.error.retryable = true
        return response
    }
}

private struct GroupPageCommandFake: V2GatewayCommandHandler {
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        var response = IMV2Envelope()
        response.groupEventPage = .init()
        response.groupEventPage.roomID = "group-compression-test"
        var event = IMV2GroupEvent()
        event.sourceEventID = "00000000-0000-0000-0000-000000000003"
        event.roomSequence = 1
        event.projectionKind = "message"
        event.payload = Data(repeating: 0x63, count: 8_192)
        response.groupEventPage.events = [event]
        return response
    }
}

private actor PreparedGroupPageCommandFake:
    V2GatewayCommandHandler,
    V2PreparedGroupEventCommandHandling {
    static let roomID = try! RoomID("00000000-0000-0000-0000-000000000901")
    private(set) var ordinaryCalls = 0
    private(set) var preparedCalls = 0

    func handle(
        envelope _: IMV2Envelope,
        identity _: V2AuthenticatedConnection
    ) async throws -> IMV2Envelope {
        ordinaryCalls += 1
        var response = IMV2Envelope()
        response.error = .init()
        response.error.code = "ORDINARY_PATH_USED"
        return response
    }

    func handlePreparedGroupEventPull(
        _ request: IMV2GroupEventPull,
        identity _: V2AuthenticatedConnection,
        originatingConnectionID _: UUID?,
        context: V2PreparedGroupEventCommandContext
    ) async throws -> V2PreparedGroupEventGatewayResponse {
        preparedCalls += 1
        let key = V2PreparedGroupEventPageCache.PageKey(
            protocolVersion: context.frameVersion,
            roomID: request.roomID,
            firstEventID: "00000000-0000-0000-0000-000000000902",
            lastEventID: "00000000-0000-0000-0000-000000000902",
            firstRoomSequence: 1,
            lastRoomSequence: 1,
            eventCount: 1,
            nextRoomSequence: 1,
            hasMore: false
        )
        let frame = try context.cache.frame(
            for: key,
            requestID: context.requestID,
            compression: context.compression,
            maximumUncompressedPayloadBytes: context.maximumUncompressedPayloadBytes,
            compressionThresholdBytes: context.compressionThresholdBytes,
            maximumExpansionRatio: context.maximumExpansionRatio
        ) {
            var response = IMV2Envelope()
            response.requestID = context.requestID
            response.protocolVersion = UInt32(context.frameVersion)
            response.groupEventPage = .init()
            response.groupEventPage.roomID = request.roomID
            response.groupEventPage.nextRoomSequence = 1
            var event = IMV2GroupEvent()
            event.sourceEventID = key.firstEventID
            event.roomSequence = 1
            event.projectionKind = "message"
            event.payload = Data("payload".utf8)
            response.groupEventPage.events = [event]
            return response
        }
        return .prepared(.init(
            frame: frame,
            roomID: Self.roomID,
            nextRoomSequence: 1,
            hasMore: false
        ))
    }
}
