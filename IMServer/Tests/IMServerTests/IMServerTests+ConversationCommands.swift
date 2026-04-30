@testable import IMServer
import Fluent
import NIOCore
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("IM create conversation endpoint respects explicit direct kind and clears title")
    func createConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "create-peer@example.com", on: app)
            var createdConversationID: UUID?

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: "Fresh Chat",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                createdConversationID = conversation.id
                #expect(conversation.title == nil)
                #expect(conversation.kind == IMConversationKind.direct.rawValue)
                #expect(conversation.directMessagingState == IMDirectMessagingState.active.rawValue)
                #expect(conversation.directPeer == IMDirectPeerResponse(id: try peerUser.requireID(), email: peerUser.email))
                #expect(conversation.memberCount == 2)
                #expect(conversation.lastMessage == nil)
                #expect(conversation.lastReadSequence == 0)
                #expect(conversation.unreadCount == 0)
                #expect(conversation.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try peerUser.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })

            let conversationID = try #require(createdConversationID)
            let directoryEntry = try await ConversationDirectoryEntry.find(conversationID, on: app.db)
            #expect(directoryEntry?.shardID == SingleShardConversationShardRouter.defaultShardID)

            let pairHash = [try demoUser.requireID(), try peerUser.requireID()]
                .map(\.uuidString)
                .sorted()
                .joined(separator: ":")
            let directIndexEntry = try await DirectConversationIndexEntry.find(pairHash, on: app.db)
            #expect(directIndexEntry?.conversationID == conversationID)
        }
    }


    @Test("IM create conversation endpoint creates group for three or more members")
    func createGroupConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let firstPeer = try await makeUser(email: "group-create-first@example.com", on: app)
            let secondPeer = try await makeUser(email: "group-create-second@example.com", on: app)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "Fresh Group",
                        memberEmails: [firstPeer.email, secondPeer.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.title == "Fresh Group")
                #expect(conversation.kind == IMConversationKind.group.rawValue)
                #expect(conversation.memberCount == 3)
                #expect(conversation.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try firstPeer.requireID(),
                    try secondPeer.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })
        }
    }


    @Test("IM group creation writes a system message into summary and history")
    func createGroupConversationPersistsSystemMessage() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let firstPeer = try await makeUser(email: "group-system-first@example.com", on: app)
            let secondPeer = try await makeUser(email: "group-system-second@example.com", on: app)
            var createdConversationID: UUID?

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "System Group",
                        memberEmails: [firstPeer.email, secondPeer.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                createdConversationID = conversation.id
                #expect(conversation.lastMessage?.content.previewText == "\(demoUser.email) 创建了群聊")
                #expect(conversation.lastReadSequence == 1)
                #expect(conversation.unreadCount == 0)
            })

            let conversationID = try #require(createdConversationID)
            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.count == 1)
                #expect(messages[0].content.previewText == "\(demoUser.email) 创建了群聊")
                #expect(messages[0].serverSequence == 1)
            })
        }
    }


    @Test("IM create conversation endpoint preserves explicit group kind for two members")
    func createTwoMemberGroupConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "two-member-group@example.com", on: app)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "Two Member Group",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.title == "Two Member Group")
                #expect(conversation.kind == IMConversationKind.group.rawValue)
                #expect(conversation.memberCount == 2)
                #expect(conversation.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try peerUser.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })
        }
    }


    @Test("IM create conversation endpoint allows duplicate explicit two-member groups")
    func createTwoMemberGroupConversationDoesNotReuseExistingGroup() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let peerUser = try await makeUser(email: "two-member-group-duplicate@example.com", on: app)
            var createdConversationIDs: [UUID] = []

            for title in ["Two Member Group A", "Two Member Group B"] {
                try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(
                        IMConversationCreateRequest(
                            kind: IMConversationKind.group.rawValue,
                            title: title,
                            memberEmails: [peerUser.email]
                        )
                    )
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)

                    let conversation = try res.content.decode(IMConversationResponse.self)
                    #expect(conversation.title == title)
                    #expect(conversation.kind == IMConversationKind.group.rawValue)
                    #expect(conversation.memberCount == 2)
                    createdConversationIDs.append(conversation.id)
                })
            }

            #expect(Set(createdConversationIDs).count == 2)

            let conversations = try await Conversation.query(on: app.db).all()
            #expect(conversations.count == 2)
            #expect(conversations.allSatisfy { $0.conversationKind == .group })
        }
    }


    @Test("IM create conversation endpoint marks untitled two-member conversations as direct")
    func createDirectConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "direct-peer@example.com", on: app)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: nil,
                        title: nil,
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.title == nil)
                #expect(conversation.kind == IMConversationKind.direct.rawValue)
                #expect(conversation.memberCount == 2)
                #expect(conversation.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try peerUser.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })
        }
    }


    @Test("IM create conversation endpoint reuses existing two-member conversation")
    func createDirectConversationReusesExistingConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let peerUser = try await makeUser(email: "direct-reuse-peer@example.com", on: app)
            var firstConversationID: UUID?
            let requestedTitles: [String?] = [nil, "Duplicate Title"]

            for title in requestedTitles {
                try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(
                        IMConversationCreateRequest(
                            kind: IMConversationKind.direct.rawValue,
                            title: title,
                            memberEmails: [peerUser.email]
                        )
                    )
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)

                    let conversation = try res.content.decode(IMConversationResponse.self)
                    #expect(conversation.title == nil)
                    #expect(conversation.kind == IMConversationKind.direct.rawValue)
                    if let firstConversationID {
                        #expect(conversation.id == firstConversationID)
                    } else {
                        firstConversationID = conversation.id
                    }
                })
            }

            let conversations = try await Conversation.query(on: app.db).all()
            let matchingMemberships = try await ConversationMember.query(on: app.db)
                .filter(\.$conversation.$id == firstConversationID!)
                .all()
            #expect(conversations.count == 1)
            #expect(matchingMemberships.count == 2)
        }
    }


    @Test("IM create conversation endpoint reuses frozen direct conversation")
    func createDirectConversationReusesFrozenConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "direct-frozen-reuse@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()

            let existingConversation = Conversation(
                title: nil,
                kind: .direct,
                directMessagingState: .frozenAfterUnfriend,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_900)
            )
            try await existingConversation.create(on: app.db)
            let existingConversationID = try existingConversation.requireID()

            try await ConversationMember(conversationID: existingConversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: existingConversationID, userID: peerUserID)
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: "Should Reuse Frozen",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.id == existingConversationID)
                #expect(conversation.kind == IMConversationKind.direct.rawValue)
                #expect(conversation.title == nil)
                #expect(conversation.directMessagingState == IMDirectMessagingState.frozenAfterUnfriend.rawValue)
                #expect(conversation.directPeer == IMDirectPeerResponse(id: peerUserID, email: peerUser.email))
            })

            let conversations = try await Conversation.query(on: app.db).all()
            #expect(conversations.count == 1)
            #expect(conversations.first?.directMessagingStateEnum == .frozenAfterUnfriend)

            let pairHash = [demoUserID, peerUserID]
                .map(\.uuidString)
                .sorted()
                .joined(separator: ":")
            let directIndexEntry = try await DirectConversationIndexEntry.find(pairHash, on: app.db)
            #expect(directIndexEntry?.conversationID == existingConversationID)
        }
    }


    @Test("IM add members endpoint rejects direct conversations")
    func imAddMembersRejectsDirectConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "direct-members-peer@example.com", on: app)
            let newUser = try await makeUser(email: "direct-members-new@example.com", on: app)
            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_004)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationMemberUpdateRequest(memberEmails: [newUser.email])
                )
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("私聊会话不支持新增成员"))
            })
        }
    }


    @Test("IM add members endpoint adds only new group members and updates summary")
    func imAddMembers() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let existingUser = try await makeUser(email: "group-existing@example.com", on: app)
            let newUser = try await makeUser(email: "group-new@example.com", on: app)
            let conversation = Conversation(
                title: "Study Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_005)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try demoUser.requireID(),
                role: .owner
            )
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try existingUser.requireID())
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationMemberUpdateRequest(
                        memberEmails: [existingUser.email, newUser.email, newUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMConversationResponse.self)
                #expect(response.id == conversationID)
                #expect(response.kind == IMConversationKind.group.rawValue)
                #expect(response.memberCount == 3)
                #expect(response.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try existingUser.requireID(),
                    try newUser.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })

            let members = try await ConversationMember.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
            #expect(members.count == 3)
        }
    }


    @Test("IM add members endpoint requires at least one actual new member")
    func imAddMembersRejectsNoOp() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let existingUser = try await makeUser(email: "group-noop@example.com", on: app)
            let conversation = Conversation(
                title: "Study Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try demoUser.requireID(),
                role: .owner
            )
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try existingUser.requireID())
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationMemberUpdateRequest(memberEmails: [existingUser.email, existingUser.email])
                )
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("没有可新增的成员"))
            })
        }
    }


    @Test("IM add members endpoint rejects plain group members")
    func imAddMembersRejectsPlainMember() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let memberUser = try await makeUser(email: "group-member@example.com", on: app)
            let newUser = try await makeUser(email: "group-member-new@example.com", on: app)
            let memberAccessToken = try await loginAccessToken(
                email: memberUser.email,
                password: "password1234",
                deviceID: "group-member-device",
                on: app
            )
            let conversation = Conversation(
                title: "Privilege Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try memberUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: memberAccessToken)
                try req.content.encode(
                    IMConversationMemberUpdateRequest(memberEmails: [newUser.email])
                )
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("只有群主或管理员可以添加成员"))
            })
        }
    }


    @Test("IM owner can promote admin and admin can remove member")
    func imOwnerPromotesAdminAndAdminRemovesMember() async throws {
        try await withApp(configure: configure) { app in
            let ownerAccessToken = try await loginAccessToken(using: app)
            let owner = try await user(email: "demo@example.com", on: app)
            let adminCandidate = try await makeUser(email: "admin-candidate@example.com", on: app)
            let removableMember = try await makeUser(email: "removable-member@example.com", on: app)
            let adminCandidateID = try adminCandidate.requireID()
            let removableMemberID = try removableMember.requireID()
            let adminAccessToken = try await loginAccessToken(
                email: adminCandidate.email,
                password: "password1234",
                deviceID: "admin-candidate-device",
                on: app
            )
            let conversation = Conversation(
                title: "Ops Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: adminCandidateID,
                role: .member
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: removableMemberID,
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members/\(adminCandidateID.uuidString)/role", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
                try req.content.encode(
                    IMConversationMemberRoleUpdateRequest(role: IMConversationMemberRole.admin.rawValue)
                )
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members/\(removableMemberID.uuidString)/remove", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: adminAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(IMConversationResponse.self)
                #expect(response.memberCount == 2)
            })

            let memberships = try await ConversationMember.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
            #expect(memberships.count == 2)
            #expect(
                memberships.first(where: { $0.$user.id == adminCandidateID })?.memberRoleEnum == .admin
            )
        }
    }


    @Test("IM admin cannot update another member's group role")
    func imAdminCannotUpdateMemberRole() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let adminUser = try await makeUser(email: "role-admin@example.com", on: app)
            let targetUser = try await makeUser(email: "role-target@example.com", on: app)
            let adminAccessToken = try await loginAccessToken(
                email: adminUser.email,
                password: "password1234",
                deviceID: "role-admin-device",
                on: app
            )
            let conversation = Conversation(
                title: "Role Boundaries",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try adminUser.requireID(),
                role: .admin
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try targetUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members/\(try targetUser.requireID().uuidString)/role", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: adminAccessToken)
                try req.content.encode(
                    IMConversationMemberRoleUpdateRequest(role: IMConversationMemberRole.admin.rawValue)
                )
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("只有群主可以调整成员角色"))
            })
        }
    }


    @Test("IM member cannot rename group conversation")
    func imMemberCannotRenameGroupConversation() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let memberUser = try await makeUser(email: "rename-member@example.com", on: app)
            let memberAccessToken = try await loginAccessToken(
                email: memberUser.email,
                password: "password1234",
                deviceID: "rename-member-device",
                on: app
            )
            let conversation = Conversation(
                title: "Rename Boundaries",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try memberUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/title", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: memberAccessToken)
                try req.content.encode(IMConversationTitleUpdateRequest(title: "Illegal Rename"))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("只有群主或管理员可以修改群名称"))
            })
        }
    }


    @Test("IM removed member can no longer manage the conversation")
    func imRemovedMemberCannotManageConversation() async throws {
        try await withApp(configure: configure) { app in
            let ownerAccessToken = try await loginAccessToken(using: app)
            let owner = try await user(email: "demo@example.com", on: app)
            let removedUser = try await makeUser(email: "removed-manager@example.com", on: app)
            let removedAccessToken = try await loginAccessToken(
                email: removedUser.email,
                password: "password1234",
                deviceID: "removed-manager-device",
                on: app
            )
            let conversation = Conversation(
                title: "Removal Boundaries",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try removedUser.requireID(),
                role: .member
            ).create(on: app.db)
            let extraUser = try await makeUser(email: "removed-extra@example.com", on: app)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try extraUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members/\(try removedUser.requireID().uuidString)/remove", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/title", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: removedAccessToken)
                try req.content.encode(IMConversationTitleUpdateRequest(title: "Should Not Work"))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }


    @Test("IM owner must transfer ownership before leaving group")
    func imOwnerMustTransferBeforeLeaving() async throws {
        try await withApp(configure: configure) { app in
            let ownerAccessToken = try await loginAccessToken(using: app)
            let owner = try await user(email: "demo@example.com", on: app)
            let secondUser = try await makeUser(email: "owner-transfer-second@example.com", on: app)
            let thirdUser = try await makeUser(email: "owner-transfer-third@example.com", on: app)
            let conversation = Conversation(
                title: "Transfer Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try secondUser.requireID(),
                role: .member
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try thirdUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/leave", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("群主退出前请先转让群主"))
            })
        }
    }


    @Test("IM leave endpoint rejects direct conversations")
    func imLeaveRejectsDirectConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "leave-direct-peer@example.com", on: app)
            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_007)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/leave", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("私聊会话不支持主动退出"))
            })
        }
    }


    @Test("IM leave endpoint rejects groups that would drop below two members")
    func imLeaveRejectsTooSmallGroup() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "leave-small-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Tiny Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_008)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/leave", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("退出后会话成员不能少于 2 人"))
            })
        }
    }


    @Test("IM leave endpoint removes the current member and keeps remaining summaries consistent")
    func imLeaveConversation() async throws {
        try await withApp(configure: configure) { app in
            let demoAccessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "leave-peer@example.com", on: app)
            let thirdUser = try await makeUser(email: "leave-third@example.com", on: app)
            let otherAccessToken = try await loginAccessToken(
                email: otherUser.email,
                password: "password1234",
                deviceID: "leave-peer-device",
                on: app
            )
            let conversation = Conversation(
                title: "Leave Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_009)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try thirdUser.requireID())
                .create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try thirdUser.requireID(),
                serverSequence: 1,
                kind: "text",
                body: ["text": "hello after join"]
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/leave", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: demoAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: demoAccessToken)
            }, afterResponse: { res async throws in
                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.isEmpty)
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: otherAccessToken)
            }, afterResponse: { res async throws in
                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.count == 1)
                #expect(conversations[0].id == conversationID)
                #expect(conversations[0].kind == IMConversationKind.group.rawValue)
                #expect(conversations[0].memberCount == 2)
                #expect(conversations[0].lastReadSequence == 0)
                #expect(conversations[0].unreadCount == 2)
                #expect(conversations[0].lastMessage?.content.previewText == "\(demoUser.email) 退出了群聊")
            })
        }
    }


    @Test("IM recall endpoint replaces message content and refreshes summaries")
    func imRecallMessage() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "recall-peer@example.com", on: app)

            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_060),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try peerUser.requireID())
                .create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try demoUser.requireID(),
                serverSequence: 1,
                content: .text("hello recall")
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()

            try await IMConversationSummaryProjectionService(db: app.db).refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [try demoUser.requireID(), try peerUser.requireID()]
            )

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/recall", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let recalled = try res.content.decode(IMMessageResponse.self)
                #expect(recalled.id == messageID)
                #expect(recalled.content == .recalled)
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.count == 1)
                #expect(messages[0].id == messageID)
                #expect(messages[0].content == .recalled)
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.count == 1)
                #expect(conversations[0].id == conversationID)
                #expect(conversations[0].lastMessage?.content == .recalled)
            })
        }
    }


    @Test("IM recall endpoint rejects messages outside the recall window")
    func imRecallMessageRejectsExpiredWindow() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "recall-expired-peer@example.com", on: app)

            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_061),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try peerUser.requireID())
                .create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try demoUser.requireID(),
                serverSequence: 1,
                content: .text("expired recall")
            )
            try await message.create(on: app.db)
            message.createdAt = Date().addingTimeInterval(-(3 * 60))
            try await message.update(on: app.db)
            let messageID = try message.requireID()

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/recall", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("消息发送超过 2 分钟后不能撤回"))
            })
        }
    }


    @Test("IM edit endpoint appends derived edit state and refreshes summary preview")
    func imEditMessageUpdatesDerivedStateAndSummaryPreview() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "edit-peer@example.com", on: app)

            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_062),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try peerUser.requireID())
                .create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try demoUser.requireID(),
                serverSequence: 1,
                content: .text("before edit")
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()

            try await IMConversationSummaryProjectionService(db: app.db).refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [try demoUser.requireID(), try peerUser.requireID()]
            )

            try await app.testing().test(
                .POST,
                "api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/edit",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(IMConversationMessageEditRequest(text: "after edit"))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let edited = try res.content.decode(IMMessageResponse.self)
                    #expect(edited.content == .text("before edit"))
                    #expect(edited.derivedState.edits.last?.text == "after edit")
                }
            )

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    let messages = try res.content.decode([IMMessageResponse].self)
                    #expect(messages.count == 1)
                    #expect(messages[0].content == .text("before edit"))
                    #expect(messages[0].derivedState.edits.last?.text == "after edit")
                }
            )

            try await app.testing().test(
                .GET,
                "api/im/conversations",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    let conversations = try res.content.decode(IMConversationPageResponse.self).items
                    #expect(conversations.count == 1)
                    #expect(
                        conversations[0].lastMessage.map {
                            MessagePresentation(
                                aggregate: $0.content.aggregate(derivedState: $0.derivedState)
                            ).previewText
                        } == "after edit"
                    )
                    #expect(conversations[0].lastMessage?.derivedState.edits.last?.text == "after edit")
                }
            )
        }
    }


    @Test("IM reaction endpoint toggles derived reaction state")
    func imToggleReactionUpdatesDerivedState() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "reaction-peer@example.com", on: app)

            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_063),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try peerUser.requireID())
                .create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try peerUser.requireID(),
                serverSequence: 1,
                content: .text("react here")
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()

            try await app.testing().test(
                .POST,
                "api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/reactions",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(IMConversationMessageReactionRequest(emoji: "👍"))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let updated = try res.content.decode(IMMessageResponse.self)
                    #expect(updated.derivedState.reactions == [
                        IMMessageReaction(emoji: "👍", actorUserIDs: [try demoUser.requireID()])
                    ])
                }
            )

            try await app.testing().test(
                .POST,
                "api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/reactions",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(IMConversationMessageReactionRequest(emoji: "👍"))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let updated = try res.content.decode(IMMessageResponse.self)
                    #expect(updated.derivedState.reactions.isEmpty)
                }
            )
        }
    }


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
                    clientMessageID: "client-read-\(sequence)",
                    kind: "text",
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
                    clientMessageID: "client-cross-read-\(sequence)",
                    content: .text("cross-read-\(sequence)")
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


    @Test("IM metadata update persists fields and emits a structured system message")
    func imConversationMetadataUpdatePersistsAndEmitsStructuredSystemMessage() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let demoUserID = try demoUser.requireID()
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
                #expect(messages.count == 1)
                guard case .system(let event) = messages[0].content else {
                    Issue.record("Expected metadata update to emit a system message")
                    return
                }

                #expect(event.type == .metadataUpdated)
                #expect(event.actorUserID == demoUserID)
                #expect(event.actorEmail == "demo@example.com")
                #expect(event.updatedFields == [.title, .notice, .avatarPreset])
                #expect(event.title == "Updated Title")
                #expect(event.notice == "Ship checklist at 18:00")
                #expect(event.avatarPreset == .forest)
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
                #expect(messages.count == 1)
                guard case .system(let event) = messages[0].content else {
                    Issue.record("Expected metadata update to emit a system message")
                    return
                }

                #expect(event.type == .metadataUpdated)
                #expect(event.updatedFields == [.notice])
                #expect(event.notice == "Only notice changed")
                #expect(event.title == "Original Title")
                #expect(event.avatarPreset == .ocean)
            })
        }
    }

}
