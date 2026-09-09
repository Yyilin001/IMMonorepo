import IMV2Core
import Testing

struct ForwardResultBoundsTests {
    @Test(arguments: [false, true], [false, true])
    func resultShape(message: Bool, sequence: Bool) throws {
        for failed in [false, true] {
            func result() throws -> V2ForwardMessageResult {
                try .init(sourceMessageID: .init("source"), targetRoomID: .init("target"),
                          messageID: message ? .init("message") : nil, roomSequence: sequence ? 1 : nil,
                          errorCode: failed ? "FORBIDDEN" : nil)
            }
            if (message && sequence && !failed) || (!message && !sequence && failed) {
                #expect(try result().errorCode == (failed ? "FORBIDDEN" : nil))
            } else { #expect(throws: V2ForwardMessageResultValidationError.invalidShape) { _ = try result() } }
        }
    }

    @Test(arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func successSequence(value: UInt64) throws {
        func result() throws -> V2ForwardMessageResult {
            try .init(sourceMessageID: .init("source"), targetRoomID: .init("target"), messageID: .init("message"), roomSequence: value, errorCode: nil)
        }
        if value == 0 || value > UInt64(Int64.max) {
            #expect(throws: V2ForwardMessageResultValidationError.invalidSequence) { _ = try result() }
        } else { #expect(try result().roomSequence == value) }
    }
}
