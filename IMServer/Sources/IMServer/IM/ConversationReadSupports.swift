import Fluent
import SQLKit
import Vapor

struct ConversationSummaryReadSupport {
    let db: any Database

    private var membershipService: ConversationMembershipService {
        ConversationMembershipService(db: db)
    }

    private var readStateService: ConversationReadStateService {
        ConversationReadStateService(db: db)
    }

    private var messageService: ConversationMessageService {
        ConversationMessageService(db: db)
    }

    private var summaryProjectionService: IMConversationSummaryProjectionService {
        IMConversationSummaryProjectionService(db: db)
    }

    func conversationSummary(
        conversationID: UUID,
        for userID: UUID
    ) async throws -> IMConversationResponse {
        let recordID = ConversationUserSummary.recordID(ownerUserID: userID, conversationID: conversationID)
        if let summary = try await ConversationUserSummary.find(recordID, on: db) {
            guard !summary.isRemoved else {
                throw Abort(.notFound, reason: "会话不存在。")
            }
            if let conversation = try await Conversation.find(conversationID, on: db),
               let conversationRevision = conversation.membershipRevision,
               let summaryRevision = summary.membershipRevision,
               conversationRevision == summaryRevision,
               summary.memberUserIDs.contains(userID)
            {
                return try await ConversationSummaryResponseOverlay.responseLoadingActivity(
                    from: summary,
                    on: db
                )
            }
        }

        let response = try await conversationResponse(
            conversationID: conversationID,
            for: userID,
            on: db
        )
        try await summaryProjectionService.refreshConversationSummaries(
            conversationID: conversationID,
            recipientUserIDs: [userID],
            on: db,
            writeChangeLog: true
        )
        return response
    }

    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?,
        kind: String? = nil
    ) async throws -> IMConversationPageResponse {
        try await summaryProjectionService.listConversations(
            for: userID,
            cursor: cursor,
            limit: limit,
            kind: kind
        )
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationChangesResponse {
        try await summaryProjectionService.listConversationChanges(
            for: userID,
            afterToken: afterToken,
            cursor: cursor,
            limit: limit
        )
    }

    func listMembers(
        in conversationID: UUID,
        for userID: UUID
    ) async throws -> [IMConversationMemberResponse] {
        try await membershipService.listMemberResponses(in: conversationID, for: userID)
    }

    func listMemberPage(
        in conversationID: UUID,
        for userID: UUID,
        cursor: String?,
        limit: Int?,
        query: String?
    ) async throws -> IMConversationMemberPageResponse {
        try await membershipService.listMemberPageResponses(
            in: conversationID,
            for: userID,
            cursor: cursor,
            limit: limit,
            query: query
        )
    }

    private func conversationResponse(
        conversationID: UUID,
        for userID: UUID,
        on database: any Database
    ) async throws -> IMConversationResponse {
        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let memberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .with(\.$user)
            .all()
        let memberUserIDs = memberships.map(\.$user.id).sorted { $0.uuidString < $1.uuidString }
        guard memberUserIDs.contains(userID) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }
        guard let membership = memberships.first(where: { $0.$user.id == userID }) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let lastMessageRows = try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$serverSequence >= membership.visibleFromSequence)
            .sort(\.$serverSequence, .descending)
            .limit(50)
            .all()
        let visibleLastMessageRows = try await IMCommonFeatureService(db: database)
            .filterVisible(lastMessageRows, for: userID)
        let lastVisibleMessage = visibleLastMessageRows.first
        let lastMessage = try lastVisibleMessage.map(messageService.makePreview)
        let readState = try await readStateService.conversationReadState(
            conversationID: conversationID,
            userID: userID,
            on: database
        )
        let preferences = try await readStateService.membershipSummaryPreferences(
            conversationID: conversationID,
            userID: userID,
            on: database
        )

        return IMConversationResponse(
            id: conversationID,
            title: conversation.title,
            kind: conversation.kind,
            directMessagingState: ConversationPresentationSupport.directMessagingState(for: conversation),
            directPeer: ConversationPresentationSupport.directPeer(from: memberships, currentUserID: userID),
            notice: conversation.notice,
            avatarPreset: conversation.avatarPresetEnum,
            muteAll: conversation.muteAll,
            memberCount: memberUserIDs.count,
            memberUserIDs: memberUserIDs,
            lastMessage: lastMessage,
            lastReadSequence: UInt64(readState.lastReadSequence),
            unreadCount: readState.unreadCount,
            isPinned: preferences.isPinned,
            pinnedAt: preferences.pinnedAt,
            isMuted: preferences.isMuted,
            createdAt: conversation.createdAt,
            updatedAt: lastMessage?.createdAt ?? conversation.updatedAt
        )
    }

}

struct ConversationTimelineReadSupport {
    let db: any Database
    let metrics: IMTimelineReadMetrics?
    let configuration: IMTimelineReadConfiguration
    let sinceHotCache: IMTimelineSinceHotCache?
    let sinceRecentCache: IMTimelineSinceRecentCache?
    let sinceVisibilitySafetyCache: IMTimelineSinceVisibilitySafetyCache?
    let sinceResponseCoalescer: IMTimelineSinceResponseCoalescer?

    init(
        db: any Database,
        metrics: IMTimelineReadMetrics? = nil,
        configuration: IMTimelineReadConfiguration = IMTimelineReadConfiguration(),
        sinceHotCache: IMTimelineSinceHotCache? = nil,
        sinceRecentCache: IMTimelineSinceRecentCache? = nil,
        sinceVisibilitySafetyCache: IMTimelineSinceVisibilitySafetyCache? = nil,
        sinceResponseCoalescer: IMTimelineSinceResponseCoalescer? = nil
    ) {
        self.db = db
        self.metrics = metrics
        self.configuration = configuration
        self.sinceHotCache = sinceHotCache
        self.sinceRecentCache = sinceRecentCache
        self.sinceVisibilitySafetyCache = sinceVisibilitySafetyCache
        self.sinceResponseCoalescer = sinceResponseCoalescer
    }

