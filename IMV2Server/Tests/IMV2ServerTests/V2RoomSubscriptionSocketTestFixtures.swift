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
        return attachNIOTransport(deviceRevocationHandler: deviceRevocationHandler,
            outboundWriter: outboundWriter, requiredNotificationWriter: requiredNotificationWriter,
            scopedNotificationWriter: scoped, requiredNotificationClose: requiredNotificationClose,
            foregroundWriter: foregroundWriter, authorPresentationWriter: authorPresentationWriter,
            roomSubscriptionSocketGate: gate)
    }
}
