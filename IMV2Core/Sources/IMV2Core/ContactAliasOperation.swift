import Foundation

public struct V2ContactAliasUpdateCommand: Equatable, Codable, Sendable {
  public let ownerUserID: UserID
  public let targetUserID: UserID
  public let operationID: ContactAliasOperationID
  public let expectedRevision: V2ProfileRevision?
  public let remarkName: String?
  public let firstSubmissionDeadlineMilliseconds: UInt64
  public let identity: V2OperationIdentity
  public let fingerprint: V2OperationFingerprint
  public init(
    ownerUserID: UserID, targetUserID: UserID, operationID: ContactAliasOperationID,
    expectedRevision: V2ProfileRevision?, remarkName: String?,
    firstSubmissionDeadlineMilliseconds: UInt64
  ) throws {
    guard firstSubmissionDeadlineMilliseconds > 0,
      firstSubmissionDeadlineMilliseconds <= UInt64(Int64.max)
    else {
      throw V2PresentationOperationValidationError.invalidDeadline
    }
    let validated = try V2ContactAlias(
      ownerUserID: ownerUserID, targetUserID: targetUserID, remarkName: remarkName,
      revision: .init(rawValue: 1)!)
    self.ownerUserID = ownerUserID
    self.targetUserID = targetUserID
    self.operationID = operationID
    self.expectedRevision = expectedRevision
    self.remarkName = validated.remarkName
    self.firstSubmissionDeadlineMilliseconds = firstSubmissionDeadlineMilliseconds
    self.identity = try .init(
      accountID: ownerUserID, scope: .userPair(ownerUserID, targetUserID),
      operation: .contactAlias(operationID))
    self.fingerprint = try .init(
      kind: .contactAlias,
      fields: [
        .init("actor", .text(ownerUserID.rawValue)), .init("target", .text(targetUserID.rawValue)),
        .init("operation", .text(operationID.rawValue)),
        .init("expectedRevision", expectedRevision.map { .unsigned($0.rawValue) } ?? .absent),
        .init("name", validated.remarkName.map { .text($0) } ?? .absent),
        .init("firstSubmissionDeadline", .unsigned(firstSubmissionDeadlineMilliseconds)),
      ])
  }
  private enum CodingKeys: String, CodingKey {
    case ownerUserID, targetUserID, operationID, expectedRevision, remarkName,
      firstSubmissionDeadlineMilliseconds
  }
  public init(from decoder: any Decoder) throws {
    let v = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      ownerUserID: v.decode(UserID.self, forKey: .ownerUserID),
      targetUserID: v.decode(UserID.self, forKey: .targetUserID),
      operationID: v.decode(ContactAliasOperationID.self, forKey: .operationID),
      expectedRevision: v.decodeIfPresent(V2ProfileRevision.self, forKey: .expectedRevision),
      remarkName: v.decodeIfPresent(String.self, forKey: .remarkName),
      firstSubmissionDeadlineMilliseconds: v.decode(
        UInt64.self, forKey: .firstSubmissionDeadlineMilliseconds))
  }
}
public enum V2ContactAliasOperationRejection: Equatable, Codable, Sendable {
  case revisionConflict(current: V2ProfileRevision?)
  case permissionDenied, notFound, expiredUnsubmitted
}
public enum V2ContactAliasOperationTerminalOutcome: Equatable, Codable, Sendable {
  case committed(V2ContactAlias)
  case rejected(V2ContactAliasOperationRejection)
  case closed
}
/// An immutable original outcome. Adapters must verify identity and fingerprint against the frozen command.
public struct V2ContactAliasUpdateReceipt: Equatable, Codable, Sendable {
  public let identity: V2OperationIdentity
  public let fingerprint: V2OperationFingerprint
  public let outcome: V2ContactAliasOperationTerminalOutcome
  public let resolvedAtMilliseconds: UInt64
  public init(
    identity: V2OperationIdentity, fingerprint: V2OperationFingerprint,
    outcome: V2ContactAliasOperationTerminalOutcome, resolvedAtMilliseconds: UInt64
  ) throws {
    try validateContactAliasIdentity(identity)
    guard resolvedAtMilliseconds <= UInt64(Int64.max) else {
      throw V2PresentationOperationValidationError.invalidReceipt
    }
    if case .committed(let value) = outcome {
      guard case .userPair(let owner, let target) = identity.scope, value.ownerUserID == owner,
        value.targetUserID == target,
        try V2ContactAlias(
          ownerUserID: owner, targetUserID: target, remarkName: value.remarkName,
          revision: value.revision)
          == value
      else { throw V2PresentationOperationValidationError.invalidReceipt }
    }
    self.identity = identity
    self.fingerprint = fingerprint
    self.outcome = outcome
    self.resolvedAtMilliseconds = resolvedAtMilliseconds
  }
  public func validates(_ command: V2ContactAliasUpdateCommand) -> Bool {
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
      outcome: v.decode(V2ContactAliasOperationTerminalOutcome.self, forKey: .outcome),
      resolvedAtMilliseconds: v.decode(UInt64.self, forKey: .resolvedAtMilliseconds))
  }
}
public struct V2ContactAliasRecoveryRequest: Equatable, Codable, Sendable {
  public let identity: V2OperationIdentity
  public let fingerprint: V2OperationFingerprint
  public let action: V2OperationRecoveryRequest.Action
  public init(
    identity: V2OperationIdentity, fingerprint: V2OperationFingerprint,
    action: V2OperationRecoveryRequest.Action
  ) throws {
    try validateContactAliasIdentity(identity)
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
public enum V2ContactAliasRecoveryResult: Equatable, Codable, Sendable {
  case receipt(V2ContactAliasUpdateReceipt)
  case unresolved, fingerprintConflict
}
private func validateContactAliasIdentity(_ identity: V2OperationIdentity) throws {
  switch (identity.operation, identity.scope) {
  case (.contactAlias, .userPair(let owner, let target)):
    guard owner == identity.accountID, target != owner else {
      throw V2PresentationOperationValidationError.invalidIdentity
    }
  default: throw V2PresentationOperationValidationError.invalidIdentity
  }
}

public enum V2PresentationOperationValidationError: Error, Equatable, Sendable {
  case invalidDeadline, invalidIdentity, invalidReceipt
}

/// Only the caller's editable field baseline; it grants no public profile display lease.
public struct V2ContactAliasSnapshot: Equatable, Codable, Sendable {
  public let ownerUserID: UserID
  public let targetUserID: UserID
  public let value: V2ContactAlias?
  public init(ownerUserID: UserID, targetUserID: UserID, value: V2ContactAlias?) throws {
    guard ownerUserID != targetUserID else {
      throw V2PresentationOperationValidationError.invalidIdentity
    }
    if let value {
      guard value.ownerUserID == ownerUserID, value.targetUserID == targetUserID,
        try V2ContactAlias(
          ownerUserID: ownerUserID, targetUserID: targetUserID, remarkName: value.remarkName,
          revision: value.revision) == value
      else {
        throw V2PresentationOperationValidationError.invalidReceipt
      }
    }
    self.ownerUserID = ownerUserID
    self.targetUserID = targetUserID
    self.value = value
  }
  private enum CodingKeys: String, CodingKey { case ownerUserID, targetUserID, value }
  public init(from decoder: any Decoder) throws {
    let v = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      ownerUserID: v.decode(UserID.self, forKey: .ownerUserID),
      targetUserID: v.decode(UserID.self, forKey: .targetUserID),
      value: v.decodeIfPresent(V2ContactAlias.self, forKey: .value))
  }
}
