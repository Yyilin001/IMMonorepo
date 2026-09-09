import Testing
import IMV2Core

struct RoomCursorBoundsTests {
    @Test(arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func bounds(value: UInt64) throws {
        if value > UInt64(Int64.max) {
            #expect(throws: V2RevisionValidationError.outOfRange) { try V2RoomCursor(value) }
        } else {
            let cursor = try V2RoomCursor(value)
            #expect(cursor.rawValue == value)
            #expect(cursor.signedValue == Int64(exactly: value))
            #expect(Set([cursor, try V2RoomCursor(value)]).count == 1)
        }
    }
}
