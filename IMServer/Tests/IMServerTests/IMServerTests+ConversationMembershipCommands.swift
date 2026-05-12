@testable import IMServer
import Fluent
import NIOCore
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("Group member limit defaults to five hundred")
    func groupMemberLimitDefaultsToFiveHundred() throws {
        let originalLimit = Environment.get(IMGroupMemberLimitConfiguration.environmentKey)
        defer { restoreEnvironment(IMGroupMemberLimitConfiguration.environmentKey, to: originalLimit) }
        unsetenv(IMGroupMemberLimitConfiguration.environmentKey)

        let configuration = IMGroupMemberLimitConfiguration.load(from: .testing)
        #expect(configuration.limit == 500)
        try IMGroupMemberLimitGuard.validateGroupMemberCount(500, configuration: configuration)

        do {
            try IMGroupMemberLimitGuard.validateGroupMemberCount(501, configuration: configuration)
            Issue.record("Expected group member limit to reject 501 members")
        } catch let abort as any AbortError {
            #expect(abort.status == .badRequest)
            #expect(abort.reason.contains("500"))
        } catch {
            Issue.record("Unexpected group member limit error: \(error)")
        }
    }

    @Test("Group member limit rejects create and add while direct conversations remain allowed")
    func groupMemberLimitRejectsCreateAndAddWhileDirectRemainsAllowed() async throws {
        let originalLimit = Environment.get(IMGroupMemberLimitConfiguration.environmentKey)
        defer { restoreEnvironment(IMGroupMemberLimitConfiguration.environmentKey, to: originalLimit) }
        setenv(IMGroupMemberLimitConfiguration.environmentKey, "3", 1)

        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let owner = try await user(email: "demo@example.com", on: app)
            let memberA = try await makeUser(email: "group-limit-a@example.com", on: app)
            let memberB = try await makeUser(email: "group-limit-b@example.com", on: app)
            let memberC = try await makeUser(email: "group-limit-c@example.com", on: app)
            let directPeer = try await makeUser(email: "group-limit-direct@example.com", on: app)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: nil,
                        memberEmails: [directPeer.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(IMConversationResponse.self)
                #expect(response.kind == IMConversationKind.direct.rawValue)
                #expect(response.memberCount == 2)
            })

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "Too Large",
                        memberEmails: [memberA.email, memberB.email, memberC.email]
                    )
                )
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("小群成员数不能超过 3 人"))
            })

            let expandableConversation = Conversation(
                title: "Expandable Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_002)
            )
            try await expandableConversation.create(on: app.db)
            let expandableConversationID = try expandableConversation.requireID()
            try await ConversationMember(
                conversationID: expandableConversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(conversationID: expandableConversationID, userID: try memberA.requireID())
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(expandableConversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(IMConversationMemberUpdateRequest(memberEmails: [memberB.email]))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(IMConversationResponse.self)
                #expect(response.memberCount == 3)
            })

            let conversation = Conversation(
                title: "Limited Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_003)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try memberA.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try memberB.requireID())
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(IMConversationMemberUpdateRequest(memberEmails: [memberC.email]))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("小群成员数不能超过 3 人"))
            })
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
            let secondUser = try await makeUser(email: "owner-transfer-second@example.com", on: app)
            let thirdUser = try await makeUser(email: "owner-transfer-third@example.com", on: app)
            var createdConversationID: UUID?

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "Transfer Group",
                        memberEmails: [secondUser.email, thirdUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                createdConversationID = try res.content.decode(IMConversationResponse.self).id
            })

            let conversationID = try #require(createdConversationID)
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
            let otherUser = try await makeUser(email: "leave-direct-peer@example.com", on: app)
            var createdConversationID: UUID?

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: nil,
                        memberEmails: [otherUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                createdConversationID = try res.content.decode(IMConversationResponse.self).id
            })

            let conversationID = try #require(createdConversationID)
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
            let otherUser = try await makeUser(email: "leave-small-peer@example.com", on: app)
            let otherAccessToken = try await loginAccessToken(
                email: otherUser.email,
                password: "password1234",
                deviceID: "leave-small-peer-device",
                on: app
            )
            var createdConversationID: UUID?

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "Tiny Group",
                        memberEmails: [otherUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let conversation = try res.content.decode(IMConversationResponse.self)
                createdConversationID = conversation.id
                #expect(conversation.kind == IMConversationKind.group.rawValue)
                #expect(conversation.memberCount == 2)
            })

            let conversationID = try #require(createdConversationID)
            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/leave", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: otherAccessToken)
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
            let otherUser = try await makeUser(email: "leave-peer@example.com", on: app)
            let thirdUser = try await makeUser(email: "leave-third@example.com", on: app)
            let otherAccessToken = try await loginAccessToken(
                email: otherUser.email,
                password: "password1234",
                deviceID: "leave-peer-device",
                on: app
            )
            var createdConversationID: UUID?

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: demoAccessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "Leave Group",
                        memberEmails: [otherUser.email, thirdUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let conversation = try res.content.decode(IMConversationResponse.self)
                createdConversationID = conversation.id
                #expect(conversation.kind == IMConversationKind.group.rawValue)
                #expect(conversation.memberCount == 3)
            })

            let conversationID = try #require(createdConversationID)
            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/leave", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: otherAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: otherAccessToken)
            }, afterResponse: { res async throws in
                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.isEmpty)
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: demoAccessToken)
            }, afterResponse: { res async throws in
                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.count == 1)
                #expect(conversations[0].id == conversationID)
                #expect(conversations[0].kind == IMConversationKind.group.rawValue)
                #expect(conversations[0].memberCount == 2)
                #expect(conversations[0].lastReadSequence == 1)
                #expect(conversations[0].unreadCount == 1)
                #expect(conversations[0].lastMessage?.content.previewText == "\(otherUser.email) 退出了群聊")
            })
        }
    }


}
