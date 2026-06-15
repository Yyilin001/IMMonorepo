@testable import IMServer
import Fluent
import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing
import Vapor
import VaporTesting

extension IMServerTests {
    @Test("Two TCP devices receive canonical message echo when one device sends")
    func twoTCPDevicesReceiveCanonicalMessageEchoFromSender() async throws {
        try await withApp(configure: { app in
            try await configure(app)
            app.imTCPConfiguration = IMTCPConfiguration(
                enabled: true,
                host: "127.0.0.1",
                port: 0,
                protocolVersion: IMRealtimeProtocolVersion.currentInt,
                authTimeout: 2,
                heartbeatInterval: 30,
                idleTimeout: 90,
                listenBacklog: 1024,
                maxFrameBytes: 64 * 1024,
                writeBufferWaterMarkLow: 512 * 1024,
                writeBufferWaterMarkHigh: 1024 * 1024,
                slowWriteThresholdMilliseconds: 1000,
                slowWriteCloseConsecutiveCount: 3,
                dropsRealtimeWhenNotWritable: true,
                requiresTLSTermination: false
            )
        }) { app in
            try await withTestIMTCPServer(app: app) { tcpServer in
                let deviceAAccessToken = try await loginAccessToken(
                    email: loginRequest.email,
                    password: loginRequest.password,
                    deviceID: "tcp-device-a",
                    on: app
                )
                let deviceBAccessToken = try await loginAccessToken(
                    email: loginRequest.email,
                    password: loginRequest.password,
                    deviceID: "tcp-device-b",
                    on: app
                )
                let peerUser = try await makeUser(email: "tcp-mirror-peer@example.com", on: app)

                var createdConversationID: UUID?
                try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: deviceAAccessToken)
                    try req.content.encode(
                        IMConversationCreateRequest(
                            kind: IMConversationKind.direct.rawValue,
                            title: "TCP Mirror",
                            memberEmails: [peerUser.email]
                        )
                    )
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    createdConversationID = try res.content.decode(IMConversationResponse.self).id
                })
                let conversationID = try #require(createdConversationID)