    private var membershipService: ConversationMembershipService {
        ConversationMembershipService(db: db)
    }

    private var messageService: ConversationMessageService {
        ConversationMessageService(db: db)
    }

    func latestMessage(in conversationID: UUID) async throws -> IMMessageResponse? {
        guard let message = try await ConversationMessage.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .sort(\.$serverSequence, .descending)
            .first()
        else {
            return nil
        }

        return try messageService.messageResponse(from: message, conversationID: conversationID)
    }

    func listTimeline(
        in conversationID: UUID,
        for userID: UUID,
        beforeSequence: Int? = nil,
        limit requestedLimit: Int? = nil
    ) async throws -> IMTimelinePageResponse {
        let startedAt = Date()
        do {
            let membership = try await membershipService.requireMembershipRecord(
                conversationID: conversationID,
                userID: userID
            )
            let visibilityOverride = try await conversationVisibilityOverride(
                conversationID: conversationID,
                userID: userID
            )
            if visibilityOverride?.isDeleted == true {
                let response = IMTimelinePageResponse(items: [], hasMore: false, nextAfterSequence: nil)
                await recordTimelineRead(.history, response: response, scan: .empty, startedAt: startedAt)
                return response
            }

            let limit = try ConversationReadPaginationSupport.normalizedHistoryLimit(requestedLimit)
            let upperBound = beforeSequence ?? Int.max
            if upperBound <= 0 {
                throw Abort(.badRequest, reason: "分页游标无效。")
            }
            let lowerTimelineBound = timelineLowerBound(
                membership: membership,
                visibilityOverride: visibilityOverride
            )
            let minimumVisibleServerSequence = membership.visibleFromSequence

            let visibleMessages = try await visibleMessagesBefore(
                conversationID: conversationID,
                userID: userID,
                visibilityOverride: visibilityOverride,
                minimumVisibleServerSequence: minimumVisibleServerSequence,
                lowerTimelineBound: lowerTimelineBound,
                upperTimelineBound: upperBound,
                visibleLimit: limit + 1
            )
            let notices = try await visibleNoticesBefore(
                conversationID: conversationID,
                for: userID,
                lowerTimelineBound: lowerTimelineBound,
                upperTimelineBound: upperBound,
                visibleLimit: limit + 1
            )

            var items = try makeTimelineItems(messages: visibleMessages.items, notices: notices.items, conversationID: conversationID)
                .sorted { lhs, rhs in
                    if lhs.timelineSequence == rhs.timelineSequence {
                        return lhs.type.rawValue < rhs.type.rawValue
                    }
                    return lhs.timelineSequence > rhs.timelineSequence
                }
            let hasMore = items.count > limit
            if hasMore {
                items = Array(items.prefix(limit))
            }
            items.reverse()
            let response = IMTimelinePageResponse(
                items: items,
                hasMore: hasMore,
                nextAfterSequence: items.last?.timelineSequence
            )
            await recordTimelineRead(.history, response: response, scan: visibleMessages.scan + notices.scan, startedAt: startedAt)
            return response
        } catch let error as TimelineVisibilityScanLimitExceeded {
            await recordTimelineReadError(scan: error.scan, startedAt: startedAt, didExceedScanLimit: true)
            throw Abort(.serviceUnavailable, reason: "Timeline visibility scan limit exceeded.")
        } catch {
            await recordTimelineReadError(scan: .empty, startedAt: startedAt, didExceedScanLimit: false)
            throw error
        }
    }

