import Foundation
import IMV2ActorContracts
import IMV2ServerInfrastructure
import Logging
import NIOCore
import PostgresKit
import PostgresNIO
import Synchronization
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The dedicated PostgreSQL session serializes Core startup. The durable
/// incarnation prevents takeover on connection loss or process failure until
/// the previous writer has been explicitly excluded.
final class GatewaySingleRoomCoreAuthority: Sendable {
    enum StartupError: Error {
        case writerAlreadyRunning
        case previousWriterRequiresExclusion
        case invalidEpoch
        case writerLost
    }

    let epoch: UInt64
    private let incarnation: UUID
    private let connection: PostgresConnection
    private let closing = Mutex(false)
    private let logger: Logger

    private init(epoch: UInt64, incarnation: UUID, connection: PostgresConnection,
                 qualification: V2ActorServiceQualification, logger: Logger) {
        self.epoch = epoch
        self.incarnation = incarnation
        self.connection = connection
        self.logger = logger
        connection.closeFuture.whenComplete { [weak self] _ in
            guard let self, !self.closing.withLock({ $0 }) else { return }
            qualification.revoke()
            logger.critical("Room Core lost its PostgreSQL writer session")
            exit(EXIT_FAILURE)
        }
    }

    static func acquire(url: String, identity: V2ActorHostIdentity, eventLoop: any EventLoop,
                        policy: V2PostgresRuntimePolicy, qualification: V2ActorServiceQualification,
                        logger: Logger) async throws -> GatewaySingleRoomCoreAuthority {
        var configuration = try SQLPostgresConfiguration(url: url).coreConfiguration
        configuration.options.connectTimeout = .milliseconds(Int64(policy.connectTimeoutMilliseconds))
        configuration.options.additionalStartupParameters += policy.startupParameters
        configuration.options.additionalStartupParameters.append(
            ("application_name", V2ActorPostgresSessionIdentity.applicationName(identity)))
        let connection = try await PostgresConnection.connect(on: eventLoop, configuration: configuration,
            id: 0, logger: logger)
        do {
            _ = try await connection.query("SET synchronous_commit = on", logger: logger).collect()
            // Reserved for the Room Core within this database.
            let lock = try await connection.query("SELECT pg_try_advisory_lock(1229805106, 1)", logger: logger)
                .collect().map { try $0.decode(Bool.self) }
            guard lock == [true] else { throw StartupError.writerAlreadyRunning }
            _ = try await connection.query("BEGIN", logger: logger).collect()
            let epochs = try await connection.query("""
                UPDATE im_v2.room_core_writer SET epoch = epoch + 1, incarnation = \(identity.incarnationID)
                WHERE singleton AND incarnation IS NULL
                RETURNING epoch
                """, logger: logger).collect().map { try $0.decode(Int64.self) }
            guard let value = epochs.first else { throw StartupError.previousWriterRequiresExclusion }
            guard let epoch = UInt64(exactly: value), epoch > 0,
                  epoch <= V2RoomActorPlacementGrant.maximumEpoch else { throw StartupError.invalidEpoch }
            // An UPDATE returning rows is not itself an explicit COMMIT acknowledgement.
            _ = try await connection.query("COMMIT", logger: logger).collect()
            logger.notice("Acquired single Room Core writer authority", metadata: [
                "epoch": .stringConvertible(epoch), "incarnation": .string(identity.incarnationID.uuidString)])
            return .init(epoch: epoch, incarnation: identity.incarnationID, connection: connection,
                qualification: qualification, logger: logger)
        } catch {
            try? await connection.close()
            throw error
        }
    }

    /// Called only after listeners, workers, room turns and database loans have drained.
    func release() async throws {
        guard !closing.withLock({ $0 }) else { return }
        _ = try await connection.query("BEGIN", logger: logger).collect()
        let epochs = try await connection.query("""
            UPDATE im_v2.room_core_writer SET incarnation = NULL
            WHERE singleton AND incarnation = \(incarnation)
            RETURNING epoch
            """, logger: logger).collect().map { try $0.decode(Int64.self) }
        guard epochs == [Int64(epoch)] else { throw StartupError.writerLost }
        _ = try await connection.query("COMMIT", logger: logger).collect()
        closing.withLock { $0 = true }
        try await connection.close()
    }
}