                try await withIMTCPTestClients(
                    port: tcpServer.port,
                    eventLoopGroup: app.eventLoopGroup
                ) { deviceA, deviceB in
                    try await deviceA.authenticate(accessToken: deviceAAccessToken, deviceID: "tcp-device-a")
                    try await deviceB.authenticate(accessToken: deviceBAccessToken, deviceID: "tcp-device-b")

                    let requestID = UUID()
                    let clientMessageID = "tcp-client-message-1"
                    try await deviceA.send(
                        type: .sendMessage,
                        requestID: requestID,
                        payload: imTCPTextPayload(
                            conversationID: conversationID,
                            clientMessageID: clientMessageID,
                            text: "hello from tcp device a"
                        )
                    )

                    let ackPacket = try await deviceA.nextPacket(ofType: .ack)
                    let acknowledgement = try ackPacket.payload.decodePayload(IMTCPAckPayload.self)
                    #expect(ackPacket.requestID == requestID)
                    #expect(acknowledgement.status == "accepted")
                    #expect(acknowledgement.conversationID == conversationID.uuidString)

                    try await app.processInlineOutboxProjectionIfAllowed()

                    let deviceAEvent = try await deviceA.nextPacket(ofType: .domainEvent)
                        .payload.decodePayload(IMTCPChatDomainEventPayload.self)
                    let deviceBEvent = try await deviceB.nextPacket(ofType: .domainEvent)
                        .payload.decodePayload(IMTCPChatDomainEventPayload.self)

                    guard case .messageCreated(let deviceAMessage, let deviceAClientMessageID) = deviceAEvent.body,
                          case .messageCreated(let deviceBMessage, let deviceBClientMessageID) = deviceBEvent.body
                    else {
                        Issue.record("Expected message_created domain events.")
                        return
                    }
                    #expect(deviceAClientMessageID == clientMessageID)
                    #expect(deviceBClientMessageID == clientMessageID)
                    #expect(deviceAMessage.id.uuidString == acknowledgement.messageID)
                    #expect(deviceBMessage.id.uuidString == acknowledgement.messageID)
                    #expect(deviceAMessage.serverSequence == 1)
                    #expect(deviceBMessage.serverSequence == 1)
                    #expect(deviceAMessage.content == .richText(.plain("hello from tcp device a")))
                    #expect(deviceBMessage.content == .richText(.plain("hello from tcp device a")))
                }
            }
        }
    }

    @Test("Cross-device read advances unread state over a real second TCP connection")
    func crossDeviceReadAdvancesUnreadStateOverSecondTCPConnection() async throws {
        try await withApp(configure: { app in
            try await configure(app)
            app.imTCPConfiguration = IMTCPConfiguration(
                enabled: true,
                host: "127.0.0.1",
                port: 0,
                protocolVersion: IMRealtimeProtocolVersion.currentInt,
                authTimeout: 2,
                heartbeatInterval: 30,
                idleTimeout: 90,
                listenBacklog: 1024,
                maxFrameBytes: 64 * 1024,
                writeBufferWaterMarkLow: 512 * 1024,
                writeBufferWaterMarkHigh: 1024 * 1024,
                slowWriteThresholdMilliseconds: 1000,
                slowWriteCloseConsecutiveCount: 3,
                dropsRealtimeWhenNotWritable: true,
                requiresTLSTermination: false
            )
        }) { app in
            try await withTestIMTCPServer(app: app) { tcpServer in
                let deviceAAccessToken = try await loginAccessToken(
                    email: loginRequest.email,
                    password: loginRequest.password,
                    deviceID: "read-tcp-device-a",
                    on: app
                )
                let deviceBAccessToken = try await loginAccessToken(
                    email: loginRequest.email,
                    password: loginRequest.password,
                    deviceID: "read-tcp-device-b",
                    on: app
                )
                let currentUser = try await user(email: loginRequest.email, on: app)
                let currentUserID = try currentUser.requireID()
                let peerUser = try await makeUser(email: "tcp-read-peer@example.com", on: app)

                var createdConversationID: UUID?
                try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: deviceAAccessToken)
                    try req.content.encode(
                        IMConversationCreateRequest(
                            kind: IMConversationKind.group.rawValue,
                            title: "TCP Read",
                            memberEmails: [peerUser.email]
                        )
                    )
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    createdConversationID = try res.content.decode(IMConversationResponse.self).id
                })
                let conversationID = try #require(createdConversationID)

                for sequence in 1...2 {
                    _ = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                        imTCPTextPayload(
                            conversationID: conversationID,
                            clientMessageID: "tcp-read-peer-\(sequence)",
                            text: "unread \(sequence)"
                        ),
                        senderUserID: try peerUser.requireID()
                    )
                }
                try await app.processInlineOutboxProjectionIfAllowed()

                try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: deviceBAccessToken)
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let page = try res.content.decode(IMConversationPageResponse.self)
                    let summary = try #require(page.items.first { $0.id == conversationID })
                    #expect(summary.memberUserIDs.contains(currentUserID))
                    #expect(summary.lastReadSequence == 0)
                    #expect(summary.unreadCount == 2)
                })

                try await withIMTCPTestClients(
                    port: tcpServer.port,
                    eventLoopGroup: app.eventLoopGroup
                ) { deviceA, deviceB in
                    try await deviceA.authenticate(accessToken: deviceAAccessToken, deviceID: "read-tcp-device-a")
                    try await deviceB.authenticate(accessToken: deviceBAccessToken, deviceID: "read-tcp-device-b")

                    try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/read", beforeRequest: { req in
                        req.headers.bearerAuthorization = .init(token: deviceAAccessToken)
                        try req.content.encode(IMConversationReadRequest(readSequence: 2))
                    }, afterResponse: { res async throws in
                        #expect(res.status == .ok)
                        let response = try res.content.decode(IMConversationReadResponse.self)
                        #expect(response.lastReadSequence == 2)
                        #expect(response.unreadCount == 0)
                    })

                    try await app.processInlineOutboxProjectionIfAllowed()

                    let event = try await deviceB.nextPacket(ofType: .domainEvent)
                        .payload.decodePayload(IMTCPChatDomainEventPayload.self)
                    #expect(event.eventType == .conversationUpdated)
                    #expect(event.conversation?.id == conversationID)
                    #expect(event.conversation?.lastReadSequence == 2)
                    #expect(event.conversation?.unreadCount == 0)
                }
            }
        }
    }

    @Test("Reconnected device can close TCP and recover missed canonical messages over messages since")
    func reconnectedDeviceRecoversMissedCanonicalMessagesOverMessagesSince() async throws {
        try await withApp(configure: { app in
            try await configure(app)
            app.imTCPConfiguration = IMTCPConfiguration(
                enabled: true,
                host: "127.0.0.1",
                port: 0,
                protocolVersion: IMRealtimeProtocolVersion.currentInt,
                authTimeout: 2,
                heartbeatInterval: 30,
                idleTimeout: 90,
                listenBacklog: 1024,
                maxFrameBytes: 64 * 1024,
                writeBufferWaterMarkLow: 512 * 1024,
                writeBufferWaterMarkHigh: 1024 * 1024,
                slowWriteThresholdMilliseconds: 1000,
                slowWriteCloseConsecutiveCount: 3,
                dropsRealtimeWhenNotWritable: true,
                requiresTLSTermination: false
            )
        }) { app in
            try await withTestIMTCPServer(app: app) { tcpServer in
                let deviceAAccessToken = try await loginAccessToken(
                    email: loginRequest.email,
                    password: loginRequest.password,
                    deviceID: "gap-tcp-device-a",
                    on: app
                )
                let deviceBAccessToken = try await loginAccessToken(
                    email: loginRequest.email,
                    password: loginRequest.password,
                    deviceID: "gap-tcp-device-b",
                    on: app
                )
                let peerUser = try await makeUser(email: "tcp-gap-peer@example.com", on: app)

                var createdConversationID: UUID?
                try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: deviceAAccessToken)
                    try req.content.encode(
                        IMConversationCreateRequest(
                            kind: IMConversationKind.group.rawValue,
                            title: "TCP Gap",
                            memberEmails: [peerUser.email]
                        )
                    )
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    createdConversationID = try res.content.decode(IMConversationResponse.self).id
                })
                let conversationID = try #require(createdConversationID)

                try await withIMTCPTestClients(
                    port: tcpServer.port,
                    eventLoopGroup: app.eventLoopGroup
                ) { deviceA, deviceB in
                    try await deviceA.authenticate(accessToken: deviceAAccessToken, deviceID: "gap-tcp-device-a")
                    try await deviceB.authenticate(accessToken: deviceBAccessToken, deviceID: "gap-tcp-device-b")
                    await deviceB.close()

                    for sequence in 1...2 {
                        try await deviceA.send(
                            type: .sendMessage,
                            requestID: UUID(),
                            payload: imTCPTextPayload(
                                conversationID: conversationID,
                                clientMessageID: "tcp-gap-\(sequence)",
                                text: "gap \(sequence)"
                            )
                        )
                        _ = try await deviceA.nextPacket(ofType: .ack)
                        try await app.processInlineOutboxProjectionIfAllowed()
                        _ = try await deviceA.nextPacket(ofType: .domainEvent)
                    }

                    try await withIMTCPTestClient(
                        port: tcpServer.port,
                        eventLoopGroup: app.eventLoopGroup
                    ) { reconnectedDeviceB in
                        try await reconnectedDeviceB.authenticate(
                            accessToken: deviceBAccessToken,
                            deviceID: "gap-tcp-device-b"
                        )

                        try await app.testing().test(
                            .GET,
                            "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0",
                            beforeRequest: { req in
                                req.headers.bearerAuthorization = .init(token: deviceBAccessToken)
                            },
                            afterResponse: { res async throws in
                                #expect(res.status == .ok)
                                let response = try res.content.decode(IMTimelinePageResponse.self)
                                let messages = response.items.compactMap(\.message)
                                #expect(messages.map(\.clientMessageID) == ["tcp-gap-1", "tcp-gap-2"])
                                #expect(messages.map(\.serverSequence) == [1, 2])
                                #expect(messages.map(\.timelineSequence) == [2, 3])
                                #expect(response.hasMore == false)
                                #expect(response.nextAfterSequence == 3)
                            }
                        )

                        try await app.testing().test(
                            .GET,
                            "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=2",
                            beforeRequest: { req in
                                req.headers.bearerAuthorization = .init(token: deviceBAccessToken)
                            },
                            afterResponse: { res async throws in
                                #expect(res.status == .ok)
                                let response = try res.content.decode(IMTimelinePageResponse.self)
                                let messages = response.items.compactMap(\.message)
                                #expect(messages.map(\.clientMessageID) == ["tcp-gap-2"])
                                #expect(messages.map(\.serverSequence) == [2])
                                #expect(messages.map(\.timelineSequence) == [3])
                                #expect(response.hasMore == false)
                            }
                        )
                    }
                }
            }
        }
    }

    @Test("Revoked TCP session is kicked before message persistence")
    func revokedTCPSessionIsKickedBeforeMessagePersistence() async throws {
        try await withApp(configure: { app in
            try await configure(app)
            app.imTCPConfiguration = IMTCPConfiguration(
                enabled: true,
                host: "127.0.0.1",
                port: 0,
                protocolVersion: IMRealtimeProtocolVersion.currentInt,
                authTimeout: 2,
                heartbeatInterval: 30,
                idleTimeout: 90,
                listenBacklog: 1024,
                maxFrameBytes: 64 * 1024,
                writeBufferWaterMarkLow: 512 * 1024,
                writeBufferWaterMarkHigh: 1024 * 1024,
                slowWriteThresholdMilliseconds: 1000,
                slowWriteCloseConsecutiveCount: 3,
                dropsRealtimeWhenNotWritable: true,
                requiresTLSTermination: false
            )
        }) { app in
            try await withTestIMTCPServer(app: app) { tcpServer in
                let accessToken = try await loginAccessToken(
                    email: loginRequest.email,
                    password: loginRequest.password,
                    deviceID: "revoked-tcp-device",
                    on: app
                )
                let peerUser = try await makeUser(email: "tcp-revoked-peer@example.com", on: app)
                var createdConversationID: UUID?
                try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(
                        IMConversationCreateRequest(
                            kind: IMConversationKind.direct.rawValue,
                            title: "TCP Revoked",
                            memberEmails: [peerUser.email]
                        )
                    )
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    createdConversationID = try res.content.decode(IMConversationResponse.self).id
                })
                let conversationID = try #require(createdConversationID)

                try await withIMTCPTestClient(port: tcpServer.port, eventLoopGroup: app.eventLoopGroup) { client in
                    try await client.authenticate(accessToken: accessToken, deviceID: "revoked-tcp-device")

                    let activeSession = try await session(for: loginRequest.email, deviceID: "revoked-tcp-device", on: app)
                    activeSession.revokedAt = Date()
                    try await activeSession.update(on: app.db)

                    try await client.send(
                        type: .sendMessage,
                        requestID: UUID(),
                        payload: imTCPTextPayload(
                            conversationID: conversationID,
                            clientMessageID: "revoked-send",
                            text: "must not persist"
                        )
                    )

                    let kick = try await client.nextPacket(ofType: .kick)
                        .payload.decodePayload(IMTCPKickPayload.self)
                    #expect(kick.reason == .sessionRevoked)

                    let persisted = try await ConversationMessage.query(on: app.db)
                        .filter(\.$conversation.$id == conversationID)
                        .filter(\.$clientMessageID == "revoked-send")
                        .first()
                    #expect(persisted == nil)
                }
            }
        }
    }

    @Test("TCP idle timeout kicks connection and clears session count")
    func tcpIdleTimeoutKicksConnectionAndClearsSessionCount() async throws {
        try await withApp(configure: { app in
            try await configure(app)
            app.imTCPConfiguration = IMTCPConfiguration(
                enabled: true,
                host: "127.0.0.1",
                port: 0,
                protocolVersion: IMRealtimeProtocolVersion.currentInt,
                authTimeout: 2,
                heartbeatInterval: 30,
                idleTimeout: 0.1,
                listenBacklog: 1024,
                maxFrameBytes: 64 * 1024,
                writeBufferWaterMarkLow: 512 * 1024,
                writeBufferWaterMarkHigh: 1024 * 1024,
                slowWriteThresholdMilliseconds: 1000,
                slowWriteCloseConsecutiveCount: 3,
                dropsRealtimeWhenNotWritable: true,
                requiresTLSTermination: false
            )
        }) { app in
            try await withTestIMTCPServer(app: app) { tcpServer in
                let accessToken = try await loginAccessToken(
                    email: loginRequest.email,
                    password: loginRequest.password,
                    deviceID: "idle-tcp-device",
                    on: app
                )
                let activeSession = try await session(
                    for: loginRequest.email,
                    deviceID: "idle-tcp-device",
                    on: app
                )
                let activeSessionID = try activeSession.requireID()

                try await withIMTCPTestClient(port: tcpServer.port, eventLoopGroup: app.eventLoopGroup) { client in
                    try await client.authenticate(accessToken: accessToken, deviceID: "idle-tcp-device")
                    #expect(await app.imConnectionRegistry.activeConnectionCounts(forSessionIDs: [activeSessionID])[activeSessionID] == 1)

                    let kick = try await client.nextPacket(ofType: .kick)
                        .payload.decodePayload(IMTCPKickPayload.self)
                    #expect(kick.message == "Connection idle timeout.")

                    try await waitUntilTCPConnectionCount(app: app, sessionID: activeSessionID, expectedCount: 0)
                }
            }
        }
    }

    @Test("TCP auth rejects a device ID that does not match the access-token session")
    func tcpAuthRejectsMismatchedDeviceID() async throws {
        try await withApp(configure: configure) { app in
            var accessToken = ""

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                accessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            let authenticator = IMTCPAuthenticator(app: app, db: app.db)
            do {
                _ = try await authenticator.authenticate(
                    accessToken: accessToken,
                    remoteIPAddress: nil,
                    deviceID: "different-device",
                    deviceName: "Different Device",
                    platform: "ios",
                    appVersion: "1.0"
                )
                Issue.record("Expected TCP auth to reject a mismatched device ID")
            } catch {
                // Expected: TCP auth must not allow clients to spoof the device identity for a session.
            }

            let connection = try await authenticator.authenticate(
                accessToken: accessToken,
                remoteIPAddress: nil,
                deviceID: "simulator",
                deviceName: "Test Device",
                platform: "ios",
                appVersion: "1.0"
            )
            #expect(connection.deviceID == "simulator")
        }
    }

    @Test("Binding a second TCP connection for the same session replaces the old connection")
    func bindingSecondTCPConnectionForSameSessionReplacesOldConnection() async throws {
        try await withApp(configure: configure) { app in
            let userID = UUID()
            let sessionID = UUID()
            let firstConnectionID = UUID()
            let secondConnectionID = UUID()
            let firstChannel = EmbeddedChannel()
            let secondChannel = EmbeddedChannel()
            let firstConnection = IMAuthenticatedConnection(
                connectionID: firstConnectionID,
                userID: userID,
                sessionID: sessionID,
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "device-a",
                deviceName: "Device A",
                platform: "ios",
                appVersion: "1.0"
            )
            let secondConnection = IMAuthenticatedConnection(
                connectionID: secondConnectionID,
                userID: userID,
                sessionID: sessionID,
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "device-a",
                deviceName: "Device A",
                platform: "ios",
                appVersion: "1.0"
            )

            try await app.gatewaySessionService.bind(
                firstConnection,
                control: IMConnectionControl(connectionID: firstConnectionID, channel: firstChannel)
            )
            #expect(await app.imConnectionRegistry.activeConnectionCounts(forSessionIDs: [sessionID])[sessionID] == 1)

            try await app.gatewaySessionService.bind(
                secondConnection,
                control: IMConnectionControl(connectionID: secondConnectionID, channel: secondChannel)
            )

            #expect(await app.imConnectionRegistry.authenticatedConnection(for: firstConnectionID)?.connectionID == nil)
            #expect(await app.imConnectionRegistry.authenticatedConnection(for: secondConnectionID)?.connectionID == secondConnectionID)
            #expect(await app.imConnectionRegistry.activeConnectionCounts(forSessionIDs: [sessionID])[sessionID] == 1)

            await app.gatewaySessionService.remove(connectionID: secondConnectionID)
        }
    }

    @Test("Gateway relay session-counts returns local active session counts")
    func gatewayRelaySessionCountsReturnsLocalCounts() async throws {
        try await withApp(configure: configure) { app in
            let userID = UUID()
            let activeSessionID = UUID()
            let inactiveSessionID = UUID()
            let connectionID = UUID()
            let channel = EmbeddedChannel()
            let connection = IMAuthenticatedConnection(
                connectionID: connectionID,
                userID: userID,
                sessionID: activeSessionID,
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "device-a",
                deviceName: "Device A",
                platform: "ios",
                appVersion: "1.0"
            )
            let control = IMConnectionControl(connectionID: connectionID, channel: channel)
            try await app.gatewaySessionService.bind(connection, control: control)

            try await app.testing().test(.POST, "internal/gateway/realtime/session-counts", beforeRequest: { req in
                try req.content.encode(GatewayRelaySessionCountsRequest(sessionIDs: [activeSessionID, inactiveSessionID]))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(GatewayRelaySessionCountsResponse.self)
                #expect(response.counts[activeSessionID] == 1)
                #expect(response.counts[inactiveSessionID] == 0)
            })

            await app.gatewaySessionService.remove(connectionID: connectionID)
        }
    }

    @Test("Local gateway fanout records packet and connection metrics")
    func localGatewayFanoutRecordsPacketAndConnectionMetrics() async throws {
        try await withApp(configure: configure) { app in
            let firstUserID = UUID()
            let secondUserID = UUID()
            let firstConnectionID = UUID()
            let secondConnectionID = UUID()
            let firstChannel = EmbeddedChannel()
            let secondChannel = EmbeddedChannel()
            let firstConnection = IMAuthenticatedConnection(
                connectionID: firstConnectionID,
                userID: firstUserID,
                sessionID: UUID(),
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "device-a",
                deviceName: "Device A",
                platform: "ios",
                appVersion: "1.0"
            )
            let secondConnection = IMAuthenticatedConnection(
                connectionID: secondConnectionID,
                userID: secondUserID,
                sessionID: UUID(),
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "device-b",
                deviceName: "Device B",
                platform: "ios",
                appVersion: "1.0"
            )
            try await app.gatewaySessionService.bind(
                firstConnection,
                control: IMConnectionControl(connectionID: firstConnectionID, channel: firstChannel)
            )
            try await app.gatewaySessionService.bind(
                secondConnection,
                control: IMConnectionControl(connectionID: secondConnectionID, channel: secondChannel)
            )

            let conversationID = UUID()
            let eventID = UUID()
            let payload = IMTCPChatDomainEventPayload(
                eventID: eventID,
                eventType: .messageCreated,
                aggregateType: "conversation",
                aggregateID: conversationID,
                aggregateSequence: 1,
                occurredAt: Date(),
                actorUserID: firstUserID,
                conversation: nil,
                ownerCursor: nil,
                ownerAggregateSequence: nil,
                body: .messageCreated(
                    message: IMMessageResponse(
                        id: UUID(),
                        conversationID: conversationID,
                        senderUserID: firstUserID,
                        clientMessageID: "local-fanout-client-1",
                        serverSequence: 1,
                        timelineSequence: 1,
                        content: .richText(.plain("hello")),
                        derivedState: MessageDerivedState(),
                        createdAt: Date()
                    ),
                    clientMessageID: "local-fanout-client-1"
                )
            )

            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: [firstUserID, secondUserID]
                    )
                ],
                requestID: eventID
            )
            firstChannel.embeddedEventLoop.run()
            secondChannel.embeddedEventLoop.run()
            try await waitUntilLocalFanoutEventLoopJobStarted(app: app, minimumStartedCount: 1)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.localFanoutTargetConnectionCount == 2)
            #expect(metrics.localFanoutPacketCount >= 1)
            #expect(metrics.localFanoutMaxTargetConnectionsPerPacket >= 1)
            #expect(metrics.localFanoutMaxTargetConnectionsPerPacket <= 2)
            #expect(metrics.localFanoutEventLoopJobCount >= 1)
            #expect(metrics.localFanoutEventLoopJobStartedCount >= 1)
            #expect(metrics.localFanoutEventLoopJobStartLagMaxMillis >= 0)
            #expect(metrics.localFanoutEncodedPacketBytes > 0)
            #expect(metrics.localFanoutMaxEncodedPacketBytes > 0)
            #expect(metrics.localFanoutEstimatedOutboundBytes >= metrics.localFanoutEncodedPacketBytes)
            #expect(metrics.localFanoutMaxEstimatedOutboundBytesPerPacket > 0)
            #expect(metrics.localFanoutEncodeFailureCount == 0)

            await app.gatewaySessionService.remove(connectionID: firstConnectionID)
            await app.gatewaySessionService.remove(connectionID: secondConnectionID)
        }
    }

    @Test("Active conversation fanout records active and inactive hint metrics")
    func activeConversationFanoutRecordsActiveAndInactiveHintMetrics() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let thresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
        let limitKey = "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT"
        let budgetKey = "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_PAYLOAD_BYTE_BUDGET"
        let debounceKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS"
        let previousFanout = Environment.get(fanoutKey)
        let previousThreshold = Environment.get(thresholdKey)
        let previousLimit = Environment.get(limitKey)
        let previousBudget = Environment.get(budgetKey)
        let previousDebounce = Environment.get(debounceKey)
        setenv(fanoutKey, "true", 1)
        setenv(thresholdKey, "2", 1)
        setenv(limitKey, "10", 1)
        setenv(budgetKey, "0", 1)
        setenv(debounceKey, "0", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(thresholdKey, to: previousThreshold)
            restoreEnvironment(limitKey, to: previousLimit)
            restoreEnvironment(budgetKey, to: previousBudget)
            restoreEnvironment(debounceKey, to: previousDebounce)
        }

        try await withApp(configure: configure) { app in
            let userIDs = [UUID(), UUID(), UUID()]
            let connectionIDs = [UUID(), UUID(), UUID()]
            let channels = userIDs.map { _ in EmbeddedChannel() }
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 12345)
            for channel in channels {
                try await channel.connect(to: address).get()
            }
            for index in userIDs.indices {
                let connection = IMAuthenticatedConnection(
                    connectionID: connectionIDs[index],
                    userID: userIDs[index],
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "active-fanout-device-\(index)",
                    deviceName: "Active Fanout Device \(index)",
                    platform: "ios",
                    appVersion: "1.0"
                )
                try await app.gatewaySessionService.bind(
                    connection,
                    control: IMConnectionControl(connectionID: connectionIDs[index], channel: channels[index])
                )
            }

            let conversationID = UUID()
            let didMarkActive = await app.connectionRoutingService.updateConversationActivity(
                connectionID: connectionIDs[0],
                conversationID: conversationID,
                isActive: true
            )
            #expect(didMarkActive)

            let eventID = UUID()
            let payload = imTestDomainEventPayload(
                eventID: eventID,
                conversationID: conversationID,
                senderUserID: userIDs[0],
                sequence: 1,
                text: "active fanout split"
            )

            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: userIDs
                    )
                ],
                requestID: eventID
            )
            channels.forEach { $0.embeddedEventLoop.run() }

            let fullPayload = try readDomainEventPayload(from: channels[0])
            let hintPayloads = try channels[1...].map { try readDomainEventPayload(from: $0) }
            let hintPayload = try #require(hintPayloads.first)
            #expect(fullPayload.eventID == eventID)
            #expect(fullPayload.eventType == .messageCreated)
            #expect(hintPayload.eventID == imLightweightMessageCreatedHintEventID(for: eventID))
            #expect(hintPayload.eventID != eventID)
            #expect(hintPayload.eventType == .conversationActivityHint)
            #expect(hintPayloads.allSatisfy { $0.eventType == .conversationActivityHint })

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutActiveRecipientCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 2)
            #expect(metrics.realtimeActiveConversationFanoutMaxActiveRecipientsPerSplit == 1)
            #expect(metrics.realtimeActiveConversationFanoutMaxInactiveHintRecipientsPerSplit == 2)
            #expect(metrics.realtimeInactiveConversationHintFlushCount == 1)
            #expect(metrics.realtimeInactiveConversationHintPayloadBatchCount == 1)
            #expect(metrics.realtimeInactiveConversationHintRecipientCount == 2)

            for connectionID in connectionIDs {
                await app.gatewaySessionService.remove(connectionID: connectionID)
            }
        }
    }

    @Test("Active conversation fanout keeps full message for active viewers and hints inactive viewers")
    func activeConversationFanoutKeepsFullMessageForActiveViewersAndHintsInactiveViewers() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let thresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
        let debounceKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS"
        let previousFanout = Environment.get(fanoutKey)
        let previousThreshold = Environment.get(thresholdKey)
        let previousDebounce = Environment.get(debounceKey)
        setenv(fanoutKey, "true", 1)
        setenv(thresholdKey, "2", 1)
        setenv(debounceKey, "0", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(thresholdKey, to: previousThreshold)
            restoreEnvironment(debounceKey, to: previousDebounce)
        }

        try await withApp(configure: configure) { app in
            let activeChannel = EmbeddedChannel()
            let inactiveChannel = EmbeddedChannel()
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 12345)
            try await activeChannel.connect(to: address).get()
            try await inactiveChannel.connect(to: address).get()

            let activeUserID = UUID()
            let inactiveUserID = UUID()
            let activeConnectionID = UUID()
            let inactiveConnectionID = UUID()
            let conversationID = UUID()
            try await app.gatewaySessionService.bind(
                IMAuthenticatedConnection(
                    connectionID: activeConnectionID,
                    userID: activeUserID,
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "active-full-message-device",
                    deviceName: "Active Full Message Device",
                    platform: "ios",
                    appVersion: "1.0"
                ),
                control: IMConnectionControl(connectionID: activeConnectionID, channel: activeChannel)
            )
            try await app.gatewaySessionService.bind(
                IMAuthenticatedConnection(
                    connectionID: inactiveConnectionID,
                    userID: inactiveUserID,
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "inactive-hint-device",
                    deviceName: "Inactive Hint Device",
                    platform: "ios",
                    appVersion: "1.0"
                ),
                control: IMConnectionControl(connectionID: inactiveConnectionID, channel: inactiveChannel)
            )
            #expect(await app.imConnectionRegistry.updateConversationActivity(
                connectionID: activeConnectionID,
                conversationID: conversationID,
                isActive: true
            ))

            let payload = imTestDomainEventPayload(
                eventID: UUID(),
                conversationID: conversationID,
                senderUserID: activeUserID,
                sequence: 7,
                text: "active full message"
            )
            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: [activeUserID, inactiveUserID]
                    )
                ],
                requestID: payload.eventID
            )
            activeChannel.embeddedEventLoop.run()
            inactiveChannel.embeddedEventLoop.run()

            let activePayload = try readDomainEventPayload(from: activeChannel)
            let inactivePayload = try readDomainEventPayload(from: inactiveChannel)

            #expect(activePayload.eventID == payload.eventID)
            #expect(activePayload.eventType == .messageCreated)
            guard case .messageCreated(let activeMessage, _) = activePayload.body else {
                Issue.record("Expected active viewer to receive full messageCreated payload.")
                return
            }
            #expect(activeMessage.content.previewText == "active full message")

            #expect(inactivePayload.eventID == imLightweightMessageCreatedHintEventID(for: payload.eventID))
            #expect(inactivePayload.eventID != payload.eventID)
            #expect(inactivePayload.eventType == .conversationActivityHint)
            guard case .conversationActivityHint(let hint) = inactivePayload.body else {
                Issue.record("Expected inactive viewer to receive conversationActivityHint.")
                return
            }
            #expect(inactivePayload.conversation == nil)
            #expect(hint.previewText == "active full message")
            #expect(inactivePayload.timelineNotice == nil)
            #expect(inactivePayload.requiresTimelineNotice == false)
            #expect(inactivePayload.ownerCursor == nil)
            #expect(inactivePayload.ownerAggregateSequence == nil)

            await app.gatewaySessionService.remove(connectionID: activeConnectionID)
            await app.gatewaySessionService.remove(connectionID: inactiveConnectionID)
        }
    }

    @Test("Active conversation fanout pull-only mode skips inactive realtime hints")
    func activeConversationFanoutPullOnlyModeSkipsInactiveRealtimeHints() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let thresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
        let modeKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE"
        let previousFanout = Environment.get(fanoutKey)
        let previousThreshold = Environment.get(thresholdKey)
        let previousMode = Environment.get(modeKey)
        setenv(fanoutKey, "true", 1)
        setenv(thresholdKey, "2", 1)
        setenv(modeKey, "pull-only", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(thresholdKey, to: previousThreshold)
            restoreEnvironment(modeKey, to: previousMode)
        }

        try await withApp(configure: configure) { app in
            let activeChannel = EmbeddedChannel()
            let inactiveChannel = EmbeddedChannel()
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 12345)
            try await activeChannel.connect(to: address).get()
            try await inactiveChannel.connect(to: address).get()

            let activeUserID = UUID()
            let inactiveUserID = UUID()
            let activeConnectionID = UUID()
            let inactiveConnectionID = UUID()
            let conversationID = UUID()
            try await app.gatewaySessionService.bind(
                IMAuthenticatedConnection(
                    connectionID: activeConnectionID,
                    userID: activeUserID,
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "active-pull-only-device",
                    deviceName: "Active Pull Only Device",
                    platform: "ios",
                    appVersion: "1.0"
                ),
                control: IMConnectionControl(connectionID: activeConnectionID, channel: activeChannel)
            )
            try await app.gatewaySessionService.bind(
                IMAuthenticatedConnection(
                    connectionID: inactiveConnectionID,
                    userID: inactiveUserID,
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "inactive-pull-only-device",
                    deviceName: "Inactive Pull Only Device",
                    platform: "ios",
                    appVersion: "1.0"
                ),
                control: IMConnectionControl(connectionID: inactiveConnectionID, channel: inactiveChannel)
            )
            #expect(await app.imConnectionRegistry.updateConversationActivity(
                connectionID: activeConnectionID,
                conversationID: conversationID,
                isActive: true
            ))

            let payload = imTestDomainEventPayload(
                eventID: UUID(),
                conversationID: conversationID,
                senderUserID: activeUserID,
                sequence: 8,
                text: "active only message"
            )
            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: [activeUserID, inactiveUserID]
                    )
                ],
                requestID: payload.eventID
            )
            activeChannel.embeddedEventLoop.run()
            inactiveChannel.embeddedEventLoop.run()

            let activePayload = try readDomainEventPayload(from: activeChannel)
            #expect(activePayload.eventType == .messageCreated)
            let inactiveOutbound = try inactiveChannel.readOutbound(as: ByteBuffer.self)
            #expect(inactiveOutbound == nil)

            await app.gatewaySessionService.remove(connectionID: activeConnectionID)
            await app.gatewaySessionService.remove(connectionID: inactiveConnectionID)
        }
    }

    @Test("Active conversation fanout downgrades non-writable active viewers")
    func activeConversationFanoutDowngradesNonWritableActiveViewers() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let thresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
        let limitKey = "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT"
        let debounceKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS"
        let dropKey = "IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE"
        let previousFanout = Environment.get(fanoutKey)
        let previousThreshold = Environment.get(thresholdKey)
        let previousLimit = Environment.get(limitKey)
        let previousDebounce = Environment.get(debounceKey)
        let previousDrop = Environment.get(dropKey)
        setenv(fanoutKey, "true", 1)
        setenv(thresholdKey, "2", 1)
        setenv(limitKey, "10", 1)
        setenv(debounceKey, "0", 1)
        setenv(dropKey, "true", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(thresholdKey, to: previousThreshold)
            restoreEnvironment(limitKey, to: previousLimit)
            restoreEnvironment(debounceKey, to: previousDebounce)
            restoreEnvironment(dropKey, to: previousDrop)
        }

        try await withApp(configure: configure) { app in
            let writableChannel = EmbeddedChannel()
            let blockedChannel = EmbeddedChannel()
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 12345)
            try await writableChannel.connect(to: address).get()
            try await blockedChannel.connect(to: address).get()
            blockedChannel.isWritable = false

            let writableUserID = UUID()
            let blockedUserID = UUID()
            let writableConnectionID = UUID()
            let blockedConnectionID = UUID()
            let conversationID = UUID()
            try await app.gatewaySessionService.bind(
                IMAuthenticatedConnection(
                    connectionID: writableConnectionID,
                    userID: writableUserID,
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "writable-active-device",
                    deviceName: "Writable Active Device",
                    platform: "ios",
                    appVersion: "1.0"
                ),
                control: IMConnectionControl(
                    connectionID: writableConnectionID,
                    channel: writableChannel,
                    metrics: app.routingMetrics
                )
            )
            try await app.gatewaySessionService.bind(
                IMAuthenticatedConnection(
                    connectionID: blockedConnectionID,
                    userID: blockedUserID,
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "blocked-active-device",
                    deviceName: "Blocked Active Device",
                    platform: "ios",
                    appVersion: "1.0"
                ),
                control: IMConnectionControl(
                    connectionID: blockedConnectionID,
                    channel: blockedChannel,
                    metrics: app.routingMetrics
                )
            )
            #expect(await app.imConnectionRegistry.updateConversationActivity(
                connectionID: writableConnectionID,
                conversationID: conversationID,
                isActive: true
            ))
            #expect(await app.imConnectionRegistry.updateConversationActivity(
                connectionID: blockedConnectionID,
                conversationID: conversationID,
                isActive: true
            ))

            let payload = imTestDomainEventPayload(
                eventID: UUID(),
                conversationID: conversationID,
                senderUserID: writableUserID,
                sequence: 8,
                text: "pressure protected active fanout"
            )
            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: [writableUserID, blockedUserID]
                    )
                ],
                requestID: payload.eventID
            )
            writableChannel.embeddedEventLoop.run()
            blockedChannel.embeddedEventLoop.run()

            let writablePayload = try readDomainEventPayload(from: writableChannel)
            #expect(writablePayload.eventType == .messageCreated)
            #expect(writablePayload.eventID == payload.eventID)
            #expect(try readOptionalDomainEventPayload(from: blockedChannel) == nil)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutActiveRecipientCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutDowngradedActiveRecipientCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutBackpressureDowngradedRecipientCount == 1)
            #expect(metrics.realtimeInactiveConversationHintRecipientCount == 0)

            await app.gatewaySessionService.remove(connectionID: writableConnectionID)
            await app.gatewaySessionService.remove(connectionID: blockedConnectionID)
        }
    }

    @Test("Active conversation full fanout limit downgrades overflow active viewers")
    func activeConversationFullFanoutLimitDowngradesOverflowActiveViewers() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let thresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
        let limitKey = "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT"
        let debounceKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS"
        let previousFanout = Environment.get(fanoutKey)
        let previousThreshold = Environment.get(thresholdKey)
        let previousLimit = Environment.get(limitKey)
        let previousDebounce = Environment.get(debounceKey)
        setenv(fanoutKey, "true", 1)
        setenv(thresholdKey, "2", 1)
        setenv(limitKey, "1", 1)
        setenv(debounceKey, "0", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(thresholdKey, to: previousThreshold)
            restoreEnvironment(limitKey, to: previousLimit)
            restoreEnvironment(debounceKey, to: previousDebounce)
        }

        try await withApp(configure: configure) { app in
            let userIDs = [UUID(), UUID(), UUID()]
            let connectionIDs = [UUID(), UUID(), UUID()]
            let channels = userIDs.map { _ in EmbeddedChannel() }
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 12345)
            for channel in channels {
                try await channel.connect(to: address).get()
            }
            let conversationID = UUID()
            for index in userIDs.indices {
                let connection = IMAuthenticatedConnection(
                    connectionID: connectionIDs[index],
                    userID: userIDs[index],
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "active-limit-device-\(index)",
                    deviceName: "Active Limit Device \(index)",
                    platform: "ios",
                    appVersion: "1.0"
                )
                try await app.gatewaySessionService.bind(
                    connection,
                    control: IMConnectionControl(connectionID: connectionIDs[index], channel: channels[index])
                )
                let didMarkActive = await app.connectionRoutingService.updateConversationActivity(
                    connectionID: connectionIDs[index],
                    conversationID: conversationID,
                    isActive: true
                )
                #expect(didMarkActive)
            }

            let eventID = UUID()
            let payload = imTestDomainEventPayload(
                eventID: eventID,
                conversationID: conversationID,
                senderUserID: userIDs[0],
                sequence: 1,
                text: "active fanout limit"
            )

            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: userIDs
                    )
                ],
                requestID: eventID
            )
            channels.forEach { $0.embeddedEventLoop.run() }

            let payloads = try channels.map { try readDomainEventPayload(from: $0) }
            let fullPayloads = payloads.filter { $0.eventType == .messageCreated }
            let compactPayloads = payloads.filter { $0.eventType == .timelineGapHint }
            #expect(fullPayloads.count == 1)
            #expect(compactPayloads.count == 2)
            #expect(fullPayloads.first?.eventID == eventID)
            #expect(compactPayloads.allSatisfy {
                $0.eventID == imLightweightMessageCreatedHintEventID(for: eventID)
            })

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutActiveRecipientCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutCompactActiveRecipientCount == 2)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutDowngradedActiveRecipientCount == 2)
            #expect(metrics.realtimeActiveConversationFanoutBackpressureDowngradedRecipientCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutMaxActiveRecipientsPerSplit == 1)
            #expect(metrics.realtimeActiveConversationFanoutMaxCompactActiveRecipientsPerSplit == 2)
            #expect(metrics.realtimeActiveConversationFanoutMaxInactiveHintRecipientsPerSplit == 0)
            #expect(metrics.realtimeActiveConversationFanoutMaxDowngradedActiveRecipientsPerSplit == 2)
            #expect(metrics.realtimeInactiveConversationHintFlushCount == 0)
            #expect(metrics.realtimeInactiveConversationHintPayloadBatchCount == 0)
            #expect(metrics.realtimeInactiveConversationHintRecipientCount == 0)

            for connectionID in connectionIDs {
                await app.gatewaySessionService.remove(connectionID: connectionID)
            }
        }
    }

    @Test("Active conversation compact-only mode downgrades all active viewers")
    func activeConversationCompactOnlyModeDowngradesAllActiveViewers() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let thresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
        let limitKey = "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT"
        let modeKey = "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_MODE"
        let debounceKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS"
        let previousFanout = Environment.get(fanoutKey)
        let previousThreshold = Environment.get(thresholdKey)
        let previousLimit = Environment.get(limitKey)
        let previousMode = Environment.get(modeKey)
        let previousDebounce = Environment.get(debounceKey)
        setenv(fanoutKey, "true", 1)
        setenv(thresholdKey, "2", 1)
        setenv(limitKey, "10", 1)
        setenv(modeKey, "compact-only", 1)
        setenv(debounceKey, "0", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(thresholdKey, to: previousThreshold)
            restoreEnvironment(limitKey, to: previousLimit)
            restoreEnvironment(modeKey, to: previousMode)
            restoreEnvironment(debounceKey, to: previousDebounce)
        }

        try await withApp(configure: configure) { app in
            let userIDs = [UUID(), UUID(), UUID()]
            let connectionIDs = [UUID(), UUID(), UUID()]
            let channels = userIDs.map { _ in EmbeddedChannel() }
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 12345)
            for channel in channels {
                try await channel.connect(to: address).get()
            }
            let conversationID = UUID()
            for index in userIDs.indices {
                let connection = IMAuthenticatedConnection(
                    connectionID: connectionIDs[index],
                    userID: userIDs[index],
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "compact-only-device-\(index)",
                    deviceName: "Compact Only Device \(index)",
                    platform: "ios",
                    appVersion: "1.0"
                )
                try await app.gatewaySessionService.bind(
                    connection,
                    control: IMConnectionControl(connectionID: connectionIDs[index], channel: channels[index])
                )
                let didMarkActive = await app.connectionRoutingService.updateConversationActivity(
                    connectionID: connectionIDs[index],
                    conversationID: conversationID,
                    isActive: true
                )
                #expect(didMarkActive)
            }

            let eventID = UUID()
            let payload = imTestDomainEventPayload(
                eventID: eventID,
                conversationID: conversationID,
                senderUserID: userIDs[0],
                sequence: 1,
                text: "compact only active fanout"
            )

            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: userIDs
                    )
                ],
                requestID: eventID
            )
            channels.forEach { $0.embeddedEventLoop.run() }

            let payloads = try channels.map { try readDomainEventPayload(from: $0) }
            #expect(payloads.allSatisfy { $0.eventType == .timelineGapHint })
            #expect(payloads.allSatisfy {
                $0.eventID == imLightweightMessageCreatedHintEventID(for: eventID)
            })

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutActiveRecipientCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutCompactActiveRecipientCount == 3)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutDowngradedActiveRecipientCount == 3)

            for connectionID in connectionIDs {
                await app.gatewaySessionService.remove(connectionID: connectionID)
            }
        }
    }

    @Test("Active conversation full fanout payload budget downgrades large payload overflow viewers")
    func activeConversationFullFanoutPayloadBudgetDowngradesLargePayloadOverflowViewers() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let thresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
        let limitKey = "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT"
        let budgetKey = "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_PAYLOAD_BYTE_BUDGET"
        let debounceKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS"
        let previousFanout = Environment.get(fanoutKey)
        let previousThreshold = Environment.get(thresholdKey)
        let previousLimit = Environment.get(limitKey)
        let previousBudget = Environment.get(budgetKey)
        let previousDebounce = Environment.get(debounceKey)
        setenv(fanoutKey, "true", 1)
        setenv(thresholdKey, "2", 1)
        setenv(limitKey, "10", 1)
        setenv(budgetKey, "1024", 1)
        setenv(debounceKey, "0", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(thresholdKey, to: previousThreshold)
            restoreEnvironment(limitKey, to: previousLimit)
            restoreEnvironment(budgetKey, to: previousBudget)
            restoreEnvironment(debounceKey, to: previousDebounce)
        }

        try await withApp(configure: configure) { app in
            let channel = EmbeddedChannel()
            let userIDs = [UUID(), UUID(), UUID()]
            let connectionIDs = [UUID(), UUID(), UUID()]
            let conversationID = UUID()
            for index in userIDs.indices {
                let connection = IMAuthenticatedConnection(
                    connectionID: connectionIDs[index],
                    userID: userIDs[index],
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "active-budget-device-\(index)",
                    deviceName: "Active Budget Device \(index)",
                    platform: "ios",
                    appVersion: "1.0"
                )
                try await app.gatewaySessionService.bind(
                    connection,
                    control: IMConnectionControl(connectionID: connectionIDs[index], channel: channel)
                )
                let didMarkActive = await app.imConnectionRegistry.updateConversationActivity(
                    connectionID: connectionIDs[index],
                    conversationID: conversationID,
                    isActive: true
                )
                #expect(didMarkActive)
            }

            let eventID = UUID()
            let payload = imTestDomainEventPayload(
                eventID: eventID,
                conversationID: conversationID,
                senderUserID: userIDs[0],
                sequence: 1,
                text: String(repeating: "large-payload", count: 400)
            )
            let budget = IMActiveConversationFullFanoutBudget.effectiveLimit(
                baseLimit: 10,
                payloadByteBudget: 1024,
                payload: payload
            )
            #expect(budget.limit == 1)

            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: userIDs
                    )
                ],
                requestID: eventID
            )

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutActiveRecipientCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutCompactActiveRecipientCount == 2)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutDowngradedActiveRecipientCount == 2)
            #expect(metrics.realtimeActiveConversationFanoutPayloadBudgetAppliedCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutPayloadBudgetDowngradedRecipientCount == 2)
            #expect(metrics.realtimeActiveConversationFanoutPayloadBudgetMaxPayloadBytes == budget.payloadByteCount)
            #expect(metrics.realtimeActiveConversationFanoutPayloadBudgetMaxEffectiveLimit == 1)

            for connectionID in connectionIDs {
                await app.gatewaySessionService.remove(connectionID: connectionID)
            }
        }
    }

    @Test("Pre-split active full fanout only targets active conversation connections")
    func preSplitActiveFullFanoutOnlyTargetsActiveConversationConnections() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let thresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
        let limitKey = "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT"
        let previousFanout = Environment.get(fanoutKey)
        let previousThreshold = Environment.get(thresholdKey)
        let previousLimit = Environment.get(limitKey)
        setenv(fanoutKey, "true", 1)
        setenv(thresholdKey, "2", 1)
        setenv(limitKey, "1", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(thresholdKey, to: previousThreshold)
            restoreEnvironment(limitKey, to: previousLimit)
        }

        try await withApp(configure: configure) { app in
            let channel = EmbeddedChannel()
            let userIDs = [UUID(), UUID(), UUID()]
            let connectionIDs = [UUID(), UUID(), UUID()]
            let inactiveSameUserConnectionID = UUID()
            let conversationID = UUID()
            for index in userIDs.indices {
                let connection = IMAuthenticatedConnection(
                    connectionID: connectionIDs[index],
                    userID: userIDs[index],
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "pre-split-device-\(index)",
                    deviceName: "Pre Split Device \(index)",
                    platform: "ios",
                    appVersion: "1.0"
                )
                try await app.gatewaySessionService.bind(
                    connection,
                    control: IMConnectionControl(connectionID: connectionIDs[index], channel: channel)
                )
                let didMarkActive = await app.imConnectionRegistry.updateConversationActivity(
                    connectionID: connectionIDs[index],
                    conversationID: conversationID,
                    isActive: true
                )
                #expect(didMarkActive)
            }
            try await app.gatewaySessionService.bind(
                IMAuthenticatedConnection(
                    connectionID: inactiveSameUserConnectionID,
                    userID: userIDs[0],
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "pre-split-inactive-device",
                    deviceName: "Pre Split Inactive Device",
                    platform: "ios",
                    appVersion: "1.0"
                ),
                control: IMConnectionControl(connectionID: inactiveSameUserConnectionID, channel: channel)
            )

            let eventID = UUID()
            let payload = imTestDomainEventPayload(
                eventID: eventID,
                conversationID: conversationID,
                senderUserID: userIDs[0],
                sequence: 1,
                text: "pre split active full"
            )

            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: userIDs,
                        fanoutIntent: .preSplitActiveFull
                    )
                ],
                requestID: eventID
            )

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 0)
            #expect(metrics.localFanoutTargetConnectionCount == 3)

            for connectionID in connectionIDs {
                await app.gatewaySessionService.remove(connectionID: connectionID)
            }
            await app.gatewaySessionService.remove(connectionID: inactiveSameUserConnectionID)
        }
    }

    @Test("Remote active conversation packet only fanouts to allowed active local connections")
    func remoteActiveConversationPacketOnlyFanoutsToAllowedActiveLocalConnections() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let previousFanout = Environment.get(fanoutKey)
        setenv(fanoutKey, "true", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
        }

        try await withApp(configure: configure) { app in
            let allowedUserID = UUID()
            let notAllowedUserID = UUID()
            let conversationID = UUID()
            let allowedActiveConnectionID = UUID()
            let allowedInactiveConnectionID = UUID()
            let notAllowedActiveConnectionID = UUID()
            let allowedActiveChannel = EmbeddedChannel()
            let allowedInactiveChannel = EmbeddedChannel()
            let notAllowedActiveChannel = EmbeddedChannel()
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 12345)
            try await allowedActiveChannel.connect(to: address).get()
            try await allowedInactiveChannel.connect(to: address).get()
            try await notAllowedActiveChannel.connect(to: address).get()

            try await app.gatewaySessionService.bind(
                IMAuthenticatedConnection(
                    connectionID: allowedActiveConnectionID,
                    userID: allowedUserID,
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "remote-active-allowed-active",
                    deviceName: "Remote Active Allowed Active",
                    platform: "ios",
                    appVersion: "1.0"
                ),
                control: IMConnectionControl(connectionID: allowedActiveConnectionID, channel: allowedActiveChannel)
            )
            try await app.gatewaySessionService.bind(
                IMAuthenticatedConnection(
                    connectionID: allowedInactiveConnectionID,
                    userID: allowedUserID,
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "remote-active-allowed-inactive",
                    deviceName: "Remote Active Allowed Inactive",
                    platform: "ios",
                    appVersion: "1.0"
                ),
                control: IMConnectionControl(connectionID: allowedInactiveConnectionID, channel: allowedInactiveChannel)
            )
            try await app.gatewaySessionService.bind(
                IMAuthenticatedConnection(
                    connectionID: notAllowedActiveConnectionID,
                    userID: notAllowedUserID,
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "remote-active-not-allowed-active",
                    deviceName: "Remote Active Not Allowed Active",
                    platform: "ios",
                    appVersion: "1.0"
                ),
                control: IMConnectionControl(connectionID: notAllowedActiveConnectionID, channel: notAllowedActiveChannel)
            )

            #expect(await app.imConnectionRegistry.updateConversationActivity(
                connectionID: allowedActiveConnectionID,
                conversationID: conversationID,
                isActive: true
            ))
            #expect(await app.imConnectionRegistry.updateConversationActivity(
                connectionID: notAllowedActiveConnectionID,
                conversationID: conversationID,
                isActive: true
            ))

            let payload = imTestDomainEventPayload(
                eventID: UUID(),
                conversationID: conversationID,
                senderUserID: allowedUserID,
                sequence: 1,
                text: "remote active room"
            )
            let packetData = try IMTCPProtobufCodec.encode(
                type: .domainEvent,
                requestID: payload.eventID,
                payload: payload
            )
            let envelope = NodeMessageDispatchEnvelope(
                requestID: payload.eventID,
                payload: .activeConversationDomainEventPacket(
                    packetBase64: packetData.base64EncodedString(),
                    conversationID: conversationID,
                    allowedUserIDs: [allowedUserID],
                    fanoutIntent: .preSplitActiveFull
                )
            )

            await app.connectionRoutingService.handleRemoteDispatch(envelope)
            allowedActiveChannel.embeddedEventLoop.run()
            allowedInactiveChannel.embeddedEventLoop.run()
            notAllowedActiveChannel.embeddedEventLoop.run()

            let deliveredPayload = try readDomainEventPayload(from: allowedActiveChannel)
            #expect(deliveredPayload.eventID == payload.eventID)
            #expect(deliveredPayload.eventType == .messageCreated)
            #expect(try readOptionalDomainEventPayload(from: allowedInactiveChannel) == nil)
            #expect(try readOptionalDomainEventPayload(from: notAllowedActiveChannel) == nil)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.localFanoutTargetConnectionCount == 1)

            await app.gatewaySessionService.remove(connectionID: allowedActiveConnectionID)
            await app.gatewaySessionService.remove(connectionID: allowedInactiveConnectionID)
            await app.gatewaySessionService.remove(connectionID: notAllowedActiveConnectionID)
        }
    }

    @Test("Active conversation fanout keeps user active until all active devices leave")
    func activeConversationFanoutKeepsUserActiveUntilAllActiveDevicesLeave() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let thresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
        let debounceKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS"
        let previousFanout = Environment.get(fanoutKey)
        let previousThreshold = Environment.get(thresholdKey)
        let previousDebounce = Environment.get(debounceKey)
        setenv(fanoutKey, "true", 1)
        setenv(thresholdKey, "2", 1)
        setenv(debounceKey, "0", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(thresholdKey, to: previousThreshold)
            restoreEnvironment(debounceKey, to: previousDebounce)
        }

        try await withApp(configure: configure) { app in
            let userID = UUID()
            let inactiveUserID = UUID()
            let conversationID = UUID()
            let activeConnectionIDs = [UUID(), UUID()]
            let inactiveConnectionID = UUID()
            let channel = EmbeddedChannel()
            for index in activeConnectionIDs.indices {
                let connection = IMAuthenticatedConnection(
                    connectionID: activeConnectionIDs[index],
                    userID: userID,
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "active-cache-device-\(index)",
                    deviceName: "Active Cache Device \(index)",
                    platform: "ios",
                    appVersion: "1.0"
                )
                try await app.gatewaySessionService.bind(
                    connection,
                    control: IMConnectionControl(connectionID: activeConnectionIDs[index], channel: channel)
                )
                let didMarkActive = await app.imConnectionRegistry.updateConversationActivity(
                    connectionID: activeConnectionIDs[index],
                    conversationID: conversationID,
                    isActive: true
                )
                #expect(didMarkActive)
            }
            let inactiveConnection = IMAuthenticatedConnection(
                connectionID: inactiveConnectionID,
                userID: inactiveUserID,
                sessionID: UUID(),
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "active-cache-inactive-device",
                deviceName: "Inactive Device",
                platform: "ios",
                appVersion: "1.0"
            )
            try await app.gatewaySessionService.bind(
                inactiveConnection,
                control: IMConnectionControl(connectionID: inactiveConnectionID, channel: channel)
            )

            let didMarkFirstInactive = await app.imConnectionRegistry.updateConversationActivity(
                connectionID: activeConnectionIDs[0],
                conversationID: conversationID,
                isActive: false
            )
            #expect(didMarkFirstInactive)

            let eventID = UUID()
            let payload = imTestDomainEventPayload(
                eventID: eventID,
                conversationID: conversationID,
                senderUserID: userID,
                sequence: 1,
                text: "active cache"
            )

            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: [userID, inactiveUserID]
                    )
                ],
                requestID: eventID
            )

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutActiveRecipientCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 1)

            for connectionID in activeConnectionIDs + [inactiveConnectionID] {
                await app.gatewaySessionService.remove(connectionID: connectionID)
            }
        }
    }

    @Test("Active conversation full fanout limit rotates selected active viewers")
    func activeConversationFullFanoutLimitRotatesSelectedActiveViewers() async throws {
        let userIDs = [UUID(), UUID(), UUID()]

        let first = IMActiveConversationFullFanoutSelector.select(
            from: userIDs,
            limit: 1,
            aggregateSequence: 1
        )
        #expect(first.fullUserIDs == [userIDs[0]])
        #expect(first.downgradedUserIDs == [userIDs[1], userIDs[2]])

        let second = IMActiveConversationFullFanoutSelector.select(
            from: userIDs,
            limit: 1,
            aggregateSequence: 2
        )
        #expect(second.fullUserIDs == [userIDs[1]])
        #expect(second.downgradedUserIDs == [userIDs[2], userIDs[0]])

        let third = IMActiveConversationFullFanoutSelector.select(
            from: userIDs,
            limit: 1,
            aggregateSequence: 3
        )
        #expect(third.fullUserIDs == [userIDs[2]])
        #expect(third.downgradedUserIDs == [userIDs[0], userIDs[1]])

        let wrapped = IMActiveConversationFullFanoutSelector.select(
            from: userIDs,
            limit: 1,
            aggregateSequence: 4
        )
        #expect(wrapped.fullUserIDs == [userIDs[0]])
        #expect(wrapped.downgradedUserIDs == [userIDs[1], userIDs[2]])
    }

    @Test("Active conversation full fanout byte budget reduces effective limit")
    func activeConversationFullFanoutByteBudgetReducesEffectiveLimit() throws {
        let payload = imTestDomainEventPayload(
            eventID: UUID(),
            conversationID: UUID(),
            senderUserID: UUID(),
            sequence: 1,
            text: String(repeating: "large-payload", count: 200)
        )
        let encodedByteCount = try IMTCPProtobufCodec.encodeDomainEvent(
            payload,
            requireDeliveryMetadata: false
        ).count

        let disabled = IMActiveConversationFullFanoutBudget.effectiveLimit(
            baseLimit: 10,
            payloadByteBudget: 0,
            payload: payload
        )
        #expect(disabled.limit == 10)
        #expect(disabled.payloadByteCount == 0)
        #expect(disabled.budgetApplied == false)

        let budgeted = IMActiveConversationFullFanoutBudget.effectiveLimit(
            baseLimit: 10,
            payloadByteBudget: encodedByteCount * 2 + max(1, encodedByteCount / 2),
            payload: payload
        )
        #expect(budgeted.limit == 2)
        #expect(budgeted.payloadByteCount == encodedByteCount)
        #expect(budgeted.budgetApplied)

        let minimum = IMActiveConversationFullFanoutBudget.effectiveLimit(
            baseLimit: 10,
            payloadByteBudget: max(1, encodedByteCount - 1),
            payload: payload
        )
        #expect(minimum.limit == 1)
        #expect(minimum.budgetApplied)
    }

    @Test("Inactive conversation hints coalesce to latest payload per recipient")
    func inactiveConversationHintsCoalesceToLatestPayloadPerRecipient() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let thresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
        let debounceKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS"
        let previousFanout = Environment.get(fanoutKey)
        let previousThreshold = Environment.get(thresholdKey)
        let previousDebounce = Environment.get(debounceKey)
        setenv(fanoutKey, "true", 1)
        setenv(thresholdKey, "2", 1)
        setenv(debounceKey, "1", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(thresholdKey, to: previousThreshold)
            restoreEnvironment(debounceKey, to: previousDebounce)
        }

        try await withApp(configure: configure) { app in
            let channel = EmbeddedChannel()
            let userIDs = [UUID(), UUID()]
            let connectionIDs = [UUID(), UUID()]
            for index in userIDs.indices {
                let connection = IMAuthenticatedConnection(
                    connectionID: connectionIDs[index],
                    userID: userIDs[index],
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "inactive-coalesce-device-\(index)",
                    deviceName: "Inactive Coalesce Device \(index)",
                    platform: "ios",
                    appVersion: "1.0"
                )
                try await app.gatewaySessionService.bind(
                    connection,
                    control: IMConnectionControl(connectionID: connectionIDs[index], channel: channel)
                )
            }
            let conversationID = UUID()
            let firstPayload = imTestDomainEventPayload(
                eventID: UUID(),
                conversationID: conversationID,
                senderUserID: userIDs[0],
                sequence: 1,
                text: "first inactive hint"
            )
            let secondPayload = imTestDomainEventPayload(
                eventID: UUID(),
                conversationID: conversationID,
                senderUserID: userIDs[0],
                sequence: 2,
                text: "second inactive hint"
            )

            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: firstPayload,
                        recipientUserIDs: userIDs
                    )
                ],
                requestID: firstPayload.eventID
            )
            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: secondPayload,
                        recipientUserIDs: userIDs
                    )
                ],
                requestID: secondPayload.eventID
            )

            try await Task.sleep(nanoseconds: 1_200_000_000)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 2)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 4)
            #expect(metrics.realtimeInactiveConversationHintFlushCount == 1)
            #expect(metrics.realtimeInactiveConversationHintPayloadBatchCount == 1)
            #expect(metrics.realtimeInactiveConversationHintRecipientCount == 2)

            for connectionID in connectionIDs {
                await app.gatewaySessionService.remove(connectionID: connectionID)
            }
        }
    }

    @Test("Inactive conversation hints flush immediately at max pending recipient threshold")
    func inactiveConversationHintsFlushImmediatelyAtMaxPendingRecipientThreshold() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let thresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
        let debounceKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS"
        let maxPendingKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_MAX_PENDING_RECIPIENTS"
        let previousFanout = Environment.get(fanoutKey)
        let previousThreshold = Environment.get(thresholdKey)
        let previousDebounce = Environment.get(debounceKey)
        let previousMaxPending = Environment.get(maxPendingKey)
        setenv(fanoutKey, "true", 1)
        setenv(thresholdKey, "2", 1)
        setenv(debounceKey, "60", 1)
        setenv(maxPendingKey, "2", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(thresholdKey, to: previousThreshold)
            restoreEnvironment(debounceKey, to: previousDebounce)
            restoreEnvironment(maxPendingKey, to: previousMaxPending)
        }

        try await withApp(configure: configure) { app in
            let channel = EmbeddedChannel()
            let userIDs = [UUID(), UUID()]
            let connectionIDs = [UUID(), UUID()]
            for index in userIDs.indices {
                let connection = IMAuthenticatedConnection(
                    connectionID: connectionIDs[index],
                    userID: userIDs[index],
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "inactive-threshold-device-\(index)",
                    deviceName: "Inactive Threshold Device \(index)",
                    platform: "ios",
                    appVersion: "1.0"
                )
                try await app.gatewaySessionService.bind(
                    connection,
                    control: IMConnectionControl(connectionID: connectionIDs[index], channel: channel)
                )
            }

            let payload = imTestDomainEventPayload(
                eventID: UUID(),
                conversationID: UUID(),
                senderUserID: userIDs[0],
                sequence: 1,
                text: "flush at threshold"
            )
            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: userIDs
                    )
                ],
                requestID: payload.eventID
            )

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 2)
            #expect(metrics.realtimeInactiveConversationHintFlushCount == 1)
            #expect(metrics.realtimeInactiveConversationHintPayloadBatchCount == 1)
            #expect(metrics.realtimeInactiveConversationHintRecipientCount == 2)

            for connectionID in connectionIDs {
                await app.gatewaySessionService.remove(connectionID: connectionID)
            }
        }
    }

    @Test("Pre-split inactive conversation hints use gateway debounce")
    func preSplitInactiveConversationHintsUseGatewayDebounce() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let debounceKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS"
        let previousFanout = Environment.get(fanoutKey)
        let previousDebounce = Environment.get(debounceKey)
        setenv(fanoutKey, "false", 1)
        setenv(debounceKey, "1", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(debounceKey, to: previousDebounce)
        }

        try await withApp(configure: configure) { app in
            let channel = EmbeddedChannel()
            let userIDs = [UUID(), UUID()]
            let connectionIDs = [UUID(), UUID()]
            for index in userIDs.indices {
                let connection = IMAuthenticatedConnection(
                    connectionID: connectionIDs[index],
                    userID: userIDs[index],
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "pre-split-hint-device-\(index)",
                    deviceName: "Pre Split Hint Device \(index)",
                    platform: "ios",
                    appVersion: "1.0"
                )
                try await app.gatewaySessionService.bind(
                    connection,
                    control: IMConnectionControl(connectionID: connectionIDs[index], channel: channel)
                )
            }

            let conversationID = UUID()
            let firstPayload = imTestConversationActivityHintPayload(
                eventID: UUID(),
                conversationID: conversationID,
                senderUserID: userIDs[0],
                sequence: 1,
                previewText: "first pre-split hint"
            )
            let secondPayload = imTestConversationActivityHintPayload(
                eventID: UUID(),
                conversationID: conversationID,
                senderUserID: userIDs[0],
                sequence: 2,
                previewText: "second pre-split hint"
            )

            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: firstPayload,
                        recipientUserIDs: userIDs,
                        fanoutIntent: .preSplitInactiveHint
                    )
                ],
                requestID: firstPayload.eventID
            )
            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: secondPayload,
                        recipientUserIDs: userIDs,
                        fanoutIntent: .preSplitInactiveHint
                    )
                ],
                requestID: secondPayload.eventID
            )

            try await Task.sleep(nanoseconds: 1_200_000_000)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 0)
            #expect(metrics.realtimeInactiveConversationHintFlushCount == 1)
            #expect(metrics.realtimeInactiveConversationHintPayloadBatchCount == 1)
            #expect(metrics.realtimeInactiveConversationHintRecipientCount == 2)
            #expect(metrics.realtimeInactiveConversationHintSuppressedRecipientCount == 2)

            for connectionID in connectionIDs {
                await app.gatewaySessionService.remove(connectionID: connectionID)
            }
        }
    }

    @Test("Active conversation fanout ignores recipients without local connections")
    func activeConversationFanoutIgnoresRecipientsWithoutLocalConnections() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let thresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
        let debounceKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS"
        let previousFanout = Environment.get(fanoutKey)
        let previousThreshold = Environment.get(thresholdKey)
        let previousDebounce = Environment.get(debounceKey)
        setenv(fanoutKey, "true", 1)
        setenv(thresholdKey, "2", 1)
        setenv(debounceKey, "0", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(thresholdKey, to: previousThreshold)
            restoreEnvironment(debounceKey, to: previousDebounce)
        }

        try await withApp(configure: configure) { app in
            let localUserID = UUID()
            let remoteOnlyUserIDs = [UUID(), UUID()]
            let connectionID = UUID()
            let channel = EmbeddedChannel()
            let connection = IMAuthenticatedConnection(
                connectionID: connectionID,
                userID: localUserID,
                sessionID: UUID(),
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "local-only-device",
                deviceName: "Local Only Device",
                platform: "ios",
                appVersion: "1.0"
            )
            try await app.gatewaySessionService.bind(
                connection,
                control: IMConnectionControl(connectionID: connectionID, channel: channel)
            )

            let conversationID = UUID()
            let payload = imTestDomainEventPayload(
                eventID: UUID(),
                conversationID: conversationID,
                senderUserID: localUserID,
                sequence: 1,
                text: "local recipient only"
            )
            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: [localUserID] + remoteOnlyUserIDs
                    )
                ],
                requestID: payload.eventID
            )

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 1)
            #expect(metrics.realtimeInactiveConversationHintFlushCount == 1)
            #expect(metrics.realtimeInactiveConversationHintRecipientCount == 1)
            #expect(metrics.localFanoutTargetConnectionCount == 1)

            await app.gatewaySessionService.remove(connectionID: connectionID)
        }
    }

    @Test("Activating conversation removes pending inactive hint for that user")
    func activatingConversationRemovesPendingInactiveHintForThatUser() async throws {
        let fanoutKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
        let thresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
        let debounceKey = "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS"
        let previousFanout = Environment.get(fanoutKey)
        let previousThreshold = Environment.get(thresholdKey)
        let previousDebounce = Environment.get(debounceKey)
        setenv(fanoutKey, "true", 1)
        setenv(thresholdKey, "2", 1)
        setenv(debounceKey, "1", 1)
        defer {
            restoreEnvironment(fanoutKey, to: previousFanout)
            restoreEnvironment(thresholdKey, to: previousThreshold)
            restoreEnvironment(debounceKey, to: previousDebounce)
        }

        try await withApp(configure: configure) { app in
            let activeLaterUserID = UUID()
            let inactiveUserID = UUID()
            let activeLaterConnectionID = UUID()
            let inactiveConnectionID = UUID()
            let channel = EmbeddedChannel()
            let conversationID = UUID()
            let activeLaterConnection = IMAuthenticatedConnection(
                connectionID: activeLaterConnectionID,
                userID: activeLaterUserID,
                sessionID: UUID(),
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "active-later-device",
                deviceName: "Active Later Device",
                platform: "ios",
                appVersion: "1.0"
            )
            try await app.gatewaySessionService.bind(
                activeLaterConnection,
                control: IMConnectionControl(connectionID: activeLaterConnectionID, channel: channel)
            )
            let inactiveConnection = IMAuthenticatedConnection(
                connectionID: inactiveConnectionID,
                userID: inactiveUserID,
                sessionID: UUID(),
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "inactive-still-device",
                deviceName: "Inactive Still Device",
                platform: "ios",
                appVersion: "1.0"
            )
            try await app.gatewaySessionService.bind(
                inactiveConnection,
                control: IMConnectionControl(connectionID: inactiveConnectionID, channel: channel)
            )

            let payload = imTestDomainEventPayload(
                eventID: UUID(),
                conversationID: conversationID,
                senderUserID: activeLaterUserID,
                sequence: 1,
                text: "pending inactive hint"
            )
            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: [activeLaterUserID, inactiveUserID]
                    )
                ],
                requestID: payload.eventID
            )

            let didMarkActive = await app.imConnectionRegistry.updateConversationActivity(
                connectionID: activeLaterConnectionID,
                conversationID: conversationID,
                isActive: true
            )
            #expect(didMarkActive)

            try await Task.sleep(nanoseconds: 1_200_000_000)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 2)
            #expect(metrics.realtimeInactiveConversationHintFlushCount == 1)
            #expect(metrics.realtimeInactiveConversationHintPayloadBatchCount == 1)
            #expect(metrics.realtimeInactiveConversationHintRecipientCount == 1)

            await app.gatewaySessionService.remove(connectionID: activeLaterConnectionID)
            await app.gatewaySessionService.remove(connectionID: inactiveConnectionID)
        }
    }

    @Test("Local gateway fanout chunks large batches into bounded event-loop jobs")
    func localGatewayFanoutChunksLargeBatchesIntoBoundedEventLoopJobs() async throws {
        let batchSizeKey = "IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE"
        let yieldChunksKey = "IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS"
        let previousBatchSize = Environment.get(batchSizeKey)
        let previousYieldChunks = Environment.get(yieldChunksKey)
        setenv(batchSizeKey, "2", 1)
        setenv(yieldChunksKey, "64", 1)
        defer {
            if let previousBatchSize {
                setenv(batchSizeKey, previousBatchSize, 1)
            } else {
                unsetenv(batchSizeKey)
            }
            if let previousYieldChunks {
                setenv(yieldChunksKey, previousYieldChunks, 1)
            } else {
                unsetenv(yieldChunksKey)
            }
        }

        try await withApp(configure: configure) { app in
            let channel = EmbeddedChannel()
            let userIDs = [UUID(), UUID(), UUID()]
            let connectionIDs = [UUID(), UUID(), UUID()]
            for index in userIDs.indices {
                let connection = IMAuthenticatedConnection(
                    connectionID: connectionIDs[index],
                    userID: userIDs[index],
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "chunk-device-\(index)",
                    deviceName: "Chunk Device \(index)",
                    platform: "ios",
                    appVersion: "1.0"
                )
                try await app.gatewaySessionService.bind(
                    connection,
                    control: IMConnectionControl(connectionID: connectionIDs[index], channel: channel)
                )
            }

            let conversationID = UUID()
            let eventID = UUID()
            let payload = imTestDomainEventPayload(
                eventID: eventID,
                conversationID: conversationID,
                senderUserID: userIDs[0],
                sequence: 1,
                text: "chunked fanout"
            )

            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: userIDs
                    )
                ],
                requestID: eventID
            )

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.localFanoutTargetConnectionCount == 3)
            #expect(metrics.localFanoutPacketCount == 1)
            #expect(metrics.localFanoutMaxTargetConnectionsPerPacket == 3)
            #expect(metrics.localFanoutEventLoopJobCount == 1)
            #expect(metrics.localFanoutChunkCount == 2)
            #expect(metrics.localFanoutMaxChunksPerEventLoopJob == 2)
            #expect(metrics.localFanoutBatchSize == 2)

            for connectionID in connectionIDs {
                await app.gatewaySessionService.remove(connectionID: connectionID)
            }
        }
    }

    @Test("Local gateway stream signal fanout uses encoded chunk runner")
    func localGatewayStreamSignalFanoutUsesEncodedChunkRunner() async throws {
        let batchSizeKey = "IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE"
        let yieldChunksKey = "IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS"
        let previousBatchSize = Environment.get(batchSizeKey)
        let previousYieldChunks = Environment.get(yieldChunksKey)
        setenv(batchSizeKey, "2", 1)
        setenv(yieldChunksKey, "64", 1)
        defer {
            if let previousBatchSize {
                setenv(batchSizeKey, previousBatchSize, 1)
            } else {
                unsetenv(batchSizeKey)
            }
            if let previousYieldChunks {
                setenv(yieldChunksKey, previousYieldChunks, 1)
            } else {
                unsetenv(yieldChunksKey)
            }
        }

        try await withApp(configure: configure) { app in
            let channel = EmbeddedChannel()
            let userIDs = [UUID(), UUID(), UUID()]
            let connectionIDs = [UUID(), UUID(), UUID()]
            for index in userIDs.indices {
                let connection = IMAuthenticatedConnection(
                    connectionID: connectionIDs[index],
                    userID: userIDs[index],
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "stream-signal-device-\(index)",
                    deviceName: "Stream Signal Device \(index)",
                    platform: "ios",
                    appVersion: "1.0"
                )
                try await app.gatewaySessionService.bind(
                    connection,
                    control: IMConnectionControl(connectionID: connectionIDs[index], channel: channel)
                )
            }

            let signal = IMTCPMessageStreamSignalPayload(
                stream: IMTCPMessageStreamPayload(
                    streamID: UUID().uuidString,
                    messageID: UUID().uuidString,
                    conversationID: UUID().uuidString,
                    chunkIndex: 1,
                    deltaText: "hello",
                    partialTextLength: 5,
                    state: .streaming,
                    serverTimestamp: Date()
                ),
                message: nil
            )

            await app.gatewaySessionService.sendStreamSignal(
                signal,
                toUserIDs: userIDs,
                requestID: UUID()
            )

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.localFanoutTargetConnectionCount == 3)
            #expect(metrics.localFanoutPacketCount == 1)
            #expect(metrics.localFanoutMaxTargetConnectionsPerPacket == 3)
            #expect(metrics.localFanoutEventLoopJobCount == 1)
            #expect(metrics.localFanoutChunkCount == 2)
            #expect(metrics.localFanoutMaxChunksPerEventLoopJob == 2)
            #expect(metrics.localFanoutBatchSize == 2)
            #expect(metrics.localFanoutEncodedPacketCount == 1)
            #expect(metrics.localFanoutEncodeFailureCount == 0)

            for connectionID in connectionIDs {
                await app.gatewaySessionService.remove(connectionID: connectionID)
            }
        }
    }

    @Test("Local gateway stream signal skips encoding without local targets")
    func localGatewayStreamSignalSkipsEncodingWithoutLocalTargets() async throws {
        try await withApp(configure: configure) { app in
            let signal = IMTCPMessageStreamSignalPayload(
                stream: IMTCPMessageStreamPayload(
                    streamID: UUID().uuidString,
                    messageID: UUID().uuidString,
                    conversationID: UUID().uuidString,
                    chunkIndex: 1,
                    deltaText: "no-local-target",
                    partialTextLength: 15,
                    state: .streaming,
                    serverTimestamp: Date()
                ),
                message: nil
            )

            await app.gatewaySessionService.sendStreamSignal(
                signal,
                toUserIDs: [UUID(), UUID()],
                requestID: UUID()
            )

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.localFanoutTargetConnectionCount == 0)
            #expect(metrics.localFanoutPacketCount == 0)
            #expect(metrics.localFanoutEventLoopJobCount == 0)
            #expect(metrics.localFanoutChunkCount == 0)
            #expect(metrics.localFanoutMaxChunksPerEventLoopJob == 0)
            #expect(metrics.localFanoutEncodedPacketCount == 0)
            #expect(metrics.localFanoutEncodeFailureCount == 0)
        }
    }

    @Test("Local gateway fanout coalesces reusable lightweight conversation hint batches")
    func localGatewayFanoutCoalescesReusableLightweightConversationHintBatches() async throws {
        try await withApp(configure: configure) { app in
            let channel = EmbeddedChannel()
            let userIDs = [UUID(), UUID()]
            let connectionIDs = [UUID(), UUID()]
            for index in userIDs.indices {
                let connection = IMAuthenticatedConnection(
                    connectionID: connectionIDs[index],
                    userID: userIDs[index],
                    sessionID: UUID(),
                    authenticatedAt: Date(),
                    remoteIPAddress: "127.0.0.1",
                    deviceID: "encode-cache-device-\(index)",
                    deviceName: "Encode Cache Device \(index)",
                    platform: "ios",
                    appVersion: "1.0"
                )
                try await app.gatewaySessionService.bind(
                    connection,
                    control: IMConnectionControl(connectionID: connectionIDs[index], channel: channel)
                )
            }

            let conversationID = UUID()
            let eventID = UUID()
            let occurredAt = Date()
            let payload = IMTCPChatDomainEventPayload(
                eventID: eventID,
                eventType: .conversationActivityHint,
                aggregateType: "conversation",
                aggregateID: conversationID,
                aggregateSequence: 7,
                occurredAt: occurredAt,
                actorUserID: userIDs[0],
                conversation: nil,
                timelineNotice: nil,
                requiresTimelineNotice: false,
                ownerCursor: nil,
                ownerAggregateSequence: nil,
                body: .conversationActivityHint(
                    IMConversationActivityHint(
                        messageID: UUID(),
                        senderUserID: userIDs[0],
                        serverSequence: 7,
                        timelineSequence: 7,
                        previewText: "cached hint",
                        messageCreatedAt: occurredAt,
                        updatedAt: occurredAt
                    )
                )
            )

            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: [userIDs[0]]
                    ),
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: [userIDs[1]]
                    )
                ],
                requestID: eventID
            )

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.localFanoutTargetConnectionCount == 2)
            #expect(metrics.localFanoutPacketCount == 1)
            #expect(metrics.localFanoutEventLoopJobCount == 1)
            #expect(metrics.localFanoutEncodedPacketCount == 1)
            #expect(metrics.localFanoutEncodeCacheHitCount == 0)
            #expect(metrics.localFanoutEncodeFailureCount == 0)

            for connectionID in connectionIDs {
                await app.gatewaySessionService.remove(connectionID: connectionID)
            }
        }
    }

    @Test("TCP write metrics record encoded packet completions")
    func tcpWriteMetricsRecordEncodedPacketCompletions() async throws {
        try await withApp(configure: configure) { app in
            let channel = EmbeddedChannel()
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 12345)
            try await channel.connect(to: address).get()
            let control = IMConnectionControl(
                connectionID: UUID(),
                channel: channel,
                metrics: app.routingMetrics
            )

            control.sendEncodedPacketOnEventLoop(Data([0x01, 0x02, 0x03]))
            let outbound = try channel.readOutbound(as: ByteBuffer.self)
            #expect(outbound != nil)
            try await Task.sleep(nanoseconds: 50_000_000)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.tcpWriteCompletionCount == 1)
            #expect(metrics.tcpWriteFailureCount == 0)
            #expect(metrics.tcpWriteMaxLatencyMillis >= 0)
        }
    }

    @Test("TCP realtime writes drop when channel is non-writable")
    func tcpRealtimeWritesDropWhenChannelIsNonWritable() async throws {
        try await withApp(configure: configure) { app in
            let channel = EmbeddedChannel()
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 12345)
            try await channel.connect(to: address).get()

            IMTCPChannelWriter.writeEncodedPacket(
                Data([0x02, 0x03, 0x04]),
                on: channel,
                metrics: app.routingMetrics,
                dropWhenNotWritable: true,
                channelIsWritable: false
            )
            IMTCPChannelWriter.writePacket(
                type: .heartbeat,
                requestID: UUID(),
                payload: IMTCPHeartbeatPayload(sequence: 1),
                on: channel,
                metrics: app.routingMetrics,
                dropWhenNotWritable: true,
                channelIsWritable: false
            )
            try await Task.sleep(nanoseconds: 50_000_000)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.tcpWriteBackpressureCount == 2)
            #expect(metrics.tcpWriteDroppedBackpressureCount == 2)
            #expect(metrics.tcpWriteCompletionCount == 0)
        }
    }

    @Test("TCP write slow metrics track count and latency")
    func tcpWriteSlowMetricsTrackCountAndLatency() async throws {
        try await withApp(configure: configure) { app in
            await app.routingMetrics.recordTCPWriteSlow(latencyMilliseconds: 1200)
            await app.routingMetrics.recordTCPWriteSlow(latencyMilliseconds: 2500)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.tcpWriteSlowCount == 2)
            #expect(metrics.tcpWriteSlowTotalLatencyMillis == 3700)
            #expect(metrics.tcpWriteSlowMaxLatencyMillis == 2500)
        }
    }

    @Test("TCP close metrics classify slow write reason")
    func tcpCloseMetricsClassifySlowWriteReason() async throws {
        try await withApp(configure: configure) { app in
            await app.routingMetrics.recordTCPChannelInactive(closeReason: "slow_write", state: "authenticated")

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.tcpCloseSlowWriteCount == 1)
            #expect(metrics.tcpClosePeerAuthenticatedCount == 0)
            #expect(metrics.tcpClosePeerOrUnknownCount == 0)
        }
    }

    @Test("TCP slow write governance closes after consecutive slow writes")
    func tcpSlowWriteGovernanceClosesAfterConsecutiveSlowWrites() async throws {
        try await withApp(configure: configure) { app in
            let channel = EmbeddedChannel()
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 12345)
            try await channel.connect(to: address).get()
            let control = IMConnectionControl(
                connectionID: UUID(),
                channel: channel,
                metrics: app.routingMetrics,
                slowWriteThresholdMilliseconds: 1,
                slowWriteCloseConsecutiveCount: 2
            )

            control.handleSlowWriteOnEventLoop(latencyMilliseconds: 1200)
            #expect(channel.isActive)

            control.handleWriteCompletionOnEventLoop(didWriteSlow: false)
            control.handleSlowWriteOnEventLoop(latencyMilliseconds: 1300)
            #expect(channel.isActive)

            control.handleSlowWriteOnEventLoop(latencyMilliseconds: 1400)
            try await Task.sleep(nanoseconds: 50_000_000)

            #expect(!channel.isActive)
            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.tcpWriteSlowConnectionClosedCount == 1)
        }
    }

    @Test("Realtime coalescing keeps only the latest pending relay")
    func realtimeCoalescingKeepsOnlyLatestPendingRelay() async throws {
        try await withApp(configure: configure) { app in
            let dispatcher = RealtimeDeliveryAsyncDispatcher(app: app, maxInFlight: 1)
            let conversationID = UUID()
            let senderUserID = UUID()
            let firstRecipients = [UUID(), UUID(), UUID()]
            let secondRecipients = [UUID(), UUID()]
            let firstEventID = UUID()
            let secondEventID = UUID()
            let firstPayload = imTestDomainEventPayload(
                eventID: firstEventID,
                conversationID: conversationID,
                senderUserID: senderUserID,
                sequence: 1,
                text: "first"
            )
            let secondPayload = imTestDomainEventPayload(
                eventID: secondEventID,
                conversationID: conversationID,
                senderUserID: senderUserID,
                sequence: 2,
                text: "second"
            )

            await dispatcher.dispatchPayloadBatches(
                [
                    ConversationRealtimeConsumer.DomainEventPayloadBatch(
                        payload: firstPayload,
                        recipientUserIDs: firstRecipients
                    )
                ],
                requestID: firstEventID,
                coalescingKey: conversationID,
                coalescingWindowMilliseconds: 100
            )
            await dispatcher.dispatchPayloadBatches(
                [
                    ConversationRealtimeConsumer.DomainEventPayloadBatch(
                        payload: secondPayload,
                        recipientUserIDs: secondRecipients
                    )
                ],
                requestID: secondEventID,
                coalescingKey: conversationID,
                coalescingWindowMilliseconds: 100
            )

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeCoalescedDispatchReplacementCount == 1)
            #expect(metrics.realtimeCoalescedDroppedPayloadBatchCount == 1)
            #expect(metrics.realtimeCoalescedDroppedRecipientDeliveryCount == firstRecipients.count)

            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    @Test("Realtime coalescing keeps active compact and inactive hint scopes independent")
    func realtimeCoalescingScopesAreIndependent() async throws {
        try await withApp(configure: configure) { app in
            let probe = RecordingRealtimeRelayProbe()
            let dispatcher = RealtimeDeliveryAsyncDispatcher(
                app: app,
                maxInFlight: 4,
                relayHandler: { batches, requestID in
                    await probe.relay(batches, requestID: requestID)
                }
            )
            let conversationID = UUID()
            let senderUserID = UUID()
            let activeEventID = UUID()
            let inactiveEventID = UUID()
            let activePayload = imTestConversationActivityHintPayload(
                eventID: activeEventID,
                conversationID: conversationID,
                senderUserID: senderUserID,
                sequence: 1,
                previewText: "active"
            )
            let inactivePayload = imTestConversationActivityHintPayload(
                eventID: inactiveEventID,
                conversationID: conversationID,
                senderUserID: senderUserID,
                sequence: 2,
                previewText: "inactive"
            )

            await dispatcher.dispatchPayloadBatches(
                [
                    ConversationRealtimeConsumer.DomainEventPayloadBatch(
                        payload: activePayload,
                        recipientUserIDs: [UUID()],
                        fanoutIntent: .preSplitActiveCompact
                    )
                ],
                requestID: activeEventID,
                coalescingKey: conversationID,
                coalescingScope: .activeCompactHint,
                coalescingWindowMilliseconds: 50
            )
            await dispatcher.dispatchPayloadBatches(
                [
                    ConversationRealtimeConsumer.DomainEventPayloadBatch(
                        payload: inactivePayload,
                        recipientUserIDs: [UUID()],
                        fanoutIntent: .preSplitInactiveHint
                    )
                ],
                requestID: inactiveEventID,
                coalescingKey: conversationID,
                coalescingScope: .inactiveHint,
                coalescingWindowMilliseconds: 50
            )

            try await Task.sleep(nanoseconds: 150_000_000)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeCoalescedDispatchReplacementCount == 0)
            #expect(await probe.callCount() == 2)
            let fanoutIntents = await probe.fanoutIntents()
            #expect(fanoutIntents.contains(.preSplitActiveCompact))
            #expect(fanoutIntents.contains(.preSplitInactiveHint))
        }
    }

    @Test("Realtime hint coalescing keeps latest payload per recipient")
    func realtimeHintCoalescingKeepsLatestPayloadPerRecipient() async throws {
        try await withApp(configure: configure) { app in
            let probe = RecordingRealtimeRelayProbe()
            let dispatcher = RealtimeDeliveryAsyncDispatcher(
                app: app,
                maxInFlight: 4,
                relayHandler: { batches, requestID in
                    await probe.relay(batches, requestID: requestID)
                }
            )
            let conversationID = UUID()
            let senderUserID = UUID()
            let recipientA = UUID()
            let recipientB = UUID()
            let recipientC = UUID()
            let firstEventID = UUID()
            let secondEventID = UUID()
            let firstPayload = imTestTimelineGapHintPayload(
                eventID: firstEventID,
                conversationID: conversationID,
                senderUserID: senderUserID,
                sequence: 1
            )
            let secondPayload = imTestTimelineGapHintPayload(
                eventID: secondEventID,
                conversationID: conversationID,
                senderUserID: senderUserID,
                sequence: 2
            )

            await dispatcher.dispatchPayloadBatches(
                [
                    ConversationRealtimeConsumer.DomainEventPayloadBatch(
                        payload: firstPayload,
                        recipientUserIDs: [recipientA, recipientB],
                        fanoutIntent: .preSplitActiveCompact
                    )
                ],
                requestID: firstEventID,
                coalescingKey: conversationID,
                coalescingScope: .activeCompactHint,
                coalescingWindowMilliseconds: 50
            )
            await dispatcher.dispatchPayloadBatches(
                [
                    ConversationRealtimeConsumer.DomainEventPayloadBatch(
                        payload: secondPayload,
                        recipientUserIDs: [recipientB, recipientC],
                        fanoutIntent: .preSplitActiveCompact
                    )
                ],
                requestID: secondEventID,
                coalescingKey: conversationID,
                coalescingScope: .activeCompactHint,
                coalescingWindowMilliseconds: 50
            )

            try await Task.sleep(nanoseconds: 150_000_000)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeCoalescedDispatchReplacementCount == 1)
            #expect(metrics.realtimeCoalescedDroppedPayloadBatchCount == 0)
            #expect(metrics.realtimeCoalescedDroppedRecipientDeliveryCount == 1)

            let sequenceByRecipient = await probe.timelineGapHintSequenceByRecipient()
            #expect(sequenceByRecipient[recipientA] == 1)
            #expect(sequenceByRecipient[recipientB] == 2)
            #expect(sequenceByRecipient[recipientC] == 2)
            #expect(sequenceByRecipient.count == 3)
        }
    }

    @Test("Realtime async dispatcher drops relay when queue is saturated")
    func realtimeAsyncDispatcherDropsRelayWhenQueueIsSaturated() async throws {
        try await withApp(configure: configure) { app in
            let probe = BlockingRealtimeRelayProbe()
            let dispatcher = RealtimeDeliveryAsyncDispatcher(
                app: app,
                maxInFlight: 1,
                maxQueued: 0,
                relayHandler: { batches, requestID in
                    await probe.relay(batches, requestID: requestID)
                }
            )
            let conversationID = UUID()
            let senderUserID = UUID()
            let firstEventID = UUID()
            let secondEventID = UUID()
            let firstPayload = imTestDomainEventPayload(
                eventID: firstEventID,
                conversationID: conversationID,
                senderUserID: senderUserID,
                sequence: 1,
                text: "first"
            )
            let secondPayload = imTestDomainEventPayload(
                eventID: secondEventID,
                conversationID: conversationID,
                senderUserID: senderUserID,
                sequence: 2,
                text: "second"
            )
            let secondRecipients = [UUID(), UUID(), UUID()]

            await dispatcher.dispatchPayloadBatches(
                [
                    ConversationRealtimeConsumer.DomainEventPayloadBatch(
                        payload: firstPayload,
                        recipientUserIDs: [UUID()]
                    )
                ],
                requestID: firstEventID
            )
            await probe.waitUntilStarted()
            var metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeAsyncRelayTaskStartedCount == 1)
            #expect(metrics.realtimeAsyncRelayTaskCompletedCount == 0)
            #expect(metrics.realtimeAsyncRelayCurrentInFlightCount == 1)
            #expect(metrics.realtimeAsyncRelayMaxInFlightCount == 1)

            await dispatcher.dispatchPayloadBatches(
                [
                    ConversationRealtimeConsumer.DomainEventPayloadBatch(
                        payload: secondPayload,
                        recipientUserIDs: secondRecipients
                    )
                ],
                requestID: secondEventID
            )

            metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeAsyncRelayDroppedDispatchCount == 1)
            #expect(metrics.realtimeAsyncRelayDroppedPayloadBatchCount == 1)
            #expect(metrics.realtimeAsyncRelayDroppedRecipientDeliveryCount == secondRecipients.count)
            #expect(metrics.realtimeAsyncRelayQueueSaturationCount == 1)
            #expect(await probe.callCount() == 1)

            await probe.release()
            try await Task.sleep(nanoseconds: 50_000_000)
            metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeAsyncRelayTaskCompletedCount == 1)
            #expect(metrics.realtimeAsyncRelayCurrentInFlightCount == 0)
        }
    }

    @Test("Gateway relay requires configured secret when present")
    func gatewayRelayRequiresConfiguredSecretWhenPresent() async throws {
        try await withApp(configure: { app in
            try await configure(app)
            app.gatewayRelayConfiguration = IMGatewayRelayConfiguration(
                mode: .local,
                baseURL: nil,
                sharedSecret: "relay-secret"
            )
        }) { app in
            try await app.testing().test(.POST, "internal/gateway/realtime/session-counts", beforeRequest: { req in
                try req.content.encode(GatewayRelaySessionCountsRequest(sessionIDs: []))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.POST, "internal/gateway/realtime/session-counts", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: "relay-secret")
                try req.content.encode(GatewayRelaySessionCountsRequest(sessionIDs: []))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.gatewayHTTPRelayInboundRequestCount == 2)
            #expect(metrics.gatewayHTTPRelayInboundSuccessCount == 1)
            #expect(metrics.gatewayHTTPRelayInboundFailureCount == 1)
            #expect(metrics.gatewayHTTPRelayInboundBodyBytes > 0)
            #expect(metrics.gatewayHTTPRelayInboundMaxBodyBytes > 0)
        }
    }

    @Test("HTTP gateway relay payload batches are planned as chunked binary work items")
    func httpGatewayRelayPayloadBatchesArePlannedAsChunkedBinaryWorkItems() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)

        let transport = HTTPGatewaySessionTransport(
            app: app,
            configuration: IMGatewayRelayConfiguration(
                mode: .http,
                baseURL: nil,
                sharedSecret: nil
            )
        )
        let conversationID = UUID()
        let recipientUserIDs = (0..<5).map { _ in UUID() }
        let firstPayload = imTestDomainEventPayload(
            eventID: UUID(),
            conversationID: conversationID,
            senderUserID: recipientUserIDs[0],
            sequence: 1,
            text: "first relay batch"
        )
        let secondPayload = imTestDomainEventPayload(
            eventID: UUID(),
            conversationID: conversationID,
            senderUserID: recipientUserIDs[0],
            sequence: 2,
            text: "second relay batch"
        )

        let plan = transport.makeDomainEventPayloadBatchWorkPlan(
            [
                IMGatewayDomainEventPayloadBatch(
                    payload: firstPayload,
                    recipientUserIDs: Array(recipientUserIDs[0..<3])
                ),
                IMGatewayDomainEventPayloadBatch(
                    payload: secondPayload,
                    recipientUserIDs: Array(recipientUserIDs[3..<5])
                ),
                IMGatewayDomainEventPayloadBatch(
                    payload: secondPayload,
                    recipientUserIDs: []
                )
            ],
            recipientBatchSize: 2
        )

        #expect(plan.payloadBatchCount == 2)
        #expect(plan.recipientCount == 5)
        #expect(plan.skippedRecipientCount == 0)
        #expect(plan.encodedPayloadBytes > 0)
        #expect(plan.maxRecipientsPerWorkItem == 5)
        #expect(plan.workItems.count == 1)
        guard case .groupedBinaryBatch(let entries)? = plan.workItems.first else {
            Issue.record("Expected grouped binary batch work item")
            try await app.asyncShutdown()
            return
        }
        #expect(entries.map { $0.recipientUserIDs.count }.sorted() == [1, 2, 2])
        #expect(entries.reduce(0) { $0 + $1.recipientUserIDs.count } == 5)

        try await app.asyncShutdown()
    }

    @Test("Gateway relay binary packet batch codec round trips entries")
    func gatewayRelayBinaryPacketBatchCodecRoundTripsEntries() async throws {
        let requestID = UUID()
        let firstRecipients = [UUID(), UUID()]
        let secondRecipients = [UUID()]
        let firstPayloadData = Data([0x01, 0x02, 0x03])
        let secondPayloadData = Data([0x04, 0x05])

        let body = try IMGatewayRelayBinaryCodec.encodeDomainEventPacketBatch(
            entries: [
                IMGatewayRelayBinaryCodec.DomainEventPacketBatchEntry(
                    payloadData: firstPayloadData,
                    recipientUserIDs: firstRecipients,
                    fanoutIntent: .preSplitActiveFull
                ),
                IMGatewayRelayBinaryCodec.DomainEventPacketBatchEntry(
                    payloadData: secondPayloadData,
                    recipientUserIDs: secondRecipients,
                    fanoutIntent: .preSplitInactiveHint
                )
            ],
            requestID: requestID
        )
        let decoded = try IMGatewayRelayBinaryCodec.decodeDomainEventPacketBatch(body)

        #expect(decoded.requestID == requestID)
        #expect(decoded.entries.count == 2)
        #expect(decoded.entries[0].payloadData == firstPayloadData)
        #expect(decoded.entries[0].recipientUserIDs == firstRecipients)
        #expect(decoded.entries[0].fanoutIntent == .preSplitActiveFull)
        #expect(decoded.entries[1].payloadData == secondPayloadData)
        #expect(decoded.entries[1].recipientUserIDs == secondRecipients)
        #expect(decoded.entries[1].fanoutIntent == .preSplitInactiveHint)
    }

    @Test("Gateway relay accepts binary domain-event packet batches")
    func gatewayRelayAcceptsBinaryDomainEventPacketBatches() async throws {
        try await withApp(configure: configure) { app in
            let firstUserID = UUID()
            let secondUserID = UUID()
            let requestID = UUID()
            let conversationID = UUID()
            let firstPayload = imTestDomainEventPayload(
                eventID: UUID(),
                conversationID: conversationID,
                senderUserID: firstUserID,
                sequence: 1,
                text: "binary batch first"
            )
            let secondPayload = imTestDomainEventPayload(
                eventID: UUID(),
                conversationID: conversationID,
                senderUserID: secondUserID,
                sequence: 2,
                text: "binary batch second"
            )
            let body = try IMGatewayRelayBinaryCodec.encodeDomainEventPacketBatch(
                entries: [
                    IMGatewayRelayBinaryCodec.DomainEventPacketBatchEntry(
                        payloadData: try IMTCPProtobufCodec.encodeDomainEvent(
                            firstPayload,
                            requireDeliveryMetadata: false
                        ),
                        recipientUserIDs: [firstUserID],
                        fanoutIntent: .preSplitActiveFull
                    ),
                    IMGatewayRelayBinaryCodec.DomainEventPacketBatchEntry(
                        payloadData: try IMTCPProtobufCodec.encodeDomainEvent(
                            secondPayload,
                            requireDeliveryMetadata: false
                        ),
                        recipientUserIDs: [secondUserID],
                        fanoutIntent: .preSplitInactiveHint
                    )
                ],
                requestID: requestID
            )

            try await app.testing().test(.POST, "internal/gateway/realtime/domain-event-packets-bin", beforeRequest: { req in
                req.headers.contentType = HTTPMediaType(type: "application", subType: "octet-stream")
                req.body = .init(data: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            try await Task.sleep(nanoseconds: 50_000_000)
            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.gatewayHTTPRelayInboundRequestCount == 1)
            #expect(metrics.gatewayHTTPRelayInboundSuccessCount == 1)
            #expect(metrics.gatewayHTTPRelayInboundBodyBytes == body.count)
        }
    }

    @Test("HTTP gateway relay direct payload batches preserve fanout intent")
    func httpGatewayRelayDirectPayloadBatchesPreserveFanoutIntent() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)

        let transport = HTTPGatewaySessionTransport(
            app: app,
            configuration: IMGatewayRelayConfiguration(
                mode: .http,
                baseURL: nil,
                sharedSecret: nil
            )
        )
        let userID = UUID()
        let payload = imTestDomainEventPayload(
            eventID: UUID(),
            conversationID: UUID(),
            senderUserID: userID,
            sequence: 1,
            text: "fanout intent"
        )

        let plan = transport.makeDomainEventPayloadBatchWorkPlan(
            [
                IMGatewayDomainEventPayloadBatch(
                    payload: payload,
                    recipientUserIDs: [userID],
                    fanoutIntent: .preSplitActiveFull
                )
            ],
            recipientBatchSize: 10
        )

        guard case .groupedBinaryBatch(let entries)? = plan.workItems.first,
              let fanoutIntent = entries.first?.fanoutIntent
        else {
            Issue.record("Expected grouped binary batch work item")
            try await app.asyncShutdown()
            return
        }
        #expect(fanoutIntent == .preSplitActiveFull)

        try await app.asyncShutdown()
    }

    @Test("HTTP gateway relay work plan honors binary body limit")
    func httpGatewayRelayWorkPlanHonorsBinaryBodyLimit() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)

        let transport = HTTPGatewaySessionTransport(
            app: app,
            configuration: IMGatewayRelayConfiguration(
                mode: .http,
                baseURL: "http://127.0.0.1:1",
                sharedSecret: nil
            )
        )
        let conversationID = UUID()
        let recipientUserIDs = (0..<5).map { _ in UUID() }
        let payload = imTestDomainEventPayload(
            eventID: UUID(),
            conversationID: conversationID,
            senderUserID: recipientUserIDs[0],
            sequence: 1,
            text: "body-limited relay batch"
        )
        let payloadData = try IMTCPProtobufCodec.encodeDomainEvent(payload, requireDeliveryMetadata: false)
        let maxBodyBytes = IMGatewayRelayBinaryCodec.encodedDomainEventPacketByteCount(
            payloadByteCount: payloadData.count,
            recipientCount: 2,
            includesRequestID: true
        )

        let plan = transport.makeDomainEventPayloadBatchWorkPlan(
            [
                IMGatewayDomainEventPayloadBatch(
                    payload: payload,
                    recipientUserIDs: recipientUserIDs
                )
            ],
            recipientBatchSize: 5,
            maxBinaryBodyBytes: maxBodyBytes
        )

        #expect(plan.workItems.count == 3)
        #expect(plan.maxRecipientsPerWorkItem == 2)
        var chunkSizes: [Int] = []
        for workItem in plan.workItems {
            switch workItem {
            case .groupedBinary(let entryPayloadData, let recipientUserIDs, _):
                chunkSizes.append(recipientUserIDs.count)
                let bodyByteCount = IMGatewayRelayBinaryCodec.encodedDomainEventPacketByteCount(
                    payloadByteCount: entryPayloadData.count,
                    recipientCount: recipientUserIDs.count,
                    includesRequestID: true
                )
                #expect(bodyByteCount <= maxBodyBytes)
            case .groupedBinaryBatch(let entries):
                chunkSizes.append(entries.reduce(0) { $0 + $1.recipientUserIDs.count })
                let bodyByteCount = IMGatewayRelayBinaryCodec.encodedDomainEventPacketBatchByteCount(
                    entries: entries.map {
                        (
                            payloadByteCount: $0.payloadData.count,
                            recipientCount: $0.recipientUserIDs.count
                        )
                    },
                    includesRequestID: true
                )
                #expect(bodyByteCount <= maxBodyBytes)
            case .batch:
                Issue.record("Expected binary work item")
            }
        }
        #expect(chunkSizes == [2, 2, 1])
        let groupedBinaryCount = plan.workItems.filter {
            if case .groupedBinary = $0 {
                return true
            }
            return false
        }.count
        #expect(groupedBinaryCount == 2)

        try await app.asyncShutdown()
    }

    @Test("HTTP gateway relay owner delivery path records work plan metrics")
    func httpGatewayRelayOwnerDeliveryPathRecordsWorkPlanMetrics() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)

        let transport = HTTPGatewaySessionTransport(
            app: app,
            configuration: IMGatewayRelayConfiguration(
                mode: .http,
                baseURL: nil,
                sharedSecret: nil
            )
        )
        let recipientUserIDs = [UUID(), UUID()]
        let payload = imTestDomainEventPayload(
            eventID: UUID(),
            conversationID: UUID(),
            senderUserID: recipientUserIDs[0],
            sequence: 1,
            text: "owner delivery metrics"
        )
        let deliveries = recipientUserIDs.map {
            IMCanonicalDomainEventDelivery(
                ownerUserID: $0,
                eventID: payload.eventID,
                payload: payload
            )
        }

        await transport.sendDomainEventPayloads(deliveries, requestID: UUID())

        let metrics = await app.routingMetrics.currentSnapshot()
        #expect(metrics.gatewayHTTPRelayWorkItemCount == 1)
        #expect(metrics.gatewayHTTPRelayPayloadBatchCount == 1)
        #expect(metrics.gatewayHTTPRelayRecipientCount == 2)
        #expect(metrics.gatewayHTTPRelaySkippedRecipientCount == 0)
        #expect(metrics.gatewayHTTPRelayEncodedPayloadBytes > 0)
        #expect(metrics.gatewayHTTPRelayMaxRecipientsPerWorkItem == 2)

        try await app.asyncShutdown()
    }

    @Test("HTTP gateway relay JSON fallback recipient chunks honor body limit")
    func httpGatewayRelayJSONFallbackRecipientChunksHonorBodyLimit() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)

        let transport = HTTPGatewaySessionTransport(
            app: app,
            configuration: IMGatewayRelayConfiguration(
                mode: .http,
                baseURL: "http://127.0.0.1:1",
                sharedSecret: nil
            )
        )
        let requestID = UUID()
        let recipientUserIDs = (0..<5).map { _ in UUID() }
        let payloadBase64 = Data(Array(repeating: UInt8(7), count: 128)).base64EncodedString()
        let maxBodyBytes = try JSONEncoder().encode(
            GatewayRelayDomainEventPayloadRequest(
                payloadBase64: payloadBase64,
                recipientUserIDs: Array(recipientUserIDs[0..<2]),
                requestID: requestID
            )
        ).count

        let chunks = transport.makeGatewayRelayPayloadRecipientChunks(
            payloadBase64: payloadBase64,
            recipientUserIDs: recipientUserIDs,
            requestID: requestID,
            maxBodyBytes: maxBodyBytes
        )

        #expect(chunks.map(\.count) == [2, 2, 1])

        try await app.asyncShutdown()
    }

    @Test("HTTP gateway relay JSON batch entry chunks honor body limit")
    func httpGatewayRelayJSONBatchEntryChunksHonorBodyLimit() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)

        let transport = HTTPGatewaySessionTransport(
            app: app,
            configuration: IMGatewayRelayConfiguration(
                mode: .http,
                baseURL: "http://127.0.0.1:1",
                sharedSecret: nil
            )
        )
        let requestID = UUID()
        let entries = (0..<5).map { index in
            GatewayRelayDomainEventPayloadBatchEntry(
                ownerUserID: UUID(),
                payloadBase64: Data(Array(repeating: UInt8(index), count: 96)).base64EncodedString()
            )
        }
        let maxBodyBytes = try JSONEncoder().encode(
            GatewayRelayDomainEventPayloadBatchRequest(
                deliveries: Array(entries[0..<2]),
                requestID: requestID
            )
        ).count

        let chunks = transport.makeGatewayRelayPayloadBatchEntryChunks(
            entries,
            requestID: requestID,
            maxBodyBytes: maxBodyBytes
        )

        #expect(chunks.map(\.count) == [2, 2, 1])

        try await app.asyncShutdown()
    }

    @Test("Connection routing fans out user packets only to routed remote nodes")
    func connectionRoutingFansOutUserPacketsToRoutedRemoteNodes() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)
        app.imNodeID = "node-a"

        let owner = try await user(email: "demo@example.com", on: app)
        let userID = try owner.requireID()
        let presenceStore = FakePresenceStore()
        await presenceStore.setUserRoutes([userID: ["node-a", "node-b"]])
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        let eventID = UUID()
        let payload = IMTCPChatDomainEventPayload(
            eventID: eventID,
            eventType: .messageCreated,
            aggregateType: "conversation",
            aggregateID: UUID(),
            aggregateSequence: 1,
            occurredAt: Date(),
            actorUserID: userID,
            conversation: nil,
            ownerCursor: 1,
            ownerAggregateSequence: 1,
            body: .messageCreated(
                message: IMMessageResponse(
                    id: UUID(),
                    conversationID: UUID(),
                    senderUserID: userID,
                    clientMessageID: "client-1",
                    serverSequence: 1,
                    timelineSequence: 1,
                    content: .richText(.plain("hello")),
                    derivedState: MessageDerivedState(),
                    createdAt: Date()
                ),
                clientMessageID: "client-1"
            )
        )
        _ = try await OwnerDomainEventDeliveryService(db: app.db).record(
            payload: payload,
            ownerUserID: userID,
            sourceType: .conversation,
            sourceEventID: eventID
        )
        await routingService.sendDomainEventDelivery(ownerUserID: userID, eventID: eventID, requestID: UUID())

        let dispatches = await dispatchService.dispatches()
        #expect(dispatches.count == 1)
        #expect(dispatches.first?.nodeID == "node-b")
        #expect(dispatches.first?.envelope.action == .domainEvent)
        #expect(dispatches.first?.envelope.targetUserIDs == [userID])
        guard case .domainEvent(let ownerUserID, let dispatchedEventID) = dispatches.first?.envelope.payload else {
            Issue.record("Expected delivery identity domain event dispatch.")
            return
        }
        #expect(ownerUserID == userID)
        #expect(dispatchedEventID == eventID)

        try await app.asyncShutdown()
    }

    @Test("Connection routing skips remote user route lookup when no remote node is active")
    func connectionRoutingSkipsRemoteUserRouteLookupWhenNoRemoteNodeIsActive() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)
        app.imNodeID = "node-a"

        let userIDs = [UUID(), UUID(), UUID()]
        let presenceStore = FakePresenceStore()
        await presenceStore.setUserRoutes(
            Dictionary(uniqueKeysWithValues: userIDs.map { ($0, Set(["node-a"])) })
        )
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        let payload = imTestDomainEventPayload(
            eventID: UUID(),
            conversationID: UUID(),
            senderUserID: userIDs[0],
            sequence: 1,
            text: "local only"
        )
        await routingService.sendDomainEventPayloadBatches(
            [
                IMGatewayDomainEventPayloadBatch(
                    payload: payload,
                    recipientUserIDs: userIDs
                )
            ],
            requestID: payload.eventID
        )

        #expect(await dispatchService.dispatches().isEmpty)
        #expect(await presenceStore.userRouteLookupTotal() == 0)
        let metrics = await app.routingMetrics.currentSnapshot()
        #expect(metrics.remoteDomainEventEncodedPacketCount == 0)
        #expect(metrics.remoteDomainEventEncodeCacheHitCount == 0)

        try await app.asyncShutdown()
    }

    @Test("Connection routing skips remote payload encoding when recipients have no remote routes")
    func connectionRoutingSkipsRemotePayloadEncodingWhenRecipientsHaveNoRemoteRoutes() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)
        app.imNodeID = "node-a"

        let userIDs = [UUID(), UUID()]
        let unrelatedRemoteUserID = UUID()
        let presenceStore = FakePresenceStore()
        await presenceStore.setUserRoutes(
            Dictionary(uniqueKeysWithValues: userIDs.map { ($0, Set(["node-a"])) })
                .merging([unrelatedRemoteUserID: Set(["node-b"])]) { current, _ in current }
        )
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        let payload = imTestDomainEventPayload(
            eventID: UUID(),
            conversationID: UUID(),
            senderUserID: userIDs[0],
            sequence: 1,
            text: "local recipients only"
        )
        await routingService.sendDomainEventPayloadBatches(
            [
                IMGatewayDomainEventPayloadBatch(
                    payload: payload,
                    recipientUserIDs: userIDs
                )
            ],
            requestID: payload.eventID
        )

        #expect(await dispatchService.dispatches().isEmpty)
        #expect(await presenceStore.userRouteLookupTotal() == 1)
        let metrics = await app.routingMetrics.currentSnapshot()
        #expect(metrics.remoteDomainEventEncodedPacketCount == 0)
        #expect(metrics.remoteDomainEventEncodeCacheHitCount == 0)
        #expect(metrics.crossNodeDispatchAttemptCount == 0)

        try await app.asyncShutdown()
    }

    @Test("Connection routing reuses encoded remote lightweight conversation hint packets across batches")
    func connectionRoutingReusesEncodedRemoteLightweightConversationHintPacketsAcrossBatches() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)
        app.imNodeID = "node-a"

        let userIDs = [UUID(), UUID()]
        let presenceStore = FakePresenceStore()
        await presenceStore.setUserRoutes(
            Dictionary(uniqueKeysWithValues: userIDs.map { ($0, Set(["node-b"])) })
        )
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        let conversationID = UUID()
        let eventID = UUID()
        let occurredAt = Date()
        let payload = IMTCPChatDomainEventPayload(
            eventID: eventID,
            eventType: .conversationActivityHint,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: 7,
            occurredAt: occurredAt,
            actorUserID: userIDs[0],
            conversation: nil,
            timelineNotice: nil,
            requiresTimelineNotice: false,
            ownerCursor: nil,
            ownerAggregateSequence: nil,
            body: .conversationActivityHint(
                IMConversationActivityHint(
                    messageID: UUID(),
                    senderUserID: userIDs[0],
                    serverSequence: 7,
                    timelineSequence: 7,
                    previewText: "cached remote hint",
                    messageCreatedAt: occurredAt,
                    updatedAt: occurredAt
                )
            )
        )

        await routingService.sendDomainEventPayloadBatches(
            [
                IMGatewayDomainEventPayloadBatch(
                    payload: payload,
                    recipientUserIDs: [userIDs[0]]
                ),
                IMGatewayDomainEventPayloadBatch(
                    payload: payload,
                    recipientUserIDs: [userIDs[1]]
                )
            ],
            requestID: eventID
        )

        let dispatches = await dispatchService.dispatches()
        #expect(dispatches.count == 2)
        #expect(Set(dispatches.map(\.nodeID)) == ["node-b"])
        #expect(Set(dispatches.flatMap { $0.envelope.targetUserIDs }) == Set(userIDs))
        let packetBase64Values = dispatches.compactMap { dispatch -> String? in
            guard case .domainEventPacket(let packetBase64, _, _) = dispatch.envelope.payload else {
                return nil
            }
            return packetBase64
        }
        #expect(Set(packetBase64Values).count == 1)

        let metrics = await app.routingMetrics.currentSnapshot()
        #expect(metrics.remoteDomainEventEncodedPacketCount == 1)
        #expect(metrics.remoteDomainEventEncodeCacheHitCount == 1)
        #expect(metrics.remoteDomainEventEncodedPacketBytes > 0)
        #expect(metrics.remoteDomainEventMaxEncodedPacketBytes > 0)
        #expect(metrics.crossNodeDispatchAttemptCount == 2)
        #expect(metrics.crossNodeDispatchTargetCount == 2)

        try await app.asyncShutdown()
    }

    @Test("Connection routing refreshes active conversation presence for heartbeat")
    func connectionRoutingRefreshesActiveConversationPresenceForHeartbeat() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)
        app.imNodeID = "node-a"

        let conversationID = UUID()
        let connectionID = UUID()
        let userID = UUID()
        let connection = IMAuthenticatedConnection(
            connectionID: connectionID,
            userID: userID,
            sessionID: UUID(),
            authenticatedAt: Date(),
            remoteIPAddress: "127.0.0.1",
            deviceID: "heartbeat-refresh-device",
            deviceName: "Heartbeat Refresh",
            platform: "ios",
            appVersion: "1.0"
        )
        let channel = EmbeddedChannel()
        await app.imConnectionRegistry.bind(
            connection,
            control: IMConnectionControl(connectionID: connectionID, channel: channel)
        )

        let presenceStore = FakePresenceStore()
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        let didActivate = await routingService.updateConversationActivity(
            connectionID: connectionID,
            conversationID: conversationID,
            isActive: true
        )
        #expect(didActivate)
        #expect(await presenceStore.activeConversationActivationCount(conversationID: conversationID, userID: userID) == 1)

        await routingService.refreshActiveConversationPresence(connectionID: connectionID)

        #expect(await presenceStore.activeConversationActivationCount(conversationID: conversationID, userID: userID) == 2)

        try await app.asyncShutdown()
    }

    @Test("Connection routing splits large remote group message fanout by active conversation route")
    func connectionRoutingSplitsLargeRemoteGroupMessageFanoutByActiveConversationRoute() async throws {
        let previewLimitKey = "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_PREVIEW_MAX_CHARS"
        let previousPreviewLimit = Environment.get(previewLimitKey)
        setenv(previewLimitKey, "12", 1)
        defer {
            if let previousPreviewLimit {
                setenv(previewLimitKey, previousPreviewLimit, 1)
            } else {
                unsetenv(previewLimitKey)
            }
        }

        let app = try await Application.make(.testing)
        try await configure(app)
        app.imNodeID = "node-a"
        app.streamConsumerConfiguration = IMStreamConsumerConfiguration.load(from: app.environment)
        app.gatewayLocalFanoutConfiguration = IMGatewayLocalFanoutConfiguration(
            batchSize: 64,
            eventLoopYieldChunkCount: 64,
            activeConversationFanoutEnabled: true,
            activeConversationFanoutRecipientThreshold: 2,
            activeConversationFullFanoutRecipientLimit: 10,
            activeConversationFullFanoutPayloadByteBudget: 0,
            inactiveConversationHintDebounceSeconds: 1,
            inactiveConversationHintMaxPendingRecipients: 5_000
        )

        let conversationID = UUID()
        let activeUserIDs = [UUID(), UUID()]
        let inactiveUserID = UUID()
        let userIDs = activeUserIDs + [inactiveUserID]
        let presenceStore = FakePresenceStore()
        await presenceStore.setUserRoutes(
            Dictionary(uniqueKeysWithValues: userIDs.map { ($0, Set(["node-b"])) })
        )
        await presenceStore.setActiveConversationRoutes([
            conversationID: Dictionary(uniqueKeysWithValues: activeUserIDs.map { ($0, Set(["node-b"])) })
        ])
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        let payload = imTestDomainEventPayload(
            eventID: UUID(),
            conversationID: conversationID,
            senderUserID: activeUserIDs[0],
            sequence: 1,
            text: "large remote group with a long inactive preview",
            content: .richText(
                IMRichTextContent(
                    text: "large remote group with a long inactive preview",
                    entities: [
                        .link(range: IMTextRange(location: 0, length: 5), url: "https://example.com")
                    ]
                )
            )
        )
        await routingService.sendDomainEventPayloadBatches(
            [
                IMGatewayDomainEventPayloadBatch(
                    payload: payload,
                    recipientUserIDs: userIDs
                )
            ],
            requestID: payload.eventID
        )

        let dispatches = await dispatchService.dispatches()
        #expect(dispatches.count == 2)
        let decodedDispatches = try dispatches.map { dispatch in
            (dispatch: dispatch, payload: try readDomainEventPayload(from: dispatch.envelope))
        }
        let fullDispatch = try #require(decodedDispatches.first { $0.payload.eventType == .messageCreated })
        let hintDispatch = try #require(decodedDispatches.first { $0.payload.eventType == .conversationActivityHint })

        #expect(fullDispatch.dispatch.nodeID == "node-b")
        #expect(Set(fullDispatch.dispatch.envelope.targetUserIDs) == Set(activeUserIDs))
        guard case .activeConversationDomainEventPacket(_, let activeConversationID, let allowedUserIDs, let fanoutIntent) = fullDispatch.dispatch.envelope.payload else {
            Issue.record("Expected active full dispatch to use an active-conversation packet envelope.")
            return
        }
        #expect(activeConversationID == conversationID)
        #expect(Set(allowedUserIDs) == Set(activeUserIDs))
        #expect(fanoutIntent == .preSplitActiveFull)
        guard case .messageCreated = fullDispatch.payload.body else {
            Issue.record("Expected active remote users to receive full message_created payload.")
            return
        }

        #expect(hintDispatch.dispatch.nodeID == "node-b")
        #expect(Set(hintDispatch.dispatch.envelope.targetUserIDs) == [inactiveUserID])
        guard case .domainEventPacket(_, _, let hintFanoutIntent) = hintDispatch.dispatch.envelope.payload else {
            Issue.record("Expected inactive hint dispatch to use a domain-event packet envelope.")
            return
        }
        #expect(hintFanoutIntent == .preSplitInactiveHint)
        #expect(hintDispatch.payload.conversation == nil)
        #expect(hintDispatch.payload.timelineNotice == nil)
        #expect(hintDispatch.payload.requiresTimelineNotice == false)
        #expect(hintDispatch.payload.ownerCursor == nil)
        #expect(hintDispatch.payload.ownerAggregateSequence == nil)
        #expect(hintDispatch.payload.eventID == imLightweightMessageCreatedHintEventID(for: payload.eventID))
        #expect(hintDispatch.payload.eventID != payload.eventID)
        guard case .conversationActivityHint(let hint) = hintDispatch.payload.body else {
            Issue.record("Expected inactive remote users to receive conversation activity hint.")
            return
        }
        #expect(hint.previewText == "large remote")
        let metrics = await app.routingMetrics.currentSnapshot()
        #expect(metrics.realtimeRemoteActiveConversationFanoutSplitCount == 1)
        #expect(metrics.realtimeRemoteActiveConversationFanoutFullRecipientCount == 2)
        #expect(metrics.realtimeRemoteActiveConversationFanoutInactiveHintRecipientCount == 1)
        #expect(metrics.realtimeRemoteActiveConversationFanoutDowngradedActiveRecipientCount == 0)
        #expect(metrics.realtimeRemoteActiveConversationFanoutFallbackCount == 0)
        #expect(metrics.realtimeRemoteActiveConversationFanoutMaxFullRecipientsPerSplit == 2)
        #expect(metrics.realtimeRemoteActiveConversationFanoutMaxInactiveHintRecipientsPerSplit == 1)

        try await app.asyncShutdown()
    }

    @Test("Connection routing drops remote unsplit fallback when active route lookup fails closed")
    func connectionRoutingDropsRemoteUnsplitFallbackWhenActiveRouteLookupFailsClosed() async throws {
        let fallbackKey = "IM_REALTIME_ACTIVE_CONVERSATION_UNSPLIT_FALLBACK_ENABLED"
        let previousFallback = Environment.get(fallbackKey)
        setenv(fallbackKey, "false", 1)
        defer {
            restoreEnvironment(fallbackKey, to: previousFallback)
        }

        let app = try await Application.make(.testing)
        try await configure(app)
        app.imNodeID = "node-a"
        app.streamConsumerConfiguration = IMStreamConsumerConfiguration.load(from: app.environment)
        app.gatewayLocalFanoutConfiguration = IMGatewayLocalFanoutConfiguration(
            batchSize: 64,
            eventLoopYieldChunkCount: 64,
            activeConversationFanoutEnabled: true,
            activeConversationFanoutRecipientThreshold: 2,
            activeConversationFullFanoutRecipientLimit: 1,
            activeConversationFullFanoutPayloadByteBudget: 0,
            inactiveConversationHintDebounceSeconds: 1,
            inactiveConversationHintMaxPendingRecipients: 5_000
        )

        let conversationID = UUID()
        let userIDs = [UUID(), UUID(), UUID()]
        let presenceStore = FakePresenceStore()
        await presenceStore.setUserRoutes(
            Dictionary(uniqueKeysWithValues: userIDs.map { ($0, Set(["node-b"])) })
        )
        await presenceStore.setFailsActiveConversationRouteLookups(true)
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        let payload = imTestDomainEventPayload(
            eventID: UUID(),
            conversationID: conversationID,
            senderUserID: userIDs[0],
            sequence: 1,
            text: "route failure must not full fanout"
        )
        await routingService.sendDomainEventPayloadBatches(
            [
                IMGatewayDomainEventPayloadBatch(
                    payload: payload,
                    recipientUserIDs: userIDs
                )
            ],
            requestID: payload.eventID
        )

        let dispatches = await dispatchService.dispatches()
        #expect(dispatches.isEmpty)
        #expect(await presenceStore.activeConversationRouteLookupTotal() == 1)
        let metrics = await app.routingMetrics.currentSnapshot()
        #expect(metrics.realtimeRemoteActiveConversationFanoutFallbackCount == 0)
        #expect(metrics.realtimeRemoteActiveConversationFanoutDroppedFallbackCount == 1)
        #expect(metrics.realtimeRemoteActiveConversationFanoutDroppedFallbackRecipientCount == userIDs.count)

        try await app.asyncShutdown()
    }

    @Test("Connection routing applies remote active conversation full fanout limit")
    func connectionRoutingAppliesRemoteActiveConversationFullFanoutLimit() async throws {
        let previewValues = [
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_PREVIEW_MAX_CHARS": "120",
            "IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS": "0"
        ]
        let originalPreviewValues = Dictionary(uniqueKeysWithValues: previewValues.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalPreviewValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in previewValues {
            setenv(key, value, 1)
        }

        let app = try await Application.make(.testing)
        try await configure(app)
        app.imNodeID = "node-a"
        app.gatewayLocalFanoutConfiguration = IMGatewayLocalFanoutConfiguration(
            batchSize: 64,
            eventLoopYieldChunkCount: 64,
            activeConversationFanoutEnabled: true,
            activeConversationFanoutRecipientThreshold: 2,
            activeConversationFullFanoutRecipientLimit: 2,
            activeConversationFullFanoutPayloadByteBudget: 0,
            inactiveConversationHintDebounceSeconds: 1,
            inactiveConversationHintMaxPendingRecipients: 5_000
        )

        let conversationID = UUID()
        let activeUserIDs = [UUID(), UUID(), UUID()]
        let inactiveUserID = UUID()
        let userIDs = activeUserIDs + [inactiveUserID]
        let presenceStore = FakePresenceStore()
        await presenceStore.setUserRoutes(
            Dictionary(uniqueKeysWithValues: userIDs.map { ($0, Set(["node-b"])) })
        )
        await presenceStore.setActiveConversationRoutes([
            conversationID: Dictionary(uniqueKeysWithValues: activeUserIDs.map { ($0, Set(["node-b"])) })
        ])
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        let payload = imTestDomainEventPayload(
            eventID: UUID(),
            conversationID: conversationID,
            senderUserID: activeUserIDs[0],
            sequence: 1,
            text: "limited remote group"
        )
        await routingService.sendDomainEventPayloadBatches(
            [
                IMGatewayDomainEventPayloadBatch(
                    payload: payload,
                    recipientUserIDs: userIDs
                )
            ],
            requestID: payload.eventID
        )

        let dispatches = await dispatchService.dispatches()
        #expect(dispatches.count == 3)
        let decodedDispatches = try dispatches.map { dispatch in
            (dispatch: dispatch, payload: try readDomainEventPayload(from: dispatch.envelope))
        }
        let messageDispatches = decodedDispatches.filter { $0.payload.eventType == .messageCreated }
        let hintDispatches = decodedDispatches.filter { $0.payload.eventType == .conversationActivityHint }
        let timelineGapDispatches = decodedDispatches.filter { $0.payload.eventType == .timelineGapHint }
        let fullDispatch = try #require(messageDispatches.first {
            guard case .activeConversationDomainEventPacket(_, _, _, .preSplitActiveFull) = $0.dispatch.envelope.payload else {
                return false
            }
            return true
        })
        let compactDispatch = try #require(timelineGapDispatches.first {
            guard case .activeConversationDomainEventPacket(_, _, _, .preSplitActiveCompact) = $0.dispatch.envelope.payload else {
                return false
            }
            return true
        })
        let inactiveHintDispatch = try #require(hintDispatches.first {
            guard case .domainEventPacket = $0.dispatch.envelope.payload else {
                return false
            }
            return true
        })

        #expect(Set(fullDispatch.dispatch.envelope.targetUserIDs) == Set(activeUserIDs.prefix(2)))
        #expect(Set(compactDispatch.dispatch.envelope.targetUserIDs) == Set(activeUserIDs.suffix(1)))
        #expect(Set(inactiveHintDispatch.dispatch.envelope.targetUserIDs) == Set([inactiveUserID]))
        #expect(compactDispatch.payload.timelineNotice == nil)
        #expect(compactDispatch.payload.requiresTimelineNotice == false)
        #expect(compactDispatch.payload.ownerCursor == nil)
        #expect(compactDispatch.payload.ownerAggregateSequence == nil)
        if case .timelineGapHint(let compactHint) = compactDispatch.payload.body {
            #expect(compactHint.timelineSequence == payload.aggregateSequence)
        } else {
            Issue.record("Expected compact active remote users to receive timelineGapHint.")
        }
        #expect(inactiveHintDispatch.payload.timelineNotice == nil)
        #expect(inactiveHintDispatch.payload.requiresTimelineNotice == false)
        #expect(inactiveHintDispatch.payload.ownerCursor == nil)
        #expect(inactiveHintDispatch.payload.ownerAggregateSequence == nil)
        if case .conversationActivityHint(let inactiveHint) = inactiveHintDispatch.payload.body {
            #expect(inactiveHint.previewText == "limited remote group")
        } else {
            Issue.record("Expected inactive remote users to receive conversationActivityHint.")
        }
        let metrics = await app.routingMetrics.currentSnapshot()
        #expect(metrics.realtimeRemoteActiveConversationFanoutSplitCount == 1)
        #expect(metrics.realtimeRemoteActiveConversationFanoutFullRecipientCount == 2)
        #expect(metrics.realtimeRemoteActiveConversationFanoutCompactRecipientCount == 1)
        #expect(metrics.realtimeRemoteActiveConversationFanoutInactiveHintRecipientCount == 1)
        #expect(metrics.realtimeRemoteActiveConversationFanoutDowngradedActiveRecipientCount == 1)
        #expect(metrics.realtimeRemoteActiveConversationFanoutMaxCompactRecipientsPerSplit == 1)
        #expect(metrics.realtimeRemoteActiveConversationFanoutMaxDowngradedActiveRecipientsPerSplit == 1)

        try await app.asyncShutdown()
    }

    @Test("Connection routing applies remote active conversation full fanout payload budget")
    func connectionRoutingAppliesRemoteActiveConversationFullFanoutPayloadBudget() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)
        app.imNodeID = "node-a"
        app.gatewayLocalFanoutConfiguration = IMGatewayLocalFanoutConfiguration(
            batchSize: 64,
            eventLoopYieldChunkCount: 64,
            activeConversationFanoutEnabled: true,
            activeConversationFanoutRecipientThreshold: 2,
            activeConversationFullFanoutRecipientLimit: 10,
            activeConversationFullFanoutPayloadByteBudget: 1024,
            inactiveConversationHintDebounceSeconds: 1,
            inactiveConversationHintMaxPendingRecipients: 5_000
        )

        let conversationID = UUID()
        let activeUserIDs = [UUID(), UUID(), UUID()]
        let inactiveUserID = UUID()
        let userIDs = activeUserIDs + [inactiveUserID]
        let presenceStore = FakePresenceStore()
        await presenceStore.setUserRoutes(
            Dictionary(uniqueKeysWithValues: userIDs.map { ($0, Set(["node-b"])) })
        )
        await presenceStore.setActiveConversationRoutes([
            conversationID: Dictionary(uniqueKeysWithValues: activeUserIDs.map { ($0, Set(["node-b"])) })
        ])
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        let payload = imTestDomainEventPayload(
            eventID: UUID(),
            conversationID: conversationID,
            senderUserID: activeUserIDs[0],
            sequence: 1,
            text: String(repeating: "large-remote-payload", count: 400)
        )
        let budget = IMActiveConversationFullFanoutBudget.effectiveLimit(
            baseLimit: 10,
            payloadByteBudget: 1024,
            payload: payload
        )
        #expect(budget.limit == 1)

        await routingService.sendDomainEventPayloadBatches(
            [
                IMGatewayDomainEventPayloadBatch(
                    payload: payload,
                    recipientUserIDs: userIDs
                )
            ],
            requestID: payload.eventID
        )

        let dispatches = await dispatchService.dispatches()
        #expect(dispatches.count == 3)
        let decodedDispatches = try dispatches.map { dispatch in
            (dispatch: dispatch, payload: try readDomainEventPayload(from: dispatch.envelope))
        }
        let messageDispatches = decodedDispatches.filter { $0.payload.eventType == .messageCreated }
        let hintDispatches = decodedDispatches.filter { $0.payload.eventType == .conversationActivityHint }
        let timelineGapDispatches = decodedDispatches.filter { $0.payload.eventType == .timelineGapHint }
        let compactHintDispatch = try #require(timelineGapDispatches.first {
            Set($0.dispatch.envelope.targetUserIDs) == Set(activeUserIDs.suffix(2))
        })
        let inactiveHintDispatch = try #require(hintDispatches.first {
            Set($0.dispatch.envelope.targetUserIDs) == Set([inactiveUserID])
        })

        #expect(Set(messageDispatches.flatMap { $0.dispatch.envelope.targetUserIDs }) == Set(activeUserIDs.prefix(1)))
        #expect(messageDispatches.contains { Set($0.dispatch.envelope.targetUserIDs) == Set(activeUserIDs.prefix(1)) })
        #expect(Set(compactHintDispatch.dispatch.envelope.targetUserIDs) == Set(activeUserIDs.suffix(2)))
        #expect(Set(inactiveHintDispatch.dispatch.envelope.targetUserIDs) == Set([inactiveUserID]))
        let metrics = await app.routingMetrics.currentSnapshot()
        #expect(metrics.realtimeRemoteActiveConversationFanoutSplitCount == 1)
        #expect(metrics.realtimeRemoteActiveConversationFanoutFullRecipientCount == 1)
        #expect(metrics.realtimeRemoteActiveConversationFanoutCompactRecipientCount == 2)
        #expect(metrics.realtimeRemoteActiveConversationFanoutInactiveHintRecipientCount == 1)
        #expect(metrics.realtimeRemoteActiveConversationFanoutDowngradedActiveRecipientCount == 2)
        #expect(metrics.realtimeActiveConversationFanoutPayloadBudgetAppliedCount == 1)
        #expect(metrics.realtimeActiveConversationFanoutPayloadBudgetDowngradedRecipientCount == 2)
        #expect(metrics.realtimeActiveConversationFanoutPayloadBudgetMaxPayloadBytes == budget.payloadByteCount)
        #expect(metrics.realtimeActiveConversationFanoutPayloadBudgetMaxEffectiveLimit == 1)

        try await app.asyncShutdown()
    }

    @Test("Connection routing maintains global active conversation presence until last local active connection leaves")
    func connectionRoutingMaintainsGlobalActiveConversationPresenceUntilLastLocalConnectionLeaves() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)
        app.imNodeID = "node-a"

        let userID = UUID()
        let conversationID = UUID()
        let firstConnectionID = UUID()
        let secondConnectionID = UUID()
        let presenceStore = FakePresenceStore()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: FakeNodeMessageDispatchService()
            )
        )

        try await routingService.bind(
            IMAuthenticatedConnection(
                connectionID: firstConnectionID,
                userID: userID,
                sessionID: UUID(),
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "device-a",
                deviceName: "Device A",
                platform: "ios",
                appVersion: "1.0"
            ),
            control: IMConnectionControl(connectionID: firstConnectionID, channel: EmbeddedChannel())
        )
        try await routingService.bind(
            IMAuthenticatedConnection(
                connectionID: secondConnectionID,
                userID: userID,
                sessionID: UUID(),
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "device-b",
                deviceName: "Device B",
                platform: "ios",
                appVersion: "1.0"
            ),
            control: IMConnectionControl(connectionID: secondConnectionID, channel: EmbeddedChannel())
        )

        #expect(await routingService.updateConversationActivity(
            connectionID: firstConnectionID,
            conversationID: conversationID,
            isActive: true
        ))
        #expect(await routingService.updateConversationActivity(
            connectionID: secondConnectionID,
            conversationID: conversationID,
            isActive: true
        ))
        #expect(await presenceStore.activeConversationActivationCount(conversationID: conversationID, userID: userID) == 2)

        #expect(await routingService.updateConversationActivity(
            connectionID: firstConnectionID,
            conversationID: conversationID,
            isActive: false
        ))
        #expect(await presenceStore.activeConversationDeactivationCount(conversationID: conversationID, userID: userID) == 0)

        await routingService.remove(connectionID: secondConnectionID)
        #expect(await presenceStore.activeConversationDeactivationCount(conversationID: conversationID, userID: userID) == 1)

        try await app.asyncShutdown()
    }

    @Test("Connection routing kicks only routed remote sessions")
    func connectionRoutingKicksOnlyRoutedRemoteSessions() async throws {
        let app = try await Application.make(.testing)
        app.imTCPConfiguration = IMTCPConfiguration.load(from: .testing)
        app.gatewayLocalFanoutConfiguration = IMGatewayLocalFanoutConfiguration.load()
        app.imNodeID = "node-a"

        let localSessionID = UUID()
        let remoteSessionID = UUID()
        let presenceStore = FakePresenceStore()
        await presenceStore.setSessionRoutes([
            localSessionID: ["node-a"],
            remoteSessionID: ["node-b"]
        ])
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        await routingService.kickConnections(
            forSessionID: remoteSessionID,
            reason: .sessionRevoked,
            message: "Session revoked"
        )

        let dispatches = await dispatchService.dispatches()
        #expect(dispatches.count == 1)
        #expect(dispatches.first?.nodeID == "node-b")
        #expect(dispatches.first?.envelope.action == .kickSession)
        #expect(dispatches.first?.envelope.sessionID == remoteSessionID)

        try await app.asyncShutdown()
    }

    @Test("Connection routing forwards conversation events only to routed remote user nodes")
    func connectionRoutingForwardsConversationEventsToRoutedRemoteUserNodes() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)
        app.imNodeID = "node-a"

        let owner = try await user(email: "demo@example.com", on: app)
        let userID = try owner.requireID()
        let conversation = IMConversationResponse(
            id: UUID(),
            title: "Remote Read",
            kind: IMConversationKind.direct.rawValue,
            directMessagingState: nil,
            directPeer: nil,
            notice: nil,
            avatarPreset: nil,
            memberCount: 2,
            memberUserIDs: [userID],
            lastMessage: nil,
            lastReadSequence: 7,
            unreadCount: 0,
            isPinned: false,
            pinnedAt: nil,
            isMuted: false,
            createdAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_400_000)
        )
        let presenceStore = FakePresenceStore()
        await presenceStore.setUserRoutes([userID: ["node-a", "node-b"]])
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        let eventID = UUID()
        let payload = IMTCPChatDomainEventPayload(
            eventID: eventID,
            eventType: .conversationUpdated,
            aggregateType: "conversation",
            aggregateID: conversation.id,
            aggregateSequence: UInt64(conversation.lastReadSequence),
            occurredAt: Date(timeIntervalSince1970: 1_700_400_001),
            actorUserID: userID,
            conversation: conversation,
            ownerCursor: 1,
            ownerAggregateSequence: 1,
            body: .conversationChanged
        )
        _ = try await OwnerDomainEventDeliveryService(db: app.db).record(
            payload: payload,
            ownerUserID: userID,
            sourceType: .conversation,
            sourceEventID: eventID
        )
        await routingService.sendDomainEventDelivery(ownerUserID: userID, eventID: eventID, requestID: UUID())

        let dispatches = await dispatchService.dispatches()
        #expect(dispatches.count == 1)
        #expect(dispatches.first?.nodeID == "node-b")
        #expect(dispatches.first?.envelope.action == .domainEvent)
        #expect(dispatches.first?.envelope.targetUserIDs == [userID])
        guard case .domainEvent(let ownerUserID, let dispatchedEventID) = dispatches.first?.envelope.payload else {
            Issue.record("Expected delivery identity domain event dispatch.")
            return
        }
        #expect(ownerUserID == userID)
        #expect(dispatchedEventID == eventID)

        try await app.asyncShutdown()
    }

    @Test("Connection routing chunks cross-node domain event packets by remote user batch size")
    func connectionRoutingChunksCrossNodeDomainEventPacketsByRemoteUserBatchSize() async throws {
        let batchSizeKey = "IM_REALTIME_REMOTE_DISPATCH_USER_BATCH_SIZE"
        let maxInFlightKey = "IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT"
        let previousBatchSize = Environment.get(batchSizeKey)
        let previousMaxInFlight = Environment.get(maxInFlightKey)
        setenv(batchSizeKey, "2", 1)
        setenv(maxInFlightKey, "2", 1)
        defer {
            if let previousBatchSize {
                setenv(batchSizeKey, previousBatchSize, 1)
            } else {
                unsetenv(batchSizeKey)
            }
            if let previousMaxInFlight {
                setenv(maxInFlightKey, previousMaxInFlight, 1)
            } else {
                unsetenv(maxInFlightKey)
            }
        }

        let app = try await Application.make(.testing)
        try await configure(app)
        app.imNodeID = "node-a"
        app.streamConsumerConfiguration = IMStreamConsumerConfiguration.load(from: app.environment)

        let userIDs = (0..<5).map { _ in UUID() }
        let routes = Dictionary(uniqueKeysWithValues: userIDs.map { ($0, Set(["node-b"])) })
        let presenceStore = FakePresenceStore()
        await presenceStore.setUserRoutes(routes)
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        let eventID = UUID()
        let payload = IMTCPChatDomainEventPayload(
            eventID: eventID,
            eventType: .messageCreated,
            aggregateType: "conversation",
            aggregateID: UUID(),
            aggregateSequence: 1,
            occurredAt: Date(),
            actorUserID: userIDs[0],
            conversation: nil,
            ownerCursor: nil,
            ownerAggregateSequence: nil,
            body: .messageCreated(
                message: IMMessageResponse(
                    id: UUID(),
                    conversationID: UUID(),
                    senderUserID: userIDs[0],
                    clientMessageID: "chunked-client-1",
                    serverSequence: 1,
                    timelineSequence: 1,
                    content: .richText(.plain("hello")),
                    derivedState: MessageDerivedState(),
                    createdAt: Date()
                ),
                clientMessageID: "chunked-client-1"
            )
        )

        await routingService.sendDomainEventPayload(payload, toUserIDs: userIDs, requestID: UUID())

        let dispatches = await dispatchService.dispatches()
        #expect(dispatches.count == 3)
        #expect(Set(dispatches.map(\.nodeID)) == ["node-b"])
        #expect(dispatches.map { $0.envelope.targetUserIDs.count }.sorted() == [1, 2, 2])
        #expect(Set(dispatches.flatMap { $0.envelope.targetUserIDs }) == Set(userIDs))

        let metrics = await app.routingMetrics.currentSnapshot()
        #expect(metrics.crossNodeDispatchAttemptCount == 3)
        #expect(metrics.crossNodeDispatchCount == 3)
        #expect(metrics.crossNodeDispatchTargetCount == 5)
        #expect(metrics.crossNodeDispatchMaxTargetsPerPacket == 2)
        #expect(metrics.crossNodeDispatchMaxLatencyMillis >= 0)

        try await app.asyncShutdown()
    }

    @Test("Connection routing still dispatches remote users when local registry has no connections")
    func connectionRoutingStillDispatchesRemoteUsersWhenLocalRegistryHasNoConnections() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)
        app.imNodeID = "node-a"

        let remoteUserIDs = [UUID(), UUID(), UUID()]
        let presenceStore = FakePresenceStore()
        await presenceStore.setUserRoutes(
            Dictionary(uniqueKeysWithValues: remoteUserIDs.map { ($0, Set(["node-b"])) })
        )
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        let payload = imTestDomainEventPayload(
            eventID: UUID(),
            conversationID: UUID(),
            senderUserID: remoteUserIDs[0],
            sequence: 1,
            text: "remote only"
        )
        await routingService.sendDomainEventPayloadBatches(
            [
                IMGatewayDomainEventPayloadBatch(
                    payload: payload,
                    recipientUserIDs: remoteUserIDs
                )
            ],
            requestID: payload.eventID
        )

        let metrics = await app.routingMetrics.currentSnapshot()
        #expect(metrics.localFanoutTargetConnectionCount == 0)

        let dispatches = await dispatchService.dispatches()
        #expect(dispatches.count == 1)
        #expect(dispatches.first?.nodeID == "node-b")
        #expect(dispatches.first?.envelope.action == .domainEventPacket)
        #expect(Set(dispatches.first?.envelope.targetUserIDs ?? []) == Set(remoteUserIDs))

        try await app.asyncShutdown()
    }

    @Test("Realtime delivery consumer splits active full messages and coalesces inactive hints")
    func realtimeDeliveryConsumerSplitsActiveFullMessagesAndCoalescesInactiveHints() async throws {
        let values = [
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "1",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS": "0"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let activeUserID = senderID
            let inactiveUserID = UUID()
            let downgradedUserID = UUID()
            let recipientUserIDs = [activeUserID, inactiveUserID, downgradedUserID]
            let conversation = Conversation(
                title: "Consumer Split",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_000),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            await presenceStore.setActiveConversationRoutes([
                conversationID: [
                    activeUserID: ["gateway-a"],
                    downgradedUserID: ["gateway-a"]
                ]
            ])
            await presenceStore.setUserRoutes([
                activeUserID: ["gateway-a"],
                inactiveUserID: ["gateway-a"],
                downgradedUserID: ["gateway-a"]
            ])

            var envelopes: [ConversationEventEnvelope] = []
            var messageIDs: [UUID] = []
            for sequence in 1...2 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "consumer-split-\(sequence)",
                    content: .richText(.plain("consumer split \(sequence)"))
                )
                try await message.create(on: app.db)
                let messageID = try message.requireID()
                messageIDs.append(messageID)
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(
                        messageID: messageID,
                        recipientUserIDs: recipientUserIDs,
                        preview: ConversationMessageCreatedPreview(
                            senderUserID: senderID,
                            serverSequence: UInt64(sequence),
                            timelineSequence: UInt64(sequence),
                            previewText: "consumer split \(sequence)",
                            createdAt: message.createdAt
                        )
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_710_500_000 + TimeInterval(sequence))
                )
                envelopes.append(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            try await ConversationRealtimeDeliveryConsumer(app: app, sourceDB: app.db)
                .consumeMessageCreatedRun(envelopes)

            let decodedPayloads = await dispatchService.dispatches().compactMap { dispatch in
                decodedDomainEventPayload(from: dispatch.envelope).map { payload in
                    (payload: payload, targetUserIDs: dispatch.envelope.targetUserIDs)
                }
            }
            let fullMessages = decodedPayloads.filter { $0.payload.eventType == .messageCreated }
            let inactiveHints = decodedPayloads.filter { $0.payload.eventType == .conversationActivityHint }
            #expect(fullMessages.count == 2)
            let messageTargetsBySequence = Dictionary(grouping: fullMessages, by: \.payload.aggregateSequence)
                .mapValues { payloads in
                    Set(payloads.flatMap { $0.targetUserIDs })
                }
            let activeRecipientSet = Set([activeUserID, downgradedUserID])
            for sequence in UInt64(1)...UInt64(2) {
                let fullTargets = try #require(messageTargetsBySequence[sequence])
                #expect(fullTargets.count == 1)
                #expect(fullTargets.isSubset(of: activeRecipientSet))
            }
            #expect(Set(fullMessages.map(\.payload.eventID)) == Set(envelopes.compactMap(\.eventID)))
            #expect(inactiveHints.count == 3)
            for sequence in UInt64(1)...UInt64(2) {
                let fullTargets = try #require(messageTargetsBySequence[sequence])
                let compactHints = inactiveHints.filter {
                    $0.payload.aggregateSequence == sequence
                        && Set($0.targetUserIDs).isSubset(of: activeRecipientSet)
                }
                #expect(compactHints.count == 1)
                #expect(Set(compactHints.flatMap(\.targetUserIDs)) == activeRecipientSet.subtracting(fullTargets))
            }
            let inactiveRecipientHints = inactiveHints.filter { Set($0.targetUserIDs) == [inactiveUserID] }
            #expect(inactiveRecipientHints.count == 1)
            let inactiveHint = try #require(inactiveRecipientHints.first)
            #expect(inactiveHint.payload.eventID != envelopes[1].eventID)
            if case .conversationActivityHint(let hint) = inactiveHint.payload.body {
                #expect(hint.messageID == messageIDs[1])
            } else {
                Issue.record("Expected inactive hint to use conversationActivityHint body.")
            }
            #expect(inactiveHint.payload.timelineNotice == nil)
            #expect(inactiveHint.payload.requiresTimelineNotice == false)
            #expect(inactiveHint.payload.ownerCursor == nil)
            #expect(inactiveHint.payload.ownerAggregateSequence == nil)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 2)
            #expect(metrics.realtimeActiveConversationFanoutActiveRecipientCount == 2)
            #expect(metrics.realtimeActiveConversationFanoutCompactActiveRecipientCount == 2)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 2)
            #expect(metrics.realtimeActiveConversationFanoutDowngradedActiveRecipientCount == 2)
            #expect(metrics.realtimeDeliveryConsumerInactiveHintRelayPayloadBatchCount == 1)
            #expect(metrics.realtimeDeliveryConsumerInactiveHintRelayRecipientCount == 1)
            #expect(metrics.realtimeDeliveryConsumerInactiveHintSuppressedRecipientCount == 1)
            #expect(metrics.realtimeActiveConversationRouteCacheHitCount == 0)
            #expect(metrics.realtimeActiveConversationRouteCacheMissCount == 1)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 1)
        }
    }

    @Test("Realtime delivery consumer compact-only mode sends active compact hints")
    func realtimeDeliveryConsumerCompactOnlyModeSendsActiveCompactHints() async throws {
        let values = [
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "10",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_MODE": "compact-only",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_COMPACT_HINT_BODY": "conversation-activity",
            "IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS": "8",
            "IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS": "0"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let secondActiveUserID = UUID()
            let inactiveUserID = UUID()
            let recipientUserIDs = [senderID, secondActiveUserID, inactiveUserID]
            let conversation = Conversation(
                title: "Consumer Compact Only",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_500),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            await presenceStore.setActiveConversationRoutes([
                conversationID: [
                    senderID: ["gateway-a"],
                    secondActiveUserID: ["gateway-a"]
                ]
            ])
            await presenceStore.setUserRoutes(
                Dictionary(uniqueKeysWithValues: recipientUserIDs.map { ($0, Set(["gateway-a"])) })
            )

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "consumer-compact-only-1",
                content: .richText(.plain("consumer compact only"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 1,
                payload: .messageCreated(
                    messageID: messageID,
                    recipientUserIDs: recipientUserIDs,
                    preview: ConversationMessageCreatedPreview(
                        senderUserID: senderID,
                        serverSequence: 1,
                        timelineSequence: 1,
                        previewText: "consumer compact only",
                        createdAt: message.createdAt
                    )
                ),
                createdAt: Date(timeIntervalSince1970: 1_710_500_501)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await ConversationRealtimeDeliveryConsumer(app: app, sourceDB: app.db)
                .consumeMessageCreatedRun([envelope])

            let decodedPayloads = await dispatchService.dispatches().compactMap { dispatch in
                decodedDomainEventPayload(from: dispatch.envelope).map { payload in
                    (payload: payload, targetUserIDs: dispatch.envelope.targetUserIDs)
                }
            }
            let fullMessages = decodedPayloads.filter { $0.payload.eventType == .messageCreated }
            let timelineGapHints = decodedPayloads.filter { $0.payload.eventType == .timelineGapHint }
            let activityHints = decodedPayloads.filter { $0.payload.eventType == .conversationActivityHint }
            let expectedHintEventID = imLightweightMessageCreatedHintEventID(for: try event.requireID())
            #expect(fullMessages.isEmpty)
            #expect(timelineGapHints.isEmpty)
            #expect(activityHints.count == 2)
            #expect((timelineGapHints + activityHints).allSatisfy {
                $0.payload.eventID == expectedHintEventID
            })
            let activeActivityHint = try #require(activityHints.first { Set($0.targetUserIDs) == [senderID, secondActiveUserID] })
            guard case .conversationActivityHint(let activeHint) = activeActivityHint.payload.body else {
                Issue.record("Expected active compact payload to use conversationActivityHint body.")
                return
            }
            #expect(activeHint.messageID == messageID)
            #expect(activeHint.previewText == "consumer")
            #expect(activityHints.contains { Set($0.targetUserIDs) == [inactiveUserID] })

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutActiveRecipientCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutCompactActiveRecipientCount == 2)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutDowngradedActiveRecipientCount == 2)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 1)
        }
    }

    @Test("Realtime delivery active conversation route cache reuses hot conversation routes across consumes")
    func realtimeDeliveryActiveConversationRouteCacheReusesHotConversationRoutesAcrossConsumes() async throws {
        let values = [
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "10",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS": "1000"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let inactiveUserID = UUID()
            let secondInactiveUserID = UUID()
            let recipientUserIDs = [senderID, inactiveUserID, secondInactiveUserID]
            let conversation = Conversation(
                title: "Consumer Route Cache",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_100),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            await presenceStore.setActiveConversationRoutes([
                conversationID: [
                    senderID: ["gateway-a"]
                ]
            ])
            await presenceStore.setUserRoutes(
                Dictionary(uniqueKeysWithValues: recipientUserIDs.map { ($0, Set(["gateway-a"])) })
            )

            let consumer = ConversationRealtimeDeliveryConsumer(app: app, sourceDB: app.db)
            for sequence in 1...2 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "consumer-route-cache-\(sequence)",
                    content: .richText(.plain("consumer route cache \(sequence)"))
                )
                try await message.create(on: app.db)
                let messageID = try message.requireID()
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(
                        messageID: messageID,
                        recipientUserIDs: recipientUserIDs,
                        preview: ConversationMessageCreatedPreview(
                            senderUserID: senderID,
                            serverSequence: UInt64(sequence),
                            timelineSequence: UInt64(sequence),
                            previewText: "consumer route cache \(sequence)",
                            createdAt: message.createdAt
                        )
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_710_500_100 + TimeInterval(sequence))
                )
                try await consumer.consume(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationRouteCacheHitCount == 1)
            #expect(metrics.realtimeActiveConversationRouteCacheMissCount == 1)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 1)
        }
    }

    @Test("Realtime delivery pull-only mode uses active conversation snapshot routes")
    func realtimeDeliveryPullOnlyModeUsesActiveConversationSnapshotRoutes() async throws {
        let values = [
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "10",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS": "1000",
            "IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE": "pull-only"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let activeUserID = UUID()
            let inactiveUserID = UUID()
            let secondInactiveUserID = UUID()
            let nonRecipientActiveUserID = UUID()
            let recipientUserIDs = [senderID, activeUserID, inactiveUserID, secondInactiveUserID]
            let conversation = Conversation(
                title: "Consumer Pull Only Active Snapshot",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_110),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            await presenceStore.setActiveConversationRoutes([
                conversationID: [
                    senderID: ["gateway-a"],
                    activeUserID: ["gateway-a"],
                    nonRecipientActiveUserID: ["gateway-a"]
                ]
            ])
            await presenceStore.setUserRoutes(
                Dictionary(uniqueKeysWithValues: recipientUserIDs.map { ($0, Set(["gateway-a"])) })
            )

            let consumer = ConversationRealtimeDeliveryConsumer(app: app, sourceDB: app.db)
            for sequence in 1...2 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "consumer-pull-only-active-snapshot-\(sequence)",
                    content: .richText(.plain("consumer pull only active snapshot \(sequence)"))
                )
                try await message.create(on: app.db)
                let messageID = try message.requireID()
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(
                        messageID: messageID,
                        recipientUserIDs: recipientUserIDs,
                        preview: ConversationMessageCreatedPreview(
                            senderUserID: senderID,
                            serverSequence: UInt64(sequence),
                            timelineSequence: UInt64(sequence),
                            previewText: "consumer pull only active snapshot \(sequence)",
                            createdAt: message.createdAt
                        )
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_710_500_110 + TimeInterval(sequence))
                )
                try await consumer.consume(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            let dispatches = await dispatchService.dispatches()
            let targetUserIDs = Set(dispatches.flatMap(\.envelope.targetUserIDs))
            #expect(targetUserIDs == Set([senderID, activeUserID]))
            #expect(!targetUserIDs.contains(nonRecipientActiveUserID))
            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationRouteCacheHitCount == 1)
            #expect(metrics.realtimeActiveConversationRouteCacheMissCount == 1)
            #expect(await presenceStore.activeConversationSnapshotRouteLookupTotal() == 1)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 0)
            #expect(await presenceStore.activeConversationRouteLookupRequestedCounts().isEmpty)
        }
    }

    @Test("Realtime delivery pull-only mode filters active recipients through shared recipient index")
    func realtimeDeliveryPullOnlyModeFiltersActiveRecipientsThroughSharedRecipientIndex() async throws {
        let values = [
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "10",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS": "1000",
            "IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE": "pull-only",
            "IM_STREAM_CONSUMER_REQUIRE_MESSAGE_CREATED_RECIPIENT_SNAPSHOT": "true"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let activeUserID = UUID()
            let inactiveUserIDs = (0..<998).map { _ in UUID() }
            let nonRecipientActiveUserID = UUID()
            let recipientUserIDs = [senderID, activeUserID] + inactiveUserIDs
            let conversation = Conversation(
                title: "Consumer Pull Only Shared Recipient Index",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_160),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            await presenceStore.setActiveConversationRoutes([
                conversationID: [
                    senderID: ["gateway-a"],
                    activeUserID: ["gateway-a"],
                    nonRecipientActiveUserID: ["gateway-a"]
                ]
            ])
            await presenceStore.setUserRoutes([
                senderID: ["gateway-a"],
                activeUserID: ["gateway-a"],
                nonRecipientActiveUserID: ["gateway-a"]
            ])

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "consumer-pull-only-shared-recipient-index",
                content: .richText(.plain("consumer pull only shared recipient index"))
            )
            try await message.create(on: app.db)
            let eventID = UUID()
            let createdAt = Date(timeIntervalSince1970: 1_710_500_161)
            let recipientHash = ConversationDomainEventRecipientSet.recipientHash(for: recipientUserIDs)
            try await ConversationDomainEventRecipientSet(
                recipientHash: recipientHash,
                recipientUserIDs: recipientUserIDs,
                createdAt: createdAt
            ).create(on: app.db)
            try await ConversationDomainEventRecipientSetMember.writeMemberIndex(
                recipientHash: recipientHash,
                recipientUserIDs: recipientUserIDs,
                createdAt: createdAt,
                on: app.db
            )
            try await ConversationDomainEventRecipientSnapshot(
                eventID: eventID,
                conversationID: conversationID,
                recipientUserIDs: recipientUserIDs,
                createdAt: createdAt,
                storesRecipientIDsInline: false
            ).create(on: app.db)
            let event = try ConversationDomainEvent(
                id: eventID,
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 1,
                payload: .messageCreated(
                    messageID: try message.requireID(),
                    recipientUserIDs: [],
                    preview: ConversationMessageCreatedPreview(
                        senderUserID: senderID,
                        serverSequence: 1,
                        timelineSequence: 1,
                        previewText: "consumer pull only shared recipient index",
                        createdAt: createdAt
                    )
                ),
                createdAt: createdAt
            )

            try await ConversationRealtimeDeliveryConsumer(app: app, sourceDB: app.db)
                .consume(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )

            let dispatches = await dispatchService.dispatches()
            let targetUserIDs = Set(dispatches.flatMap(\.envelope.targetUserIDs))
            #expect(targetUserIDs == Set([senderID, activeUserID]))
            #expect(!targetUserIDs.contains(nonRecipientActiveUserID))
            #expect(await presenceStore.activeConversationSnapshotRouteLookupTotal() == 1)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 0)
            let domainMetrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(domainMetrics.recipientResolveMaxUserCount == 2)
            #expect(domainMetrics.recipientSnapshotResolveMaxRecipients == 2)
        }
    }

    @Test("Realtime delivery active conversation route cache reuses partial hot conversation snapshot")
    func realtimeDeliveryActiveConversationRouteCacheReusesPartialHotConversationSnapshot() async throws {
        let values = [
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "10",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS": "1000"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let inactiveUserID = UUID()
            let secondInactiveUserID = UUID()
            let newlyActiveUserID = UUID()
            let firstRecipients = [senderID, inactiveUserID, secondInactiveUserID]
            let secondRecipients = [senderID, inactiveUserID, secondInactiveUserID, newlyActiveUserID]
            let conversation = Conversation(
                title: "Partial Consumer Route Cache",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_120),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            await presenceStore.setActiveConversationRoutes([
                conversationID: [
                    senderID: ["gateway-a"],
                    newlyActiveUserID: ["gateway-a"]
                ]
            ])
            await presenceStore.setUserRoutes(
                Dictionary(uniqueKeysWithValues: secondRecipients.map { ($0, Set(["gateway-a"])) })
            )

            let consumer = ConversationRealtimeDeliveryConsumer(app: app, sourceDB: app.db)
            for (sequence, recipients) in [(1, firstRecipients), (2, secondRecipients)] {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "partial-consumer-route-cache-\(sequence)",
                    content: .richText(.plain("partial consumer route cache \(sequence)"))
                )
                try await message.create(on: app.db)
                let messageID = try message.requireID()
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(
                        messageID: messageID,
                        recipientUserIDs: recipients,
                        preview: ConversationMessageCreatedPreview(
                            senderUserID: senderID,
                            serverSequence: UInt64(sequence),
                            timelineSequence: UInt64(sequence),
                            previewText: "partial consumer route cache \(sequence)",
                            createdAt: message.createdAt
                        )
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_710_500_120 + TimeInterval(sequence))
                )
                try await consumer.consume(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationRouteCacheHitCount == 0)
            #expect(metrics.realtimeActiveConversationRouteCachePartialHitCount == 1)
            #expect(metrics.realtimeActiveConversationRouteCacheMissCount == 1)
            #expect(metrics.realtimeActiveConversationRouteCacheCachedUserCount == 3)
            #expect(metrics.realtimeActiveConversationRouteCacheMissedUserCount == 4)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 2)
            #expect(await presenceStore.activeConversationRouteLookupRequestedCounts() == [3, 1])
        }
    }

    @Test("Realtime delivery active conversation route cache can be disabled for comparison tests")
    func realtimeDeliveryActiveConversationRouteCacheCanBeDisabledForComparisonTests() async throws {
        let values = [
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "10",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS": "0"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let inactiveUserID = UUID()
            let secondInactiveUserID = UUID()
            let recipientUserIDs = [senderID, inactiveUserID, secondInactiveUserID]
            let conversation = Conversation(
                title: "Consumer Route Cache Disabled",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_150),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            await presenceStore.setActiveConversationRoutes([
                conversationID: [
                    senderID: ["gateway-a"]
                ]
            ])
            await presenceStore.setUserRoutes(
                Dictionary(uniqueKeysWithValues: recipientUserIDs.map { ($0, Set(["gateway-a"])) })
            )

            let consumer = ConversationRealtimeDeliveryConsumer(app: app, sourceDB: app.db)
            for sequence in 1...2 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "consumer-route-cache-disabled-\(sequence)",
                    content: .richText(.plain("consumer route cache disabled \(sequence)"))
                )
                try await message.create(on: app.db)
                let messageID = try message.requireID()
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(
                        messageID: messageID,
                        recipientUserIDs: recipientUserIDs,
                        preview: ConversationMessageCreatedPreview(
                            senderUserID: senderID,
                            serverSequence: UInt64(sequence),
                            timelineSequence: UInt64(sequence),
                            previewText: "consumer route cache disabled \(sequence)",
                            createdAt: message.createdAt
                        )
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_710_500_150 + TimeInterval(sequence))
                )
                try await consumer.consume(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationRouteCacheHitCount == 0)
            #expect(metrics.realtimeActiveConversationRouteCacheMissCount == 2)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 2)
        }
    }

    @Test("Realtime delivery drops unsplit fallback when route split fails closed")
    func realtimeDeliveryDropsUnsplitFallbackWhenRouteSplitFailsClosed() async throws {
        let values = [
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "10",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "0",
            "IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE": "relay",
            "IM_REALTIME_ACTIVE_CONVERSATION_UNSPLIT_FALLBACK_ENABLED": "false"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )
            app.gatewayLocalFanoutConfiguration = IMGatewayLocalFanoutConfiguration(
                batchSize: 64,
                eventLoopYieldChunkCount: 64,
                activeConversationFanoutEnabled: true,
                activeConversationFanoutRecipientThreshold: 3,
                activeConversationFullFanoutRecipientLimit: 10,
                activeConversationFullFanoutPayloadByteBudget: 0,
                inactiveConversationHintMode: .relay,
                inactiveConversationHintDebounceSeconds: 1,
                inactiveConversationHintMaxPendingRecipients: 5_000
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let recipientUserIDs = [senderID, UUID(), UUID()]
            let conversation = Conversation(
                title: "Consumer Pull Only Route Failure",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_180),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            await presenceStore.setUserRoutes(
                Dictionary(uniqueKeysWithValues: recipientUserIDs.map { ($0, Set(["gateway-a"])) })
            )
            await presenceStore.setFailsActiveConversationRouteLookups(true)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "consumer-pull-only-route-failure",
                content: .richText(.plain("consumer pull only route failure"))
            )
            try await message.create(on: app.db)
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 1,
                payload: .messageCreated(
                    messageID: try message.requireID(),
                    recipientUserIDs: recipientUserIDs,
                    preview: ConversationMessageCreatedPreview(
                        senderUserID: senderID,
                        serverSequence: 1,
                        timelineSequence: 1,
                        previewText: "consumer pull only route failure",
                        createdAt: message.createdAt
                    )
                ),
                createdAt: Date(timeIntervalSince1970: 1_710_500_181)
            )

            try await ConversationRealtimeDeliveryConsumer(app: app, sourceDB: app.db)
                .consume(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )

            #expect(await dispatchService.dispatches().isEmpty)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 1)
            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutDroppedFallbackCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutDroppedFallbackRecipientCount == recipientUserIDs.count)
            #expect(metrics.realtimeActiveConversationFanoutUnsplitFallbackCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutHintFallbackRecipientCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 0)
        }
    }

    @Test("Domain relay-after-record drops unsplit fallback when route split fails closed")
    func domainRelayAfterRecordDropsUnsplitFallbackWhenRouteSplitFailsClosed() async throws {
        let values = [
            "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "10",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE": "relay",
            "IM_REALTIME_ACTIVE_CONVERSATION_UNSPLIT_FALLBACK_ENABLED": "false"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let recipientUserIDs = [senderID, UUID(), UUID()]
            let conversation = Conversation(
                title: "Relay Route Failure",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_190),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            await presenceStore.setUserRoutes(
                Dictionary(uniqueKeysWithValues: recipientUserIDs.map { ($0, Set(["gateway-a"])) })
            )
            await presenceStore.setFailsActiveConversationRouteLookups(true)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "relay-route-failure",
                content: .richText(.plain("relay route failure"))
            )
            try await message.create(on: app.db)
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 1,
                payload: .messageCreated(
                    messageID: try message.requireID(),
                    recipientUserIDs: recipientUserIDs,
                    preview: ConversationMessageCreatedPreview(
                        senderUserID: senderID,
                        serverSequence: 1,
                        timelineSequence: 1,
                        previewText: "relay route failure",
                        createdAt: message.createdAt
                    )
                ),
                createdAt: Date(timeIntervalSince1970: 1_710_500_191)
            )

            try await OwnerDomainEventDeliveryConsumer(
                app: app,
                sourceDB: app.db,
                relayRealtimeAfterRecord: true
            ).consume(
                try ConversationEventEnvelope(
                    event: event,
                    payload: try event.decodedPayload(),
                    deliveryContext: nil
                )
            )

            #expect(try await OwnerDomainEventDelivery.query(on: app.imSummaryDB).count() == 0)
            #expect(await dispatchService.dispatches().isEmpty)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 1)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.domainRelayAfterRecordPreSplitFallbackCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutDroppedFallbackCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutDroppedFallbackRecipientCount == recipientUserIDs.count)
            #expect(metrics.realtimeActiveConversationFanoutUnsplitFallbackCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutHintFallbackRecipientCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 0)
        }
    }

    @Test("Domain relay-after-record pre-splits active messages and inactive hints")
    func domainRelayAfterRecordPreSplitsActiveMessagesAndInactiveHints() async throws {
        let values = [
            "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "1",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let compactActiveUserID = UUID()
            let inactiveUserID = UUID()
            let secondInactiveUserID = UUID()
            let recipientUserIDs = [senderID, compactActiveUserID, inactiveUserID, secondInactiveUserID]
            let conversation = Conversation(
                title: "Relay Pre Split",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_200),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            await presenceStore.setActiveConversationRoutes([
                conversationID: [
                    senderID: ["gateway-a"],
                    compactActiveUserID: ["gateway-a"]
                ]
            ])
            await presenceStore.setUserRoutes(
                Dictionary(uniqueKeysWithValues: recipientUserIDs.map { ($0, Set(["gateway-a"])) })
            )

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "relay-pre-split-message",
                content: .richText(.plain("relay pre split payload"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 1,
                payload: .messageCreated(
                    messageID: messageID,
                    recipientUserIDs: recipientUserIDs,
                    preview: ConversationMessageCreatedPreview(
                        senderUserID: senderID,
                        serverSequence: 1,
                        timelineSequence: 1,
                        previewText: "relay pre split payload",
                        createdAt: message.createdAt
                    )
                ),
                createdAt: Date(timeIntervalSince1970: 1_710_500_201)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await OwnerDomainEventDeliveryConsumer(
                app: app,
                sourceDB: app.db,
                relayRealtimeAfterRecord: true
            ).consume(envelope)

            #expect(try await OwnerDomainEventDelivery.query(on: app.imSummaryDB).count() == 0)

            let decodedPayloads = await dispatchService.dispatches().compactMap { dispatch in
                decodedDomainEventPayload(from: dispatch.envelope).map { payload in
                    (payload: payload, targetUserIDs: dispatch.envelope.targetUserIDs)
                }
            }
            let fullMessages = decodedPayloads.filter { $0.payload.eventType == .messageCreated }
            let inactiveHints = decodedPayloads.filter { $0.payload.eventType == .conversationActivityHint }
            #expect(fullMessages.count == 1)
            let activeRecipientSet = Set([senderID, compactActiveUserID])
            let fullActiveTargets = Set(fullMessages.flatMap(\.targetUserIDs))
            #expect(fullActiveTargets.count == 1)
            #expect(fullActiveTargets.isSubset(of: activeRecipientSet))
            #expect(inactiveHints.count == 2)
            #expect(inactiveHints.contains { Set($0.targetUserIDs) == activeRecipientSet.subtracting(fullActiveTargets) })
            #expect(inactiveHints.contains { Set($0.targetUserIDs) == [inactiveUserID, secondInactiveUserID] })

            let fullPayload = try #require(fullMessages.first?.payload)
            guard case .messageCreated(let activeMessage, _) = fullPayload.body else {
                Issue.record("Expected active relay to keep messageCreated payload.")
                return
            }
            #expect(activeMessage.id == messageID)
            #expect(activeMessage.content.previewText == "relay pre split payload")

            let hintPayload = try #require(inactiveHints.first { Set($0.targetUserIDs) == [inactiveUserID, secondInactiveUserID] }?.payload)
            guard case .conversationActivityHint(let hint) = hintPayload.body else {
                Issue.record("Expected inactive relay to use conversationActivityHint.")
                return
            }
            #expect(fullPayload.eventID == (try event.requireID()))
            #expect(hintPayload.eventID != (try event.requireID()))
            #expect(hintPayload.conversation == nil)
            #expect(hint.messageID == messageID)
            #expect(hint.previewText == "relay pre split payload")
            #expect(hintPayload.timelineNotice == nil)
            #expect(hintPayload.requiresTimelineNotice == false)
            #expect(hintPayload.ownerCursor == nil)
            #expect(hintPayload.ownerAggregateSequence == nil)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutActiveRecipientCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutCompactActiveRecipientCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 2)
            #expect(metrics.domainRelayAfterRecordPreSplitCount == 1)
            #expect(metrics.domainRelayAfterRecordPreSplitActiveRecipientCount == 1)
            #expect(metrics.domainRelayAfterRecordPreSplitCompactActiveRecipientCount == 1)
            #expect(metrics.domainRelayAfterRecordPreSplitInactiveHintRecipientCount == 2)
            #expect(metrics.domainRelayAfterRecordPreSplitDowngradedActiveRecipientCount == 1)
            #expect(metrics.domainRelayAfterRecordPreSplitFallbackCount == 0)
            #expect(metrics.domainRelayAfterRecordInactiveHintSuppressedRecipientCount == 0)
            #expect(metrics.domainRelayAfterRecordActiveRouteCacheHitCount == 0)
            #expect(metrics.domainRelayAfterRecordActiveRouteCacheMissCount == 1)
            #expect(metrics.domainRelayAfterRecordPreSplitMaxActiveRecipients == 1)
            #expect(metrics.domainRelayAfterRecordPreSplitMaxCompactActiveRecipients == 1)
            #expect(metrics.domainRelayAfterRecordPreSplitMaxInactiveHintRecipients == 2)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 1)
        }
    }

    @Test("Domain relay-after-record coalesces inactive hints across messageCreated runs")
    func domainRelayAfterRecordCoalescesInactiveHintsAcrossMessageCreatedRuns() async throws {
        let values = [
            "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "10",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let inactiveUserID = UUID()
            let secondInactiveUserID = UUID()
            let recipientUserIDs = [senderID, inactiveUserID, secondInactiveUserID]
            let conversation = Conversation(
                title: "Relay Run Coalesce",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_300),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            await presenceStore.setActiveConversationRoutes([
                conversationID: [
                    senderID: ["gateway-a"]
                ]
            ])
            await presenceStore.setUserRoutes(
                Dictionary(uniqueKeysWithValues: recipientUserIDs.map { ($0, Set(["gateway-a"])) })
            )

            var envelopes: [ConversationEventEnvelope] = []
            var messageIDs: [UUID] = []
            for sequence in 1...2 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "relay-run-coalesce-\(sequence)",
                    content: .richText(.plain("relay run coalesce \(sequence)"))
                )
                try await message.create(on: app.db)
                let messageID = try message.requireID()
                messageIDs.append(messageID)
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(
                        messageID: messageID,
                        recipientUserIDs: recipientUserIDs,
                        preview: ConversationMessageCreatedPreview(
                            senderUserID: senderID,
                            serverSequence: UInt64(sequence),
                            timelineSequence: UInt64(sequence),
                            previewText: "relay run coalesce \(sequence)",
                            createdAt: message.createdAt
                        )
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_710_500_300 + TimeInterval(sequence))
                )
                envelopes.append(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            try await OwnerDomainEventDeliveryConsumer(
                app: app,
                sourceDB: app.db,
                relayRealtimeAfterRecord: true
            ).consumeMessageCreatedRun(envelopes)

            #expect(try await OwnerDomainEventDelivery.query(on: app.imSummaryDB).count() == 0)

            let decodedPayloads = await dispatchService.dispatches().compactMap { dispatch in
                decodedDomainEventPayload(from: dispatch.envelope).map { payload in
                    (payload: payload, targetUserIDs: dispatch.envelope.targetUserIDs)
                }
            }
            let fullMessages = decodedPayloads.filter { $0.payload.eventType == .messageCreated }
            let inactiveHints = decodedPayloads.filter { $0.payload.eventType == .conversationActivityHint }
            #expect(fullMessages.count == 2)
            #expect(Set(fullMessages.flatMap(\.targetUserIDs)) == [senderID])
            #expect(Set(fullMessages.map(\.payload.aggregateSequence)) == [1, 2])
            #expect(inactiveHints.count == 1)
            #expect(Set(inactiveHints.first?.targetUserIDs ?? []) == [inactiveUserID, secondInactiveUserID])
            let hintPayload = try #require(inactiveHints.first?.payload)
            #expect(hintPayload.aggregateSequence == 2)
            #expect(hintPayload.eventID != envelopes[1].eventID)
            if case .conversationActivityHint(let hint) = hintPayload.body {
                #expect(hint.messageID == messageIDs[1])
                #expect(hint.previewText == "relay run coalesce 2")
            } else {
                Issue.record("Expected inactive relay to use conversationActivityHint.")
            }
            #expect(hintPayload.ownerCursor == nil)
            #expect(hintPayload.ownerAggregateSequence == nil)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.domainRelayAfterRecordPreSplitCount == 2)
            #expect(metrics.domainRelayAfterRecordPreSplitActiveRecipientCount == 2)
            #expect(metrics.domainRelayAfterRecordPreSplitInactiveHintRecipientCount == 4)
            #expect(metrics.domainRelayAfterRecordInactiveHintSuppressedRecipientCount == 2)
            #expect(metrics.domainRelayAfterRecordActiveRouteCacheHitCount == 1)
            #expect(metrics.domainRelayAfterRecordActiveRouteCacheMissCount == 1)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 1)
        }
    }

    @Test("Domain relay-after-record coalesces single-message inactive hints by conversation window")
    func domainRelayAfterRecordCoalescesSingleMessageInactiveHintsByConversationWindow() async throws {
        let values = [
            "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "1",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_PREVIEW_MAX_CHARS": "120",
            "IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS": "0",
            "IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS": "100",
            "IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED": "true"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let recipientUserIDs = [senderID, UUID(), UUID()]
            let conversation = Conversation(
                title: "Relay Single Coalesce",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_450),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            await presenceStore.setUserRoutes(
                Dictionary(uniqueKeysWithValues: recipientUserIDs.map { ($0, Set(["gateway-a"])) })
            )

            var envelopes: [ConversationEventEnvelope] = []
            var messageIDs: [UUID] = []
            for sequence in 1...2 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "relay-single-coalesce-\(sequence)",
                    content: .richText(.plain("relay single coalesce \(sequence)"))
                )
                try await message.create(on: app.db)
                let messageID = try message.requireID()
                messageIDs.append(messageID)
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(
                        messageID: messageID,
                        recipientUserIDs: recipientUserIDs,
                        preview: ConversationMessageCreatedPreview(
                            senderUserID: senderID,
                            serverSequence: UInt64(sequence),
                            timelineSequence: UInt64(sequence),
                            previewText: "relay single coalesce \(sequence)",
                            createdAt: message.createdAt
                        )
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_710_500_450 + TimeInterval(sequence))
                )
                envelopes.append(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            let consumer = OwnerDomainEventDeliveryConsumer(
                app: app,
                sourceDB: app.db,
                relayRealtimeAfterRecord: true
            )
            try await consumer.consume(envelopes[0])
            try await consumer.consume(envelopes[1])
            try await Task.sleep(nanoseconds: 200_000_000)

            #expect(try await OwnerDomainEventDelivery.query(on: app.imSummaryDB).count() == 0)

            let decodedPayloads = await dispatchService.dispatches().compactMap { dispatch in
                decodedDomainEventPayload(from: dispatch.envelope).map { payload in
                    (payload: payload, targetUserIDs: dispatch.envelope.targetUserIDs)
                }
            }
            #expect(decodedPayloads.filter { $0.payload.eventType == .messageCreated }.isEmpty)
            let inactiveHints = decodedPayloads.filter { $0.payload.eventType == .conversationActivityHint }
            #expect(inactiveHints.count == 1)
            let hintPayload = try #require(inactiveHints.first?.payload)
            #expect(Set(inactiveHints.first?.targetUserIDs ?? []) == Set(recipientUserIDs))
            #expect(hintPayload.aggregateSequence == 2)
            #expect(hintPayload.eventID != envelopes[1].eventID)
            if case .conversationActivityHint(let hint) = hintPayload.body {
                #expect(hint.messageID == messageIDs[1])
                #expect(hint.previewText == "relay single coalesce 2")
            } else {
                Issue.record("Expected domain relay-after-record coalescing to relay conversationActivityHint.")
            }
            #expect(hintPayload.ownerCursor == nil)
            #expect(hintPayload.ownerAggregateSequence == nil)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.domainRelayAfterRecordPreSplitCount == 2)
            #expect(metrics.domainRelayAfterRecordPreSplitActiveRecipientCount == 0)
            #expect(metrics.domainRelayAfterRecordPreSplitInactiveHintRecipientCount == recipientUserIDs.count * 2)
            #expect(metrics.domainRelayAfterRecordInactiveHintSuppressedRecipientCount == 0)
            #expect(metrics.realtimeCoalescedDispatchReplacementCount == 1)
            #expect(metrics.realtimeCoalescedDroppedPayloadBatchCount == 1)
            #expect(metrics.realtimeCoalescedDroppedRecipientDeliveryCount == recipientUserIDs.count)
            #expect(metrics.realtimeActiveConversationRouteCacheHitCount == 1)
            #expect(metrics.realtimeActiveConversationRouteCacheMissCount == 1)
            #expect(metrics.domainRelayAfterRecordActiveRouteCacheHitCount == 1)
            #expect(metrics.domainRelayAfterRecordActiveRouteCacheMissCount == 1)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 1)
        }
    }

    @Test("Realtime delivery consumer coalesces single-message inactive hints by conversation window")
    func realtimeDeliveryConsumerCoalescesSingleMessageInactiveHintsByConversationWindow() async throws {
        let values = [
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "1",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS": "100",
            "IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED": "true"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let recipientUserIDs = [senderID, UUID(), UUID()]
            let conversation = Conversation(
                title: "Consumer Single Coalesce",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_400),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            await presenceStore.setUserRoutes(
                Dictionary(uniqueKeysWithValues: recipientUserIDs.map { ($0, Set(["gateway-a"])) })
            )

            var envelopes: [ConversationEventEnvelope] = []
            var messageIDs: [UUID] = []
            for sequence in 1...2 {
                let messageID = UUID()
                messageIDs.append(messageID)
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(
                        messageID: messageID,
                        recipientUserIDs: recipientUserIDs,
                        preview: ConversationMessageCreatedPreview(
                            senderUserID: senderID,
                            serverSequence: UInt64(sequence),
                            timelineSequence: UInt64(sequence),
                            previewText: "single coalesce \(sequence)",
                            createdAt: Date(timeIntervalSince1970: 1_710_500_400 + TimeInterval(sequence))
                        )
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_710_500_400 + TimeInterval(sequence))
                )
                envelopes.append(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            let consumer = ConversationRealtimeDeliveryConsumer(app: app, sourceDB: app.db)
            try await consumer.consumeMessageCreatedRun([envelopes[0]])
            try await consumer.consumeMessageCreatedRun([envelopes[1]])
            try await Task.sleep(nanoseconds: 200_000_000)

            let decodedPayloads = await dispatchService.dispatches().compactMap { dispatch in
                decodedDomainEventPayload(from: dispatch.envelope).map { payload in
                    (payload: payload, targetUserIDs: dispatch.envelope.targetUserIDs)
                }
            }
            #expect(decodedPayloads.filter { $0.payload.eventType == .messageCreated }.isEmpty)
            let hints = decodedPayloads.filter { $0.payload.eventType == .conversationActivityHint }
            #expect(hints.count == 1)
            let hintPayload = try #require(hints.first?.payload)
            #expect(Set(hints.first?.targetUserIDs ?? []) == Set(recipientUserIDs))
            #expect(hintPayload.aggregateSequence == 2)
            #expect(hintPayload.eventID != envelopes[1].eventID)
            if case .conversationActivityHint(let hint) = hintPayload.body {
                #expect(hint.messageID == messageIDs[1])
                #expect(hint.previewText == "single coalesce 2")
            } else {
                Issue.record("Expected coalesced single-message fanout to relay conversationActivityHint.")
            }

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeCoalescedDispatchReplacementCount == 1)
            #expect(metrics.realtimeCoalescedDroppedPayloadBatchCount == 1)
            #expect(metrics.realtimeCoalescedDroppedRecipientDeliveryCount == recipientUserIDs.count)
            #expect(metrics.realtimeDeliveryConsumerInactiveHintRelayPayloadBatchCount == 2)
            #expect(metrics.realtimeDeliveryConsumerInactiveHintRelayRecipientCount == recipientUserIDs.count * 2)
            #expect(metrics.realtimeActiveConversationRouteCacheHitCount == 1)
            #expect(metrics.realtimeActiveConversationRouteCacheMissCount == 1)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 1)
        }
    }

    @Test("Realtime delivery active compact hints bypass inactive coalescing window")
    func realtimeDeliveryActiveCompactHintsBypassInactiveCoalescingWindow() async throws {
        let values = [
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "10",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_MODE": "compact-only",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS": "100",
            "IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS": "0",
            "IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED": "true"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let activeUserIDs = [senderID, UUID(), UUID()]
            let conversation = Conversation(
                title: "Active Compact Immediate",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_600),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            await presenceStore.setActiveConversationRoutes([
                conversationID: Dictionary(uniqueKeysWithValues: activeUserIDs.map { ($0, Set(["gateway-a"])) })
            ])
            await presenceStore.setUserRoutes(
                Dictionary(uniqueKeysWithValues: activeUserIDs.map { ($0, Set(["gateway-a"])) })
            )

            var envelopes: [ConversationEventEnvelope] = []
            var messageIDs: [UUID] = []
            for sequence in 1...2 {
                let messageID = UUID()
                messageIDs.append(messageID)
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(
                        messageID: messageID,
                        recipientUserIDs: activeUserIDs,
                        preview: ConversationMessageCreatedPreview(
                            senderUserID: senderID,
                            serverSequence: UInt64(sequence),
                            timelineSequence: UInt64(sequence),
                            previewText: "active compact immediate \(sequence)",
                            createdAt: Date(timeIntervalSince1970: 1_710_500_600 + TimeInterval(sequence))
                        )
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_710_500_600 + TimeInterval(sequence))
                )
                envelopes.append(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            let consumer = ConversationRealtimeDeliveryConsumer(app: app, sourceDB: app.db)
            try await consumer.consumeMessageCreatedRun([envelopes[0]])
            try await consumer.consumeMessageCreatedRun([envelopes[1]])
            try await Task.sleep(nanoseconds: 50_000_000)

            let decodedPayloads = await dispatchService.dispatches().compactMap { dispatch in
                decodedDomainEventPayload(from: dispatch.envelope).map { payload in
                    (payload: payload, targetUserIDs: dispatch.envelope.targetUserIDs)
                }
            }
            let hints = decodedPayloads.filter { $0.payload.eventType == .timelineGapHint }
            #expect(hints.count == 2)
            #expect(hints.allSatisfy { Set($0.targetUserIDs) == Set(activeUserIDs) })
            #expect(Set(hints.map(\.payload.aggregateSequence)) == [1, 2])
            #expect(Set(hints.map(\.payload.eventID)) == Set(envelopes.compactMap(\.eventID).map(imLightweightMessageCreatedHintEventID)))
            let hintMessageIDs = hints.compactMap { entry -> UUID? in
                guard case .timelineGapHint(let hint) = entry.payload.body else {
                    return nil
                }
                return hint.messageID
            }
            #expect(Set(hintMessageIDs) == Set(messageIDs))

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeCoalescedDispatchReplacementCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutCompactActiveRecipientCount == activeUserIDs.count * 2)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == 0)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 1)
        }
    }

    @Test("Realtime delivery consumer sends only lightweight hints when no large-group recipients are active")
    func realtimeDeliveryConsumerSendsOnlyLightweightHintsWhenNoLargeGroupRecipientsAreActive() async throws {
        let values = [
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
            "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT": "1",
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS": "0"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let presenceStore = FakePresenceStore()
            let dispatchService = FakeNodeMessageDispatchService()
            app.connectionRoutingService = ConnectionRoutingService(
                app: app,
                backend: FakeConnectionRoutingBackend(
                    presenceStore: presenceStore,
                    dispatchService: dispatchService
                )
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let recipientUserIDs = [senderID, UUID(), UUID()]
            let conversation = Conversation(
                title: "Consumer Hint Only",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_500_100),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            await presenceStore.setUserRoutes(
                Dictionary(uniqueKeysWithValues: recipientUserIDs.map { ($0, Set(["gateway-a"])) })
            )

            let messageID = UUID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 1,
                payload: .messageCreated(
                    messageID: messageID,
                    recipientUserIDs: recipientUserIDs,
                    preview: ConversationMessageCreatedPreview(
                        senderUserID: senderID,
                        serverSequence: 1,
                        timelineSequence: 1,
                        previewText: "hint only payload",
                        createdAt: Date(timeIntervalSince1970: 1_710_500_101)
                    )
                ),
                createdAt: Date(timeIntervalSince1970: 1_710_500_101)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await ConversationRealtimeDeliveryConsumer(app: app, sourceDB: app.db)
                .consumeMessageCreatedRun([envelope])

            let decodedPayloads = await dispatchService.dispatches().compactMap { dispatch in
                decodedDomainEventPayload(from: dispatch.envelope).map { payload in
                    (payload: payload, targetUserIDs: dispatch.envelope.targetUserIDs)
                }
            }
            #expect(decodedPayloads.filter { $0.payload.eventType == .messageCreated }.isEmpty)
            let hints = decodedPayloads.filter { $0.payload.eventType == .conversationActivityHint }
            #expect(hints.count == 1)
            #expect(Set(hints.first?.targetUserIDs ?? []) == Set(recipientUserIDs))
            let hintPayload = try #require(hints.first?.payload)
            guard case .conversationActivityHint(let hint) = hintPayload.body else {
                Issue.record("Expected hint-only fanout to relay conversationActivityHint.")
                return
            }
            #expect(hintPayload.eventID != event.id)
            #expect(hintPayload.conversation == nil)
            #expect(hint.messageID == messageID)
            #expect(hint.previewText == "hint only payload")
            #expect(hintPayload.timelineNotice == nil)
            #expect(hintPayload.requiresTimelineNotice == false)
            #expect(hintPayload.ownerCursor == nil)
            #expect(hintPayload.ownerAggregateSequence == nil)

            let metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimeActiveConversationFanoutSplitCount == 1)
            #expect(metrics.realtimeActiveConversationFanoutActiveRecipientCount == 0)
            #expect(metrics.realtimeActiveConversationFanoutInactiveHintRecipientCount == recipientUserIDs.count)
            #expect(metrics.realtimeDeliveryConsumerInactiveHintRelayPayloadBatchCount == 1)
            #expect(metrics.realtimeDeliveryConsumerInactiveHintRelayRecipientCount == recipientUserIDs.count)
            #expect(await presenceStore.activeConversationRouteLookupTotal() == 1)
        }
    }
}

