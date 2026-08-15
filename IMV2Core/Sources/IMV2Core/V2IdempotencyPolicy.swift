import Foundation

/// Wire-level retry contract shared by the first-party client and server.
///
/// Operation identifiers provide exactly-once replay only inside this finite
/// window.  The client stops automatic replay first; the server keeps a
/// longer result window so clock skew, delayed maintenance, and an in-flight
/// final attempt cannot cross the deletion boundary.
public enum V2IdempotencyPolicy: Sendable {
    public static let maximumClientRetryAge: TimeInterval = 30 * 86_400
    public static let minimumServerRetention: TimeInterval = 35 * 86_400
    public static let expiredClientCommandCode = "IDEMPOTENCY_WINDOW_EXPIRED"
}
