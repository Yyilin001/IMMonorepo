import IMV2Core

extension IMV2ProfilePresentationKey {
    init(_ key: V2ProfileViewLookupKey) {
        self.init()
        userID = key.userID.rawValue
        switch key.context {
        case .relationship: context = .relationship(true)
        case .directConversation: context = .directConversation(true)
        case .room(let room): context = .roomID(room.rawValue)
        case .groupJoinReview(let room): context = .groupJoinReviewRoomID(room.rawValue)
        }
    }
}
