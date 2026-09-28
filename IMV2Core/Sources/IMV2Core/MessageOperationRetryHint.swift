import Foundation

/// A bound scheduling hint, not evidence of acceptance, rejection, or closure.
public struct V2MessageOperationRetryHint:Equatable,Codable,Sendable {
    public enum Reason:String,Codable,Sendable { case rateLimited,admissionUnavailable }
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let reason:Reason
    public let retryAfterMilliseconds:UInt64?
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,reason:Reason,retryAfterMilliseconds:UInt64?) throws {
        guard [.sendMessage,.editMessage,.withdrawMessage,.reaction,.forwardMessage,.directRoom,.relationship,.userBlock,.strangerMessagePreference,.userAddPreference,.readReceiptPreference,.liveActivityPreference,.membership,.moderation,.memberMute,.moderatedMemberRemoval,.groupRoom,.pinnedMessage,.groupAnnouncement,.groupPermission,.groupRole,.groupInvite,.groupJoinRequest,.groupJoinDecision].contains(identity.kind),
            retryAfterMilliseconds.map({ $0>0 && $0<=86_400_000 }) ?? true else { throw V2MessageOperationValidationError.invalidReceipt }
        self.identity=identity;self.fingerprint=fingerprint;self.reason=reason;self.retryAfterMilliseconds=retryAfterMilliseconds
    }
    public func validates(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint)->Bool { self.identity==identity && self.fingerprint==fingerprint }
    private enum CodingKeys:String,CodingKey { case identity,fingerprint,reason,retryAfterMilliseconds }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(identity:v.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:v.decode(V2OperationFingerprint.self,forKey:.fingerprint),reason:v.decode(Reason.self,forKey:.reason),retryAfterMilliseconds:v.decodeIfPresent(UInt64.self,forKey:.retryAfterMilliseconds))
    }
}
