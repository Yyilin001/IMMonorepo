import Foundation
import IMClientKit
import SwiftUI
import UIKit

@MainActor
extension AuthManager {
    func markIMConversationReadUpToLatestLoadedSequence(for conversationID: String) async {
        await conversationRuntimeController.markConversationReadUpToLatestLoadedSequence(for: conversationID)
    }

    func markIMConversationReadIfSelectedUpToLatestLoadedSequence(for conversationID: String) async {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              imConversationStore.selectedConversationID == trimmedConversationID
        else {
            return
        }

        await conversationRuntimeController.markConversationReadUpToLatestLoadedSequence(for: trimmedConversationID)
    }

    func markIMConversationRead(
        conversationID: String,
        readSequence: UInt64,
        debounceNanoseconds: UInt64 = 250_000_000
    ) async {
        await conversationRuntimeController.markConversationRead(
            conversationID: conversationID,
            readSequence: readSequence,
            debounceNanoseconds: debounceNanoseconds
        )
    }
}
