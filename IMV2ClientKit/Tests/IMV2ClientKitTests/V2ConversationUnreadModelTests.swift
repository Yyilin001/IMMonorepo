import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("V2 conversation unread model")
struct V2ConversationUnreadModelTests {
    @Test("displayed unread never exceeds the server value and never grows locally")
    func clampsToTheSmallerValue() {
        // 本地水位领先服务端（刚进入房间、回执还在路上）：展示 0，而不是服务端的 5。
        #expect(V2ClientConversationUnread.displayedUnread(serverUnread: 5, head: 10, localWatermark: 10) == 0)
        #expect(V2ClientConversationUnread.displayedUnread(serverUnread: 5, head: 10, localWatermark: 8) == 2)
        // 本地水位落后服务端：服务端更小，取服务端，绝不虚报。
        #expect(V2ClientConversationUnread.displayedUnread(serverUnread: 2, head: 10, localWatermark: 3) == 2)
        // 没有本地水位：退化为服务端值。
        #expect(V2ClientConversationUnread.displayedUnread(serverUnread: 4, head: 10, localWatermark: nil) == 4)
        // 自己发的消息让服务端未读小于"到 head 的距离"，展示值只能是更小的那个。
        #expect(V2ClientConversationUnread.displayedUnread(serverUnread: 1, head: 10, localWatermark: nil) == 1)
    }

    @Test("a local watermark at or beyond the head floors at zero")
    func neverUnderflows() {
        #expect(V2ClientConversationUnread.displayedUnread(serverUnread: 7, head: 10, localWatermark: 11) == 0)
        #expect(V2ClientConversationUnread.displayedUnread(serverUnread: 0, head: 0, localWatermark: nil) == 0)
        #expect(V2ClientConversationUnread.displayedUnread(serverUnread: 9, head: 9, localWatermark: 9) == 0)
    }

}
