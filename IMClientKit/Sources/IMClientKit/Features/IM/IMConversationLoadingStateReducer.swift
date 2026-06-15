import Foundation

struct IMConversationLoadingState: Equatable, Sendable {
    var isLoadingConversations: Bool
    var isLoadingMoreConversationSummaries: Bool
    var detailState: ConversationDetailState
}

enum IMConversationLoadingStateEvent: Equatable, Sendable {
    case setLoadingConversations(Bool)
    case setLoadingMoreConversationSummaries(Bool)
    case setLoadingMembers(Bool)
    case setLoadingMessages(Bool)
}

struct IMConversationLoadingStateReducer: Sendable {
    func reduce(
        _ event: IMConversationLoadingStateEvent,
        state: inout IMConversationLoadingState
    ) {
        switch event {
        case .setLoadingConversations(let isLoading):
            state.isLoadingConversations = isLoading
        case .setLoadingMoreConversationSummaries(let isLoading):
            state.isLoadingMoreConversationSummaries = isLoading
        case .setLoadingMembers(let isLoading):
            state.detailState.isLoadingMembers = isLoading
        case .setLoadingMessages(let isLoading):
            state.detailState.isLoadingMessages = isLoading
        }
    }
}
