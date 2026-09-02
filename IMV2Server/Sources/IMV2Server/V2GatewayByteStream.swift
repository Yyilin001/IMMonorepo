import Foundation
import IMV2Compression
import IMV2Core
import NIOCore
import Synchronization

/// One immutable server-push frame shared by every authorized local recipient
/// that negotiated the same protocol version. The bytes carry no
/// connection-specific state: audience selection and transport lifecycle
/// checks remain outside this value.
struct V2PreparedGatewayGroupEventAvailable: Sendable {
    let protocolVersion: UInt8
    /// `ByteBuffer` is a COW, `Sendable` value. One prepared group frame can
    /// therefore share its immutable storage across every authorized channel;
    /// a channel pipeline that needs to mutate its copy detaches normally.
    private let uncompressedBytes: ByteBuffer
    private let compressedBytes: ByteBuffer?

    init?(
        roomID: RoomID,
        highWatermark: UInt64,
        directEvent: V2DirectRoomLiveEvent?,
        frameLimits: V2FrameLimits,
        protocolVersion: UInt8 = UInt8(IMV2ProtocolVersion.current),
        compression: V2NegotiatedFrameCompression? = nil,
        maximumUncompressedPayloadBytes: Int = V2ServerProtobufFrameCodec
            .defaultMaximumUncompressedPayloadBytes,
        compressionThresholdBytes: Int = V2ServerProtobufFrameCodec
            .defaultCompressionThresholdBytes,
        maximumExpansionRatio: Int = V2ZlibFrameCompression.defaultMaximumExpansionRatio
    ) {
        var envelope = IMV2Envelope()
        envelope.requestID = 0
        envelope.protocolVersion = UInt32(protocolVersion)
        envelope.groupEventAvailable = .init()
        envelope.groupEventAvailable.roomID = roomID.rawValue
        envelope.groupEventAvailable.highWatermark = highWatermark
        if let directEvent,
           directEvent.roomID == roomID,
           directEvent.highWatermark == highWatermark {
            envelope.groupEventAvailable.sourceEventID = directEvent.sourceEventID.rawValue
            envelope.groupEventAvailable.roomSequence = directEvent.roomSequence
            envelope.groupEventAvailable.projectionKind = directEvent.projectionKind
            envelope.groupEventAvailable.eventPayload = directEvent.payload
        }
        guard let uncompressedBytes = Self.encodedBytes(
            envelope,
            frameLimits: frameLimits,
            protocolVersion: protocolVersion,
            compression: nil,
            maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
            compressionThresholdBytes: compressionThresholdBytes,
            maximumExpansionRatio: maximumExpansionRatio
        ) else { return nil }
        self.protocolVersion = protocolVersion
        self.uncompressedBytes = uncompressedBytes
        compressedBytes = compression.flatMap { compression in
            Self.encodedBytes(
                envelope,
                frameLimits: frameLimits,
                protocolVersion: protocolVersion,
                compression: compression,
                maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
                compressionThresholdBytes: compressionThresholdBytes,
                maximumExpansionRatio: maximumExpansionRatio
            )
        }
    }

    /// Encodes one room-local ordered group batch once. No connection-specific
    /// field is present, so the exact same immutable bytes may be enqueued on
    /// every authorized stream.
    init?(
        groupEvents: [V2DirectRoomLiveEvent],
        frameLimits: V2FrameLimits,
        protocolVersion: UInt8 = UInt8(IMV2ProtocolVersion.current),
        compression: V2NegotiatedFrameCompression? = nil,
        maximumUncompressedPayloadBytes: Int = V2ServerProtobufFrameCodec
            .defaultMaximumUncompressedPayloadBytes,
        compressionThresholdBytes: Int = V2ServerProtobufFrameCodec
            .defaultCompressionThresholdBytes,
        maximumExpansionRatio: Int = V2ZlibFrameCompression.defaultMaximumExpansionRatio
    ) {
        guard let first = groupEvents.first,
              let membershipRevision = first.groupMembershipRevision,
              first.recipientUserIDs.isEmpty,
              first.excludedConnectionID == nil,
              groupEvents.allSatisfy({ event in
                  event.roomID == first.roomID
                      && event.groupMembershipRevision == membershipRevision
                      && event.recipientUserIDs.isEmpty
                      && event.excludedConnectionID == nil
              })
        else { return nil }
        let ordered = v2GroupEventsOrderedByRoomSequence(groupEvents)
        var envelope = IMV2Envelope()
        envelope.requestID = 0
        envelope.protocolVersion = UInt32(protocolVersion)
        envelope.groupEventAvailable = .init()
        envelope.groupEventAvailable.roomID = first.roomID.rawValue
        envelope.groupEventAvailable.highWatermark = ordered.last?.roomSequence ?? first.highWatermark
        envelope.groupEventAvailable.liveEvents = ordered.map { event in
            var wire = IMV2GroupEvent()
            wire.sourceEventID = event.sourceEventID.rawValue
            wire.roomSequence = event.roomSequence
            wire.projectionKind = event.projectionKind
            wire.payload = event.payload
            return wire
        }
        guard let uncompressedBytes = Self.encodedBytes(
            envelope,
            frameLimits: frameLimits,
            protocolVersion: protocolVersion,
            compression: nil,
            maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
            compressionThresholdBytes: compressionThresholdBytes,
            maximumExpansionRatio: maximumExpansionRatio
        ) else { return nil }
        self.protocolVersion = protocolVersion
        self.uncompressedBytes = uncompressedBytes
        compressedBytes = compression.flatMap { compression in
            Self.encodedBytes(
                envelope,
                frameLimits: frameLimits,
                protocolVersion: protocolVersion,
                compression: compression,
                maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
                compressionThresholdBytes: compressionThresholdBytes,
                maximumExpansionRatio: maximumExpansionRatio
            )
        }
    }