    func listTimelineSince(
        in conversationID: UUID,
        for userID: UUID,
        afterSequence: Int,
        targetSequence: Int? = nil,
        limit requestedLimit: Int? = nil,
        useSharedCache: Bool = true
    ) async throws -> IMTimelinePageResponse {
        let startedAt = Date()
        do {
            let membership = try await membershipService.requireMembershipRecord(
                conversationID: conversationID,
                userID: userID
            )
            let visibilityOverride = try await conversationVisibilityOverride(
                conversationID: conversationID,
                userID: userID
            )
            guard afterSequence >= 0 else {
                throw Abort(.badRequest, reason: "增量游标无效。")
            }
            if visibilityOverride?.isDeleted == true {
                let response = IMTimelinePageResponse(items: [], hasMore: false, nextAfterSequence: UInt64(afterSequence))
                await recordTimelineRead(.since, response: response, scan: .empty, startedAt: startedAt)
                return response
            }

            let limit = try ConversationReadPaginationSupport.normalizedIncrementalLimit(requestedLimit)
            let lowerTimelineBound = max(
                afterSequence,
                timelineLowerBound(membership: membership, visibilityOverride: visibilityOverride)
            )
            let minimumVisibleServerSequence = membership.visibleFromSequence

            if useSharedCache,
               visibilityOverride == nil,
               let response = try await cachedTimelineSinceResponseIfSafe(
                conversationID: conversationID,
                lowerTimelineBound: lowerTimelineBound,
                minimumVisibleServerSequence: minimumVisibleServerSequence,
                limit: limit,
                targetSequence: targetSequence
            ) {
                await recordTimelineRead(.since, response: response, scan: .empty, startedAt: startedAt)
                return response
            }

            let cacheKey = timelineSinceHotCacheKey(
                conversationID: conversationID,
                lowerTimelineBound: lowerTimelineBound,
                minimumVisibleServerSequence: minimumVisibleServerSequence,
                limit: limit
            )
            if useSharedCache,
               visibilityOverride == nil,
               try await canUseSharedTimelineSinceCache(
                   conversationID: conversationID,
                   lowerTimelineBound: lowerTimelineBound
               ) {
                if let response = await cachedRecentTimelineSinceResponseIfSafe(
                    conversationID: conversationID,
                    minimumVisibleServerSequence: minimumVisibleServerSequence,
                    lowerTimelineBound: lowerTimelineBound,
                    limit: limit,
                    targetSequence: targetSequence
                ) {
                    await recordTimelineRead(.since, response: response, scan: .empty, startedAt: startedAt)
                    return response
                }

                let result = try await sharedTimelineSinceResponse(
                    cacheKey: cacheKey,
                    conversationID: conversationID,
                    userID: userID,
                    visibilityOverride: visibilityOverride,
                    minimumVisibleServerSequence: minimumVisibleServerSequence,
                    lowerTimelineBound: lowerTimelineBound,
                    limit: limit,
                    targetSequence: targetSequence
                )
                await recordTimelineRead(
                    .since,
                    response: result.response,
                    scan: TimelineVisibilityScan(
                        rawRowsScanned: result.scannedRows,
                        queryPages: result.scannedPages
                    ),
                    startedAt: startedAt
                )
                return result.response
            }

            let response = try await visibleTimelineSinceResponse(
                conversationID: conversationID,
                userID: userID,
                visibilityOverride: visibilityOverride,
                minimumVisibleServerSequence: minimumVisibleServerSequence,
                lowerTimelineBound: lowerTimelineBound,
                limit: limit
            )
            await recordTimelineRead(.since, response: response.response, scan: response.scan, startedAt: startedAt)
            return response.response
        } catch let error as TimelineVisibilityScanLimitExceeded {
            await recordTimelineReadError(scan: error.scan, startedAt: startedAt, didExceedScanLimit: true)
            throw Abort(.serviceUnavailable, reason: "Timeline visibility scan limit exceeded.")
        } catch {
            await recordTimelineReadError(scan: .empty, startedAt: startedAt, didExceedScanLimit: false)
            throw error
        }
    }

    private func visibleTimelineSinceResponse(
        conversationID: UUID,
        userID: UUID,
        visibilityOverride: ConversationVisibilityOverride?,
        minimumVisibleServerSequence: Int,
        lowerTimelineBound: Int,
        limit: Int
    ) async throws -> (response: IMTimelinePageResponse, scan: TimelineVisibilityScan) {
        let visibleMessages = try await visibleMessagesSince(
            conversationID: conversationID,
            userID: userID,
            visibilityOverride: visibilityOverride,
            minimumVisibleServerSequence: minimumVisibleServerSequence,
            lowerTimelineBound: lowerTimelineBound,
            visibleLimit: limit + 1
        )
        let notices = try await visibleNoticesSince(
            conversationID: conversationID,
            for: userID,
            lowerTimelineBound: lowerTimelineBound,
            visibleLimit: limit + 1
        )

        let response = try timelineSinceResponse(
            messages: visibleMessages.items,
            notices: notices.items,
            conversationID: conversationID,
            lowerTimelineBound: lowerTimelineBound,
            limit: limit
        )
        return (response, visibleMessages.scan + notices.scan)
    }

    private func cachedTimelineSinceResponseIfSafe(
        conversationID: UUID,
        lowerTimelineBound: Int,
        minimumVisibleServerSequence: Int,
        limit: Int,
        targetSequence: Int?
    ) async throws -> IMTimelinePageResponse? {
        guard let cacheKey = timelineSinceHotCacheKey(
            conversationID: conversationID,
            lowerTimelineBound: lowerTimelineBound,
            minimumVisibleServerSequence: minimumVisibleServerSequence,
            limit: limit
        ) else {
            return nil
        }

        guard let cached = sinceHotCache?.response(for: cacheKey) else {
            await metrics?.recordSinceHotCacheMiss()
            return nil
        }
        guard cached.items.allSatisfy({ $0.notice == nil }) else {
            await metrics?.recordSinceHotCacheUnsafeBypass()
            return nil
        }
        guard timelineSinceResponse(cached, satisfiesTargetSequence: targetSequence) else {
            await metrics?.recordSinceHotCacheTargetSequenceBypass()
            return nil
        }
        guard try await canUseSharedTimelineSinceCache(
            conversationID: conversationID,
            lowerTimelineBound: lowerTimelineBound
        ) else {
            await metrics?.recordSinceHotCacheUnsafeBypass()
            return nil
        }

        await metrics?.recordSinceHotCacheHit()
        return cached
    }

    private func cachedRecentTimelineSinceResponseIfSafe(
        conversationID: UUID,
        minimumVisibleServerSequence: Int,
        lowerTimelineBound: Int,
        limit: Int,
        targetSequence: Int?
    ) async -> IMTimelinePageResponse? {
        guard configuration.isSinceRecentCacheEnabled,
              let sinceRecentCache
        else {
            return nil
        }
        guard let cached = sinceRecentCache.response(
            conversationID: conversationID,
            minimumVisibleServerSequence: minimumVisibleServerSequence,
            lowerTimelineBound: lowerTimelineBound,
            limit: limit
        ) else {
            await metrics?.recordSinceRecentCacheMiss()
            return nil
        }
        guard cached.items.allSatisfy({ $0.notice == nil }) else {
            await metrics?.recordSinceRecentCacheMiss()
            return nil
        }
        guard timelineSinceResponse(cached, satisfiesTargetSequence: targetSequence) else {
            await metrics?.recordSinceRecentCacheTargetSequenceBypass()
            return nil
        }
        await metrics?.recordSinceRecentCacheHit()
        return cached
    }

