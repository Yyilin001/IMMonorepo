import Foundation
import IMClientKit

@MainActor
struct AuthManagerDependencies {
    let sessionClient: SessionClient
    let openIMConnection: @Sendable () async throws -> IMTCPConnection
    let backgroundTransferMonitor: any BackgroundTransferMonitoring
    let imConversationCache: IMConversationCacheHandler
    let contactStateCache: ContactStateCacheHandler
    let shouldRestoreSession: Bool
}

@MainActor
struct AuthRuntimeContext {
    let sessionClient: SessionClient
    let openIMConnection: @Sendable () async throws -> IMTCPConnection
    let imConversationStore: IMConversationStore
    let currentUserProvider: () -> AuthUser?
    let isSignedInProvider: () -> Bool
    let latestConversationSummariesProvider: () -> [IMConversationSummaryResponseBody]
    let setLatestConversationSummaries: ([IMConversationSummaryResponseBody]) -> Void
    let conversationSummaryRefreshAtProvider: () -> Date?
    let setConversationSummaryRefreshAt: (Date?) -> Void
    let conversationSummarySyncTokenProvider: () -> String?
    let setConversationSummarySyncToken: (String?) -> Void
    let markServerOnline: () -> Void
    let clearSession: (String?) async -> Void
    let handleIMDataRequestError: (Error) async -> Void
    let syncContactStateAfterConnection: () async -> Void
    let scheduleConversationCachePersist: () -> Void
    let flushConversationCache: () async -> Void
    let flushContactStateCache: () async -> Void
    let applyContactEvent: (IMTCPContactEventPayload) -> Void
    let setConnectionStatus: (AuthManager.IMConnectionStatus) -> Void
    let setQueuedFlushActive: (Bool) -> Void
    let backgroundTransferMonitor: any BackgroundTransferMonitoring
}

@MainActor
enum ConversationRuntimeFactory {
    static func make(context: AuthRuntimeContext) -> ConversationRuntimeController {
        ConversationRuntimeController(
            sessionClient: context.sessionClient,
            openIMConnection: context.openIMConnection,
            imConversationStore: context.imConversationStore,
            currentUserProvider: context.currentUserProvider,
            isSignedInProvider: context.isSignedInProvider,
            latestConversationSummariesProvider: context.latestConversationSummariesProvider,
            setLatestConversationSummaries: context.setLatestConversationSummaries,
            conversationSummaryRefreshAtProvider: context.conversationSummaryRefreshAtProvider,
            setConversationSummaryRefreshAt: context.setConversationSummaryRefreshAt,
            conversationSummarySyncTokenProvider: context.conversationSummarySyncTokenProvider,
            setConversationSummarySyncToken: context.setConversationSummarySyncToken,
            markServerOnline: context.markServerOnline,
            clearSession: context.clearSession,
            handleIMDataRequestError: context.handleIMDataRequestError,
            syncContactStateAfterConnection: context.syncContactStateAfterConnection,
            scheduleConversationCachePersist: context.scheduleConversationCachePersist,
            flushConversationCache: context.flushConversationCache,
            flushContactStateCache: context.flushContactStateCache,
            applyContactEvent: context.applyContactEvent,
            setConnectionStatus: context.setConnectionStatus,
            setQueuedFlushActive: context.setQueuedFlushActive,
            backgroundTransferMonitor: context.backgroundTransferMonitor
        )
    }
}
