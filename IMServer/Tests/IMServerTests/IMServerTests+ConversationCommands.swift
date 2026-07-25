@testable import IMServer
import Fluent
import NIOCore
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("Cross-Cell migration permits the same local shard name in different Cells")
    func crossCellMigrationAllowsSameShardName() throws {
        let sourceRoute = ConversationRoute(cellID: "cell-a", shardID: "shard-0", version: 1)
        try ConversationShardMigrationPreflight.validateTarget(
            sourceRoute: sourceRoute,
            targetCellID: "cell-b",
            targetShardID: "shard-0"
        )
        do {
            try ConversationShardMigrationPreflight.validateTarget(
                sourceRoute: sourceRoute,
                targetCellID: "cell-a",
                targetShardID: "shard-0"
            )
            Issue.record("A same-Cell migration accepted its source shard as the target.")
        } catch let error as Abort {
            #expect(error.status == .badRequest)
        }
    }

    @Test("Remote Cell migration target preflight requires ingress credentials and exposes only the target snapshot")
    func remoteCellMigrationTargetPreflight() async throws {
        try await withApp(configure: configure) { app in
            app.imRealtimeCellConfiguration = IMRealtimeCellConfiguration(cellID: "cell-b")
            app.cellIngressConfiguration = IMCellIngressConfiguration(
                endpointsByCellID: ["cell-b": "https://cell-b.internal"],
                sharedSecret: "migration-preflight-secret"
            )
            let body = IMCellShardMigrationTargetPreflightRequest(
                conversationID: UUID(),
                originCellID: "cell-a",
                targetCellID: "cell-b",
                targetShardID: SingleShardConversationShardRouter.defaultShardID
            )

            try await app.testing().test(
                .POST,
                "internal/im/migrations/target-preflight",
                beforeRequest: { httpRequest in
                    try httpRequest.content.encode(body)
                },
                afterResponse: { response async in
                    #expect(response.status == .unauthorized)
                }
            )

            try await app.testing().test(
                .POST,
                "internal/im/migrations/target-preflight",
                beforeRequest: { httpRequest in
                    httpRequest.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: "migration-preflight-secret")
                    try httpRequest.content.encode(body)
                },
                afterResponse: { response async throws in
                    #expect(response.status == .ok)
                    let snapshot = try response.content.decode(ConversationShardMigrationPreflight.CanonicalDataSnapshot.self)
                    #expect(snapshot.isEmpty)
                }
            )
        }
    }

    @Test("Remote Cell migration transfer imports a checksummed page idempotently")
    func remoteCellMigrationTransferPage() async throws {
        try await withApp(configure: configure) { app in
            app.imRealtimeCellConfiguration = IMRealtimeCellConfiguration(cellID: "cell-b")
            app.cellIngressConfiguration = IMCellIngressConfiguration(
                endpointsByCellID: ["cell-b": "https://cell-b.internal"],
                sharedSecret: "migration-transfer-secret"
            )
            let conversation = Conversation(id: UUID(), title: "Transferred", kind: .group)
            let migration = ConversationShardMigration(
                conversationID: try conversation.requireID(),
                sourceRoute: ConversationRoute(cellID: "cell-a", shardID: "source-shard", version: 7),
                targetCellID: "cell-b",
                targetShardID: SingleShardConversationShardRouter.defaultShardID,
                source: .init(
                    conversationCount: 1,
                    memberCount: 0,
                    messageCount: 0,
                    domainEventCount: 0,
                    domainEventSequenceCount: 0,
                    timelineNoticeCount: 0,
                    mediaReferenceCount: 0,
                    recipientSnapshotCount: 0
                ),
                transferToken: "migration-transfer-token"
            )
            migration.statusEnum = .copying
            try await migration.create(on: app.db)
            let records = [try JSONEncoder().encode(conversation)]
            let batch = IMCellConversationMigrationTransferBatch(
                conversationID: try conversation.requireID(),
                originCellID: "cell-a",
                targetCellID: "cell-b",
                targetShardID: SingleShardConversationShardRouter.defaultShardID,
                sourceRouteVersion: 7,
                transferToken: "migration-transfer-token",
                kind: .conversation,
                records: records,
                checksum: IMCellConversationMigrationTransferBatch.checksum(for: records)
            )

            let invalidCapabilityBatch = IMCellConversationMigrationTransferBatch(
                conversationID: try conversation.requireID(),
                originCellID: "cell-a",
                targetCellID: "cell-b",
                targetShardID: SingleShardConversationShardRouter.defaultShardID,
                sourceRouteVersion: 7,
                transferToken: "wrong-migration-transfer-token",
                kind: .conversation,
                records: records,
                checksum: IMCellConversationMigrationTransferBatch.checksum(for: records)
            )
            try await app.testing().test(
                .POST,
                "internal/im/migrations/transfer-page",
                beforeRequest: { request in
                    request.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: "migration-transfer-secret")
                    try request.content.encode(invalidCapabilityBatch)
                },
                afterResponse: { response async in
                    #expect(response.status == .conflict)
                }
            )

            try await app.testing().test(
                .POST,
                "internal/im/migrations/transfer-page",
                beforeRequest: { request in
                    request.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: "migration-transfer-secret")
                    try request.content.encode(batch)
                },
                afterResponse: { response async throws in
                    #expect(response.status == .ok)
                    let result = try response.content.decode(IMCellConversationMigrationTransferResponse.self)
                    #expect(result.importedCount == 1)
                    #expect(result.alreadyPresentCount == 0)
                }
            )
            try await app.testing().test(
                .POST,
                "internal/im/migrations/transfer-page",
                beforeRequest: { request in
                    request.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: "migration-transfer-secret")
                    try request.content.encode(batch)
                },
                afterResponse: { response async throws in
                    #expect(response.status == .ok)
                    let result = try response.content.decode(IMCellConversationMigrationTransferResponse.self)
                    #expect(result.importedCount == 0)
                    #expect(result.alreadyPresentCount == 1)
                }
            )

            migration.statusEnum = .verifying
            try await migration.update(on: app.db)
            let verificationRequest = IMCellConversationMigrationVerificationRequest(
                conversationID: try conversation.requireID(),
                originCellID: "cell-a",
                targetCellID: "cell-b",
                targetShardID: SingleShardConversationShardRouter.defaultShardID,
                sourceRouteVersion: 7,
                transferToken: "migration-transfer-token",
                pageSize: 100
            )
            try await app.testing().test(
                .POST,
                "internal/im/migrations/target-verification",
                beforeRequest: { request in
                    request.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: "migration-transfer-secret")
                    try request.content.encode(verificationRequest)
                },
                afterResponse: { response async throws in
                    #expect(response.status == .ok)
                    let result = try response.content.decode(IMCellConversationMigrationVerificationResponse.self)
                    #expect(result.snapshot.conversationCount == 1)
                    #expect(result.fingerprint.count == 64)
                    #expect(result.sideEffectCount == 0)
                }
            )

            migration.statusEnum = .cutoverPreparing
            migration.cutoverLeaseToken = "remote-finalize-lease"
            migration.cutoverLeaseExpiresAt = Date().addingTimeInterval(60)
            try await migration.update(on: app.db)
            let finalizeRequest = IMCellConversationMigrationFinalizeRequest(
                conversationID: try conversation.requireID(),
                originCellID: "cell-a",
                targetCellID: "cell-b",
                targetShardID: SingleShardConversationShardRouter.defaultShardID,
                sourceRouteVersion: 7,
                transferToken: "migration-transfer-token",
                cutoverLeaseToken: "remote-finalize-lease",
                pageSize: 100
            )
            try await app.testing().test(
                .POST,
                "internal/im/migrations/target-finalize",
                beforeRequest: { request in
                    request.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: "migration-transfer-secret")
                    try request.content.encode(finalizeRequest)
                },
                afterResponse: { response async in
                    #expect(response.status == .noContent)
                }
            )
        }
    }

    @Test("Remote Cell ingress revalidates credential and route version before serving a conversation request")
    func remoteCellIngressRevalidatesCredentialAndRouteVersion() async throws {
        try await withApp(configure: configure) { app in
            app.imRealtimeCellConfiguration = IMRealtimeCellConfiguration(cellID: "cell-b")
            app.cellIngressConfiguration = IMCellIngressConfiguration(
                endpointsByCellID: ["cell-b": "https://cell-b.internal"],
                sharedSecret: "cell-ingress-test-secret"
            )
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "cell-ingress-peer@example.com", on: app)
            let result = try await IMConversationService.command(app: app).createConversation(
                kind: IMConversationKind.direct.rawValue,
                title: nil,
                memberEmails: [peerUser.email],
                creatorUserID: try demoUser.requireID()
            )
            let conversationID = result.receipt.conversationID
            let route = try await app.conversationDirectory.route(for: conversationID)
            #expect(route.cellID == "cell-b")

            func configureForwardedHeaders(_ request: inout TestingHTTPRequest, routeVersion: Int, secret: String) {
                request.headers.bearerAuthorization = .init(token: accessToken)
                request.headers.replaceOrAdd(name: "X-IM-Cell-Forwarded-By", value: "cell-a")
                request.headers.replaceOrAdd(name: "X-IM-Cell-Forward-Target", value: "cell-b")
                request.headers.replaceOrAdd(name: "X-IM-Cell-Forward-Hop", value: "1")
                request.headers.replaceOrAdd(name: "X-IM-Conversation-Route-Version", value: String(routeVersion))
                request.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: secret)
            }

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline"
            ) { request in
                configureForwardedHeaders(&request, routeVersion: route.version, secret: "cell-ingress-test-secret")
            } afterResponse: { response async in
                #expect(response.status == .ok)
            }

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline"
            ) { request in
                configureForwardedHeaders(&request, routeVersion: route.version - 1, secret: "cell-ingress-test-secret")
            } afterResponse: { response async in
                #expect(response.status == .conflict)
            }

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline"
            ) { request in
                configureForwardedHeaders(&request, routeVersion: route.version, secret: "wrong-secret")
            } afterResponse: { response async in
                #expect(response.status == .unauthorized)
            }
        }
    }

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
            #expect(directoryEntry?.lifecycleState == .active)
            #expect(directoryEntry?.routeVersion == 1)

            let pairHash = [try demoUser.requireID(), try peerUser.requireID()]
                .map(\.uuidString)
                .sorted()
                .joined(separator: ":")
            let directIndexEntry = try await DirectConversationIndexEntry.find(pairHash, on: app.db)
            #expect(directIndexEntry?.conversationID == conversationID)
        }
    }

    @Test("Direct conversation index atomically reserves one winning conversation per pair")
    func directConversationIndexReservationPreventsDuplicateCreation() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let peer = try await makeUser(email: "direct-reservation-peer@example.com", on: app)
            let memberUserIDs = [try owner.requireID(), try peer.requireID()]
            let firstConversationID = UUID()
            let secondConversationID = UUID()

            let first = try await app.directConversationIndex.reserveDirectConversation(
                conversationID: firstConversationID,
                memberUserIDs: memberUserIDs,
                shardID: SingleShardConversationShardRouter.defaultShardID
            )
            #expect(first == .reserved)

            let second = try await app.directConversationIndex.reserveDirectConversation(
                conversationID: secondConversationID,
                memberUserIDs: Array(memberUserIDs.reversed()),
                shardID: SingleShardConversationShardRouter.defaultShardID
            )
            #expect(second == .existing(conversationID: firstConversationID))

            do {
                _ = try await ConversationCommandService(app: app).createConversation(
                    kind: IMConversationKind.direct.rawValue,
                    title: nil,
                    memberEmails: [peer.email],
                    creatorUserID: try owner.requireID()
                )
                Issue.record("A direct-pair reservation without an active conversation must not be returned.")
            } catch let error as Abort {
                #expect(error.status == .serviceUnavailable)
            }

            try await app.directConversationIndex.releaseDirectConversationReservation(
                conversationID: firstConversationID,
                memberUserIDs: memberUserIDs
            )
            let replacement = try await app.directConversationIndex.reserveDirectConversation(
                conversationID: secondConversationID,
                memberUserIDs: memberUserIDs,
                shardID: SingleShardConversationShardRouter.defaultShardID
            )
            #expect(replacement == .reserved)
        }
    }

    @Test("Independent summary read models require command receipts before mutation")
    func independentSummaryReadModelsRequireCommandReceiptsBeforeMutation() async throws {
        try await withApp(configure: configure) { app in
            app.summaryShardDatabaseIDs = ["independent-summary": .sqlite]
            let accessToken = try await loginAccessToken(using: app)
            let peer = try await makeUser(email: "independent-summary-peer@example.com", on: app)

            let conversationCountBefore = try await Conversation.query(on: app.db).count()
            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: nil,
                        memberEmails: [peer.email]
                    )
                )
            }, afterResponse: { res async in
                #expect(res.status == .notAcceptable)
            })
            #expect(try await Conversation.query(on: app.db).count() == conversationCountBefore)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                req.headers.replaceOrAdd(
                    name: "Accept",
                    value: IMConversationController.commandReceiptMediaType
                )
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: nil,
                        memberEmails: [peer.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .accepted)
                let receipt = try res.content.decode(IMConversationCommandReceiptResponse.self)
                #expect(receipt.projectionPending)
                #expect(try await Conversation.find(receipt.conversationID, on: app.db) != nil)
            })
        }
    }

    @Test("Conversation create command returns an outbox-backed receipt before summary projection")
    func createConversationCommandReturnsReceiptBeforeProjection() async throws {
        try await withApp(configure: configure) { app in
            let creator = try await user(email: "demo@example.com", on: app)
            let peer = try await makeUser(email: "receipt-peer@example.com", on: app)
            let creatorID = try creator.requireID()

            let result = try await IMConversationService.command(app: app).createConversation(
                kind: IMConversationKind.direct.rawValue,
                title: "ignored for direct conversations",
                memberEmails: [peer.email],
                creatorUserID: creatorID
            )

            #expect(result.kind == .direct)
            #expect(result.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                creatorID,
                try peer.requireID()
            ].sorted { $0.uuidString < $1.uuidString })
            #expect(result.receipt.didMutate)
            #expect(result.receipt.projectionPending)
            #expect(result.receipt.eventType == .membershipAdded)

            let eventID = try #require(result.receipt.eventID)
            let event = try #require(await ConversationDomainEvent.find(eventID, on: app.db))
            #expect(event.conversationID == result.receipt.conversationID)
            #expect(try event.eventTypeEnum == .membershipAdded)

            let summaryID = ConversationUserSummary.recordID(
                ownerUserID: creatorID,
                conversationID: result.receipt.conversationID
            )
            #expect(try await ConversationUserSummary.find(summaryID, on: app.db) == nil)
        }
    }

    @Test("Conversation commands write canonical state to an independent shard before summary projection")
    func conversationCommandsUseIndependentShardBeforeProjection() async throws {
        try await withApp(configure: configure) { app in
            let shardID = "command-receipt-shard"
            let shardDatabaseID = DatabaseID(string: "command-receipt-shard-db")
            app.databases.use(.sqlite(.memory), as: shardDatabaseID)
            app.migrations.add(IMMigrationRegistry.conversationShardMigrations(), to: shardDatabaseID)
            try await app.autoMigrate()

            app.conversationShardRouter = DirectoryBackedConversationShardRouter(
                app: app,
                shardIDs: [shardID],
                shardDatabaseIDs: [shardID: shardDatabaseID],
                shardReplicaDatabaseIDs: [:],
                directory: DatabaseConversationDirectory(db: app.db)
            )
            app.summaryShardRouter = PrimaryDatabaseSummaryShardRouter(database: app.db)

            let creator = try await user(email: "demo@example.com", on: app)
            let peer = try await makeUser(email: "command-shard-peer@example.com", on: app)
            let creatorID = try creator.requireID()
            let result = try await IMConversationService.command(app: app).createConversation(
                kind: IMConversationKind.group.rawValue,
                title: "Independent shard group",
                memberEmails: [peer.email],
                creatorUserID: creatorID
            )
            let conversationID = result.receipt.conversationID
            let shardDatabase = app.db(shardDatabaseID)

            #expect(result.receipt.projectionPending)
            #expect(try await Conversation.find(conversationID, on: shardDatabase) != nil)
            #expect(try await Conversation.find(conversationID, on: app.db) == nil)
            #expect(try await app.conversationDirectory.shardID(for: conversationID) == shardID)

            let preferencesReceipt = try await IMConversationService.command(app: app)
                .updateConversationPreferences(
                    in: conversationID,
                    isPinned: true,
                    isMuted: true,
                    requesterUserID: creatorID
                )
            #expect(preferencesReceipt.projectionPending)

            let membership = try await ConversationMember.query(on: shardDatabase)
                .filter(\.$conversation.$id == conversationID)
                .filter(\.$user.$id == creatorID)
                .first()
            #expect(membership?.isPinned == true)
            #expect(membership?.isMuted == true)

            let summaryID = ConversationUserSummary.recordID(
                ownerUserID: creatorID,
                conversationID: conversationID
            )
            #expect(try await ConversationUserSummary.find(summaryID, on: app.db) == nil)

            _ = try await ConversationOutboxProcessor(db: shardDatabase).processPendingBatch(
                app: app,
                configuration: app.conversationOutboxConfiguration
            )

            let projectedSummary = try await ConversationUserSummary.find(summaryID, on: app.db)
            #expect(projectedSummary?.isPinned == true)
            #expect(projectedSummary?.isMuted == true)
        }
    }

    @Test("Conversation outbox activates a route left pending after canonical shard creation")
    func conversationOutboxActivatesPendingRouteAfterCanonicalShardCreation() async throws {
        try await withApp(configure: configure) { app in
            let shardID = "route-recovery-shard"
            let shardDatabaseID = DatabaseID(string: "route-recovery-shard-db")
            app.databases.use(.sqlite(.memory), as: shardDatabaseID)
            app.migrations.add(IMMigrationRegistry.conversationShardMigrations(), to: shardDatabaseID)
            try await app.autoMigrate()
            app.summaryShardRouter = PrimaryDatabaseSummaryShardRouter(database: app.db)

            let creator = try await user(email: "demo@example.com", on: app)
            let peer = try await makeUser(email: "route-recovery-peer@example.com", on: app)
            let creatorID = try creator.requireID()
            let conversationID = UUID()
            let shardDatabase = app.db(shardDatabaseID)

            try await app.conversationDirectory.reserveConversation(
                conversationID: conversationID,
                shardID: shardID,
                cellID: app.imRealtimeCellID
            )
            let pendingEntry = try #require(await ConversationDirectoryEntry.find(conversationID, on: app.db))
            #expect(pendingEntry.lifecycleState == .pending)

            _ = try await ConversationCommandSupport(
                db: shardDatabase,
                userDirectoryDB: app.db,
                usesLocalConversationDirectoryTables: false
            ).createConversation(
                conversationID: conversationID,
                assignedShardID: shardID,
                kind: IMConversationKind.group.rawValue,
                title: "Route recovery",
                memberEmails: [peer.email],
                creatorUserID: creatorID
            )

            do {
                _ = try await app.conversationDirectory.route(for: conversationID)
                Issue.record("A pending route must not be used before outbox recovery.")
            } catch let abort as any AbortError {
                #expect(abort.status == .serviceUnavailable)
                #expect(abort.reason.contains("pending"))
            }

            let processed = try await ConversationOutboxProcessor(db: shardDatabase).processPendingBatch(
                app: app,
                configuration: app.conversationOutboxConfiguration
            )
            #expect(processed == 1)

            let route = try await app.conversationDirectory.route(for: conversationID)
            #expect(route == ConversationRoute(cellID: app.imRealtimeCellID, shardID: shardID))
            let activeEntry = try #require(await ConversationDirectoryEntry.find(conversationID, on: app.db))
            #expect(activeEntry.lifecycleState == .active)
            #expect(activeEntry.activatedAt != nil)
        }
    }

    @Test("Conversation create receipt survives an immediate route activation failure")
    func createConversationReceiptSurvivesImmediateRouteActivationFailure() async throws {
        try await withApp(configure: configure) { app in
            let directory = DeferredActivationConversationDirectory()
            app.conversationDirectory = directory
            app.summaryShardRouter = PrimaryDatabaseSummaryShardRouter(database: app.db)

            let creator = try await user(email: "demo@example.com", on: app)
            let peer = try await makeUser(email: "deferred-route-peer@example.com", on: app)
            let result = try await IMConversationService.command(app: app).createConversation(
                kind: IMConversationKind.group.rawValue,
                title: "Deferred route activation",
                memberEmails: [peer.email],
                creatorUserID: try creator.requireID()
            )

            #expect(result.receipt.didMutate)
            #expect(await directory.activationAttemptCount() == 1)

            let processed = try await ConversationOutboxProcessor(db: app.db).processPendingBatch(
                app: app,
                configuration: app.conversationOutboxConfiguration
            )
            #expect(processed == 1)
            #expect(await directory.activationAttemptCount() == 2)
        }
    }

    @Test("Pending route reconciliation verifies canonical shard state before changing lifecycle")
    func pendingRouteReconciliationVerifiesCanonicalShardState() async throws {
        try await withApp(configure: configure) { app in
            let shardID = "route-reconciler-shard"
            let shardDatabaseID = DatabaseID(string: "route-reconciler-shard-db")
            app.databases.use(.sqlite(.memory), as: shardDatabaseID)
            app.migrations.add(IMMigrationRegistry.conversationShardMigrations(), to: shardDatabaseID)
            try await app.autoMigrate()
            app.conversationShardRouter = DirectoryBackedConversationShardRouter(
                app: app,
                shardIDs: [shardID],
                shardDatabaseIDs: [shardID: shardDatabaseID],
                shardReplicaDatabaseIDs: [:],
                directory: app.conversationDirectory
            )

            let canonicalConversationID = UUID()
            let staleConversationID = UUID()
            let shardDatabase = app.db(shardDatabaseID)
            try await Conversation(
                id: canonicalConversationID,
                title: "Canonical route",
                kind: .group
            ).create(on: shardDatabase)
            try await app.conversationDirectory.reserveConversation(
                conversationID: canonicalConversationID,
                shardID: shardID,
                cellID: app.imRealtimeCellID
            )
            try await app.conversationDirectory.reserveConversation(
                conversationID: staleConversationID,
                shardID: shardID,
                cellID: app.imRealtimeCellID
            )

            let result = try await ConversationRouteLifecycleReconciler(app: app)
                .reconcilePendingRoutes(
                    olderThan: Date().addingTimeInterval(1),
                    limit: 10
                )
            #expect(result.activatedCount == 1)
            #expect(result.abandonedCount == 1)
            #expect(result.skippedCount == 0)

            #expect(
                try await app.conversationDirectory.route(for: canonicalConversationID)
                    == ConversationRoute(cellID: app.imRealtimeCellID, shardID: shardID)
            )
            let staleEntry = try #require(await ConversationDirectoryEntry.find(staleConversationID, on: app.db))
            #expect(staleEntry.lifecycleState == .abandoned)
        }
    }

    @Test("Conversation shard migration preflight requires an active source and empty target")
    func conversationShardMigrationPreflightProtectsRouteOnlyCutover() async throws {
        try await withApp(configure: configure) { app in
            let sourceShardID = "migration-source"
            let targetShardID = "migration-target"
            let sourceDatabaseID = DatabaseID(string: "migration-source-db")
            let targetDatabaseID = DatabaseID(string: "migration-target-db")
            app.databases.use(.sqlite(.memory), as: sourceDatabaseID)
            app.databases.use(.sqlite(.memory), as: targetDatabaseID)
            app.migrations.add(IMMigrationRegistry.conversationShardMigrations(), to: sourceDatabaseID)
            app.migrations.add(IMMigrationRegistry.conversationShardMigrations(), to: targetDatabaseID)
            try await app.autoMigrate()
            app.conversationShardRouter = DirectoryBackedConversationShardRouter(
                app: app,
                shardIDs: [sourceShardID, targetShardID],
                shardDatabaseIDs: [
                    sourceShardID: sourceDatabaseID,
                    targetShardID: targetDatabaseID
                ],
                shardReplicaDatabaseIDs: [:],
                directory: app.conversationDirectory
            )

            let conversationID = UUID()
            let sourceDatabase = app.db(sourceDatabaseID)
            try await Conversation(
                id: conversationID,
                title: "Migration source",
                kind: .group
            ).create(on: sourceDatabase)
            try await app.conversationDirectory.registerConversation(
                conversationID: conversationID,
                shardID: sourceShardID,
                cellID: app.imRealtimeCellID
            )

            let preflight = ConversationShardMigrationPreflight(app: app)
            let ready = try await preflight.inspect(
                conversationID: conversationID,
                targetShardID: targetShardID
            )
            #expect(ready.isReadyToCopy)
            #expect(ready.source.conversationCount == 1)
            #expect(ready.target.isEmpty)

            let coordinator = ConversationShardMigrationCoordinator(app: app)
            let prepared = try await coordinator.prepare(
                conversationID: conversationID,
                targetShardID: targetShardID
            )
            let preparedAgain = try await coordinator.prepare(
                conversationID: conversationID,
                targetShardID: targetShardID
            )
            #expect(prepared.statusEnum == .prepared)
            #expect(try prepared.requireID() == conversationID)
            #expect(try preparedAgain.requireID() == conversationID)
            #expect(
                try await app.conversationDirectory.route(for: conversationID)
                    == ConversationRoute(cellID: app.imRealtimeCellID, shardID: sourceShardID)
            )

            try await Conversation(
                id: conversationID,
                title: "Conflicting target",
                kind: .group
            ).create(on: app.db(targetDatabaseID))
            let conflicted = try await preflight.inspect(
                conversationID: conversationID,
                targetShardID: targetShardID
            )
            #expect(!conflicted.isReadyToCopy)
            #expect(conflicted.blockers.contains("target_contains_existing_conversation_data"))
        }
    }

    @Test("Conversation shard migration copies canonically with durable watermarks before route cutover")
    func conversationShardMigrationCopyAndVerifyKeepsSourceRouteActive() async throws {
        try await withApp(configure: configure) { app in
            let sourceShardID = "migration-copy-source"
            let targetShardID = "migration-copy-target"
            let sourceDatabaseID = DatabaseID(string: "migration-copy-source-db")
            let targetDatabaseID = DatabaseID(string: "migration-copy-target-db")
            app.databases.use(.sqlite(.memory), as: sourceDatabaseID)
            app.databases.use(.sqlite(.memory), as: targetDatabaseID)
            app.migrations.add(IMMigrationRegistry.conversationShardMigrations(), to: sourceDatabaseID)
            app.migrations.add(IMMigrationRegistry.conversationShardMigrations(), to: targetDatabaseID)
            try await app.autoMigrate()
            app.conversationShardRouter = DirectoryBackedConversationShardRouter(
                app: app,
                shardIDs: [sourceShardID, targetShardID],
                shardDatabaseIDs: [
                    sourceShardID: sourceDatabaseID,
                    targetShardID: targetDatabaseID
                ],
                shardReplicaDatabaseIDs: [:],
                directory: app.conversationDirectory
            )

            let conversationID = UUID()
            let memberID = UUID()
            let memberUserID = UUID()
            let sourceDatabase = app.db(sourceDatabaseID)
            try await Conversation(
                id: conversationID,
                title: "Migration copy source",
                kind: .group
            ).create(on: sourceDatabase)
            try await ConversationMember(
                id: memberID,
                conversationID: conversationID,
                userID: memberUserID,
                role: .owner,
                isPinned: true,
                pinnedAt: Date(),
                isMuted: true
            ).create(on: sourceDatabase)
            let eventID = UUID()
            let sideEffectKey = "migration-copy-side-effect"
            try await ConversationDomainEvent(
                id: eventID,
                conversationID: conversationID,
                eventType: .metadataUpdated,
                aggregateSequence: 1,
                sideEffectKey: sideEffectKey,
                payload: .metadataUpdated(recipientUserIDs: [memberUserID]),
                status: .processed
            ).create(on: sourceDatabase)
            try await ConversationDomainEventSideEffect(
                sideEffectKey: sideEffectKey,
                eventID: eventID
            ).create(on: sourceDatabase)
            let sourceRecipientSnapshot = try ConversationDomainEventRecipientSnapshot(
                eventID: eventID,
                conversationID: conversationID,
                recipientUserIDs: [memberUserID]
            )
            try await sourceRecipientSnapshot.create(on: sourceDatabase)
            // Inline snapshots from older rows may not carry a shared-set hash.
            // Physical migration must preserve that exact representation.
            sourceRecipientSnapshot.recipientHash = nil
            try await sourceRecipientSnapshot.update(on: sourceDatabase)
            try await ConversationDomainEventSequence(
                conversationID: conversationID,
                lastSequence: 1
            ).create(on: sourceDatabase)
            try await app.conversationDirectory.registerConversation(
                conversationID: conversationID,
                shardID: sourceShardID,
                cellID: app.imRealtimeCellID
            )

            let prepared = try await ConversationShardMigrationCoordinator(app: app).prepare(
                conversationID: conversationID,
                targetShardID: targetShardID
            )
            #expect(prepared.sourceMemberCount == 1)
            #expect(prepared.sourceDomainEventCount == 1)
            #expect(prepared.sourceDomainEventSequenceCount == 1)
            #expect(prepared.sourceRecipientSnapshotCount == 1)
            let preparedFence = try #require(await ConversationWriteFence.find(conversationID, on: sourceDatabase))
            #expect(preparedFence.stateEnum == .writable)

            let coordinator = ConversationShardMigrationCopyCoordinator(app: app)
            let copied = try await coordinator.copy(conversationID: conversationID, pageSize: 1)
            #expect(copied.statusEnum == .copied)
            #expect(copied.copyConversationWatermark == 1)
            #expect(copied.copyMemberWatermark == 1)
            #expect(copied.copyDomainEventWatermark == 1)
            #expect(copied.copyDomainEventSequenceWatermark == 1)
            #expect(copied.copyRecipientSnapshotWatermark == 1)
            #expect(try await Conversation.find(conversationID, on: app.db(targetDatabaseID)) != nil)
            #expect(
                try await ConversationMember.query(on: app.db(targetDatabaseID))
                    .filter(\.$conversation.$id == conversationID)
                    .count() == 1
            )
            #expect(try await ConversationDomainEvent.find(eventID, on: app.db(targetDatabaseID)) != nil)
            #expect(try await ConversationDomainEventSideEffect.find(sideEffectKey, on: app.db(targetDatabaseID)) != nil)
            #expect(try await ConversationDomainEventRecipientSnapshot.find(eventID, on: app.db(targetDatabaseID)) != nil)
            #expect(
                try await ConversationDomainEventRecipientSnapshot.find(eventID, on: app.db(targetDatabaseID))?.recipientHash == nil
            )
            #expect(
                try await ConversationDomainEventSequence.find(conversationID, on: app.db(targetDatabaseID))?.lastSequence == 1
            )
            let copiedConversation = try #require(await Conversation.find(conversationID, on: app.db(targetDatabaseID)))
            let sourceConversation = try #require(await Conversation.find(conversationID, on: sourceDatabase))
            #expect(copiedConversation.createdAt == sourceConversation.createdAt)
            let copiedMember = try #require(
                await ConversationMember.query(on: app.db(targetDatabaseID))
                    .filter(\.$id == memberID)
                    .first()
            )
            let sourceMember = try #require(
                await ConversationMember.query(on: sourceDatabase)
                    .filter(\.$id == memberID)
                    .first()
            )
            #expect(copiedMember.joinedAt == sourceMember.joinedAt)

            let copiedAgain = try await coordinator.copy(conversationID: conversationID, pageSize: 1)
            #expect(copiedAgain.copyMemberWatermark == 1)
            let verified = try await coordinator.verify(conversationID: conversationID, pageSize: 1)
            #expect(verified.statusEnum == .readyToCutover)
            #expect(verified.sourceFingerprint == verified.targetFingerprint)
            #expect(
                try await app.conversationDirectory.route(for: conversationID)
                    == ConversationRoute(cellID: app.imRealtimeCellID, shardID: sourceShardID)
            )

            let cutover = try await ConversationShardMigrationCutoverCoordinator(app: app).cutover(
                conversationID: conversationID,
                pageSize: 1
            )
            #expect(cutover.statusEnum == .cutover)
            #expect(cutover.cutoverAt != nil)
            #expect(
                try await app.conversationDirectory.route(for: conversationID)
                    == ConversationRoute(cellID: app.imRealtimeCellID, shardID: targetShardID, version: 2)
            )
            let repeatedCutover = try await ConversationShardMigrationCutoverCoordinator(app: app).cutover(
                conversationID: conversationID,
                pageSize: 1
            )
            #expect(repeatedCutover.statusEnum == .cutover)
            let blockedFence = try #require(await ConversationWriteFence.find(conversationID, on: sourceDatabase))
            #expect(blockedFence.stateEnum == .blocked)
            let retentionInspector = ConversationShardMigrationRetentionInspector(app: app)
            let retentionWaiting = try await retentionInspector.inspect(
                conversationID: conversationID,
                minimumRetentionSeconds: 3_600
            )
            #expect(!retentionWaiting.isEligibleForManualPurge)
            #expect(retentionWaiting.blockers.contains("retention_window_not_elapsed"))
            let retentionReady = try await retentionInspector.inspect(
                conversationID: conversationID,
                minimumRetentionSeconds: 0
            )
            #expect(retentionReady.isEligibleForManualPurge)
            let migrationMetrics = await app.conversationShardMigrationMetrics.currentSnapshot()
            #expect(migrationMetrics.copyAttemptCount == 2)
            #expect(migrationMetrics.copySuccessCount == 2)
            #expect(migrationMetrics.copyFailureCount == 0)
            #expect(migrationMetrics.verifyAttemptCount == 1)
            #expect(migrationMetrics.verifySuccessCount == 1)
            #expect(migrationMetrics.verifyFailureCount == 0)
            do {
                try await sourceDatabase.transaction { database in
                    try await ConversationWriteFenceService.requireWritesAllowed(
                        conversationID: conversationID,
                        on: database
                    )
                }
                Issue.record("A blocked conversation write fence accepted a canonical write transaction.")
            } catch let error as Abort {
                #expect(error.status == .conflict)
            }
        }
    }

    @Test("IM create conversation returns a receipt when the client opts into asynchronous projection")
    func createConversationReturnsReceiptForAsyncProjectionClient() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let peer = try await makeUser(email: "receipt-http-peer@example.com", on: app)
            var receipt: IMConversationCommandReceiptResponse?

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                req.headers.replaceOrAdd(
                    name: "Accept",
                    value: IMConversationController.commandReceiptMediaType
                )
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: nil,
                        memberEmails: [peer.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .accepted)
                receipt = try res.content.decode(IMConversationCommandReceiptResponse.self)
            })

            let resolvedReceipt = try #require(receipt)
            #expect(resolvedReceipt.didMutate)
            #expect(resolvedReceipt.projectionPending)
            #expect(resolvedReceipt.eventType == ConversationDomainEventType.membershipAdded.rawValue)
            let eventID = try #require(resolvedReceipt.eventID)
            #expect(try await ConversationDomainEvent.find(eventID, on: app.db) != nil)
            let summaryID = ConversationUserSummary.recordID(
                ownerUserID: try (await user(email: "demo@example.com", on: app)).requireID(),
                conversationID: resolvedReceipt.conversationID
            )
            #expect(try await ConversationUserSummary.find(summaryID, on: app.db) == nil)
        }
    }

    @Test("IM leave conversation returns a receipt when the client opts into asynchronous projection")
    func leaveConversationReturnsReceiptForAsyncProjectionClient() async throws {
        try await withApp(configure: configure) { app in
            let ownerAccessToken = try await loginAccessToken(using: app)
            let leavingMember = try await makeUser(email: "leave-receipt-member@example.com", on: app)
            let remainingMember = try await makeUser(email: "leave-receipt-remaining@example.com", on: app)
            var conversationID: UUID?

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "Leave receipt group",
                        memberEmails: [leavingMember.email, remainingMember.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                conversationID = try res.content.decode(IMConversationResponse.self).id
            })

            let leavingAccessToken = try await loginAccessToken(
                email: leavingMember.email,
                password: "password1234",
                deviceID: "leave-receipt-member-device",
                on: app
            )
            let id = try #require(conversationID)
            try await app.testing().test(.POST, "api/im/conversations/\(id.uuidString)/leave", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: leavingAccessToken)
                req.headers.replaceOrAdd(
                    name: "Accept",
                    value: IMConversationController.commandReceiptMediaType
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .accepted)
                let receipt = try res.content.decode(IMConversationCommandReceiptResponse.self)
                #expect(receipt.conversationID == id)
                #expect(receipt.eventType == ConversationDomainEventType.membershipRemoved.rawValue)
                #expect(receipt.didMutate)
                #expect(receipt.projectionPending)
            })
        }
    }

    @Test("IM group invite join returns a receipt when the client opts into asynchronous projection")
    func joinInviteReturnsReceiptForAsyncProjectionClient() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let ownerID = try owner.requireID()
            let existingMember = try await makeUser(email: "invite-receipt-existing@example.com", on: app)
            let joiningMember = try await makeUser(email: "invite-receipt-joining@example.com", on: app)
            let created = try await IMConversationService.command(app: app).createConversation(
                kind: IMConversationKind.group.rawValue,
                title: "Invite receipt group",
                memberEmails: [existingMember.email],
                creatorUserID: ownerID
            )
            let invite = try await ConversationCommonFeatureCommandService(app: app).createInvite(
                userID: ownerID,
                conversationID: created.receipt.conversationID,
                expiresInSeconds: 3_600
            )
            let joiningAccessToken = try await loginAccessToken(
                email: joiningMember.email,
                password: "password1234",
                deviceID: "invite-receipt-joining-device",
                on: app
            )

            try await app.testing().test(.POST, "api/im/invites/\(invite.token)/join", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: joiningAccessToken)
                req.headers.replaceOrAdd(
                    name: "Accept",
                    value: IMConversationController.commandReceiptMediaType
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .accepted)
                let receipt = try res.content.decode(IMConversationCommandReceiptResponse.self)
                #expect(receipt.conversationID == created.receipt.conversationID)
                #expect(receipt.eventType == ConversationDomainEventType.membershipAdded.rawValue)
                #expect(receipt.didMutate)
                #expect(receipt.projectionPending)
            })

            let joiningMemberID = try joiningMember.requireID()
            let membership = try await ConversationMember.query(on: app.db)
                .filter(\.$conversation.$id == created.receipt.conversationID)
                .filter(\.$user.$id == joiningMemberID)
                .first()
            #expect(membership != nil)
        }
    }

    @Test("IM group invite token index remains in the primary database when its conversation is sharded")
    func groupInviteTokenIndexUsesPrimaryDatabaseAcrossConversationShards() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "sharded-invite-owner@example.com", on: app)
            let ownerID = try owner.requireID()
            let shardID = "invite-shard"
            let shardDatabaseID = DatabaseID(string: "test-invite-shard")
            app.databases.use(.sqlite(.memory), as: shardDatabaseID)
            app.migrations.add(IMMigrationRegistry.conversationShardMigrations(), to: shardDatabaseID)
            try await app.autoMigrate()

            let shardDatabase = app.db(shardDatabaseID)
            let conversation = Conversation(title: "Sharded invite group", kind: .group)
            try await conversation.create(on: shardDatabase)
            let conversationID = try conversation.requireID()
            try await ConversationMember(
                conversationID: conversationID,
                userID: ownerID,
                role: .owner,
                visibleFromSequence: 1
            ).create(on: shardDatabase)

            let directory = DatabaseConversationDirectory(
                db: app.db,
                localCellID: app.imRealtimeCellID
            )
            try await directory.registerConversation(
                conversationID: conversationID,
                shardID: shardID,
                cellID: app.imRealtimeCellID
            )
            app.conversationDirectory = directory
            app.conversationShardRouter = DirectoryBackedConversationShardRouter(
                app: app,
                shardIDs: [shardID],
                shardDatabaseIDs: [shardID: shardDatabaseID],
                shardReplicaDatabaseIDs: [:],
                directory: directory
            )

            let response = try await ConversationCommonFeatureCommandService(app: app).createInvite(
                userID: ownerID,
                conversationID: conversationID,
                expiresInSeconds: 3_600
            )
            let persistedInvite = try await GroupInvite.find(response.token, on: app.db)
            #expect(persistedInvite?.conversationID == conversationID)

            guard let shardSQL = shardDatabase as? any SQLDatabase else {
                Issue.record("Expected the independent conversation shard to be SQL-backed")
                return
            }
            struct SQLiteTableRow: Decodable {
                let name: String
            }
            let tables = try await shardSQL.raw("""
                SELECT name
                FROM sqlite_master
                WHERE type = 'table'
                """).all(decoding: SQLiteTableRow.self)
            #expect(tables.contains { $0.name == GroupInvite.schema } == false)
        }
    }

    @Test("AI message stream endpoint creates canonical message and exposes completed snapshot")
    func aiMessageStreamCreatesCanonicalMessageAndSnapshot() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let peerUser = try await makeUser(email: "ai-stream-peer@example.com", on: app)

            var createdConversationID: UUID?
            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: "AI Stream",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                createdConversationID = try res.content.decode(IMConversationResponse.self).id
            })
            let conversationID = try #require(createdConversationID)

            var response: IMMessageStreamResponse?
            try await app.testing().test(
                .POST,
                "api/im/conversations/\(conversationID.uuidString)/ai/messages",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(IMAIMessageStreamStartRequest(prompt: "hello"))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(IMMessageStreamResponse.self)
                    response = body
                    #expect(body.message.conversationID == conversationID)
                    #expect(body.message.derivedState.streamState?.state == .streaming)
                    #expect(body.stream.messageID == body.message.id.uuidString)
                    #expect(body.stream.state == .streaming)
                }
            )

            let started = try #require(response)
            try await Task.sleep(nanoseconds: 250_000_000)

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/\(started.message.id.uuidString)/stream",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(IMMessageStreamResponse.self)
                    #expect(body.message.id == started.message.id)
                    #expect(body.stream.streamID == started.stream.streamID)
                    #expect(body.stream.state == .completed)
                    #expect(body.message.content.previewText == "AI: hello")
                    #expect(body.message.derivedState.streamState?.partialText == "AI: hello")
                }
            )

            try await app.testing().test(
                .POST,
                "api/im/conversations/\(conversationID.uuidString)/messages/\(started.message.id.uuidString)/stream/cancel",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(IMMessageStreamResponse.self)
                    #expect(body.stream.streamID == started.stream.streamID)
                    #expect(body.stream.state == .completed)
                    #expect(body.message.content.previewText == "AI: hello")
                }
            )
        }
    }

    @Test("AI stream guardrails reject unsafe or over-budget prompts before provider execution")
    func aiMessageStreamGuardrailsRejectUnsafeOrOverBudgetPrompts() async throws {
        try await withApp(configure: configure) { app in
            app.aiStreamGuardrailConfiguration = AIStreamGuardrailConfiguration(
                maxPromptCharacters: 32,
                maxEstimatedCostUnits: 16_420,
                blockedPromptTerms: ["blocked-term"]
            )
            let guardrails = AIStreamRequestGuardrails(app: app)
            let conversationID = UUID()
            let userID = UUID()

            #expect(throws: Abort.self) {
                try guardrails.validateStart(
                    prompt: "please include blocked-term",
                    conversationID: conversationID,
                    userID: userID
                )
            }

            #expect(throws: Abort.self) {
                try guardrails.validateStart(
                    prompt: String(repeating: "x", count: 33),
                    conversationID: conversationID,
                    userID: userID
                )
            }

            app.aiStreamGuardrailConfiguration = AIStreamGuardrailConfiguration(
                maxPromptCharacters: 4_000,
                maxEstimatedCostUnits: 16_384,
                blockedPromptTerms: []
            )
            #expect(throws: Abort.self) {
                try guardrails.validateStart(
                    prompt: "cost",
                    conversationID: conversationID,
                    userID: userID
                )
            }
        }
    }

    @Test("AI stream provider policy enforces rate limits, cost ledger, and model routing")
    func aiMessageStreamProviderPolicyEnforcesRateCostAndModelRouting() async throws {
        try await withApp(configure: configure) { app in
            app.aiStreamGuardrailConfiguration = AIStreamGuardrailConfiguration(
                maxPromptCharacters: 128,
                maxEstimatedCostUnits: 17_000,
                blockedPromptTerms: [],
                maxRequestsPerUserPerMinute: 2,
                maxCostUnitsPerUserPerDay: 60_000,
                defaultModelID: "test-small",
                largePromptModelID: "test-large",
                largePromptCharacterThreshold: 8
            )
            let policy = AIStreamProviderPolicyService(app: app)
            let conversationID = UUID()
            let userID = UUID()

            let small = try await policy.authorizeStart(
                prompt: "short",
                conversationID: conversationID,
                userID: userID
            )
            #expect(small.modelID == "test-small")
            #expect(small.estimatedCostUnits == "short".count + AIStreamProviderRunner.maxFinalTextLength)

            let large = try await policy.authorizeStart(
                prompt: "this prompt routes large",
                conversationID: conversationID,
                userID: userID
            )
            #expect(large.modelID == "test-large")

            do {
                _ = try await policy.authorizeStart(
                    prompt: "third",
                    conversationID: conversationID,
                    userID: userID
                )
                Issue.record("Expected AI stream rate limit rejection")
            } catch let abort as Abort {
                #expect(abort.status == .tooManyRequests)
            }
        }

        try await withApp(configure: configure) { app in
            app.aiStreamGuardrailConfiguration = AIStreamGuardrailConfiguration(
                maxPromptCharacters: 128,
                maxEstimatedCostUnits: 17_000,
                blockedPromptTerms: [],
                maxRequestsPerUserPerMinute: 10,
                maxCostUnitsPerUserPerDay: 16_384,
                defaultModelID: "test-small",
                largePromptModelID: "test-large",
                largePromptCharacterThreshold: 8
            )
            do {
                _ = try await AIStreamProviderPolicyService(app: app).authorizeStart(
                    prompt: "cost-budget",
                    conversationID: UUID(),
                    userID: UUID()
                )
                Issue.record("Expected AI stream cost ledger rejection")
            } catch let abort as Abort {
                #expect(abort.status == .paymentRequired)
            }
        }
    }

    @Test("AI stream startup repair marks stale streaming messages failed")
    func aiMessageStreamStartupRepairMarksStaleStreamsFailed() async throws {
        try await withApp(configure: configure) { app in
            app.aiStreamingProvider = NeverAIStreamingProvider()
            let accessToken = try await loginAccessToken(using: app)
            let peerUser = try await makeUser(email: "ai-stream-repair-peer@example.com", on: app)

            var createdConversationID: UUID?
            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: "AI Stream Repair",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                createdConversationID = try res.content.decode(IMConversationResponse.self).id
            })
            let conversationID = try #require(createdConversationID)

            var response: IMMessageStreamResponse?
            try await app.testing().test(
                .POST,
                "api/im/conversations/\(conversationID.uuidString)/ai/messages",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(IMAIMessageStreamStartRequest(prompt: "blocked"))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    response = try res.content.decode(IMMessageStreamResponse.self)
                }
            )
            let started = try #require(response)
            let repaired = try await IMAIStreamRepairService(app: app).repairStaleStreamingMessages()
            #expect(repaired >= 1)

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/\(started.message.id.uuidString)/stream",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(IMMessageStreamResponse.self)
                    #expect(body.stream.streamID == started.stream.streamID)
                    #expect(body.stream.state == .failed)
                    #expect(body.message.derivedState.streamState?.errorCode == "server_restarted")
                }
            )
        }
    }

    @Test("AI stream startup repair does not create missing stream indexes")
    func aiMessageStreamStartupRepairDoesNotCreateMissingStreamIndexes() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "ai-stream-repair-peer@example.com", on: app)

            var createdConversationID: UUID?
            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: "AI Stream Missing Index",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                createdConversationID = try res.content.decode(IMConversationResponse.self).id
            })
            let conversationID = try #require(createdConversationID)
            let userID = try demoUser.requireID()
            let messageID = UUID()
            let streamID = UUID().uuidString
            let streamState = MessageStreamState(
                streamID: streamID,
                state: .streaming,
                lastChunkIndex: 2,
                partialText: "partial missing-index",
                updatedAt: Date()
            )
            let messageWithoutIndex = try ConversationMessage(
                id: messageID,
                conversationID: conversationID,
                senderUserID: userID,
                serverSequence: 1,
                timelineSequence: 1,
                content: .richText(.plain("partial missing-index")),
                derivedState: MessageDerivedState(streamState: streamState)
            )
            try await messageWithoutIndex.create(on: app.db)
            #expect(try await AIMessageStreamIndex.find(streamID, on: app.db) == nil)

            let repaired = try await IMAIStreamRepairService(app: app).repairStaleStreamingMessages()
            #expect(repaired == 0)
            #expect(try await AIMessageStreamIndex.find(streamID, on: app.db) == nil)
        }
    }

    @Test("AI stream state store audits missing index and repairs runtime index state")
    func aiMessageStreamStateStoreAuditsMissingIndexAndRepairsRuntimeIndexState() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "ai-stream-audit-peer@example.com", on: app)
            let conversation = Conversation(title: "AI Stream Audit", kind: .direct)
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            let userID = try demoUser.requireID()
            try await ConversationMember(conversationID: conversationID, userID: userID).create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try peerUser.requireID()).create(on: app.db)

            let messageID = UUID()
            let streamID = UUID().uuidString
            let streamState = MessageStreamState(
                streamID: streamID,
                state: .streaming,
                lastChunkIndex: 3,
                partialText: "audit partial",
                updatedAt: Date()
            )
            let message = try ConversationMessage(
                id: messageID,
                conversationID: conversationID,
                senderUserID: userID,
                serverSequence: 1,
                timelineSequence: 1,
                content: .richText(.plain("audit partial")),
                derivedState: MessageDerivedState(streamState: streamState)
            )
            try await message.create(on: app.db)

            let stateStore = AIMessageStreamStateStore(app: app)
            var issues = try await stateStore.auditConsistency()
            #expect(issues.contains { $0.kind == .missingIndex && $0.streamID == streamID })

            try await AIMessageStreamIndex(
                streamID: streamID,
                messageID: messageID,
                conversationID: conversationID,
                userID: userID,
                state: .streaming,
                lastChunkIndex: 3
            ).create(on: app.db)
            issues = try await stateStore.auditConsistency()
            #expect(!issues.contains { $0.kind == .missingIndex && $0.streamID == streamID })

            let index = try #require(try await AIMessageStreamIndex.find(streamID, on: app.db))
            let repaired = try await stateStore.repair(index: index, reason: .serverRestarted, now: Date())
            #expect(repaired)
            let repairedIndex = try #require(try await AIMessageStreamIndex.find(streamID, on: app.db))
            #expect(repairedIndex.lifecycleState == .failed)
            #expect(repairedIndex.terminalAt != nil)
            issues = try await stateStore.auditConsistency()
            #expect(!issues.contains { $0.streamID == streamID && $0.kind == .missingTerminalAt })
        }
    }

    @Test("Local AI stream lease enforces limits and cancellation")
    func localAIStreamLeaseEnforcesLimitsAndCancellation() async throws {
        let store = LocalAIStreamLeaseStore()
        let userID = UUID()
        let conversationID = UUID()
        let firstStreamID = UUID().uuidString
        let secondStreamID = UUID().uuidString

        try await store.reserve(streamID: firstStreamID, conversationID: conversationID, userID: userID)
        try await store.reserve(streamID: secondStreamID, conversationID: conversationID, userID: userID)
        await #expect(throws: Abort.self) {
            try await store.reserve(streamID: UUID().uuidString, conversationID: conversationID, userID: userID)
        }

        var counts = try await store.activeCounts(conversationID: conversationID, userID: userID)
        #expect(counts.userCount == 2)
        #expect(counts.conversationCount == 2)

        try await store.requestCancel(streamID: firstStreamID)
        #expect(try await store.cancelRequested(streamID: firstStreamID))
        #expect(try await store.heartbeat(streamID: firstStreamID, conversationID: conversationID, userID: userID))

        try await store.finish(streamID: firstStreamID, conversationID: conversationID, userID: userID)
        #expect(try await !store.isActive(streamID: firstStreamID))
        counts = try await store.activeCounts(conversationID: conversationID, userID: userID)
        #expect(counts.userCount == 1)
        #expect(counts.conversationCount == 1)

        for _ in 0..<4 {
            try await store.reserve(streamID: UUID().uuidString, conversationID: conversationID, userID: UUID())
        }
        await #expect(throws: Abort.self) {
            try await store.reserve(streamID: UUID().uuidString, conversationID: conversationID, userID: UUID())
        }
    }

    @Test("Database AI stream lease enforces global quotas and cleans expired records")
    func databaseAIStreamLeaseEnforcesGlobalQuotasAndCleansExpiredRecords() async throws {
        try await withApp(configure: configure) { app in
            let store = DatabaseAIStreamLeaseStore(database: app.db, nodeID: "lease-test-node")
            let userID = UUID()
            let firstConversationID = UUID()
            let secondConversationID = UUID()
            let firstStreamID = UUID().uuidString
            let secondStreamID = UUID().uuidString

            try await store.reserve(
                streamID: firstStreamID,
                conversationID: firstConversationID,
                userID: userID
            )
            try await store.reserve(
                streamID: secondStreamID,
                conversationID: secondConversationID,
                userID: userID
            )
            await #expect(throws: Abort.self) {
                try await store.reserve(
                    streamID: UUID().uuidString,
                    conversationID: UUID(),
                    userID: userID
                )
            }

            try await store.requestCancel(streamID: firstStreamID)
            #expect(try await store.cancelRequested(streamID: firstStreamID))
            #expect(try await store.heartbeat(
                streamID: firstStreamID,
                conversationID: firstConversationID,
                userID: userID
            ))

            try await store.finish(
                streamID: firstStreamID,
                conversationID: firstConversationID,
                userID: userID
            )
            #expect(try await !store.isActive(streamID: firstStreamID))

            let sharedConversationID = UUID()
            try await AIStreamLease(
                streamID: "expired-lease",
                conversationID: sharedConversationID,
                userID: UUID(),
                nodeID: "expired-node",
                expiresAt: Date().addingTimeInterval(-1)
            ).create(on: app.db)
            for _ in 0..<5 {
                try await store.reserve(
                    streamID: UUID().uuidString,
                    conversationID: sharedConversationID,
                    userID: UUID()
                )
            }
            let counts = try await store.activeCounts(
                conversationID: sharedConversationID,
                userID: userID
            )
            #expect(counts.conversationCount == 5)
            #expect(try await AIStreamLease.find("expired-lease", on: app.db) == nil)
            await #expect(throws: Abort.self) {
                try await store.reserve(
                    streamID: UUID().uuidString,
                    conversationID: sharedConversationID,
                    userID: UUID()
                )
            }
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


    @Test("IM group creation does not write system message content into summary or history")
    func createGroupConversationDoesNotPersistSystemMessage() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
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
                #expect(conversation.lastMessage == nil)
                #expect(conversation.lastReadSequence == 0)
                #expect(conversation.unreadCount == 0)
            })

            let conversationID = try #require(createdConversationID)
            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/timeline", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let timeline = try res.content.decode(IMTimelinePageResponse.self)
                let messages = timeline.items.compactMap(\.message)
                #expect(messages.isEmpty)
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


    @Test("IM create conversation endpoint does not scan memberships when direct index is missing")
    func createDirectConversationDoesNotScanMembershipsWhenDirectIndexIsMissing() async throws {
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
                        title: "Should Not Scan Frozen",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.id != existingConversationID)
                #expect(conversation.kind == IMConversationKind.direct.rawValue)
                #expect(conversation.title == nil)
                #expect(conversation.directMessagingState == IMDirectMessagingState.active.rawValue)
                #expect(conversation.directPeer == IMDirectPeerResponse(id: peerUserID, email: peerUser.email))
            })

            let conversations = try await Conversation.query(on: app.db).all()
            #expect(conversations.count == 2)
            #expect(conversations.contains { (try? $0.requireID()) == existingConversationID && $0.directMessagingStateEnum == .frozenAfterUnfriend })

            let pairHash = [demoUserID, peerUserID]
                .map(\.uuidString)
                .sorted()
                .joined(separator: ":")
            let directIndexEntry = try await DirectConversationIndexEntry.find(pairHash, on: app.db)
            #expect(directIndexEntry?.conversationID != existingConversationID)
        }
    }


}

private struct NeverAIStreamingProvider: AIStreamingProvider {
    func streamText(for request: AIStreamingRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { _ in }
    }
}

private struct PrimaryDatabaseSummaryShardRouter: SummaryShardRouter {
    let database: any Database

    var routerName: String { "primary-database-summary-test" }
    var shardIDs: [String] { ["primary"] }

    func shardID(forOwnerUserID userID: UUID) -> String {
        "primary"
    }

    func database(forShardID shardID: String) -> any Database {
        database
    }

    func database(forOwnerUserID userID: UUID) -> any Database {
        database
    }
}

private actor DeferredActivationConversationDirectory: ConversationDirectory {
    private var activationAttempts = 0

    func shardID(for conversationID: UUID) async throws -> String {
        SingleShardConversationShardRouter.defaultShardID
    }

    func registerConversation(conversationID: UUID, shardID: String) async throws { }

    func reserveConversation(conversationID: UUID, shardID: String, cellID: String) async throws { }

    func activateConversation(conversationID: UUID) async throws {
        activationAttempts += 1
        if activationAttempts == 1 {
            throw Abort(.serviceUnavailable, reason: "Simulated primary directory outage")
        }
    }

    func activationAttemptCount() -> Int {
        activationAttempts
    }
}
