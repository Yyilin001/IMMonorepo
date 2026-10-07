import IMV2Core
@testable import IMV2ServerContracts
import Foundation
import Testing

struct V2DeviceRoomProgressTests {
    @Test("durable reports accept zero and the authorized boundary")
    func validBoundaries() throws {
        let room = RoomID(uuid: UUID())
        #expect(try V2DeviceRoomProgress(roomID: room, appliedThrough: 0, authorizedHighWatermark: 0).appliedThrough == 0)
        #expect(try V2DeviceRoomProgress(roomID: room, appliedThrough: 42, authorizedHighWatermark: 42).appliedThrough == 42)
        #expect(try V2DeviceRoomProgress(roomID: room, appliedThrough: UInt64(Int64.max), authorizedHighWatermark: UInt64(Int64.max)).appliedThrough == UInt64(Int64.max))
    }
    @Test("device reports cannot pass the live grant head or persistence range")
    func invalidBoundaries() {
        let room = RoomID(uuid: UUID())
        for (cursor, head) in [(UInt64(43), UInt64(42)), (UInt64(0), UInt64.max), (UInt64.max, UInt64.max)] {
            #expect(throws: V2RoomRecoveryReadError.invalidRequest) {
                try V2DeviceRoomProgress(roomID: room, appliedThrough: cursor, authorizedHighWatermark: head)
            }
        }
    }
}