private func decodedDomainEventPayload(from envelope: NodeMessageDispatchEnvelope) -> IMTCPChatDomainEventPayload? {
    let packetBase64: String
    switch envelope.payload {
    case .domainEventPacket(let encoded, _, _),
         .activeConversationDomainEventPacket(let encoded, _, _, _):
        packetBase64 = encoded
    case .domainEvent,
         .streamSignal,
         .kickSession,
         .kickUser:
        return nil
    }
    guard let packetData = Data(base64Encoded: packetBase64),
          let packet = try? IMTCPProtobufCodec.decode(packetData)
    else {
        return nil
    }
    return try? packet.payload.decodePayload(IMTCPChatDomainEventPayload.self)
}

private struct FakeConnectionRoutingBackend: ConnectionRoutingBackend {
    let backendName = "fake"
    let presenceStore: any PresenceStore
    let dispatchService: any NodeMessageDispatchService

    func start(app: Application) async throws {}
    func shutdown() async {}
}

private struct IMTCPTestServer: Sendable {
    let channel: any Channel
    let port: Int

    func close() async {
        try? await channel.close().get()
    }
}

private func startTestIMTCPServer(app: Application) async throws -> IMTCPTestServer {
    let configuration = app.imTCPConfiguration
    let channel = try await ServerBootstrap(group: app.eventLoopGroup)
        .serverChannelOption(ChannelOptions.backlog, value: 16)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.addHandler(
                IdleStateHandler(
                    readTimeout: .milliseconds(Int64(configuration.idleTimeout * 1000))
                )
            )
            .flatMap {
                channel.pipeline.addHandler(
                ByteToMessageHandler(
                    IMTCPFrameDecoder(maxFrameBytes: configuration.maxFrameBytes)
                )
                )
            }
            .flatMap {
                channel.pipeline.addHandler(IMTCPConnectionHandler(application: app))
            }
        }
        .bind(host: configuration.host, port: configuration.port)
        .get()

    guard let port = channel.localAddress?.port else {
        throw IMTCPTestFailure.missingBoundPort
    }
    return IMTCPTestServer(channel: channel, port: port)
}

