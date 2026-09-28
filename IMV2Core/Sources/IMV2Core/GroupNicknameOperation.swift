import Foundation

public struct V2GroupNicknameUpdateCommand: Equatable, Codable, Sendable {
  public let actorUserID: UserID
  public let roomID: RoomID
  public let operationID: GroupNicknameOperationID
  public let expectedRevision: V2ProfileRevision?
  public let nickname: String?
  public let firstSubmissionDeadlineMilliseconds: UInt64
  public let identity: V2OperationIdentity
  public let fingerprint: V2OperationFingerprint
  public init(
    actorUserID: UserID, roomID: RoomID, operationID: GroupNicknameOperationID,
    expectedRevision: V2ProfileRevision?, nickname: String?,
    firstSubmissionDeadlineMilliseconds: UInt64
  ) throws {
    guard firstSubmissionDeadlineMilliseconds > 0,
      firstSubmissionDeadlineMilliseconds <= UInt64(Int64.max)
    else {
      throw V2PresentationOperationValidationError.invalidDeadline
    }
    let validated = try V2GroupMemberPresentation(
      roomID: roomID, userID: actorUserID, groupNickname: nickname, revision: .init(rawValue: 1)!)
    self.actorUserID = actorUserID
    self.roomID = roomID
    self.operationID = operationID
    self.expectedRevision = expectedRevision
    self.nickname = validated.groupNickname
    self.firstSubmissionDeadlineMilliseconds = firstSubmissionDeadlineMilliseconds
    self.identity = try .init(
      accountID: actorUserID, scope: .room(roomID), operation: .groupNickname(operationID))
    self.fingerprint = try .init(
      kind: .groupNickname,
      fields: [
        .init("actor", .text(actorUserID.rawValue)), .init("target", .text(roomID.rawValue)),
        .init("operation", .text(operationID.rawValue)),
        .init("expectedRevision", expectedRevision.map { .unsigned($0.rawValue) } ?? .absent),
        .init("name", validated.groupNickname.map { .text($0) } ?? .absent),
        .init("firstSubmissionDeadline", .unsigned(firstSubmissionDeadlineMilliseconds)),
      ])
  }
  private enum CodingKeys: String, CodingKey {
    case actorUserID, roomID, operationID, expectedRevision, nickname,
      firstSubmissionDeadlineMilliseconds
  }
  public init(from decoder: any Decoder) throws {
    let v = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      actorUserID: v.decode(UserID.self, forKey: .actorUserID),
      roomID: v.decode(RoomID.self, forKey: .roomID),
      operationID: v.decode(GroupNicknameOperationID.self, forKey: .operationID),
      expectedRevision: v.decodeIfPresent(V2ProfileRevision.self, forKey: .expectedRevision),
      nickname: v.decodeIfPresent(String.self, forKey: .nickname),
      firstSubmissionDeadlineMilliseconds: v.decode(
        UInt64.self, forKey: .firstSubmissionDeadlineMilliseconds))
  }
}
public enum V2GroupNicknameOperationRejection: Equatable, Codable, Sendable {
  case revisionConflict(current: V2ProfileRevision?)
  case permissionDenied, notFound, expiredUnsubmitted
}
public enum V2GroupNicknameOperationTerminalOutcome: Equatable, Codable, Sendable {
  case committed(V2GroupMemberPresentation)
  case rejected(V2GroupNicknameOperationRejection)
  case closed
}
/// An immutable original outcome. Adapters must verify identity and fingerprint against the frozen command.
public struct V2GroupNicknameUpdateReceipt: Equatable, Codable, Sendable {
  public let identity: V2OperationIdentity
  public let fingerprint: V2OperationFingerprint
  public let outcome: V2GroupNicknameOperationTerminalOutcome
  public let resolvedAtMilliseconds: UInt64
  public init(
    identity: V2OperationIdentity, fingerprint: V2OperationFingerprint,
    outcome: V2GroupNicknameOperationTerminalOutcome, resolvedAtMilliseconds: UInt64
  ) throws {
    try validateGroupNicknameIdentity(identity)
    guard resolvedAtMilliseconds <= UInt64(Int64.max) else {
      throw V2PresentationOperationValidationError.invalidReceipt
    }
    if case .committed(let value) = outcome {
      guard case .room(let room) = identity.scope, value.roomID == room,
        value.userID == identity.accountID,
        try V2GroupMemberPresentation(
          roomID: room, userID: value.userID, groupNickname: value.groupNickname,
          revision: value.revision)
          == value
      else { throw V2PresentationOperationValidationError.invalidReceipt }
    }
    self.identity = identity
    self.fingerprint = fingerprint
    self.outcome = outcome
    self.resolvedAtMilliseconds = resolvedAtMilliseconds
  }
  public func validates(_ command: V2GroupNicknameUpdateCommand) -> Bool {
    identity == command.identity && fingerprint == command.fingerprint
  }
  private enum CodingKeys: String, CodingKey {
    case identity, fingerprint, outcome, resolvedAtMilliseconds
  }
  public init(from decoder: any Decoder) throws {
    let v = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      identity: v.decode(V2OperationIdentity.self, forKey: .identity),
      fingerprint: v.decode(V2OperationFingerprint.self, forKey: .fingerprint),
      outcome: v.decode(V2GroupNicknameOperationTerminalOutcome.self, forKey: .outcome),
      resolvedAtMilliseconds: v.decode(UInt64.self, forKey: .resolvedAtMilliseconds))
  }
}
public struct V2GroupNicknameRecoveryRequest: Equatable, Codable, Sendable {
  public var actorUserID: UserID { identity.accountID }
  public var roomID: RoomID {
    if case .room(let room) = identity.scope { return room }
    preconditionFailure("validated group nickname scope")
  }
  public var operationID: GroupNicknameOperationID {
    if case .groupNickname(let operation) = identity.operation { return operation }
    preconditionFailure("validated nickname operation")
  }
  public let identity: V2OperationIdentity
  public let fingerprint: V2OperationFingerprint
  public let action: V2OperationRecoveryRequest.Action
  public init(
    identity: V2OperationIdentity, fingerprint: V2OperationFingerprint,
    action: V2OperationRecoveryRequest.Action
  ) throws {
    try validateGroupNicknameIdentity(identity)
    self.identity = identity
    self.fingerprint = fingerprint
    self.action = action
  }
  private enum CodingKeys: String, CodingKey { case identity, fingerprint, action }
  public init(from decoder: any Decoder) throws {
    let v = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      identity: v.decode(V2OperationIdentity.self, forKey: .identity),
      fingerprint: v.decode(V2OperationFingerprint.self, forKey: .fingerprint),
      action: v.decode(V2OperationRecoveryRequest.Action.self, forKey: .action))
  }
}
public enum V2GroupNicknameRecoveryResult: Equatable, Codable, Sendable {
  case receipt(V2GroupNicknameUpdateReceipt)
  case unresolved, fingerprintConflict
}
private func validateGroupNicknameIdentity(_ identity: V2OperationIdentity) throws {
  switch (identity.operation, identity.scope) {
  case (.groupNickname, .room): break
  default: throw V2PresentationOperationValidationError.invalidIdentity
  }
}

/// Only the caller's editable field baseline; it grants no public profile display lease.
public struct V2GroupNicknameSnapshot: Equatable, Codable, Sendable {
  public let actorUserID: UserID
  public let roomID: RoomID
  public let value: V2GroupMemberPresentation?
  public init(actorUserID: UserID, roomID: RoomID, value: V2GroupMemberPresentation?) throws {
    if let value {
      guard value.userID == actorUserID, value.roomID == roomID,
        try V2GroupMemberPresentation(
          roomID: roomID, userID: actorUserID, groupNickname: value.groupNickname,
          revision: value.revision) == value
      else {
        throw V2PresentationOperationValidationError.invalidReceipt
      }
    }
    self.actorUserID = actorUserID
    self.roomID = roomID
    self.value = value
  }
  private enum CodingKeys: String, CodingKey { case actorUserID, roomID, value }
  public init(from decoder: any Decoder) throws {
    let v = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      actorUserID: v.decode(UserID.self, forKey: .actorUserID),
      roomID: v.decode(RoomID.self, forKey: .roomID),
      value: v.decodeIfPresent(V2GroupMemberPresentation.self, forKey: .value))
  }
}
