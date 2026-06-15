import Testing
@testable import IMClientKit

struct IMConversationLoadingStateReducerTests {
    @Test func reducerAppliesLoadingFlagsWithoutMainActorStore() {
        let reducer = IMConversationLoadingStateReducer()
        var state = IMConversationLoadingState(
            isLoadingConversations: false,
            isLoadingMoreConversationSummaries: false,
            detailState: ConversationDetailState()
        )

        reducer.reduce(.setLoadingConversations(true), state: &state)
        reducer.reduce(.setLoadingMoreConversationSummaries(true), state: &state)
        reducer.reduce(.setLoadingMembers(true), state: &state)
        reducer.reduce(.setLoadingMessages(true), state: &state)

        #expect(state.isLoadingConversations)
        #expect(state.isLoadingMoreConversationSummaries)
        #expect(state.detailState.isLoadingMembers)
        #expect(state.detailState.isLoadingMessages)

        reducer.reduce(.setLoadingConversations(false), state: &state)
        reducer.reduce(.setLoadingMoreConversationSummaries(false), state: &state)
        reducer.reduce(.setLoadingMembers(false), state: &state)
        reducer.reduce(.setLoadingMessages(false), state: &state)

        #expect(!state.isLoadingConversations)
        #expect(!state.isLoadingMoreConversationSummaries)
        #expect(!state.detailState.isLoadingMembers)
        #expect(!state.detailState.isLoadingMessages)
    }
}
