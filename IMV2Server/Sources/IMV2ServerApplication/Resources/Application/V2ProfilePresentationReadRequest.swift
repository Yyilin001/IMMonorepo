import IMV2Core

/// One recipient in a bounded presentation batch. Sharing work never shares
/// this recipient's device, context, private aliases or authorization result.
public struct V2ProfilePresentationReadRequest: Sendable {
    public let request: V2ProfilePresentationBatchRequest
    public let actorUserID: UserID
    public let deviceID: DeviceID
    /// The caller's complete operation budget, including authority reads.
    /// An optional delivery job must not silently acquire a fresh HTTP budget.
    /// Shared I/O can continue for another live caller; this caller cannot
    /// enter a later authority pass or receive a presentation after its cutoff.
    public let deadline: ContinuousClock.Instant

    public init(request: V2ProfilePresentationBatchRequest, actorUserID: UserID, deviceID: DeviceID,
                deadline: ContinuousClock.Instant = .now + .seconds(10)) {
        self.request = request; self.actorUserID = actorUserID; self.deviceID = deviceID
        self.deadline = deadline
    }
}