private func withTestIMTCPServer<T>(
    app: Application,
    _ body: (IMTCPTestServer) async throws -> T
) async throws -> T {
    let server = try await startTestIMTCPServer(app: app)
    do {
        let result = try await body(server)
        await server.close()
        return result
    } catch {
        await server.close()
        throw error
    }
}

private func withIMTCPTestClient<T>(
    port: Int,
    eventLoopGroup: any EventLoopGroup,
    _ body: (IMTCPTestClient) async throws -> T
) async throws -> T {
    let client = try await IMTCPTestClient.connect(port: port, eventLoopGroup: eventLoopGroup)
    do {
        let result = try await body(client)
        await client.close()
        return result
    } catch {
        await client.close()
        throw error
    }
}

private func withIMTCPTestClients<T>(
    port: Int,
    eventLoopGroup: any EventLoopGroup,
    _ body: (IMTCPTestClient, IMTCPTestClient) async throws -> T
) async throws -> T {
    let first = try await IMTCPTestClient.connect(port: port, eventLoopGroup: eventLoopGroup)
    do {
        let second = try await IMTCPTestClient.connect(port: port, eventLoopGroup: eventLoopGroup)
        do {
            let result = try await body(first, second)
            await second.close()
            await first.close()
            return result
        } catch {
            await second.close()
            throw error
        }
    } catch {
        await first.close()
        throw error
    }
}

