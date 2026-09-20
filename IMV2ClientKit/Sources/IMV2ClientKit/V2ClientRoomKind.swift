/// Room category; it does not establish membership authorization.
public enum V2ClientRoomKind: String, Equatable, Sendable {
    case group
    case direct
}