    private func canUseSharedTimelineSinceCache(
        conversationID: UUID,
        lowerTimelineBound: Int
    ) async throws -> Bool {
        guard let sinceVisibilitySafetyCache else {
            return false
        }
        let key = IMTimelineSinceVisibilitySafetyCache.Key(
            conversationID: conversationID,
            lowerTimelineBound: lowerTimelineBound
        )
        let result = try await sinceVisibilitySafetyCache.hasHiddenOverrides(
            for: key,
            ttlMilliseconds: configuration.sinceHotCacheTTLMilliseconds,
            loader: {
                try await MessageVisibilityOverride.query(on: db)
                    .filter(\.$conversationID == conversationID)
                    .filter(\.$serverSequence > lowerTimelineBound)
                    .filter(\.$isHidden == true)
                    .count() > 0
            }
        )
        await metrics?.recordSinceVisibilitySafetyCache(
            cacheHit: result.cacheHit,
            joinedInFlight: result.joinedInFlight,
            hasHiddenOverrides: result.hasHiddenOverrides
        )
        guard !result.hasHiddenOverrides else {
            return false
        }

        let hasTimelineNotices = try await ConversationTimelineNotice.query(on: db)
            .filter(\.$conversationID == conversationID)
            .filter(\.$timelineSequence > lowerTimelineBound)
            .count() > 0
        if hasTimelineNotices {
            await metrics?.recordSinceVisibilitySafetyNoticeBypass()
            return false
        }
        return true
    }

    private func sharedTimelineSinceResponse(
        cacheKey: IMTimelineSinceHotCache.Key?,
        conversationID: UUID,
        userID: UUID,
        visibilityOverride: ConversationVisibilityOverride?,
        minimumVisibleServerSequence: Int,
        lowerTimelineBound: Int,
        limit: Int,
        targetSequence: Int?
    ) async throws -> IMTimelineSinceResponseCoalescer.PageResult {
        guard let cacheKey,
              let sinceResponseCoalescer
        else {
            let response = try await visibleTimelineSinceResponse(
                conversationID: conversationID,
                userID: userID,
                visibilityOverride: visibilityOverride,
                minimumVisibleServerSequence: minimumVisibleServerSequence,
                lowerTimelineBound: lowerTimelineBound,
                limit: limit
            )
            await storeTimelineSinceCacheResponseIfSafe(
                response.response,
                for: cacheKey,
                conversationID: conversationID,
                minimumVisibleServerSequence: minimumVisibleServerSequence,
                lowerTimelineBound: lowerTimelineBound
            )
            return IMTimelineSinceResponseCoalescer.PageResult(
                response: response.response,
                scannedRows: response.scan.rawRowsScanned,
                scannedPages: response.scan.queryPages
            )
        }

        if let targetSequence,
           configuration.sinceTargetSequenceCoalesceWindowMilliseconds > 0 {
            let coalesced = try await sinceResponseCoalescer.targetSequenceResponse(
                for: cacheKey,
                targetSequence: targetSequence,
                coalescingWindowMilliseconds: configuration.sinceTargetSequenceCoalesceWindowMilliseconds
            ) { coalescedLowerTimelineBound, coalescedLimit in
                let coalescedCacheKey = IMTimelineSinceHotCache.Key(
                    conversationID: conversationID,
                    lowerTimelineBound: coalescedLowerTimelineBound,
                    minimumVisibleServerSequence: minimumVisibleServerSequence,
                    limit: coalescedLimit
                )
                if let cached = sinceHotCache?.response(for: coalescedCacheKey),
                   cached.items.allSatisfy({ $0.notice == nil }),
                   timelineSinceResponse(cached, satisfiesTargetSequence: targetSequence) {
                    return IMTimelineSinceResponseCoalescer.PageResult(
                        response: cached,
                        scannedRows: 0,
                        scannedPages: 0
                    )
                }
                let response = try await visibleTimelineSinceResponse(
                    conversationID: conversationID,
                    userID: userID,
                    visibilityOverride: visibilityOverride,
                    minimumVisibleServerSequence: minimumVisibleServerSequence,
                    lowerTimelineBound: coalescedLowerTimelineBound,
                    limit: coalescedLimit
                )
                await storeTimelineSinceCacheResponseIfSafe(
                    response.response,
                    for: coalescedCacheKey,
                    conversationID: conversationID,
                    minimumVisibleServerSequence: minimumVisibleServerSequence,
                    lowerTimelineBound: coalescedLowerTimelineBound
                )
                return IMTimelineSinceResponseCoalescer.PageResult(
                    response: response.response,
                    scannedRows: response.scan.rawRowsScanned,
                    scannedPages: response.scan.queryPages
                )
            }
            if coalesced.joinedWindow {
                await metrics?.recordSinceResponseSingleflightJoined()
                await metrics?.recordSinceTargetSequenceSingleflightJoined()
                await metrics?.recordSinceTargetSequenceWindowJoined()
                if timelineSinceResponseContainsNotice(coalesced.result.response) {
                    return try await timelineSinceNoticeSafeBypass(
                        conversationID: conversationID,
                        userID: userID,
                        visibilityOverride: visibilityOverride,
                        minimumVisibleServerSequence: minimumVisibleServerSequence,
                        lowerTimelineBound: lowerTimelineBound,
                        limit: limit
                    )
                }
            }
            return coalesced.result
        }

        let coalesced = try await sinceResponseCoalescer.response(
            for: cacheKey,
            targetSequence: targetSequence
        ) {
            if let cached = sinceHotCache?.response(for: cacheKey),
               cached.items.allSatisfy({ $0.notice == nil }),
               timelineSinceResponse(cached, satisfiesTargetSequence: targetSequence) {
                return IMTimelineSinceResponseCoalescer.PageResult(
                    response: cached,
                    scannedRows: 0,
                    scannedPages: 0
                )
            }
            let response = try await visibleTimelineSinceResponse(
                conversationID: conversationID,
                userID: userID,
                visibilityOverride: visibilityOverride,
                minimumVisibleServerSequence: minimumVisibleServerSequence,
                lowerTimelineBound: lowerTimelineBound,
                limit: limit
            )
            await storeTimelineSinceCacheResponseIfSafe(
                response.response,
                for: cacheKey,
                conversationID: conversationID,
                minimumVisibleServerSequence: minimumVisibleServerSequence,
                lowerTimelineBound: lowerTimelineBound
            )
            return IMTimelineSinceResponseCoalescer.PageResult(
                response: response.response,
                scannedRows: response.scan.rawRowsScanned,
                scannedPages: response.scan.queryPages
            )
        }
        if coalesced.joinedInFlight {
            await metrics?.recordSinceResponseSingleflightJoined()
            if targetSequence != nil {
                await metrics?.recordSinceTargetSequenceSingleflightJoined()
            }
            if timelineSinceResponseContainsNotice(coalesced.result.response) {
                return try await timelineSinceNoticeSafeBypass(
                    conversationID: conversationID,
                    userID: userID,
                    visibilityOverride: visibilityOverride,
                    minimumVisibleServerSequence: minimumVisibleServerSequence,
                    lowerTimelineBound: lowerTimelineBound,
                    limit: limit
                )
            }
        }
        return coalesced.result
    }

