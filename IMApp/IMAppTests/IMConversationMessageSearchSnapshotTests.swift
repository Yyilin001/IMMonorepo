import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

struct IMConversationMessageSearchSnapshotTests {
    @Test func searchResultSnapshotProjectsSearchHitForRendering() {
        let messageID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let hit = IMConversationMessageSearchHitResponseBody(
            messageID: messageID,
            senderUserID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            serverSequence: 42,
            content: .richText(.plain("full message body")),
            snippet: "message",
            createdAt: nil
        )

        let snapshot = IMConversationMessageSearchResultSnapshot(hit: hit)

        #expect(snapshot.id == messageID.uuidString)
        #expect(snapshot.snippet == "message")
        #expect(snapshot.previewText == "full message body")
        #expect(snapshot.createdAtText == nil)
    }
}
