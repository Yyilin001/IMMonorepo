@testable import IMServer
import Fluent
import NIOCore
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("Expired refresh session no longer authorizes access token requests")
    func accessTokenStopsWorkingWhenSessionExpires() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let currentSession = try await session(for: "demo@example.com", deviceID: "simulator", on: app)

            currentSession.refreshExpiresAt = Date().addingTimeInterval(-1)
            try await currentSession.update(on: app.db)

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            let expiredSession = try await session(for: "demo@example.com", deviceID: "simulator", on: app)
            #expect(expiredSession.revokedAt != nil)
        }
    }


    @Test("Logout all revokes every active session")
    func logoutAll() async throws {
        try await withApp(configure: configure) { app in
            var firstAccessToken = ""
            var secondAccessToken = ""

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                firstAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(
                    LoginRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: DeviceMetadata(
                            deviceID: "simulator-2",
                            deviceName: "Second Device",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { res async throws in
                secondAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.DELETE, "api/auth/sessions/all", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: firstAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let result = try res.content.decode(LogoutAllResponse.self)
                #expect(result.revokedSessions == 2)
            })

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }


    @Test("Logout all also revokes expired but not yet revoked sessions")
    func logoutAllRevokesExpiredSessions() async throws {
        try await withApp(configure: configure) { app in
            var primaryAccessToken = ""

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(
                    LoginRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: DeviceMetadata(
                            deviceID: "primary-device",
                            deviceName: "Primary Device",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { res async throws in
                primaryAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(
                    LoginRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: DeviceMetadata(
                            deviceID: "stale-device",
                            deviceName: "Stale Device",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { _ async in })

            let staleSession = try await session(for: "demo@example.com", deviceID: "stale-device", on: app)
            staleSession.refreshExpiresAt = Date().addingTimeInterval(-1)
            try await staleSession.update(on: app.db)

            try await app.testing().test(.DELETE, "api/auth/sessions/all", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: primaryAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let result = try res.content.decode(LogoutAllResponse.self)
                #expect(result.revokedSessions == 2)
            })

            let revokedStaleSession = try await session(for: "demo@example.com", deviceID: "stale-device", on: app)
            #expect(revokedStaleSession.revokedAt != nil)
        }
    }


    @Test("Logging in twice on the same device revokes the previous session")
    func singleActiveSessionPerDevice() async throws {
        try await withApp(configure: configure) { app in
            var firstAccessToken = ""
            var secondAccessToken = ""

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                firstAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                secondAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: firstAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.GET, "api/auth/sessions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondAccessToken)
            }, afterResponse: { res async throws in
                let sessions = try res.content.decode([AuthSessionResponse].self)
                #expect(sessions.count == 1)
                #expect(sessions[0].deviceID == "simulator")
                #expect(sessions[0].isCurrent == true)
            })
        }
    }


    @Test("Specific device logout revokes only the targeted session")
    func logoutSpecificSession() async throws {
        try await withApp(configure: configure) { app in
            var primaryAccessToken = ""
            var secondaryAccessToken = ""
            var secondarySessionID: UUID?

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(
                    LoginRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: DeviceMetadata(
                            deviceID: "primary-device",
                            deviceName: "Primary Device",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { res async throws in
                primaryAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(
                    LoginRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: DeviceMetadata(
                            deviceID: "secondary-device",
                            deviceName: "Secondary Device",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { res async throws in
                secondaryAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.GET, "api/auth/sessions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: primaryAccessToken)
            }, afterResponse: { res async throws in
                let sessions = try res.content.decode([AuthSessionResponse].self)
                secondarySessionID = sessions.first(where: { $0.deviceID == "secondary-device" })?.id
            })

            guard let secondarySessionID else {
                Issue.record("Missing secondary session id")
                return
            }

            try await app.testing().test(.DELETE, "api/auth/sessions/\(secondarySessionID.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: primaryAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondaryAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: primaryAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }


    @Test("Authenticated upload is persisted and can be downloaded")
    func uploadAndDownloadFile() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let payload = "sample file payload"

            try await app.testing().test(.POST, "api/files/upload", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                req.headers.contentType = .init(type: "application", subType: "octet-stream")
                req.body = ByteBuffer(string: payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/files/download", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .acceptRanges) == "bytes")
                #expect(res.body.string == payload)
            })
        }
    }


    @Test("Friend request accept creates bilateral contacts")
    func friendRequestAcceptCreatesBilateralContacts() async throws {
        try await withApp(configure: configure) { app in
            let requesterToken = try await loginAccessToken(using: app)
            let requester = try await user(email: "demo@example.com", on: app)
            let addressee = try await makeUser(email: "friend-accept@example.com", on: app)
            let addresseeToken = try await loginAccessToken(
                email: addressee.email,
                password: "password1234",
                deviceID: "friend-accept-device",
                on: app
            )
            var requestID: UUID?

            try await app.testing().test(.POST, "api/contact-requests", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
                try req.content.encode(
                    ContactRequestCreateRequest(
                        email: addressee.email,
                        message: "我是 demo",
                        remark: "好友备注"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(FriendRequestResponse.self)
                requestID = response.id
                #expect(response.status == FriendRequestStatus.pending.rawValue)
                #expect(response.requester.email == requester.email)
                #expect(response.addressee.email == addressee.email)
                #expect(response.requesterRemark == "好友备注")
            })

            try await app.testing().test(.GET, "api/contact-requests?box=outgoing", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
            }, afterResponse: { res async throws in
                let requests = try res.content.decode([FriendRequestResponse].self)
                #expect(requests.map(\.id) == [requestID])
            })

            try await app.testing().test(.GET, "api/contact-requests?box=incoming", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: addresseeToken)
            }, afterResponse: { res async throws in
                let requests = try res.content.decode([FriendRequestResponse].self)
                #expect(requests.map(\.id) == [requestID])
            })

            let acceptedRequestID = try #require(requestID)
            try await app.testing().test(.POST, "api/contact-requests/\(acceptedRequestID.uuidString)/accept", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: addresseeToken)
                try req.content.encode(ContactRequestAcceptRequest(remark: "Demo 备注"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let contact = try res.content.decode(ContactResponse.self)
                #expect(contact.email == requester.email)
                #expect(contact.remark == "Demo 备注")
            })

            try await app.testing().test(.GET, "api/contacts", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
            }, afterResponse: { res async throws in
                let contacts = try res.content.decode([ContactResponse].self)
                #expect(contacts.map(\.email) == [addressee.email])
                #expect(contacts.first?.remark == "好友备注")
            })

            try await app.testing().test(.GET, "api/contacts", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: addresseeToken)
            }, afterResponse: { res async throws in
                let contacts = try res.content.decode([ContactResponse].self)
                #expect(contacts.map(\.email) == [requester.email])
                #expect(contacts.first?.remark == "Demo 备注")
            })
        }
    }

    @Test("Contact changes endpoint reports request contact and removal deltas")
    func contactChangesReportsRequestContactAndRemovalDeltas() async throws {
        try await withApp(configure: configure) { app in
            func queryEncoded(_ value: String) throws -> String {
                var allowedCharacters = CharacterSet.urlQueryAllowed
                allowedCharacters.remove(charactersIn: "+&=")
                return try #require(value.addingPercentEncoding(withAllowedCharacters: allowedCharacters))
            }

            let requesterToken = try await loginAccessToken(using: app)
            let addressee = try await makeUser(email: "friend-changes@example.com", on: app)
            let addresseeID = try addressee.requireID()
            let addresseeToken = try await loginAccessToken(
                email: addressee.email,
                password: "password1234",
                deviceID: "friend-changes-device",
                on: app
            )
            var requestID: UUID?
            var requesterCursor = ""
            var addresseeCursor = ""
            var acceptedRequesterCursor = ""

            try await app.testing().test(.POST, "api/contact-requests", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
                try req.content.encode(
                    ContactRequestCreateRequest(
                        email: addressee.email,
                        message: "changes",
                        remark: "delta"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                requestID = try res.content.decode(FriendRequestResponse.self).id
            })

            let createdRequestID = try #require(requestID)
            try await app.testing().test(.GET, "api/contacts/changes?limit=10", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let changes = try res.content.decode(ContactChangesResponse.self)
                #expect(changes.requestUpserts.map(\.id) == [createdRequestID])
                #expect(changes.requestUpserts.first?.status == FriendRequestStatus.pending.rawValue)
                #expect(changes.contactUpserts.isEmpty)
                #expect(changes.removedContactIDs.isEmpty)
                requesterCursor = changes.targetToken
            })

            try await app.testing().test(.GET, "api/contacts/changes?limit=10", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: addresseeToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let changes = try res.content.decode(ContactChangesResponse.self)
                #expect(changes.requestUpserts.map(\.id) == [createdRequestID])
                #expect(changes.requestUpserts.first?.status == FriendRequestStatus.pending.rawValue)
                #expect(changes.contactUpserts.isEmpty)
                addresseeCursor = changes.targetToken
            })

            try await app.testing().test(.POST, "api/contact-requests/\(createdRequestID.uuidString)/accept", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: addresseeToken)
                try req.content.encode(ContactRequestAcceptRequest(remark: "accepted"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/contacts/changes?afterToken=\(try queryEncoded(requesterCursor))&limit=10", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let changes = try res.content.decode(ContactChangesResponse.self)
                #expect(changes.requestUpserts.map(\.id) == [createdRequestID])
                #expect(changes.requestUpserts.first?.status == FriendRequestStatus.accepted.rawValue)
                #expect(changes.contactUpserts.map(\.id) == [addresseeID])
                #expect(changes.removedContactIDs.isEmpty)
                acceptedRequesterCursor = changes.targetToken
            })

            try await app.testing().test(.GET, "api/contacts/changes?afterToken=\(try queryEncoded(addresseeCursor))&limit=10", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: addresseeToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let changes = try res.content.decode(ContactChangesResponse.self)
                #expect(changes.requestUpserts.map(\.id) == [createdRequestID])
                #expect(changes.requestUpserts.first?.status == FriendRequestStatus.accepted.rawValue)
                #expect(changes.contactUpserts.count == 1)
                #expect(changes.removedContactIDs.isEmpty)
            })

            try await app.testing().test(.DELETE, "api/contacts/\(addresseeID.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/contacts/changes?afterToken=\(try queryEncoded(acceptedRequesterCursor))&limit=10", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let changes = try res.content.decode(ContactChangesResponse.self)
                #expect(changes.contactUpserts.isEmpty)
                #expect(changes.removedContactIDs == [addresseeID])
            })
        }
    }


    @Test("Accepting a friend request reactivates an existing frozen direct conversation")
    func friendRequestAcceptReactivatesFrozenDirectConversation() async throws {
        try await withApp(configure: configure) { app in
            let requester = try await user(email: "demo@example.com", on: app)
            let requesterID = try requester.requireID()
            let requesterToken = try await loginAccessToken(using: app)
            let addressee = try await makeUser(email: "friend-reactivate@example.com", on: app)
            let addresseeID = try addressee.requireID()
            let addresseeToken = try await loginAccessToken(
                email: addressee.email,
                password: "password1234",
                deviceID: "friend-reactivate-device",
                on: app
            )
            let directConversation = Conversation(
                title: nil,
                kind: .direct,
                directMessagingState: .frozenAfterUnfriend,
                updatedAt: Date(timeIntervalSince1970: 1_700_200_100)
            )
            try await directConversation.create(on: app.db)
            let directConversationID = try directConversation.requireID()

            try await ConversationMember(conversationID: directConversationID, userID: requesterID)
                .create(on: app.db)
            try await ConversationMember(conversationID: directConversationID, userID: addresseeID)
                .create(on: app.db)

            var requestID: UUID?
            try await app.testing().test(.POST, "api/contact-requests", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
                try req.content.encode(
                    ContactRequestCreateRequest(
                        email: addressee.email,
                        message: "重新加好友",
                        remark: "再次备注"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                requestID = try res.content.decode(FriendRequestResponse.self).id
            })

            let acceptedRequestID = try #require(requestID)
            try await app.testing().test(.POST, "api/contact-requests/\(acceptedRequestID.uuidString)/accept", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: addresseeToken)
                try req.content.encode(ContactRequestAcceptRequest(remark: "回来吧"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let reloadedConversation = try await Conversation.find(directConversationID, on: app.db)
            #expect(reloadedConversation?.directMessagingStateEnum == .active)

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.first?.id == directConversationID)
                #expect(conversations.first?.directMessagingState == IMDirectMessagingState.active.rawValue)
                #expect(conversations.first?.directPeer == IMDirectPeerResponse(id: addresseeID, email: addressee.email))
            })

            let requesterContact = try await UserContact.query(on: app.db)
                .filter(\.$owner.$id == requesterID)
                .filter(\.$contact.$id == addresseeID)
                .first()
            let addresseeContact = try await UserContact.query(on: app.db)
                .filter(\.$owner.$id == addresseeID)
                .filter(\.$contact.$id == requesterID)
                .first()
            #expect(requesterContact != nil)
            #expect(addresseeContact != nil)
        }
    }


    @Test("Friend request rejects invalid transitions")
    func friendRequestRejectsInvalidTransitions() async throws {
        try await withApp(configure: configure) { app in
            let requesterToken = try await loginAccessToken(using: app)
            let addressee = try await makeUser(email: "friend-rules@example.com", on: app)
            let addresseeToken = try await loginAccessToken(
                email: addressee.email,
                password: "password1234",
                deviceID: "friend-rules-device",
                on: app
            )
            let stranger = try await makeUser(email: "friend-stranger@example.com", on: app)
            let strangerToken = try await loginAccessToken(
                email: stranger.email,
                password: "password1234",
                deviceID: "friend-stranger-device",
                on: app
            )
            var requestID: UUID?

            try await app.testing().test(.POST, "api/contact-requests", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
                try req.content.encode(ContactRequestCreateRequest(email: "demo@example.com", message: nil, remark: nil))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.POST, "api/contact-requests", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
                try req.content.encode(ContactRequestCreateRequest(email: addressee.email, message: nil, remark: nil))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                requestID = try res.content.decode(FriendRequestResponse.self).id
            })

            try await app.testing().test(.POST, "api/contact-requests", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
                try req.content.encode(ContactRequestCreateRequest(email: addressee.email, message: nil, remark: nil))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            let pendingRequestID = try #require(requestID)
            try await app.testing().test(.POST, "api/contact-requests/\(pendingRequestID.uuidString)/accept", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: strangerToken)
                try req.content.encode(ContactRequestAcceptRequest(remark: nil))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            try await app.testing().test(.POST, "api/contact-requests/\(pendingRequestID.uuidString)/decline", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: addresseeToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/contacts", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
            }, afterResponse: { res async throws in
                let contacts = try res.content.decode([ContactResponse].self)
                #expect(contacts.isEmpty)
            })
        }
    }


    @Test("Contacts direct add is disabled and delete removes both directions")
    func contactsDirectAddDisabledAndDeleteRemovesBothDirections() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let owner = try await user(email: "demo@example.com", on: app)
            let contact = try await makeUser(email: "delete-friend@example.com", on: app)
            let ownerID = try owner.requireID()
            let contactID = try contact.requireID()

            try await app.testing().test(.POST, "api/contacts", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(ContactCreateRequest(email: contact.email, remark: nil))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            try await UserContact(ownerUserID: ownerID, contactUserID: contactID, remark: "peer")
                .create(on: app.db)
            try await UserContact(ownerUserID: contactID, contactUserID: ownerID, remark: "owner")
                .create(on: app.db)
            let directConversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_300_100)
            )
            try await directConversation.create(on: app.db)
            let directConversationID = try directConversation.requireID()
            try await ConversationMember(conversationID: directConversationID, userID: ownerID)
                .create(on: app.db)
            try await ConversationMember(conversationID: directConversationID, userID: contactID)
                .create(on: app.db)

            try await app.testing().test(.DELETE, "api/contacts/\(contactID.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let remainingContacts = try await UserContact.query(on: app.db).all()
            #expect(remainingContacts.isEmpty)
            let reloadedConversation = try await Conversation.find(directConversationID, on: app.db)
            #expect(reloadedConversation != nil)
            #expect(reloadedConversation?.directMessagingStateEnum == .frozenAfterUnfriend)

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.first?.id == directConversationID)
                #expect(conversations.first?.directMessagingState == IMDirectMessagingState.frozenAfterUnfriend.rawValue)
                #expect(conversations.first?.directPeer == IMDirectPeerResponse(id: contactID, email: contact.email))
            })
        }
    }


    @Test("Download supports HTTP range requests")
    func downloadSupportsRangeRequests() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let payload = "range-download-check"

            try await app.testing().test(.POST, "api/files/upload", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                req.headers.contentType = .init(type: "application", subType: "octet-stream")
                req.body = ByteBuffer(string: payload)
            }, afterResponse: { _ async in })

            try await app.testing().test(.GET, "api/files/download", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                req.headers.replaceOrAdd(name: .range, value: "bytes=6-13")
            }, afterResponse: { res async in
                #expect(res.status == .partialContent)
                #expect(res.headers.first(name: .contentRange) == "bytes 6-13/\(payload.utf8.count)")
                #expect(res.body.string == "download")
            })
        }
    }

}