    private func timelineSinceNoticeSafeBypass(
        conversationID: UUID,
        userID: UUID,
        visibilityOverride: ConversationVisibilityOverride?,
        minimumVisibleServerSequence: Int,
        lowerTimelineBound: Int,
        limit: Int
    ) async throws -> IMTimelineSinceResponseCoalescer.PageResult {
        await metrics?.recordSinceResponseSingleflightNoticeBypass()
        let response = try await visibleTimelineSinceResponse(
            conversationID: conversationID,
            userID: userID,
            visibilityOverride: visibilityOverride,
            minimumVisibleServerSequence: minimumVisibleServerSequence,
            lowerTimelineBound: lowerTimelineBound,
            limit: limit
        )
        return IMTimelineSinceResponseCoalescer.PageResult(
            response: response.response,
            scannedRows: response.scan.rawRowsScanned,
            scannedPages: response.scan.queryPages
        )
    }

    private func timelineSinceResponseContainsNotice(_ response: IMTimelinePageResponse) -> Bool {
        response.items.contains { $0.notice != nil }
    }

    private func storeTimelineSinceCacheResponseIfSafe(
        _ response: IMTimelinePageResponse,
        for cacheKey: IMTimelineSinceHotCache.Key?,
        conversationID: UUID,
        minimumVisibleServerSequence: Int,
        lowerTimelineBound: Int
    ) async {
        guard response.items.allSatisfy({ $0.notice == nil }) else {
            return
        }
        if let cacheKey {
            sinceHotCache?.store(
                response,
                for: cacheKey,
                ttlMilliseconds: configuration.sinceHotCacheTTLMilliseconds,
                maxEntries: configuration.sinceHotCacheMaxEntries
            )
        }
        if configuration.isSinceRecentCacheEnabled,
           let sinceRecentCache,
           sinceRecentCache.store(
               response,
               conversationID: conversationID,
               minimumVisibleServerSequence: minimumVisibleServerSequence,
               lowerTimelineBound: lowerTimelineBound,
               ttlMilliseconds: configuration.sinceRecentCacheTTLMilliseconds,
               maxConversations: configuration.sinceRecentCacheMaxConversations,
               maxItemsPerConversation: configuration.sinceRecentCacheMaxItemsPerConversation
           ) {
            await metrics?.recordSinceRecentCacheStore()
        }
    }

    private func timelineSinceHotCacheKey(
        conversationID: UUID,
        lowerTimelineBound: Int,
        minimumVisibleServerSequence: Int,
        limit: Int
    ) -> IMTimelineSinceHotCache.Key? {
        guard configuration.isSinceHotCacheEnabled,
              sinceHotCache != nil
        else {
            return nil
        }
        return IMTimelineSinceHotCache.Key(
            conversationID: conversationID,
            lowerTimelineBound: lowerTimelineBound,
            minimumVisibleServerSequence: minimumVisibleServerSequence,
            limit: limit
        )
    }

    private func timelineSinceResponse(
        _ response: IMTimelinePageResponse,
        satisfiesTargetSequence targetSequence: Int?
    ) -> Bool {
        guard let targetSequence else {
            return true
        }
        return latestTimelineSequence(in: response) >= UInt64(targetSequence)
    }

    private func latestTimelineSequence(in response: IMTimelinePageResponse) -> UInt64 {
        response.items.map(\.timelineSequence).max() ?? response.nextAfterSequence ?? 0
    }

    private func timelineSinceResponse(
        messages: [ConversationMessage],
        notices: [ConversationTimelineNotice],
        conversationID: UUID,
        lowerTimelineBound: Int,
        limit: Int
    ) throws -> IMTimelinePageResponse {
        var items = try makeTimelineItems(messages: messages, notices: notices, conversationID: conversationID)
            .sorted { lhs, rhs in
                if lhs.timelineSequence == rhs.timelineSequence {
                    return lhs.type.rawValue < rhs.type.rawValue
                }
                return lhs.timelineSequence < rhs.timelineSequence
            }
        let hasMore = items.count > limit
        if hasMore {
            items = Array(items.prefix(limit))
        }
        let nextAfterSequence: UInt64
        if let lastItem = items.last {
            nextAfterSequence = lastItem.timelineSequence
        } else {
            nextAfterSequence = UInt64(lowerTimelineBound)
        }
        return IMTimelinePageResponse(
            items: items,
            hasMore: hasMore,
            nextAfterSequence: nextAfterSequence
        )
    }