private func waitUntilTCPConnectionCount(
    app: Application,
    sessionID: UUID,
    expectedCount: Int
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        let count = await app.imConnectionRegistry.activeConnectionCounts(forSessionIDs: [sessionID])[sessionID] ?? 0
        if count == expectedCount {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw IMTCPTestFailure.sessionCountTimeout
}

private func waitUntilLocalFanoutEventLoopJobStarted(
    app: Application,
    minimumStartedCount: Int
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        let metrics = await app.routingMetrics.currentSnapshot()
        if metrics.localFanoutEventLoopJobStartedCount >= minimumStartedCount {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for local fanout event loop job start metrics.")
}

private struct IMTCPTestClient: Sendable {
    let channel: any Channel
    let inbox: IMTCPTestInbox

    static func connect(port: Int, eventLoopGroup: any EventLoopGroup) async throws -> IMTCPTestClient {
        let inbox = IMTCPTestInbox()
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    ByteToMessageHandler(
                        IMTCPFrameDecoder(maxFrameBytes: 64 * 1024)
                    )
                )
                .flatMap {
                    channel.pipeline.addHandler(IMTCPTestClientHandler(inbox: inbox))
                }
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        return IMTCPTestClient(channel: channel, inbox: inbox)
    }

    func authenticate(accessToken: String, deviceID: String) async throws {
        try await send(
            type: .auth,
            requestID: UUID(),
            payload: IMTCPAuthRequestPayload(
                accessToken: accessToken,
                deviceID: deviceID,
                deviceName: "Test \(deviceID)",
                platform: "ios",
                appVersion: "1.0"
            )
        )
        _ = try await nextPacket(ofType: .authOK)
    }

    func send<Payload: Sendable>(
        type: IMTCPPacketType,
        requestID: UUID? = nil,
        payload: Payload
    ) async throws {
        let data = try IMTCPProtobufCodec.encode(type: type, requestID: requestID, payload: payload)
        var buffer = channel.allocator.buffer(capacity: data.count + 4)
        buffer.writeInteger(UInt32(data.count), endianness: .big)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }

    func nextPacket(ofType type: IMTCPPacketType) async throws -> IMTCPInboundPacket {
        try await inbox.nextPacket(ofType: type)
    }

    func close() async {
        try? await channel.close().get()
    }
}

private final class IMTCPTestClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Data

    private let inbox: IMTCPTestInbox

    init(inbox: IMTCPTestInbox) {
        self.inbox = inbox
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard let packet = try? IMTCPProtobufCodec.decode(frame) else {
            return
        }

        Task {
            await inbox.append(packet)
        }
    }
}

