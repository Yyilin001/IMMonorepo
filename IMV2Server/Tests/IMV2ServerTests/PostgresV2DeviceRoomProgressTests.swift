import Foundation
import SQLKit
import IMV2Core
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import Testing

@Suite(.serialized)
struct PostgresV2DeviceRoomProgressTests {
    @Test("startup rejects device progress storage without its cursor constraint",
        .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func readinessRejectsBrokenDeviceProgress() async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).device_room_progress DROP CONSTRAINT device_room_progress_applied_through_check").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("\(schema).device_room_progress[device-cursor]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }
    @Test("device progress persists independently and out-of-order reports cannot regress")
    func independentDeviceProgress() async throws {
        try await withUserEventDatabase { database, _, schema in
            let store = try PostgresV2DeviceRoomProgressStore(database: database, schema: schema)
            let user = UserID(uuid: UUID()), other = UserID(uuid: UUID())
            let a = DeviceID(uuid: UUID()), b = DeviceID(uuid: UUID())
            let room = RoomID(uuid: UUID()), second = RoomID(uuid: UUID())
            func progress(_ room: RoomID, _ cursor: UInt64) throws -> V2DeviceRoomProgress {
                try .init(roomID: room, appliedThrough: cursor, authorizedHighWatermark: 100)
            }
            try await store.record(userID: user, deviceID: a, progress: [progress(room, 8), progress(second, 3)])
            try await store.record(userID: user, deviceID: b, progress: [progress(room, 2)])
            try await store.record(userID: user, deviceID: a, progress: [progress(room, 4)])
            #expect(try await store.load(userID: user, deviceID: a, roomIDs: [room, second]) == [room: 8, second: 3])
            #expect(try await store.load(userID: user, deviceID: b, roomIDs: [room, second]) == [room: 2])
            #expect(try await store.load(userID: other, deviceID: a, roomIDs: [room]).isEmpty)
            await #expect(throws: V2RoomRecoveryReadError.invalidRequest) {
                try await store.record(userID: user, deviceID: a, progress: [progress(room, 9), progress(room, 10)])
            }
        }
    }
}