    private func conversationVisibilityOverride(
        conversationID: UUID,
        userID: UUID
    ) async throws -> ConversationVisibilityOverride? {
        try await ConversationVisibilityOverride.find(
            ConversationVisibilityOverride.recordID(ownerUserID: userID, conversationID: conversationID),
            on: db
        )
    }

    private func timelineLowerBound(
        membership: ConversationMember,
        visibilityOverride: ConversationVisibilityOverride?
    ) -> Int {
        max(
            max(0, membership.visibleFromSequence - 1),
            visibilityOverride?.hiddenBeforeSequence ?? 0
        )
    }

    private func visibleMessagesBefore(
        conversationID: UUID,
        userID: UUID,
        visibilityOverride: ConversationVisibilityOverride?,
        minimumVisibleServerSequence: Int,
        lowerTimelineBound: Int,
        upperTimelineBound: Int,
        visibleLimit: Int
    ) async throws -> TimelineVisibilityScanResult<ConversationMessage> {
        guard visibleLimit > 0 else {
            return TimelineVisibilityScanResult(items: [], scan: .empty)
        }
        let pageSize = visibleLimit
        var cursor = upperTimelineBound
        var visibleMessages: [ConversationMessage] = []
        visibleMessages.reserveCapacity(visibleLimit)
        var scan = TimelineVisibilityScan()

        while visibleMessages.count < visibleLimit {
            let rawMessages = try await ConversationMessage.query(on: db)
                .filter(\.$conversation.$id == conversationID)
                .filter(\.$serverSequence >= minimumVisibleServerSequence)
                .filter(\.$timelineSequence > lowerTimelineBound)
                .filter(\.$timelineSequence < cursor)
                .sort(\.$timelineSequence, .descending)
                .limit(pageSize)
                .all()
            scan.record(rawRows: rawMessages.count)
            guard !rawMessages.isEmpty else {
                break
            }
            visibleMessages.append(
                contentsOf: try await filterVisibleMessages(
                    rawMessages,
                    for: userID,
                    visibilityOverride: visibilityOverride
                )
            )
            if rawMessages.count < pageSize {
                break
            }
            guard let nextCursor = rawMessages.last?.timelineSequence,
                  nextCursor < cursor
            else {
                break
            }
            cursor = nextCursor
            try enforceVisibilityScanBudget(scan)
        }
        return TimelineVisibilityScanResult(items: Array(visibleMessages.prefix(visibleLimit)), scan: scan)
    }

    private func visibleMessagesSince(
        conversationID: UUID,
        userID: UUID,
        visibilityOverride: ConversationVisibilityOverride?,
        minimumVisibleServerSequence: Int,
        lowerTimelineBound: Int,
        visibleLimit: Int
    ) async throws -> TimelineVisibilityScanResult<ConversationMessage> {
        guard visibleLimit > 0 else {
            return TimelineVisibilityScanResult(items: [], scan: .empty)
        }
        let pageSize = visibleLimit
        var cursor = lowerTimelineBound
        var visibleMessages: [ConversationMessage] = []
        visibleMessages.reserveCapacity(visibleLimit)
        var scan = TimelineVisibilityScan()

        while visibleMessages.count < visibleLimit {
            let rawMessages = try await ConversationMessage.query(on: db)
                .filter(\.$conversation.$id == conversationID)
                .filter(\.$serverSequence >= minimumVisibleServerSequence)
                .filter(\.$timelineSequence > cursor)
                .sort(\.$timelineSequence, .ascending)
                .limit(pageSize)
                .all()
            scan.record(rawRows: rawMessages.count)
            guard !rawMessages.isEmpty else {
                break
            }
            visibleMessages.append(
                contentsOf: try await filterVisibleMessages(
                    rawMessages,
                    for: userID,
                    visibilityOverride: visibilityOverride
                )
            )
            if rawMessages.count < pageSize {
                break
            }
            guard let nextCursor = rawMessages.last?.timelineSequence,
                  nextCursor > cursor
            else {
                break
            }
            cursor = nextCursor
            try enforceVisibilityScanBudget(scan)
        }
        return TimelineVisibilityScanResult(items: Array(visibleMessages.prefix(visibleLimit)), scan: scan)
    }

    private func filterVisibleMessages(
        _ messages: [ConversationMessage],
        for userID: UUID,
        visibilityOverride: ConversationVisibilityOverride?
    ) async throws -> [ConversationMessage] {
        guard !messages.isEmpty else {
            return []
        }
        if visibilityOverride?.isDeleted == true {
            return []
        }

        let hiddenBeforeSequence = visibilityOverride?.hiddenBeforeSequence
        let messageIDs = messages.compactMap(\.id)
        let messageOverridesByMessageID: [UUID: MessageVisibilityOverride]
        if messageIDs.isEmpty {
            messageOverridesByMessageID = [:]
        } else {
            let messageOverrides = try await MessageVisibilityOverride.query(on: db)
                .filter(\.$ownerUserID == userID)
                .filter(\.$messageID ~~ messageIDs)
                .all()
            messageOverridesByMessageID = Dictionary(
                uniqueKeysWithValues: messageOverrides.map { ($0.messageID, $0) }
            )
        }

        return messages.filter { message in
            if let hiddenBeforeSequence, message.serverSequence <= hiddenBeforeSequence {
                return false
            }
            guard let messageID = message.id,
                  let row = messageOverridesByMessageID[messageID]
            else {
                return true
            }
            return !row.isHidden
        }
    }

