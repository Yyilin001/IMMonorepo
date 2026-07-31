import Foundation
import Testing
@testable import IMV2Core

@Suite("V2 rich message content")
struct RichMessageContentTests {
    @Test("UTF-16 entities preserve emoji boundaries and reject unsafe links")
    func validatesUTF16RangesAndLinkPolicy() throws {
        let text = "Hi 👋 link"
        let entity = try V2MessageEntity(offsetUTF16: 6, lengthUTF16: 4, kind: .bold)
        try V2RichMessageContent.validate(text: text, entities: [entity])

        #expect(throws: V2RichMessageContentError.invalidEntity) {
            try V2RichMessageContent.validate(text: text, entities: [try .init(offsetUTF16: 4, lengthUTF16: 1, kind: .italic)])
        }
        #expect(throws: V2RichMessageContentError.invalidEntity) {
            try V2MessageEntity(offsetUTF16: 0, lengthUTF16: 2, kind: .link, linkURL: URL(string: "javascript:alert(1)"))
        }
    }
}
