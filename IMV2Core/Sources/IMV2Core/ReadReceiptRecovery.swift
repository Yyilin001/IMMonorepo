import Foundation

extension V2RecordReadReceiptCommand {
    public var identity: V2OperationIdentity {
        get throws { try .init(accountID:actorUserID,scope:.room(roomID),operation:.readReceipt(operationID)) }
    }
    public var fingerprint: V2OperationFingerprint {
        get throws { try .init(kind:.readReceipt,fields:[.init("actor",.text(actorUserID.rawValue)),.init("room",.text(roomID.rawValue)),.init("operation",.text(operationID.rawValue)),.init("readThroughRoomSequence",.unsigned(readThroughRoomSequence))]) }
    }
    private enum RecoveryCodingKeys:String,CodingKey { case roomID,actorUserID,operationID,readThroughRoomSequence }
    public init(from decoder:any Decoder) throws {
        let c = try decoder.container(keyedBy:RecoveryCodingKeys.self)
        try self.init(roomID:c.decode(RoomID.self,forKey:.roomID),actorUserID:c.decode(UserID.self,forKey:.actorUserID),operationID:c.decode(ReadReceiptOperationID.self,forKey:.operationID),readThroughRoomSequence:c.decode(UInt64.self,forKey:.readThroughRoomSequence))
    }
}

/// Monotonic recovery has no ordinary first-submission deadline or close action.
public struct V2ReadReceiptRecoveryRequest:Equatable,Codable,Sendable {
    public let command:V2RecordReadReceiptCommand
    public init(command:V2RecordReadReceiptCommand) { self.command = command }
}
public enum V2ReadReceiptRecoveryRejection:Equatable,Codable,Sendable {
    case roomNotFound, permissionDenied, invalidWatermark
}
/// An immutable original operation result. This is distinct from a current-watermark proof.
public struct V2ReadReceiptOperationReceipt:Equatable,Codable,Sendable {
    public let command:V2RecordReadReceiptCommand
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let receipt:V2ReadReceipt
    public init(command:V2RecordReadReceiptCommand,receipt:V2ReadReceipt) throws {
        try validateReadProof(command:command,receipt:receipt)
        self.command = command; self.identity = try command.identity;self.fingerprint = try command.fingerprint;self.receipt = receipt
    }
    public func validates(_ command:V2RecordReadReceiptCommand) -> Bool { self.command == command }
    private enum CodingKeys:String,CodingKey { case command,identity,fingerprint,receipt }
    public init(from decoder:any Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        try self.init(command:c.decode(V2RecordReadReceiptCommand.self,forKey:.command),receipt:c.decode(V2ReadReceipt.self,forKey:.receipt))
        guard try c.decode(V2OperationIdentity.self,forKey:.identity) == identity,try c.decode(V2OperationFingerprint.self,forKey:.fingerprint) == fingerprint else { throw V2ReadReceiptRecoveryValidationError.invalidProof }
    }
}
/// Proves this frozen intent's watermark is already satisfied. It does not prove its operation ID was submitted.
public struct V2ReadReceiptWatermarkProof:Equatable,Codable,Sendable {
    public let command:V2RecordReadReceiptCommand
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let watermark:V2ReadReceipt
    public init(command:V2RecordReadReceiptCommand,watermark:V2ReadReceipt) throws {
        try validateReadProof(command:command,receipt:watermark)
        self.command = command;self.identity = try command.identity;self.fingerprint = try command.fingerprint;self.watermark = watermark
    }
    public func validates(_ command:V2RecordReadReceiptCommand) -> Bool { self.command == command }
    private enum CodingKeys:String,CodingKey { case command,identity,fingerprint,watermark }
    public init(from decoder:any Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        try self.init(command:c.decode(V2RecordReadReceiptCommand.self,forKey:.command),watermark:c.decode(V2ReadReceipt.self,forKey:.watermark))
        guard try c.decode(V2OperationIdentity.self,forKey:.identity) == identity,try c.decode(V2OperationFingerprint.self,forKey:.fingerprint) == fingerprint else { throw V2ReadReceiptRecoveryValidationError.invalidProof }
    }
}
public enum V2ReadReceiptRecoveryResult:Equatable,Codable,Sendable {
    case originalReceipt(V2ReadReceiptOperationReceipt)
    case watermarkProof(V2ReadReceiptWatermarkProof)
    case unresolved
    case fingerprintConflict
    /// Current authority is unavailable; this does not determine whether the original operation executed.
    case currentUnavailable(V2ReadReceiptRecoveryRejection)
}
public enum V2ReadReceiptRecoveryValidationError:Error,Equatable,Sendable { case invalidProof }
private func validateReadProof(command:V2RecordReadReceiptCommand,receipt:V2ReadReceipt) throws {
    guard receipt.roomID == command.roomID,receipt.userID == command.actorUserID,
          receipt.readThroughRoomSequence >= command.readThroughRoomSequence,
          receipt.readThroughRoomSequence <= UInt64(Int64.max),
          receipt.recordedAt.timeIntervalSince1970.isFinite,
          Int64(exactly:(receipt.recordedAt.timeIntervalSince1970*1000).rounded(.towardZero)) != nil else { throw V2ReadReceiptRecoveryValidationError.invalidProof }
}

extension V2ReadReceipt {
    private enum ReceiptCodingKeys:String,CodingKey { case roomID,userID,readThroughRoomSequence,recordedAt }
    public init(from decoder:any Decoder) throws {
        let c = try decoder.container(keyedBy:ReceiptCodingKeys.self)
        try self.init(roomID:c.decode(RoomID.self,forKey:.roomID),userID:c.decode(UserID.self,forKey:.userID),readThroughRoomSequence:c.decode(UInt64.self,forKey:.readThroughRoomSequence),recordedAt:c.decode(Date.self,forKey:.recordedAt))
    }
}