private func readDomainEventPayload(from channel: EmbeddedChannel) throws -> IMTCPChatDomainEventPayload {
    guard var frame = try channel.readOutbound(as: ByteBuffer.self) else {
        throw Abort(.internalServerError, reason: "Expected outbound TCP frame.")
    }
    guard let length: UInt32 = frame.readInteger(endianness: .big),
          let bytes = frame.readBytes(length: Int(length))
    else {
        throw Abort(.internalServerError, reason: "Outbound TCP frame is incomplete.")
    }
    let packet = try IMTCPProtobufCodec.decode(Data(bytes))
    guard packet.type == .domainEvent else {
        throw Abort(.internalServerError, reason: "Expected outbound domain-event packet.")
    }
    return try packet.payload.decodePayload(IMTCPChatDomainEventPayload.self)
}

private func readAllDomainEventPayloads(from channel: EmbeddedChannel) throws -> [IMTCPChatDomainEventPayload] {
    var payloads: [IMTCPChatDomainEventPayload] = []
    while let payload = try readOptionalDomainEventPayload(from: channel) {
        payloads.append(payload)
    }
    return payloads
}

private func readOptionalDomainEventPayload(from channel: EmbeddedChannel) throws -> IMTCPChatDomainEventPayload? {
    guard var frame = try channel.readOutbound(as: ByteBuffer.self) else {
        return nil
    }
    guard let length: UInt32 = frame.readInteger(endianness: .big),
          let bytes = frame.readBytes(length: Int(length))
    else {
        throw Abort(.internalServerError, reason: "Outbound TCP frame is incomplete.")
    }
    let packet = try IMTCPProtobufCodec.decode(Data(bytes))
    guard packet.type == .domainEvent else {
        throw Abort(.internalServerError, reason: "Expected outbound domain-event packet.")
    }
    return try packet.payload.decodePayload(IMTCPChatDomainEventPayload.self)
}

