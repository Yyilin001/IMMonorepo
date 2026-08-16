import Foundation
import IMV2Core

/// The transport-neutral half of a gateway connection. TLS is deliberately
/// terminated outside this actor; callers feed only decrypted bytes and write
/// the returned bytes back to the same connection. This keeps framing,
/// lifecycle fencing, and domain dispatch testable without a socket.
public actor V2GatewayByteStream {
    private var decoder: V2FrameDecoder
    private let frameLimits: V2FrameLimits
    private let session: V2GatewaySession
    private let handler: any V2GatewayCommandHandler
    private let connectionID: UUID
    private let registry: V2DeviceConnectionRegistry
    private var registeredIdentity: V2AuthenticatedConnection?
    // A revocation worker must not advance its durable cursor until the
    // transport confirms the local channel has closed. The handler therefore
    // bridges the NIO close future into this actor rather than merely
    // scheduling a best-effort close.
    private var deviceRevocationHandler: (@Sendable () async -> Void)?
    private var outboundWriter: (@Sendable (Data) async -> Void)?
    /// Once the owning transport closes, late callback installation must not
    /// recreate a stream -> callback -> channel-handler -> stream retain
    /// cycle. This also fences the handlerAdded/channelInactive race.
    private var transportClosed = false

    public init(
        frameLimits: V2FrameLimits,
        session: V2GatewaySession,
        handler: any V2GatewayCommandHandler,
        connectionID: UUID = UUID(),
        registry: V2DeviceConnectionRegistry
    ) {
        self.decoder = .init(limits: frameLimits)
        self.frameLimits = frameLimits
        self.session = session
        self.handler = handler
        self.connectionID = connectionID
        self.registry = registry
    }

    /// Accepts any fragment produced by a TLS stream. One input may produce no
    /// response (partial frame) or several responses (coalesced frames).
    /// Framing or command failures close the session so a malformed stream
    /// cannot continue from an unknown protocol state.
    public func receive(_ bytes: Data) async throws -> [Data] {
        var responses: [Data] = []
        try await receive(bytes) { response in
            responses.append(response)
        }
        return responses
    }

    /// Production transports use this form so replies can cross their
    /// writability boundary one at a time instead of materializing a second
    /// response batch beside the decoded frame batch.
    public func receive(
        _ bytes: Data,
        respond: (Data) async throws -> Void
    ) async throws {
        do {
            let inbound = try decoder.append(bytes)
            for frame in inbound {
                let inboundEnvelope = try V2ServerProtobufFrameCodec.decode(frame)
                let response: V2Frame
                if await session.authenticatedIdentity() == nil {
                    response = try await session.receiveBootstrap(frame)
                } else {
                    response = try await session.receiveAuthenticated(frame, handler: handler)
                }
                try await registerAuthenticatedDeviceIfNeeded()
                try await updateHybridGroupSubscription(inbound: inboundEnvelope, response: response)
                try await respond(try V2FrameCodec.encode(response, limits: frameLimits))
            }
        } catch {
            // A framing failure may leave an invalid prefix buffered. Session
            // closure fences further commands, but resetting the parser also
            // prevents a later receive from rethrowing stale framing data.
            decoder = .init(limits: frameLimits)
            await unregisterAuthenticatedDevice()
            await session.close()
            throw error
        }
    }

    /// Must be called when the underlying TLS channel reaches EOF. A trailing
    /// partial frame is a protocol failure, not an ignored disconnect.
    public func finish() async throws {
        detachTransport()
        do {
            try decoder.finish()
            await unregisterAuthenticatedDevice()
            await session.close()
        } catch {
            await unregisterAuthenticatedDevice()
            await session.close()
            throw error
        }
    }

    public func revokeDevice() async {
        await unregisterAuthenticatedDevice()
        await session.revokeDevice()
        if let deviceRevocationHandler {
            await deviceRevocationHandler()
        }
        detachTransport()
    }

    public func setDeviceRevocationHandler(_ handler: @escaping @Sendable () async -> Void) {
        guard !transportClosed else { return }
        deviceRevocationHandler = handler
    }

    /// Live availability is explicitly best effort. The NIO owner drops it
    /// when its outbound channel is not writable; recovery is always SYNC_PULL.
    public func setOutboundWriter(_ writer: @escaping @Sendable (Data) async -> Void) {
        guard !transportClosed else { return }
        outboundWriter = writer
    }

    /// Installs both channel callbacks in one actor turn. Installing them in
    /// separate awaits allowed EOF to clear the first callback before the
    /// second one was installed, retaining a closed NIO pipeline forever.
    public func attachTransport(
        deviceRevocationHandler: @escaping @Sendable () async -> Void,
        outboundWriter: @escaping @Sendable (Data) async -> Void
    ) -> Bool {
        guard !transportClosed else { return false }
        self.deviceRevocationHandler = deviceRevocationHandler
        self.outboundWriter = outboundWriter
        return true
    }

    /// Transport admission uses this only to cancel its absolute pre-auth
    /// deadline. Identity data remains inside the session actor.
    public func isAuthenticated() async -> Bool {
        await session.authenticatedIdentity() != nil
    }

    public func sendSyncAvailable(eventID: UInt64, highWatermark: UInt64) async {
        guard let version = await session.authenticatedProtocolVersion(), let outboundWriter else { return }
        var envelope = IMV2Envelope()
        envelope.requestID = 0
        envelope.protocolVersion = UInt32(version)
        envelope.syncAvailable = .init()
        envelope.syncAvailable.eventID = eventID
        envelope.syncAvailable.highWatermark = highWatermark
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version),
              let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits)
        else { return }
        await outboundWriter(bytes)
    }

    /// A best-effort foreground wake over the same authenticated TLS stream.
    /// Its payload is deliberately metadata-only; cursor pull remains the
    /// durable and authorization-checked read path.
    public func sendGroupEventAvailable(roomID: RoomID, highWatermark: UInt64) async {
        guard let version = await session.authenticatedProtocolVersion(), let outboundWriter else { return }
        var envelope = IMV2Envelope()
        envelope.requestID = 0
        envelope.protocolVersion = UInt32(version)
        envelope.groupEventAvailable = .init()
        envelope.groupEventAvailable.roomID = roomID.rawValue
        envelope.groupEventAvailable.highWatermark = highWatermark
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version),
              let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits)
        else { return }
        await outboundWriter(bytes)
    }

    public func sendPresenceState(_ state: V2PresenceState) async {
        guard let version = await session.authenticatedProtocolVersion(), let outboundWriter else { return }
        var envelope = IMV2Envelope(); envelope.requestID = 0; envelope.protocolVersion = UInt32(version); envelope.presenceChanged = .init()
        envelope.presenceChanged.roomID = state.roomID.rawValue
        envelope.presenceChanged.targetUserID = state.targetUserID.rawValue
        envelope.presenceChanged.isOnline = state.isOnline
        envelope.presenceChanged.expiresAtMs = Int64(state.expiresAt.timeIntervalSince1970 * 1_000)
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version), let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits) else { return }
        await outboundWriter(bytes)
    }

    public func sendTypingState(_ state: V2TypingState) async {
        guard let version = await session.authenticatedProtocolVersion(), let outboundWriter else { return }
        var envelope = IMV2Envelope(); envelope.requestID = 0; envelope.protocolVersion = UInt32(version); envelope.typingStateChanged = .init()
        envelope.typingStateChanged.roomID = state.roomID.rawValue
        envelope.typingStateChanged.userID = state.userID.rawValue
        envelope.typingStateChanged.isTyping = state.isTyping
        envelope.typingStateChanged.expiresAtMs = Int64(state.expiresAt.timeIntervalSince1970 * 1_000)
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version), let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits) else { return }
        await outboundWriter(bytes)
    }

    private func detachTransport() {
        transportClosed = true
        deviceRevocationHandler = nil
        outboundWriter = nil
    }

    private func registerAuthenticatedDeviceIfNeeded() async throws {
        guard registeredIdentity == nil, let identity = await session.authenticatedIdentity() else { return }
        registeredIdentity = identity
        let accepted = await registry.register(self, connectionID: connectionID, identity: identity)
        guard accepted, registeredIdentity == identity, !transportClosed else {
            if registeredIdentity == identity { registeredIdentity = nil }
            await registry.unregister(connectionID: connectionID)
            throw V2GatewaySessionError.authenticatedConnectionLimit
        }
    }

    private func unregisterAuthenticatedDevice() async {
        guard registeredIdentity != nil else { return }
        registeredIdentity = nil
        await registry.unregister(connectionID: connectionID)
    }

    private func updateHybridGroupSubscription(inbound: IMV2Envelope, response: V2Frame) async throws {
        switch inbound.body {
        case .setLiveActivityPreferences:
            let responseEnvelope = try V2ServerProtobufFrameCodec.decode(response)
            guard case .liveActivityPreferencesSet(let updated)? = responseEnvelope.body
            else { return }
            guard await registry.applyLiveActivityPreferences(
                connectionID: connectionID,
                allowsOnlinePresence: updated.allowsOnlinePresence
            ) else { throw V2GatewaySessionError.authenticatedConnectionLimit }
        case .groupEventSubscribe(let request):
            let responseEnvelope = try V2ServerProtobufFrameCodec.decode(response)
            guard case .groupEventSubscribed(let subscribed)? = responseEnvelope.body,
                  subscribed.roomID == request.roomID
            else { return }
            await registry.subscribeForegroundGroup(self, connectionID: connectionID, roomID: try .init(request.roomID))
        case .groupEventUnsubscribe(let request):
            await registry.unsubscribeForegroundGroup(connectionID: connectionID, roomID: try .init(request.roomID))
        case .subscribePresence(let request):
            let responseEnvelope = try V2ServerProtobufFrameCodec.decode(response)
            guard case .presenceSubscribed(let subscribed)? = responseEnvelope.body,
                  subscribed.roomID == request.roomID,
                  let roomID = try? RoomID(request.roomID), let targetUserID = try? UserID(subscribed.targetUserID)
            else { return }
            await registry.subscribePresence(self, connectionID: connectionID, roomID: roomID, targetUserID: targetUserID)
        case .unsubscribePresence(let request):
            await registry.unsubscribePresence(connectionID: connectionID, roomID: try .init(request.roomID))
        case .subscribeTyping(let request):
            await registry.subscribeTyping(self, connectionID: connectionID, roomID: try .init(request.roomID))
        case .unsubscribeTyping(let request):
            await registry.unsubscribeTyping(connectionID: connectionID, roomID: try .init(request.roomID))
        case .setTypingState(let request):
            guard case .acknowledged? = try V2ServerProtobufFrameCodec.decode(response).body,
                  let identity = registeredIdentity
            else { return }
            await registry.notifyTyping(roomID: try .init(request.roomID), actorUserID: identity.userID, isTyping: request.isTyping, expiresAt: request.isTyping ? Date().addingTimeInterval(6) : Date())
        case .heartbeat:
            guard await registry.refreshLivePresence(connectionID: connectionID)
            else { throw V2GatewaySessionError.authenticatedConnectionLimit }
        default:
            return
        }
    }
}
