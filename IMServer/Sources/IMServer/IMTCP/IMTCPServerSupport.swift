import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Vapor

struct IMTCPConfiguration: Sendable {
    let enabled: Bool
    let host: String
    let port: Int
    let protocolVersion: Int
    let authTimeout: TimeInterval
    let heartbeatInterval: TimeInterval
    let idleTimeout: TimeInterval
    let maxFrameBytes: Int

    static func load(from environment: Environment) -> IMTCPConfiguration {
        let enabled = Environment.get("IM_TCP_ENABLED").flatMap(Bool.init(_:)) ?? (environment != .testing)

        return IMTCPConfiguration(
            enabled: enabled,
            host: Environment.get("IM_TCP_HOST") ?? "0.0.0.0",
            port: Environment.get("IM_TCP_PORT").flatMap(Int.init(_:)) ?? 9000,
            protocolVersion: Environment.get("IM_TCP_PROTOCOL_VERSION").flatMap(Int.init(_:)) ?? 1,
            authTimeout: Environment.get("IM_TCP_AUTH_TIMEOUT").flatMap(TimeInterval.init(_:)) ?? 10,
            heartbeatInterval: Environment.get("IM_TCP_HEARTBEAT_INTERVAL").flatMap(TimeInterval.init(_:)) ?? 30,
            idleTimeout: Environment.get("IM_TCP_IDLE_TIMEOUT").flatMap(TimeInterval.init(_:)) ?? 90,
            maxFrameBytes: Environment.get("IM_TCP_MAX_FRAME_BYTES").flatMap(Int.init(_:)) ?? 64 * 1024
        )
    }
}

final class IMConnectionControl: @unchecked Sendable {
    let connectionID: UUID

    private let channel: any Channel

    init(connectionID: UUID, channel: any Channel) {
        self.connectionID = connectionID
        self.channel = channel
    }

    func sendPacket<Payload: Codable & Sendable>(
        type: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload
    ) {
        let channel = self.channel
        channel.eventLoop.execute {
            guard channel.isActive else {
                return
            }
            IMTCPChannelWriter.writePacket(type: type, requestID: requestID, payload: payload, on: channel)
        }
    }

    func kick(reason: IMTCPKickReason, message: String) {
        let channel = self.channel
        channel.eventLoop.execute {
            guard channel.isActive else {
                return
            }
            IMTCPChannelWriter.sendKickAndClose(on: channel, reason: reason, message: message)
        }
    }

    func close() {
        let channel = self.channel
        channel.eventLoop.execute {
            channel.close(promise: nil)
        }
    }
}

struct IMAuthenticatedConnection: Sendable {
    let connectionID: UUID
    let userID: UUID
    let sessionID: UUID
    let authenticatedAt: Date
    let remoteIPAddress: String?
    let deviceID: String?
    let deviceName: String?
    let platform: String?
    let appVersion: String?
}

actor IMConnectionRegistry {
    private struct Entry: Sendable {
        let connection: IMAuthenticatedConnection
        let control: IMConnectionControl
    }

    private var connectionsByID: [UUID: Entry] = [:]
    private var connectionIDsBySessionID: [UUID: Set<UUID>] = [:]
    private var connectionIDsByUserID: [UUID: Set<UUID>] = [:]

    func bind(_ connection: IMAuthenticatedConnection, control: IMConnectionControl) {
        connectionsByID[connection.connectionID] = Entry(connection: connection, control: control)
        connectionIDsBySessionID[connection.sessionID, default: []].insert(connection.connectionID)
        connectionIDsByUserID[connection.userID, default: []].insert(connection.connectionID)
    }

    func remove(connectionID: UUID) {
        guard let removed = connectionsByID.removeValue(forKey: connectionID) else {
            return
        }

        connectionIDsBySessionID[removed.connection.sessionID]?.remove(connectionID)
        if connectionIDsBySessionID[removed.connection.sessionID]?.isEmpty == true {
            connectionIDsBySessionID.removeValue(forKey: removed.connection.sessionID)
        }

        connectionIDsByUserID[removed.connection.userID]?.remove(connectionID)
        if connectionIDsByUserID[removed.connection.userID]?.isEmpty == true {
            connectionIDsByUserID.removeValue(forKey: removed.connection.userID)
        }
    }

    func connectionIDs(forSessionID sessionID: UUID) -> [UUID] {
        Array(connectionIDsBySessionID[sessionID] ?? [])
    }

    func connectionIDs(forUserID userID: UUID) -> [UUID] {
        Array(connectionIDsByUserID[userID] ?? [])
    }

    func authenticatedConnection(for connectionID: UUID) -> IMAuthenticatedConnection? {
        connectionsByID[connectionID]?.connection
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) {
        let controls = connectionIDs(forSessionID: sessionID)
            .compactMap { connectionsByID[$0]?.control }

        for control in controls {
            control.kick(reason: reason, message: message)
        }
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) {
        let controls = connectionIDs(forUserID: userID)
            .compactMap { connectionsByID[$0]?.control }

        for control in controls {
            control.kick(reason: reason, message: message)
        }
    }

    func sendMessage(
        _ payload: IMTCPMessagePayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) {
        sendPacket(type: .message, payload: payload, toUserIDs: userIDs, requestID: requestID)
    }

    func sendConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        toUserID userID: UUID,
        requestID: UUID? = UUID()
    ) {
        sendPacket(type: .conversationEvent, payload: payload, toUserIDs: [userID], requestID: requestID)
    }

    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID? = UUID()
    ) {
        sendPacket(type: .contactEvent, payload: payload, toUserIDs: [userID], requestID: requestID)
    }

    private func sendPacket<Payload: Codable & Sendable>(
        type: IMTCPPacketType,
        payload: Payload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) {
        let uniqueConnectionIDs = Set(userIDs).flatMap { connectionIDsByUserID[$0] ?? [] }
        let controls = uniqueConnectionIDs.compactMap { connectionsByID[$0]?.control }

        for control in controls {
            control.sendPacket(type: type, requestID: requestID, payload: payload)
        }
    }
}