private func readDomainEventPayload(from envelope: NodeMessageDispatchEnvelope) throws -> IMTCPChatDomainEventPayload {
    let packetBase64: String
    switch envelope.payload {
    case .domainEventPacket(let encoded, _, _),
         .activeConversationDomainEventPacket(let encoded, _, _, _):
        packetBase64 = encoded
    default:
        throw Abort(.internalServerError, reason: "Expected domain-event packet envelope.")
    }
    guard let packetData = Data(base64Encoded: packetBase64) else {
        throw Abort(.internalServerError, reason: "Expected valid domain-event packet envelope.")
    }
    let packet = try IMTCPProtobufCodec.decode(packetData)
    guard packet.type == .domainEvent else {
        throw Abort(.internalServerError, reason: "Expected domain-event packet payload.")
    }
    return try packet.payload.decodePayload(IMTCPChatDomainEventPayload.self)
}

private actor IMTCPTestInbox {
    private var packets: [IMTCPInboundPacket] = []

    func append(_ packet: IMTCPInboundPacket) {
        packets.append(packet)
    }

    func nextPacket(ofType type: IMTCPPacketType) async throws -> IMTCPInboundPacket {
        let timeout: UInt64 = 2_000_000_000
        let pollInterval: UInt64 = 10_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout

        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let index = packets.firstIndex(where: { $0.type == type }) {
                return packets.remove(at: index)
            }
            try await Task.sleep(nanoseconds: pollInterval)
        }

        throw IMTCPTestFailure.packetTimeout(type)
    }
}

