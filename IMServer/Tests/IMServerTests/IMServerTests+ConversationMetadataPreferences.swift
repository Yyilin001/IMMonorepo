@testable import IMServer
import Fluent
import NIOCore
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("IM conversation preference changes sync across devices")
    func imConversationPreferenceChangesSyncAcrossDevices() async throws {
        try await withApp(configure: configure) { app in
            let firstDeviceToken = try await loginAccessToken(
                email: "demo@example.com",
                password: "password1234",
                deviceID: "preferences-device-1",
                on: app
            )
            let secondDeviceToken = try await loginAccessToken(
                email: "demo@example.com",
                password: "password1234",
                deviceID: "preferences-device-2",
                on: app
            )
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "preferences-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Preferences",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_500_100)
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
                userID: try peerUser.requireID(),
                role: .member
            ).create(on: app.db)

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
                #expect(page.items.count == 1)
                #expect(page.items[0].isPinned == false)
                #expect(page.items[0].isMuted == false)
                baselineToken = page.snapshotToken
            })

            try await app.testing().test(.PATCH, "api/im/conversations/\(conversationID.uuidString)/preferences", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: firstDeviceToken)
                try req.content.encode(
                    IMConversationPreferencesUpdateRequest(isPinned: true, isMuted: true)
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(IMConversationResponse.self)
                #expect(response.isPinned == true)
                #expect(response.pinnedAt != nil)
                #expect(response.isMuted == true)
            })

            try await app.testing().test(.GET, queryPath("api/im/conversations/changes", items: [
                URLQueryItem(name: "afterToken", value: baselineToken)
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondDeviceToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let changes = try res.content.decode(IMConversationChangesResponse.self)
                #expect(changes.upserts.count == 1)
                #expect(changes.upserts[0].id == conversationID)
                #expect(changes.upserts[0].isPinned == true)
                #expect(changes.upserts[0].pinnedAt != nil)
                #expect(changes.upserts[0].isMuted == true)
            })
        }
    }


    @Test("Profile update refreshes direct peer in summary changes")
    func profileUpdateRefreshesDirectPeerInSummaryChanges() async throws {
        try await withApp(configure: configure) { app in
            let ownerToken = try await loginAccessToken(
                email: "demo@example.com",
                password: "password1234",
                deviceID: "profile-owner-device",
                on: app
            )
            let peer = User(
                email: User.normalize("profile-peer@example.com"),
                passwordHash: try Bcrypt.hash("password1234"),
                status: .active
            )
            try await peer.create(on: app.db)
            let peerToken = try await loginAccessToken(
                email: peer.email,
                password: "password1234",
                deviceID: "profile-peer-device",
                on: app
            )
            let ownerUser = try await user(email: "demo@example.com", on: app)
            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_510_000)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            let peerUserID = try peer.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try ownerUser.requireID(),
                role: .member
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: peerUserID,
                role: .member
            ).create(on: app.db)

            try await IMConversationSummaryProjectionService(db: app.db).refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [try ownerUser.requireID()]
            )

            var baselineToken = ""
            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.count == 1)
                #expect(page.items[0].directPeer == IMDirectPeerResponse(
                    id: peerUserID,
                    email: peer.email,
                    displayName: nil,
                    avatarPreset: nil
                ))
                baselineToken = page.snapshotToken
            })

            try await app.testing().test(.PATCH, "api/me/profile", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: peerToken)
                try req.content.encode(
                    UserProfileUpdateRequest(
                        displayName: "Peer Display",
                        avatarPreset: .rose
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, queryPath("api/im/conversations/changes", items: [
                URLQueryItem(name: "afterToken", value: baselineToken)
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let changes = try res.content.decode(IMConversationChangesResponse.self)
                #expect(changes.upserts.count == 1)
                #expect(changes.upserts[0].id == conversationID)
                #expect(changes.upserts[0].directPeer == IMDirectPeerResponse(
                    id: peerUserID,
                    email: peer.email,
                    displayName: "Peer Display",
                    avatarPreset: .rose
                ))
            })
        }
    }


    @Test("IM metadata update persists fields without writing a system message")
    func imConversationMetadataUpdatePersistsAndEmitsStructuredSystemMessage() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "metadata-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Original Title",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_500_200)
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
                userID: try peerUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.PATCH, "api/im/conversations/\(conversationID.uuidString)/metadata", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationMetadataUpdateRequest(
                        title: "Updated Title",
                        notice: "Ship checklist at 18:00",
                        avatarPreset: .forest
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(IMConversationResponse.self)
                #expect(response.title == "Updated Title")
                #expect(response.notice == "Ship checklist at 18:00")
                #expect(response.avatarPreset == .forest)
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.isEmpty)
            })
        }
    }


    @Test("IM metadata update only records changed fields")
    func imConversationMetadataUpdateOnlyRecordsChangedFields() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "metadata-notice-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Original Title",
                notice: "Old notice",
                avatarPreset: .ocean,
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_500_220)
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
                userID: try peerUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.PATCH, "api/im/conversations/\(conversationID.uuidString)/metadata", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationMetadataUpdateRequest(
                        title: "Original Title",
                        notice: "Only notice changed",
                        avatarPreset: .ocean
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.isEmpty)
            })
        }
    }

}