struct IMTCPAuthenticator {
    let app: Application
    let db: any Database

    func authenticate(
        accessToken: String,
        remoteIPAddress: String?,
        deviceID: String?,
        deviceName: String?,
        platform: String?,
        appVersion: String?
    ) async throws -> IMAuthenticatedConnection {
        let (_, sessionContext) = try await AuthService(app: app, db: db)
            .authenticateAccessToken(accessToken)

        return IMAuthenticatedConnection(
            connectionID: UUID(),
            userID: sessionContext.userID,
            sessionID: sessionContext.sessionID,
            authenticatedAt: Date(),
            remoteIPAddress: remoteIPAddress,
            deviceID: deviceID,
            deviceName: deviceName,
            platform: platform,
            appVersion: appVersion
        )
    }
}

final class IMTCPServerLifecycle: LifecycleHandler, @unchecked Sendable {
    private let serverChannel = NIOLockedValueBox<(any Channel)?>(nil)

    func didBootAsync(_ application: Application) async throws {
        let configuration = application.imTCPConfiguration
        guard configuration.enabled else {
            application.logger.info("IM TCP server disabled")
            return
        }

        let bootstrap = ServerBootstrap(group: application.eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    ByteToMessageHandler(
                        IMTCPLineFrameDecoder(maxFrameBytes: configuration.maxFrameBytes)
                    )
                )
                    .flatMap {
                        channel.pipeline.addHandler(IMTCPConnectionHandler(application: application))
                    }
            }

        let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        self.serverChannel.withLockedValue { $0 = channel }

        application.logger.info(
            "IM TCP server started",
            metadata: [
                "host": .string(configuration.host),
                "port": .stringConvertible(configuration.port)
            ]
        )
    }

    func shutdownAsync(_ application: Application) async {
        let channel = self.serverChannel.withLockedValue { value in
            let channel = value
            value = nil
            return channel
        }

        guard let channel else {
            return
        }

        do {
            try await channel.close().get()
            application.logger.info("IM TCP server stopped")
        } catch {
            application.logger.warning(
                "Failed to stop IM TCP server cleanly",
                metadata: ["error": .string(String(describing: error))]
            )
        }
    }
}

private struct IMTCPConfigurationStorageKey: StorageKey {
    typealias Value = IMTCPConfiguration
}

private struct IMConnectionRegistryStorageKey: StorageKey {
    typealias Value = IMConnectionRegistry
}

extension Application {
    var imTCPConfiguration: IMTCPConfiguration {
        get {
            guard let configuration = storage[IMTCPConfigurationStorageKey.self] else {
                fatalError("IMTCPConfiguration not configured")
            }
            return configuration
        }
        set {
            storage[IMTCPConfigurationStorageKey.self] = newValue
        }
    }

    var imConnectionRegistry: IMConnectionRegistry {
        get {
            if let registry = storage[IMConnectionRegistryStorageKey.self] {
                return registry
            }

            let registry = IMConnectionRegistry()
            storage[IMConnectionRegistryStorageKey.self] = registry
            return registry
        }
        set {
            storage[IMConnectionRegistryStorageKey.self] = newValue
        }
    }
}