private enum IMTCPTestFailure: Error {
    case missingBoundPort
    case packetTimeout(IMTCPPacketType)
    case sessionCountTimeout
}

private func imTestDomainEventPayload(
    eventID: UUID,
    conversationID: UUID,
    senderUserID: UUID,
    sequence: UInt64,
    text: String,
    content: IMMessageContent? = nil,
    derivedState: IMMessageDerivedState = IMMessageDerivedState()
) -> IMTCPChatDomainEventPayload {
    IMTCPChatDomainEventPayload(
        eventID: eventID,
        eventType: .messageCreated,
        aggregateType: "conversation",
        aggregateID: conversationID,
        aggregateSequence: sequence,
        occurredAt: Date(),
        actorUserID: senderUserID,
        conversation: nil,
        ownerCursor: nil,
        ownerAggregateSequence: nil,
        body: .messageCreated(
            message: IMMessageResponse(
                id: UUID(),
                conversationID: conversationID,
                senderUserID: senderUserID,
                clientMessageID: "coalesced-\(sequence)",
                serverSequence: sequence,
                timelineSequence: sequence,
                content: content ?? .richText(.plain(text)),
                derivedState: derivedState,
                createdAt: Date()
            ),
            clientMessageID: "coalesced-\(sequence)"
        )
    )
}

private func imTestConversationActivityHintPayload(
    eventID: UUID,
    conversationID: UUID,
    senderUserID: UUID,
    sequence: UInt64,
    previewText: String
) -> IMTCPChatDomainEventPayload {
    let occurredAt = Date()
    return IMTCPChatDomainEventPayload(
        eventID: eventID,
        eventType: .conversationActivityHint,
        aggregateType: "conversation",
        aggregateID: conversationID,
        aggregateSequence: sequence,
        occurredAt: occurredAt,
        actorUserID: senderUserID,
        conversation: nil,
        timelineNotice: nil,
        requiresTimelineNotice: false,
        ownerCursor: nil,
        ownerAggregateSequence: nil,
        body: .conversationActivityHint(
            IMConversationActivityHint(
                messageID: UUID(),
                senderUserID: senderUserID,
                serverSequence: sequence,
                timelineSequence: sequence,
                previewText: previewText,
                messageCreatedAt: occurredAt,
                updatedAt: occurredAt
            )
        )
    )
}

private func imTestTimelineGapHintPayload(
    eventID: UUID,
    conversationID: UUID,
    senderUserID: UUID,
    sequence: UInt64
) -> IMTCPChatDomainEventPayload {
    let occurredAt = Date()
    return IMTCPChatDomainEventPayload(
        eventID: eventID,
        eventType: .timelineGapHint,
        aggregateType: "conversation",
        aggregateID: conversationID,
        aggregateSequence: sequence,
        occurredAt: occurredAt,
        actorUserID: senderUserID,
        conversation: nil,
        timelineNotice: nil,
        requiresTimelineNotice: false,
        ownerCursor: nil,
        ownerAggregateSequence: nil,
        body: .timelineGapHint(
            IMTimelineGapHint(
                messageID: UUID(),
                senderUserID: senderUserID,
                serverSequence: sequence,
                timelineSequence: sequence,
                updatedAt: occurredAt
            )
        )
    )
}

private actor BlockingRealtimeRelayProbe {
    private var relayCallCount = 0
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func relay(
        _ batches: [ConversationRealtimeConsumer.DomainEventPayloadBatch],
        requestID: UUID?
    ) async {
        _ = batches
        _ = requestID
        relayCallCount += 1
        let continuations = startedContinuations
        startedContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }

        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard relayCallCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func callCount() -> Int {
        relayCallCount
    }
}

private actor RecordingRealtimeRelayProbe {
    private var relayedBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch] = []

    func relay(
        _ batches: [ConversationRealtimeConsumer.DomainEventPayloadBatch],
        requestID: UUID?
    ) {
        _ = requestID
        relayedBatches.append(contentsOf: batches)
    }

    func callCount() -> Int {
        relayedBatches.count
    }

    func fanoutIntents() -> Set<IMGatewayDomainEventFanoutIntent> {
        Set(relayedBatches.map(\.fanoutIntent))
    }

    func timelineGapHintSequenceByRecipient() -> [UUID: UInt64] {
        var result: [UUID: UInt64] = [:]
        for batch in relayedBatches {
            guard case .timelineGapHint(let hint) = batch.payload.body else {
                continue
            }
            for recipientUserID in batch.recipientUserIDs {
                result[recipientUserID] = hint.serverSequence
            }
        }
        return result
    }
}

private actor FakePresenceStore: PresenceStore {
    nonisolated let backendName = "fake-presence"

    private var userRoutes: [UUID: Set<String>] = [:]
    private var sessionRoutes: [UUID: Set<String>] = [:]
    private var activeConversationRoutes: [UUID: [UUID: Set<String>]] = [:]
    private var activeConversationActivations: [(conversationID: UUID, userID: UUID)] = []
    private var activeConversationDeactivations: [(conversationID: UUID, userID: UUID)] = []
    private var activeConversationRouteLookupCount = 0
    private var activeConversationRouteLookupRequestedUserCounts: [Int] = []
    private var activeConversationSnapshotRouteLookupCount = 0
    private var userRouteLookupCount = 0
    private var sessionRouteLookupCount = 0
    private var failsActiveConversationRouteLookups = false

    func setUserRoutes(_ routes: [UUID: Set<String>]) {
        userRoutes = routes
    }

    func setSessionRoutes(_ routes: [UUID: Set<String>]) {
        sessionRoutes = routes
    }

    func setActiveConversationRoutes(_ routes: [UUID: [UUID: Set<String>]]) {
        activeConversationRoutes = routes
    }

    func setFailsActiveConversationRouteLookups(_ shouldFail: Bool) {
        failsActiveConversationRouteLookups = shouldFail
    }

    func activeConversationActivationCount(conversationID: UUID, userID: UUID) -> Int {
        activeConversationActivations.filter { $0.conversationID == conversationID && $0.userID == userID }.count
    }

    func activeConversationDeactivationCount(conversationID: UUID, userID: UUID) -> Int {
        activeConversationDeactivations.filter { $0.conversationID == conversationID && $0.userID == userID }.count
    }

    func userRouteLookupTotal() -> Int {
        userRouteLookupCount
    }

    func activeConversationRouteLookupTotal() -> Int {
        activeConversationRouteLookupCount
    }

    func activeConversationRouteLookupRequestedCounts() -> [Int] {
        activeConversationRouteLookupRequestedUserCounts
    }

    func activeConversationSnapshotRouteLookupTotal() -> Int {
        activeConversationSnapshotRouteLookupCount
    }

    func start(app: Application) async throws {}
    func shutdown() async {}
    func activatePresence(forUserID userID: UUID) async throws {}
    func deactivatePresence(forUserID userID: UUID) async throws {}
    func activatePresence(forSessionID sessionID: UUID, userID: UUID) async throws {}
    func deactivatePresence(forSessionID sessionID: UUID, userID: UUID) async throws {}
    func activateConversationPresence(conversationID: UUID, userID: UUID) async throws {
        activeConversationActivations.append((conversationID: conversationID, userID: userID))
    }

    func deactivateConversationPresence(conversationID: UUID, userID: UUID) async throws {
        activeConversationDeactivations.append((conversationID: conversationID, userID: userID))
    }

    func routeNodeIDs(
        forActiveConversationID conversationID: UUID,
        amongUserIDs userIDs: [UUID]
    ) async throws -> [UUID: Set<String>] {
        activeConversationRouteLookupCount += 1
        activeConversationRouteLookupRequestedUserCounts.append(userIDs.count)
        if failsActiveConversationRouteLookups {
            throw FakePresenceStoreError.activeConversationRouteLookupFailed
        }
        return Dictionary(uniqueKeysWithValues: userIDs.map {
            ($0, activeConversationRoutes[conversationID]?[$0] ?? [])
        })
    }

    func routeNodeIDs(forActiveConversationID conversationID: UUID) async throws -> [UUID: Set<String>] {
        activeConversationSnapshotRouteLookupCount += 1
        if failsActiveConversationRouteLookups {
            throw FakePresenceStoreError.activeConversationRouteLookupFailed
        }
        return activeConversationRoutes[conversationID] ?? [:]
    }

    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>] {
        userRouteLookupCount += 1
        return Dictionary(uniqueKeysWithValues: userIDs.map { ($0, userRoutes[$0] ?? []) })
    }

    func routeNodeIDs(forSessionIDs sessionIDs: [UUID]) async throws -> [UUID: Set<String>] {
        sessionRouteLookupCount += 1
        return Dictionary(uniqueKeysWithValues: sessionIDs.map { ($0, sessionRoutes[$0] ?? []) })
    }

    func activeNodeIDs() async throws -> Set<String> {
        Set(userRoutes.values.flatMap { $0 })
            .union(sessionRoutes.values.flatMap { $0 })
            .union(activeConversationRoutes.values.flatMap { $0.values }.flatMap { $0 })
    }
}

private enum FakePresenceStoreError: Error {
    case activeConversationRouteLookupFailed
}

private actor FakeNodeMessageDispatchService: NodeMessageDispatchService {
    struct Dispatch: Sendable {
        let envelope: NodeMessageDispatchEnvelope
        let nodeID: String
    }

    private var recordedDispatches: [Dispatch] = []

    func start(app: Application) async throws {}
    func shutdown() async {}

    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws {
        recordedDispatches.append(Dispatch(envelope: envelope, nodeID: nodeID))
    }

    func dispatches() -> [Dispatch] {
        recordedDispatches
    }
}