    private func visibleNoticesBefore(
        conversationID: UUID,
        for userID: UUID,
        lowerTimelineBound: Int,
        upperTimelineBound: Int,
        visibleLimit: Int
    ) async throws -> TimelineVisibilityScanResult<ConversationTimelineNotice> {
        guard visibleLimit > 0 else {
            return TimelineVisibilityScanResult(items: [], scan: .empty)
        }
        let pageSize = visibleLimit
        var cursor = upperTimelineBound
        var notices: [ConversationTimelineNotice] = []
        notices.reserveCapacity(visibleLimit)
        var scan = TimelineVisibilityScan()

        while notices.count < visibleLimit {
            let rawNotices = try await ConversationTimelineNotice.query(on: db)
                .filter(\.$conversationID == conversationID)
                .filter(\.$timelineSequence > lowerTimelineBound)
                .filter(\.$timelineSequence < cursor)
                .sort(\.$timelineSequence, .descending)
                .limit(pageSize)
                .all()
            scan.record(rawRows: rawNotices.count)
            guard !rawNotices.isEmpty else {
                break
            }
            notices.append(contentsOf: try visibleNotices(rawNotices, for: userID))
            if rawNotices.count < pageSize {
                break
            }
            guard let nextCursor = rawNotices.last?.timelineSequence,
                  nextCursor < cursor
            else {
                break
            }
            cursor = nextCursor
            try enforceVisibilityScanBudget(scan)
        }
        return TimelineVisibilityScanResult(items: Array(notices.prefix(visibleLimit)), scan: scan)
    }

    private func visibleNoticesSince(
        conversationID: UUID,
        for userID: UUID,
        lowerTimelineBound: Int,
        visibleLimit: Int
    ) async throws -> TimelineVisibilityScanResult<ConversationTimelineNotice> {
        guard visibleLimit > 0 else {
            return TimelineVisibilityScanResult(items: [], scan: .empty)
        }
        let pageSize = visibleLimit
        var cursor = lowerTimelineBound
        var notices: [ConversationTimelineNotice] = []
        notices.reserveCapacity(visibleLimit)
        var scan = TimelineVisibilityScan()

        while notices.count < visibleLimit {
            let rawNotices = try await ConversationTimelineNotice.query(on: db)
                .filter(\.$conversationID == conversationID)
                .filter(\.$timelineSequence > cursor)
                .sort(\.$timelineSequence, .ascending)
                .limit(pageSize)
                .all()
            scan.record(rawRows: rawNotices.count)
            guard !rawNotices.isEmpty else {
                break
            }
            notices.append(contentsOf: try visibleNotices(rawNotices, for: userID))
            if rawNotices.count < pageSize {
                break
            }
            guard let nextCursor = rawNotices.last?.timelineSequence,
                  nextCursor > cursor
            else {
                break
            }
            cursor = nextCursor
            try enforceVisibilityScanBudget(scan)
        }
        return TimelineVisibilityScanResult(items: Array(notices.prefix(visibleLimit)), scan: scan)
    }

    private func enforceVisibilityScanBudget(_ scan: TimelineVisibilityScan) throws {
        if scan.rawRowsScanned >= configuration.visibilityScanMaxRows ||
            scan.queryPages >= configuration.visibilityScanMaxPages
        {
            throw TimelineVisibilityScanLimitExceeded(scan: scan)
        }
    }

    private func recordTimelineRead(
        _ kind: IMTimelineReadMetrics.ReadKind,
        response: IMTimelinePageResponse,
        scan: TimelineVisibilityScan,
        startedAt: Date
    ) async {
        await metrics?.recordRead(
            kind: kind,
            itemCount: response.items.count,
            scannedRows: scan.rawRowsScanned,
            scannedPages: scan.queryPages,
            elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
        )
    }

    private func recordTimelineReadError(
        scan: TimelineVisibilityScan,
        startedAt: Date,
        didExceedScanLimit: Bool
    ) async {
        await metrics?.recordReadError(
            scannedRows: scan.rawRowsScanned,
            scannedPages: scan.queryPages,
            elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
            didExceedScanLimit: didExceedScanLimit
        )
    }

    private func elapsedMilliseconds(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }

    private func makeTimelineItems(
        messages: [ConversationMessage],
        notices: [ConversationTimelineNotice],
        conversationID: UUID
    ) throws -> [IMTimelineItemResponse] {
        let messageItems = try messages.map { message in
            let response = try messageService.messageResponse(from: message, conversationID: conversationID)
            return IMTimelineItemResponse(
                type: .message,
                timelineSequence: response.timelineSequence,
                message: response,
                notice: nil
            )
        }
        let noticeItems = try notices.map { notice -> IMTimelineItemResponse in
            guard let eventID = notice.eventID else {
                throw Abort(.internalServerError, reason: "Timeline notice 缺少 event_id。")
            }
            return IMTimelineItemResponse(
                type: .notice,
                timelineSequence: try imPositiveUInt64Sequence(notice.timelineSequence, field: "timeline_sequence"),
                message: nil,
                notice: IMTimelineNoticeResponse(
                    id: eventID,
                    conversationID: notice.conversationID,
                    timelineSequence: try imPositiveUInt64Sequence(notice.timelineSequence, field: "timeline_sequence"),
                    eventType: notice.eventType,
                    actorUserID: notice.actorUserID,
                    targetUserIDs: try notice.targetUserIDs,
                    noticeKind: notice.noticeKind,
                    params: try notice.params,
                    fallbackText: notice.fallbackText,
                    createdAt: notice.createdAt
                )
            )
        }
        return messageItems + noticeItems
    }

