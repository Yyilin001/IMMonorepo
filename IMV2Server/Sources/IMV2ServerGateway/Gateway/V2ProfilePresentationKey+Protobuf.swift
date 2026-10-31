import IMV2Core

extension IMV2ProfilePresentationKey {
    func domain() throws -> V2ProfileViewLookupKey {
        let user = try UserID(userID)
        guard user.uuidValue != nil else { throw V2GatewaySessionError.unsupportedCommand }
        let scope: V2ProfileViewContext
        switch context {
        case .relationship(true): scope = .relationship
        case .directConversation(true): scope = .directConversation
        case .roomID(let value):
            let room = try RoomID(value)
            guard room.uuidValue != nil else { throw V2GatewaySessionError.unsupportedCommand }
            scope = .room(room)
        case .groupJoinReviewRoomID(let value):
            let room = try RoomID(value)
            guard room.uuidValue != nil else { throw V2GatewaySessionError.unsupportedCommand }
            scope = .groupJoinReview(room)
        default: throw V2GatewaySessionError.unsupportedCommand
        }
        return .init(userID: user, context: scope)
    }
}
