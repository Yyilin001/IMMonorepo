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
    private let registry: V2DeviceConnectionRegistry?
    private var registeredIdentity: V2AuthenticatedConnection?
    // A revocation worker must not advance its durable cursor until the
    // transport confirms the local channel has closed. The handler therefore
    // bridges the NIO close future into this actor rather than merely
    // scheduling a best-effort close.
    private var deviceRevocationHandler: (@Sendable () async -> Void)?
    private var outboundWriter: (@Sendable (Data) -> Void)?

    public init(
        frameLimits: V2FrameLimits,
        session: V2GatewaySession,
        handler: any V2GatewayCommandHandler,
        connectionID: UUID = UUID(),
        registry: V2DeviceConnectionRegistry? = nil
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
        do {
            let inbound = try decoder.append(bytes)
            var outbound: [Data] = []
            outbound.reserveCapacity(inbound.count)
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
                outbound.append(try V2FrameCodec.encode(response, limits: frameLimits))
            }
            return outbound
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
    }

    public func setDeviceRevocationHandler(_ handler: @escaping @Sendable () async -> Void) {
        deviceRevocationHandler = handler
    }

    /// Live availability is explicitly best effort. The NIO owner drops it
    /// when its outbound channel is not writable; recovery is always SYNC_PULL.
    public func setOutboundWriter(_ writer: @escaping @Sendable (Data) -> Void) {
        outboundWriter = writer
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
        outboundWriter(bytes)
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
        outboundWriter(bytes)
    }

    private func registerAuthenticatedDeviceIfNeeded() async throws {
        guard registeredIdentity == nil, let registry, let identity = await session.authenticatedIdentity() else { return }
        registeredIdentity = identity
        await registry.register(self, connectionID: connectionID, identity: identity)
    }

    private func unregisterAuthenticatedDevice() async {
        guard registeredIdentity != nil else { return }
        registeredIdentity = nil
        await registry?.unregister(connectionID: connectionID)
    }

    private func updateHybridGroupSubscription(inbound: IMV2Envelope, response: V2Frame) async throws {
        guard let registry else { return }
        switch inbound.body {
        case .groupEventSubscribe(let request):
            let responseEnvelope = try V2ServerProtobufFrameCodec.decode(response)
            guard case .groupEventSubscribed(let subscribed)? = responseEnvelope.body,
                  subscribed.roomID == request.roomID
            else { return }
            await registry.subscribeForegroundGroup(self, connectionID: connectionID, roomID: try .init(request.roomID))
        case .groupEventUnsubscribe(let request):
            await registry.unsubscribeForegroundGroup(connectionID: connectionID, roomID: try .init(request.roomID))
        default:
            return
        }
    }
}
