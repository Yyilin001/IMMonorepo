import Foundation
import IMV2Core

/// A single user click, captured before resolving an add target's public handle.
/// This local monotonic budget is deliberately not Codable or network authority.
/// Only its original wall-clock cutoff enters the later server-validated intent.
public struct V2MembershipConfirmationWindow:Sendable {
    public let operationID:MembershipOperationID
    public let roomID:RoomID
    public let action:V2RoomMembershipAction
    public let expectedMembershipRevision:UInt64
    public let confirmedUntilMilliseconds:UInt64
    public let deadline:ContinuousClock.Instant
    let activationID:UUID
    public init(roomID:RoomID,action:V2RoomMembershipAction,expectedMembershipRevision:UInt64,activationID:UUID) throws {
        try self.init(roomID:roomID,action:action,expectedMembershipRevision:expectedMembershipRevision,activationID:activationID,wallNow:Date(),monotonicNow:.now)
    }
    init(roomID:RoomID,action:V2RoomMembershipAction,expectedMembershipRevision:UInt64,activationID:UUID,wallNow:Date,monotonicNow:ContinuousClock.Instant) throws {
        _ = try V2MembershipRevision(expectedMembershipRevision)
        let milliseconds=(wallNow.timeIntervalSince1970*1000).rounded(.towardZero)
        guard milliseconds.isFinite,milliseconds>=0,milliseconds<Double(Int64.max)-120_000,
            let timestamp=UInt64(exactly:milliseconds) else { throw V2OperationWorkError.invalidRecord }
        self.operationID = .init(uuid:UUID())
        self.roomID=roomID;self.action=action;self.expectedMembershipRevision=expectedMembershipRevision
        self.activationID=activationID;self.confirmedUntilMilliseconds=timestamp+V2ClientSubmissionWindow.confirmationMilliseconds
        self.deadline=monotonicNow.advanced(by:.seconds(V2ClientSubmissionWindow.confirmationSeconds))
    }
    func validates(activationID:UUID,now:ContinuousClock.Instant = .now) -> Bool {
        self.activationID==activationID && now<deadline
    }
}
