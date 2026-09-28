import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
@Suite("App send action handoff")
struct V2OperationConversationSenderTests {
    @Test("mentions and reply enter the immutable local send action")
    func groupMentionsReachDurableIntent() async throws {
        let f=try V2AppMessageWorkFixture();defer { f.remove() }
        let sender=V2OperationConversationSender(service:f.send)
        let mentions:[V2MentionTarget]=[.user(.init(uuid:UUID())),.everyone]
        let reply=V2MessageReplyReference(messageID:.init(uuid:UUID()))
        #expect(try await sender.send(text:"请关注",media:[],mentions:mentions,entities:[],replyTo:reply,in:f.room.rawValue) == .queuedForRetry)
        let intent=try #require(try await f.store.preparingSendIntents().first)
        #expect(intent.text=="请关注" && intent.mentions==mentions && intent.replyTo==reply)
        #expect(await f.remote.calls==0)
        try await f.store.close()
    }
    @Test("untracked media cannot bypass resource Ready dependencies")
    func untrackedMediaRejected() async throws {
        let f=try V2AppMessageWorkFixture();defer { f.remove() }
        let sender=V2OperationConversationSender(service:f.send)
        await #expect(throws:V2OperationWorkError.dependencyUnavailable) {
            try await sender.send(text:"",media:[.init(mediaID:.init(uuid:UUID()))],in:f.room.rawValue)
        }
        #expect(try await f.store.preparingSendIntents().isEmpty)
        try await f.store.close()
    }
}