    private func visibleNotices(
        _ notices: [ConversationTimelineNotice],
        for userID: UUID
    ) throws -> [ConversationTimelineNotice] {
        try notices.filter { notice in
            try notice.targetUserIDs.contains(userID)
        }
    }
}

private struct TimelineVisibilityScan: Sendable {
    static let empty = TimelineVisibilityScan()

    var rawRowsScanned: Int = 0
    var queryPages: Int = 0

    mutating func record(rawRows: Int) {
        rawRowsScanned += max(0, rawRows)
        queryPages += 1
    }

    static func + (lhs: TimelineVisibilityScan, rhs: TimelineVisibilityScan) -> TimelineVisibilityScan {
        TimelineVisibilityScan(
            rawRowsScanned: lhs.rawRowsScanned + rhs.rawRowsScanned,
            queryPages: lhs.queryPages + rhs.queryPages
        )
    }
}

private struct TimelineVisibilityScanResult<Element> {
    let items: [Element]
    let scan: TimelineVisibilityScan
}

private struct TimelineVisibilityScanLimitExceeded: Error {
    let scan: TimelineVisibilityScan
}

struct ConversationSearchReadSupport {
    let db: any Database

    private var membershipService: ConversationMembershipService {
        ConversationMembershipService(db: db)
    }

    private var searchService: ConversationSearchService {
        ConversationSearchService(db: db)
    }

    func searchMessages(
        in conversationID: UUID,
        for userID: UUID,
        query rawQuery: String,
        cursor rawCursor: String?,
        limit requestedLimit: Int? = nil
    ) async throws -> IMConversationMessageSearchPageResponse {
        let membership = try await membershipService.requireMembershipRecord(
            conversationID: conversationID,
            userID: userID
        )
        let page = try await searchService.searchMessages(
            in: conversationID,
            membership: membership,
            query: rawQuery,
            cursor: rawCursor,
            limit: requestedLimit
        )
        var visibleItems: [IMConversationMessageSearchHitResponse] = []
        let featureService = IMCommonFeatureService(db: db)
        for item in page.items {
            guard let message = try await ConversationMessage.find(item.messageID, on: db),
                  try await !featureService.isHidden(message: message, for: userID)
            else {
                continue
            }
            visibleItems.append(item)
        }
        return IMConversationMessageSearchPageResponse(
            items: visibleItems,
            nextCursor: page.nextCursor,
            hasMore: page.hasMore
        )
    }
}

struct ConversationReadSupport {
    let db: any Database

    private var summaryReadSupport: ConversationSummaryReadSupport {
        ConversationSummaryReadSupport(db: db)
    }

    private var timelineReadSupport: ConversationTimelineReadSupport {
        ConversationTimelineReadSupport(db: db)
    }

    private var searchReadSupport: ConversationSearchReadSupport {
        ConversationSearchReadSupport(db: db)
    }

    func latestMessage(in conversationID: UUID) async throws -> IMMessageResponse? {
        try await timelineReadSupport.latestMessage(in: conversationID)
    }

    func conversationSummary(
        conversationID: UUID,
        for userID: UUID
    ) async throws -> IMConversationResponse {
        try await summaryReadSupport.conversationSummary(
            conversationID: conversationID,
            for: userID
        )
    }

    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?,
        kind: String? = nil
    ) async throws -> IMConversationPageResponse {
        try await summaryReadSupport.listConversations(
            for: userID,
            cursor: cursor,
            limit: limit,
            kind: kind
        )
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationChangesResponse {
        try await summaryReadSupport.listConversationChanges(
            for: userID,
            afterToken: afterToken,
            cursor: cursor,
            limit: limit
        )
    }

    func listMembers(
        in conversationID: UUID,
        for userID: UUID
    ) async throws -> [IMConversationMemberResponse] {
        try await summaryReadSupport.listMembers(in: conversationID, for: userID)
    }

    func listMemberPage(
        in conversationID: UUID,
        for userID: UUID,
        cursor: String?,
        limit: Int?,
        query: String?
    ) async throws -> IMConversationMemberPageResponse {
        try await summaryReadSupport.listMemberPage(
            in: conversationID,
            for: userID,
            cursor: cursor,
            limit: limit,
            query: query
        )
    }

    func listTimeline(
        in conversationID: UUID,
        for userID: UUID,
        beforeSequence: Int? = nil,
        limit requestedLimit: Int? = nil
    ) async throws -> IMTimelinePageResponse {
        try await timelineReadSupport.listTimeline(
            in: conversationID,
            for: userID,
            beforeSequence: beforeSequence,
            limit: requestedLimit
        )
    }

    func listTimelineSince(
        in conversationID: UUID,
        for userID: UUID,
        afterSequence: Int,
        targetSequence: Int? = nil,
        limit requestedLimit: Int? = nil,
        useSharedCache: Bool = true
    ) async throws -> IMTimelinePageResponse {
        try await timelineReadSupport.listTimelineSince(
            in: conversationID,
            for: userID,
            afterSequence: afterSequence,
            targetSequence: targetSequence,
            limit: requestedLimit,
            useSharedCache: useSharedCache
        )
    }

    func searchMessages(
        in conversationID: UUID,
        for userID: UUID,
        query rawQuery: String,
        cursor rawCursor: String?,
        limit requestedLimit: Int? = nil
    ) async throws -> IMConversationMessageSearchPageResponse {
        try await searchReadSupport.searchMessages(
            in: conversationID,
            for: userID,
            query: rawQuery,
            cursor: rawCursor,
            limit: requestedLimit
        )
    }
}
