import Foundation
import IMV2Core
import IMV2ClientKit
@testable import IMApp

/// Holds an already materialized SQLite result, so scrolling can happen after
/// the database snapshot without relying on scheduling delays.
actor V2ListWindowReadGate {
    private var armed = false
    private var pending: CheckedContinuation<Void, Never>?
    private var readerArrival: CheckedContinuation<Void, Never>?
    private(set) var reads = 0

    func arm() { armed = true; reads = 0 }
    func holdResult() async {
        reads += 1
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation in
            pending = continuation
            readerArrival?.resume(); readerArrival = nil
        }
    }
    func waitForRead() async {
        guard pending == nil else { return }
        await withCheckedContinuation { readerArrival = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}

struct V2GatedConversationWindows: V2ConversationDataSource, V2ConversationWindowReading {
    let source: V2GRDBConversationDataSource
    let gate: V2ListWindowReadGate
    func conversationSummaryPage(for userID: String, isArchived: Bool, before cursor: V2ClientConversationListCursor?, limit: Int) async throws -> V2ConversationListPage {
        let result = try await source.conversationSummaryPage(for: userID, isArchived: isArchived, before: cursor, limit: limit)
        await gate.holdResult()
        return result
    }
    func timelineWindow(in roomID: String, for userID: String, around messageID: String, before: Int, after: Int) async throws -> V2ConversationTimelineLocation {
        try await source.timelineWindow(in: roomID, for: userID, around: messageID, before: before, after: after)
    }
    func timelinePage(in roomID: String, for userID: String, before cursor: V2ConversationTimelineCursor?, limit: Int) async throws -> V2ConversationTimelinePage {
        try await source.timelinePage(in: roomID, for: userID, before: cursor, limit: limit)
    }
    func conversationWindow(for userID: String, isArchived: Bool, around anchor: V2ClientConversationListCursor, limit: Int, precedingCount: Int) async throws -> V2ConversationListWindow {
        let result = try await source.conversationWindow(for: userID, isArchived: isArchived, around: anchor, limit: limit, precedingCount: precedingCount)
        await gate.holdResult()
        return result
    }
}

struct V2GatedContactWindows: V2ContactsReading, V2ContactsWindowReading {
    let source: V2GRDBContactsDataSource
    let gate: V2ListWindowReadGate
    func contactProjectionPage(scope: V2ContactProjectionPageScope, matching query: String?, before cursor: V2ClientRelationshipCursor?, limit: Int, includeTotalCount: Bool) async throws -> V2ContactProjectionPage {
        let result = try await source.contactProjectionPage(scope: scope, matching: query, before: cursor, limit: limit, includeTotalCount: includeTotalCount)
        await gate.holdResult()
        return result
    }
    func hydrateRelationshipProfiles(for userIDs: [UserID]) async throws {
        try await source.hydrateRelationshipProfiles(for: userIDs)
    }
    func contactProjectionWindow(scope: V2ContactProjectionPageScope, matching query: String?, around anchor: V2ClientRelationshipCursor, limit: Int, precedingCount: Int, includeTotalCount: Bool) async throws -> V2ContactProjectionWindow {
        let result = try await source.contactProjectionWindow(scope: scope, matching: query, around: anchor, limit: limit, precedingCount: precedingCount, includeTotalCount: includeTotalCount)
        await gate.holdResult()
        return result
    }
}