    func bytes(for compression: V2NegotiatedFrameCompression?) -> ByteBuffer {
        compression == .zlib ? (compressedBytes ?? uncompressedBytes) : uncompressedBytes
    }

    private static func encodedBytes(
        _ envelope: IMV2Envelope,
        frameLimits: V2FrameLimits,
        protocolVersion: UInt8,
        compression: V2NegotiatedFrameCompression?,
        maximumUncompressedPayloadBytes: Int,
        compressionThresholdBytes: Int,
        maximumExpansionRatio: Int
    ) -> ByteBuffer? {
        guard let frame = try? V2ServerProtobufFrameCodec.encode(
            envelope,
            frameVersion: protocolVersion,
            compression: compression,
            maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
            compressionThresholdBytes: compressionThresholdBytes,
            maximumExpansionRatio: maximumExpansionRatio
        ) else { return nil }
        guard let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits) else {
            return nil
        }
        return ByteBuffer(bytes: bytes)
    }
}

/// Process-local authorization and lifecycle fence for the high-frequency
/// foreground push path. The registry still selects an audience from an
/// authenticated subscription; this second fence prevents a stale routing
/// snapshot from writing after unregister, revocation, or transport close.
/// The synchronous writer only enqueues bounded best-effort work on the
/// channel's own EventLoop. Durable room-log cursor pull remains the recovery
/// path for every drop.
private final class V2GatewayForegroundTransport: Sendable {
    private enum Writer: Sendable {
        case callback(@Sendable (ByteBuffer) -> Void)
        case nio(V2NIOGatewayForegroundWriter)
    }

    private struct State: Sendable {
        var protocolVersion: UInt8?
        var compression: V2NegotiatedFrameCompression?
        var writer: Writer?
    }

    private let state = Mutex(State())

    func attach(writer: (@Sendable (ByteBuffer) -> Void)?) {
        state.withLock { $0.writer = writer.map(Writer.callback) }
    }

    func attach(nioWriter: V2NIOGatewayForegroundWriter?) {
        state.withLock { $0.writer = nioWriter.map(Writer.nio) }
    }

    func activate(
        protocolVersion: UInt8,
        compression: V2NegotiatedFrameCompression?
    ) {
        state.withLock {
            $0.protocolVersion = protocolVersion
            $0.compression = compression
        }
    }

    func deactivate() {
        state.withLock {
            $0.protocolVersion = nil
            $0.compression = nil
        }
    }

    func detach() {
        state.withLock {
            $0.protocolVersion = nil
            $0.compression = nil
            $0.writer = nil
        }
    }

    func submit(_ prepared: V2PreparedGatewayGroupEventAvailable) -> Bool {
        let submission = state.withLock { state -> (
            writer: Writer,
            bytes: ByteBuffer
        )? in
            guard state.protocolVersion == prepared.protocolVersion else { return nil }
            guard let writer = state.writer else { return nil }
            return (writer, prepared.bytes(for: state.compression))
        }
        guard let submission else { return false }
        switch submission.writer {
        case .callback(let writer):
            writer(submission.bytes)
        case .nio(let writer):
            writer.submit(submission.bytes)
        }
        return true
    }

    /// Captures the same authentication and lifecycle fence as `submit`, but
    /// leaves lane scheduling to the group publisher so many local recipients
    /// can be admitted as one EventLoop batch.
    func prepareNIOSubmission(
        _ prepared: V2PreparedGatewayGroupEventAvailable
    ) -> V2NIOGatewayForegroundWriteSubmission? {
        state.withLock { state in
            guard state.protocolVersion == prepared.protocolVersion,
                  case .nio(let writer)? = state.writer
            else { return nil }
            return .init(
                writer: writer,
                bytes: prepared.bytes(for: state.compression)
            )
        }
    }
}

