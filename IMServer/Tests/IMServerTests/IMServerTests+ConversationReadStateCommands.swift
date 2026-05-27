@testable import IMServer
import Fluent
import NIOCore
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("IM read endpoint advances explicit read sequence for conversation members only")
    func imMarkRead() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "read-peer@example.com", on: app)
            let conversation = Conversation(title: "Read Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_012))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            for sequence in 1...2 {
                try await ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: try otherUser.requireID(),
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "client-read-\(sequence)",
                    kind: "rich_text",
                    body: ["text": "read-\(sequence)"]
                ).create(on: app.db)
            }

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/read", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(IMConversationReadRequest(readSequence: 1))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMConversationReadResponse.self)
                #expect(response.conversationID == conversationID)
                #expect(response.lastReadSequence == 1)
                #expect(response.unreadCount == 1)
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.first?.id == conversationID)
                #expect(conversations.first?.unreadCount == 1)
            })

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/read", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(IMConversationReadRequest(readSequence: 999))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMConversationReadResponse.self)
                #expect(response.conversationID == conversationID)
                #expect(response.lastReadSequence == 2)
                #expect(response.unreadCount == 0)
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.first?.id == conversationID)
                #expect(conversations.first?.unreadCount == 0)
            })

            let stranger = try await makeUser(email: "read-outsider@example.com", on: app)
            let strangerAccessToken = try await loginAccessToken(
                email: stranger.email,
                password: "password1234",
                deviceID: "read-outsider-device",
                on: app
            )

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/read", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: strangerAccessToken)
                try req.content.encode(IMConversationReadRequest(readSequence: 2))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }


    @Test("IM summary changes reflect read updates across devices for the same user")
    func imConversationChangesReflectCrossDeviceReadProgress() async throws {
        try await withApp(configure: configure) { app in
            let firstDeviceToken = try await loginAccessToken(
                email: "demo@example.com",
                password: "password1234",
                deviceID: "read-device-1",
                on: app
            )
            let secondDeviceToken = try await loginAccessToken(
                email: "demo@example.com",
                password: "password1234",
                deviceID: "read-device-2",
                on: app
            )
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "changes-read-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Cross Device Read",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_012)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try demoUser.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try otherUser.requireID(),
                role: .member
            ).create(on: app.db)

            for sequence in 1...2 {
                try await ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: try otherUser.requireID(),
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "client-cross-read-\(sequence)",
                    content: .richText(.plain("cross-read-\(sequence)"))
                ).create(on: app.db)
            }
            try await IMConversationSummaryProjectionService(db: app.db).refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [try demoUser.requireID()]
            )

            var baselineToken = ""
            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondDeviceToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.first?.id == conversationID)
                #expect(page.items.first?.lastReadSequence == 0)
                #expect(page.items.first?.unreadCount == 2)
                baselineToken = page.snapshotToken
            })

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/read", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: firstDeviceToken)
                try req.content.encode(IMConversationReadRequest(readSequence: 2))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(IMConversationReadResponse.self)
                #expect(response.lastReadSequence == 2)
                #expect(response.unreadCount == 0)
            })

            try await app.testing().test(.GET, queryPath("api/im/conversations/changes", items: [
                URLQueryItem(name: "afterToken", value: baselineToken)
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondDeviceToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let changes = try res.content.decode(IMConversationChangesResponse.self)
                #expect(changes.upserts.count == 1)
                #expect(changes.upserts.first?.id == conversationID)
                #expect(changes.upserts.first?.lastReadSequence == 2)
                #expect(changes.upserts.first?.unreadCount == 0)
                #expect(changes.removedConversationIDs.isEmpty)
            })
        }
    }


}
