import Foundation

/// Parsed member-email draft shared by conversation creation and member-add sheets.
struct IMConversationMemberEmailDraft: Equatable, Sendable {
    let rawValue: String
    let emails: [String]

    init(_ rawValue: String) {
        self.rawValue = rawValue
        self.emails = rawValue
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool {
        emails.isEmpty
    }

    var hasSingleEmail: Bool {
        emails.count == 1
    }
}