/// The transport-neutral half of a gateway connection. TLS is deliberately
/// terminated outside this actor; callers feed only decrypted bytes and write
/// the returned bytes back to the same connection. This keeps framing,
/// lifecycle fencing, and domain dispatch testable without a socket.
public actor V2GatewayByteStream {
    /// Process-unique connection identity backed by the same CSPRNG expansion
    /// and atomic counter used for accepted-message identifiers. This avoids
    /// relying on the platform UUID implementation during reconnect bursts.
    public nonisolated static func makeConnectionID() -> UUID {
        V2SecureProcessUUIDGenerator.shared.makeOne()
    }

    private var decoder: V2FrameDecoder
    private let frameLimits: V2FrameLimits
    private let session: V2GatewaySession
    private let handler: any V2GatewayCommandHandler
    private let connectionID: UUID
    private let registry: V2DeviceConnectionRegistry
    private nonisolated let foregroundTransport = V2GatewayForegroundTransport()
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
        connectionID: UUID = V2GatewayByteStream.makeConnectionID(),
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
        var needsFrameDrain = try await receive(bytes) { response in
            responses.append(response)
        }
        while needsFrameDrain {
            needsFrameDrain = try await receive(Data()) { response in
                responses.append(response)
            }
        }
        return responses
    }

    /// Production transports use this form so replies can cross their
    /// writability boundary one at a time instead of materializing a second
    /// response batch beside the decoded frame batch.
    public func receive(
        _ bytes: Data,
        respond: (Data) async throws -> Void
    ) async throws -> Bool {
        try await receiveFrames(bytes) { frame in
            try await respond(try V2FrameCodec.encode(frame, limits: frameLimits))
        }
    }

    /// Production NIO transports use the validated frame form so they can
    /// write header and protobuf payload directly into their outbound
    /// `ByteBuffer`. Transport-neutral callers retain the `Data` API above.
    func receiveFrames(
        _ bytes: Data,
        respond: (V2Frame) async throws -> Void
    ) async throws -> Bool {
        do {
            let inbound = try decoder.append(bytes)
            for frame in inbound {
                let exchange = try await session.receive(
                    frame,
                    handler: handler,
                    originatingConnectionID: connectionID
                )
                try await registerAuthenticatedDeviceIfNeeded()
                try await updateHybridGroupSubscription(
                    inbound: exchange.request,
                    response: exchange.responseEnvelope
                )
                try V2FrameCodec.validateForEncoding(exchange.response, limits: frameLimits)
                try await respond(exchange.response)
            }
            // A full decode quantum can leave a valid complete frame behind.
            // The NIO owner schedules one continuation before it consumes a
            // later TCP chunk, retaining per-connection wire order. A trailing
            // partial frame costs at most one empty drain and remains buffered
            // for the next actual transport read.
            return inbound.count == frameLimits.maximumFramesPerAppend && decoder.hasBufferedBytes
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
        outboundWriter: @escaping @Sendable (Data) async -> Void,
        foregroundWriter: (@Sendable (Data) -> Void)? = nil
    ) -> Bool {
        guard !transportClosed else { return false }
        self.deviceRevocationHandler = deviceRevocationHandler
        self.outboundWriter = outboundWriter
        let adaptedForegroundWriter: (@Sendable (ByteBuffer) -> Void)?
        if let foregroundWriter {
            adaptedForegroundWriter = { buffer in
                foregroundWriter(Data(buffer.readableBytesView))
            }
        } else {
            adaptedForegroundWriter = nil
        }
        foregroundTransport.attach(writer: adaptedForegroundWriter)
        return true
    }

    /// Production SwiftNIO attachment. The actor-backed `Data` callback stays
    /// unchanged for transport-neutral compatibility, while foreground group
    /// frames retain their prepared COW `ByteBuffer` all the way to the channel.
    func attachNIOTransport(
        deviceRevocationHandler: @escaping @Sendable () async -> Void,
        outboundWriter: @escaping @Sendable (Data) async -> Void,
        foregroundWriter: V2NIOGatewayForegroundWriter?
    ) -> Bool {
        guard !transportClosed else { return false }
        self.deviceRevocationHandler = deviceRevocationHandler
        self.outboundWriter = outboundWriter
        foregroundTransport.attach(nioWriter: foregroundWriter)
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
    /// A plain direct event may include an optional post-commit payload, but
    /// cursor pull remains the durable recovery and gap-repair path.
    public func sendGroupEventAvailable(
        roomID: RoomID,
        highWatermark: UInt64,
        directEvent: V2DirectRoomLiveEvent? = nil
    ) async {
        guard let version = await session.authenticatedProtocolVersion(), let outboundWriter else { return }
        var envelope = IMV2Envelope()
        envelope.requestID = 0
        envelope.protocolVersion = UInt32(version)
        envelope.groupEventAvailable = .init()
        envelope.groupEventAvailable.roomID = roomID.rawValue
        envelope.groupEventAvailable.highWatermark = highWatermark
        if let directEvent,
           directEvent.roomID == roomID,
           directEvent.highWatermark == highWatermark {
            envelope.groupEventAvailable.sourceEventID = directEvent.sourceEventID.rawValue
            envelope.groupEventAvailable.roomSequence = directEvent.roomSequence
            envelope.groupEventAvailable.projectionKind = directEvent.projectionKind
            envelope.groupEventAvailable.eventPayload = directEvent.payload
        }
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version),
              let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits)
        else { return }
        await outboundWriter(bytes)
    }

    /// Sends a frame encoded once for a process-local authorized audience.
    /// The stream still fences the write by its authenticated negotiation and
    /// current transport callback; a stale or differently-versioned stream
    /// cannot consume shared bytes.
    func sendGroupEventAvailable(_ prepared: V2PreparedGatewayGroupEventAvailable) async {
        guard let contract = await session.authenticatedFrameContract(),
              contract.protocolVersion == prepared.protocolVersion,
              let outboundWriter
        else { return }
        let buffer = prepared.bytes(for: contract.compression)
        await outboundWriter(Data(buffer.readableBytesView))
    }

    /// Production foreground notifications use this nonisolated fast path.
    /// A false result means the connection is unauthenticated, detached, uses
    /// another protocol version, or has no NIO fast writer; callers retain the
    /// actor-backed compatibility path for those cases.
    nonisolated func submitGroupEventAvailable(
        _ prepared: V2PreparedGatewayGroupEventAvailable
    ) -> Bool {
        foregroundTransport.submit(prepared)
    }

    /// Production group publication first collects these lifecycle-fenced NIO
    /// submissions, then enters each EventLoop lane once. Alternate transports
    /// return nil and continue through `submitGroupEventAvailable` unchanged.
    nonisolated func prepareNIOGroupEventAvailable(
        _ prepared: V2PreparedGatewayGroupEventAvailable
    ) -> V2NIOGatewayForegroundWriteSubmission? {
        foregroundTransport.prepareNIOSubmission(prepared)
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
        foregroundTransport.detach()
    }

    private func registerAuthenticatedDeviceIfNeeded() async throws {
        guard registeredIdentity == nil, let identity = await session.authenticatedIdentity() else { return }
        registeredIdentity = identity
        let accepted = try await registry.register(self, connectionID: connectionID, identity: identity)
        guard accepted, registeredIdentity == identity, !transportClosed else {
            if registeredIdentity == identity { registeredIdentity = nil }
            foregroundTransport.deactivate()
            await registry.unregister(connectionID: connectionID)
            throw V2GatewaySessionError.authenticatedConnectionLimit
        }
        guard let contract = await session.authenticatedFrameContract() else {
            registeredIdentity = nil
            foregroundTransport.deactivate()
            await registry.unregister(connectionID: connectionID)
            throw V2GatewaySessionError.unsupportedCommand
        }
        foregroundTransport.activate(
            protocolVersion: contract.protocolVersion,
            compression: contract.compression
        )
    }

    private func unregisterAuthenticatedDevice() async {
        guard registeredIdentity != nil else { return }
        registeredIdentity = nil
        foregroundTransport.deactivate()
        await registry.unregister(connectionID: connectionID)
    }

    private func updateHybridGroupSubscription(inbound: IMV2Envelope, response: IMV2Envelope) async throws {
        switch inbound.body {
        case .setLiveActivityPreferences:
            guard case .liveActivityPreferencesSet(let updated)? = response.body
            else { return }
            guard await registry.applyLiveActivityPreferences(
                connectionID: connectionID,
                allowsOnlinePresence: updated.allowsOnlinePresence
            ) else { throw V2GatewaySessionError.authenticatedConnectionLimit }
        case .groupEventSubscribe(let request):
            guard case .groupEventSubscribed(let subscribed)? = response.body,
                  subscribed.roomID == request.roomID
            else { return }
            await registry.subscribeForegroundGroup(
                self,
                connectionID: connectionID,
                roomID: try .init(request.roomID),
                membershipRevision: subscribed.membershipRevision
            )
        case .groupEventUnsubscribe(let request):
            await registry.unsubscribeForegroundGroup(connectionID: connectionID, roomID: try .init(request.roomID))
        case .subscribePresence(let request):
            guard case .presenceSubscribed(let subscribed)? = response.body,
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
            guard case .acknowledged? = response.body,
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
