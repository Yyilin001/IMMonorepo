import Foundation
import NIOCore
import NIOPosix
import Synchronization
import IMV2Core
@testable import IMV2ServerGateway

/// 测试中的逻辑连接也绑定正式 Socket Gate，许可检查在所属 EventLoop 上执行。
private enum SubscriptionSocketFixtures {
    static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    struct Key: Hashable {
        let authority: ObjectIdentifier
        let connection: UUID
        let lifecycle: UUID
        let user: UserID
    }
    static let gates = Mutex<[Key: V2RoomSubscriptionSocketGate]>([:])
}

extension V2GatewayRoomSubscriptionAuthority {
    func registerFixtureConnection(_ connectionID: UUID, userID: UserID, lifecycle: UUID,
                                   eventLoop: (any EventLoop)? = nil) async -> Bool {
        guard registerConnection(connectionID, userID: userID, lifecycle: lifecycle) else { return false }
        let key = SubscriptionSocketFixtures.Key(authority: ObjectIdentifier(self), connection: connectionID,
                                                  lifecycle: lifecycle, user: userID)
        let gate: V2RoomSubscriptionSocketGate
        if let existing = SubscriptionSocketFixtures.gates.withLock({ $0[key] }) { gate = existing }
        else {
            let loop = eventLoop ?? SubscriptionSocketFixtures.group.next()
            gate = try! await loop.submit { V2RoomSubscriptionSocketGate(eventLoop: loop) }.get()
            SubscriptionSocketFixtures.gates.withLock { $0[key] = gate }
        }
        await bindSocket(connectionID, lifecycle: lifecycle, gate: gate)
        return true
    }

    func enqueueFixtureIfCurrent(_ permit: Permit,
                                 enqueue: @escaping @Sendable () -> Void) async -> Bool {
        guard let gate = permit.socketGate else { return false }
        return (try? await gate.eventLoop.submit { self.enqueueIfCurrent(permit, enqueue: enqueue) }.get()) ?? false
    }
}

import IMV2ServerApplication

extension V2GatewayByteStream {
    func attachFixtureTransport(
        deviceRevocationHandler: @escaping @Sendable () async -> Void,
        outboundWriter: @escaping @Sendable (Data) async -> Void,
        requiredNotificationWriter: (@Sendable (Data) async -> Bool)? = nil,
        scopedNotificationWriter: (@Sendable (V2GatewayScopedNotificationWrite) async -> Bool)? = nil,
        requiredNotificationClose: (@Sendable () async -> Void)? = nil,
        foregroundWriter: V2NIOGatewayForegroundWriter? = nil,
        authorPresentationWriter: (@Sendable (V2AuthorPresentationWrite) async -> Bool)? = nil
    ) async -> Bool {
        let loop = foregroundWriter?.eventLoop ?? SubscriptionSocketFixtures.group.next()
        let gate = try! await loop.submit { V2RoomSubscriptionSocketGate(eventLoop: loop) }.get()
        let scoped: (@Sendable (V2GatewayScopedNotificationWrite) async -> Bool)?
        if let writer = scopedNotificationWriter {
            scoped = { @Sendable (write: V2GatewayScopedNotificationWrite) async -> Bool in
                let marshalled = V2GatewayScopedNotificationWrite(bytes: write.bytes, permit: { enqueue in
                    if loop.inEventLoop { return write.enqueueIfCurrent(enqueue) }
                    return withoutActuallyEscaping(enqueue) { action in
                        let callback = Mutex<(@Sendable () -> Void)?>(action)
                        return (try? loop.submit {
                            defer { callback.withLock { $0 = nil } }
                            return write.enqueueIfCurrent { callback.withLock { $0?() } }
                        }.wait()) ?? false
                    }
                })
                return await writer(marshalled)
            }
        } else { scoped = nil }
        let authorWriter: (@Sendable (V2AuthorPresentationWrite) async -> V2AuthorPresentationWriteResult)?
        if let writer = authorPresentationWriter {
            authorWriter = { await writer($0) ? .enqueued : .discarded }
        } else { authorWriter = nil }
        return attachNIOTransport(deviceRevocationHandler: deviceRevocationHandler,
            outboundWriter: outboundWriter, requiredNotificationWriter: requiredNotificationWriter,
            scopedNotificationWriter: scoped, requiredNotificationClose: requiredNotificationClose,
            foregroundWriter: foregroundWriter, authorPresentationWriter: authorWriter,
            roomSubscriptionSocketGate: gate)
    }
}

import IMV2ActorContracts
private let fixtureDeliveryGateway = V2GatewayRealtimeIdentity(nodeID: "fixture", serviceID: "fixture", incarnationID: UUID())
extension V2GatewayRoomSubscriptionAuthority {
    func retireTestSession(fence: V2RoomSubscriptionFence, serviceID: String) -> V2RoomDeliverySessionResult {
        let session = V2RoomDeliverySession(host: fence.activation.host, gateway: fixtureDeliveryGateway, generation: 1)
        return applyDeliverySession(.init(session: session, kind: .retire, sequence: 2), serviceID: serviceID)
    }
    func installTestSession(fence: V2RoomSubscriptionFence, serviceID: String,
                            afterAuthoritativeReset: Bool = false) async -> Bool {
        let session = V2RoomDeliverySession(host: fence.activation.host, gateway: fixtureDeliveryGateway, generation: 1)
        guard applyDeliverySession(.init(session: session, kind: .open, sequence: 1), serviceID: serviceID) == .accepted else { return false }
        return await install(fence: fence, serviceID: serviceID, session: session, afterAuthoritativeReset: afterAuthoritativeReset)
    }
}
extension V2GatewayRoomSubscriptionIngress {
    func installTestSession(fence: V2RoomSubscriptionFence, sourceShardID: String, serviceID: String,
                            afterAuthoritativeReset: Bool = false) async -> Bool {
        guard fence.activation.owner.shardID == sourceShardID else { return false }
        return await authority.installTestSession(fence: fence, serviceID: serviceID, afterAuthoritativeReset: afterAuthoritativeReset)
    }
}
func testDeliverySession(fence: V2RoomSubscriptionFence, gateway: V2GatewayRealtimeIdentity,
                         authority: V2GatewayRoomSubscriptionAuthority, serviceID: String = "owner") -> V2RoomDeliverySession {
    let session = V2RoomDeliverySession(host: fence.activation.host, gateway: gateway, generation: 1)
    _ = authority.applyDeliverySession(.init(session: session, kind: .open, sequence: 1), serviceID: serviceID)
    return session
}
