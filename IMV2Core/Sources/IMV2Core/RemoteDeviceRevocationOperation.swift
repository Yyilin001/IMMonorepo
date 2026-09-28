import Crypto
import Foundation

public enum V2RemoteDeviceRevocationValidationError: Error, Sendable { case invalidBaseline, invalidCommand, invalidReceipt }
/// An observed, server-frozen management snapshot. It grants no access token.
public struct V2RemoteDeviceRevocationBaseline: Codable, Equatable, Sendable {
    public static let maximumTargets = 256
    public let id: UUID
    public let actorUserID: UserID
    public let currentDeviceID: DeviceID
    public let targetDeviceIDs: [DeviceID]
    public let issuedAtMilliseconds: UInt64
    public let expiresAtMilliseconds: UInt64
    public init(id:UUID,actorUserID:UserID,currentDeviceID:DeviceID,targetDeviceIDs:[DeviceID],issuedAtMilliseconds:UInt64,expiresAtMilliseconds:UInt64) throws {
        guard actorUserID.uuidValue != nil,currentDeviceID.uuidValue != nil,targetDeviceIDs.count <= Self.maximumTargets,
              targetDeviceIDs.allSatisfy({$0.uuidValue != nil && $0 != currentDeviceID}),Set(targetDeviceIDs).count == targetDeviceIDs.count,
              targetDeviceIDs == targetDeviceIDs.sorted(by:{$0.rawValue < $1.rawValue}),issuedAtMilliseconds > 0,expiresAtMilliseconds > issuedAtMilliseconds,
              expiresAtMilliseconds <= UInt64(Int64.max),expiresAtMilliseconds-issuedAtMilliseconds <= 120_000 else {throw V2RemoteDeviceRevocationValidationError.invalidBaseline}
        self.id=id;self.actorUserID=actorUserID;self.currentDeviceID=currentDeviceID;self.targetDeviceIDs=targetDeviceIDs
        self.issuedAtMilliseconds=issuedAtMilliseconds;self.expiresAtMilliseconds=expiresAtMilliseconds
    }
    private enum CodingKeys:CodingKey {case id,actorUserID,currentDeviceID,targetDeviceIDs,issuedAtMilliseconds,expiresAtMilliseconds}
    public init(from decoder:any Decoder) throws {let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(id:c.decode(UUID.self,forKey:.id),actorUserID:c.decode(UserID.self,forKey:.actorUserID),currentDeviceID:c.decode(DeviceID.self,forKey:.currentDeviceID),targetDeviceIDs:c.decode([DeviceID].self,forKey:.targetDeviceIDs),issuedAtMilliseconds:c.decode(UInt64.self,forKey:.issuedAtMilliseconds),expiresAtMilliseconds:c.decode(UInt64.self,forKey:.expiresAtMilliseconds))}
}
public struct V2RemoteDeviceRevocationCommand: Codable, Equatable, Sendable {
    public enum Selection: Codable, Equatable, Sendable {case device(DeviceID),allObservedOthers}
    public let operationID:UUID
    public let baseline:V2RemoteDeviceRevocationBaseline
    public let selection:Selection
    public let firstSubmissionDeadlineMilliseconds:UInt64
    public var targetDeviceIDs:[DeviceID] {switch selection {case .device(let id):[id];case .allObservedOthers:baseline.targetDeviceIDs}}
    public init(operationID:UUID,baseline:V2RemoteDeviceRevocationBaseline,selection:Selection,firstSubmissionDeadlineMilliseconds:UInt64) throws {
        guard firstSubmissionDeadlineMilliseconds > baseline.issuedAtMilliseconds,firstSubmissionDeadlineMilliseconds <= UInt64(Int64.max),
              firstSubmissionDeadlineMilliseconds <= baseline.expiresAtMilliseconds else {throw V2RemoteDeviceRevocationValidationError.invalidCommand}
        if case .device(let id)=selection {guard baseline.targetDeviceIDs.contains(id) else {throw V2RemoteDeviceRevocationValidationError.invalidCommand}}
        self.operationID=operationID;self.baseline=baseline;self.selection=selection;self.firstSubmissionDeadlineMilliseconds=firstSubmissionDeadlineMilliseconds
    }
    /// Versioned canonical JSON of validated immutable metadata only.
    public var fingerprint:Data { get throws {let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return Data(SHA256.hash(data:Data("IMV2.remote-device-revocation.command.v1\u{0}".utf8)+(try encoder.encode(self))))} }
    private enum CodingKeys:CodingKey {case operationID,baseline,selection,firstSubmissionDeadlineMilliseconds}
    public init(from decoder:any Decoder) throws {let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(operationID:c.decode(UUID.self,forKey:.operationID),baseline:c.decode(V2RemoteDeviceRevocationBaseline.self,forKey:.baseline),selection:c.decode(Selection.self,forKey:.selection),firstSubmissionDeadlineMilliseconds:c.decode(UInt64.self,forKey:.firstSubmissionDeadlineMilliseconds))}
}
public struct V2RemoteDeviceRevocationReceipt: Codable, Equatable, Sendable {
    public enum Outcome:Codable,Equatable,Sendable {case revoked,rejected(Reason),closed}
    public enum Reason:String,Codable,Sendable {case deadlineExpired,baselineUnavailable,authorizationDenied}
    public let actorUserID:UserID
    public let currentDeviceID:DeviceID
    public let operationID:UUID
    public let fingerprint:Data
    public let targetDeviceIDs:[DeviceID]
    public let outcome:Outcome
    public let resolvedAtMilliseconds:UInt64
    public init(command:V2RemoteDeviceRevocationCommand,outcome:Outcome,resolvedAtMilliseconds:UInt64) throws {
        self.actorUserID=command.baseline.actorUserID;self.currentDeviceID=command.baseline.currentDeviceID;self.operationID=command.operationID
        self.fingerprint=try command.fingerprint;self.targetDeviceIDs=command.targetDeviceIDs;self.outcome=outcome;self.resolvedAtMilliseconds=resolvedAtMilliseconds
        guard validates(command) else {throw V2RemoteDeviceRevocationValidationError.invalidReceipt}
    }
    public func validates(_ command:V2RemoteDeviceRevocationCommand)->Bool {actorUserID==command.baseline.actorUserID && currentDeviceID==command.baseline.currentDeviceID && operationID==command.operationID && fingerprint==(try? command.fingerprint) && targetDeviceIDs==command.targetDeviceIDs && resolvedAtMilliseconds>0 && resolvedAtMilliseconds<=UInt64(Int64.max)}
}
public struct V2RemoteDeviceRevocationRecoveryRequest:Codable,Equatable,Sendable {
    public enum Action:String,Codable,Sendable {case query,closeIfAbsent}
    public let command:V2RemoteDeviceRevocationCommand
    public let action:Action
    public init(command:V2RemoteDeviceRevocationCommand,action:Action) {self.command=command;self.action=action}
}
public enum V2RemoteDeviceRevocationResult:Codable,Equatable,Sendable {case receipt(V2RemoteDeviceRevocationReceipt),unresolved,fingerprintConflict}
