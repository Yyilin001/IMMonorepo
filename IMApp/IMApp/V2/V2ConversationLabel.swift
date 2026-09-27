import IMV2ClientKit
import IMV2Core
import SwiftUI

/// Private conversation labels carry only a lookup key. Profile strings stay
/// in the memory-only, expiring presentation pipeline.
enum V2ConversationLabel: Hashable, Sendable {
    case group(String)
    case profile(V2ProfileViewLookupKey)
    case unavailable

    init(context: V2ClientConversationLookupContext?) {
        switch context {
        case .group(let title): self = .group(title)
        case .direct(let peer): self = .profile(.init(userID: peer, context: .directConversation))
        case nil: self = .unavailable
        }
    }

    init(item: V2ConversationListItem) {
        switch item.kind {
        case .group: self = .group(item.title)
        case .direct:
            if let key = item.presentationKey, key.context == .directConversation { self = .profile(key) }
            else { self = .unavailable }
        case .unknown: self = .unavailable
        }
    }
}

struct V2ConversationLabelView: View {
    let label: V2ConversationLabel
    var body: some View {
        switch label {
        case .group(let title): Text(title)
        case .profile(let key): V2AuthorizedProfileNameView(key: key, placeholder: "会话")
        case .unavailable: Text("会话")
        }
    }
}

extension V2ClientConversationLookupContext {
    func authorKey(for user: UserID, in room: RoomID, actorUserID: UserID?) -> V2ProfileViewLookupKey? {
        switch self {
        case .group: return .init(userID: user, context: .room(room))
        case .direct(let peer):
            guard user == actorUserID || user == peer else { return nil }
            return .init(userID: user, context: .room(room))
        }
    }
}
