import Foundation

public enum V2ResourceUploadSessionState: String, Codable, Sendable {
    case created, uploading, finalizing, completed, cancelled, expired, failed
}

public enum V2ResourceState: String, Codable, Sendable {
    case pending, verifying, scanning, processing, ready, rejected
    case deletionPending = "deletion_pending"
    case deleted
}

/// 上传准入请求；当前 actor/device 从认证会话取得，供应商信息不进入请求。
public struct V2ResourceUploadRequest: Equatable, Codable, Sendable {
    public let operationID: MediaUploadOperationID
    public let mediaID: MediaID
    public let usage: V2ResourceUsage
    public let contentType: String
    public let byteCount: Int64
    public let checksum: V2ResourceChecksum
    public let clientModes: [V2ResourceTransferMode]

    public init(operationID: MediaUploadOperationID, mediaID: MediaID, usage: V2ResourceUsage,
                contentType: String, byteCount: Int64, checksum: V2ResourceChecksum,
                clientModes: [V2ResourceTransferMode] = [.httpPut]) throws {
        guard V2ResourceMetadataValidation.contentType(contentType), byteCount > 0,
              !clientModes.isEmpty, clientModes.count <= V2ResourceTransferMode.allCases.count,
              Set(clientModes).count == clientModes.count, clientModes.allSatisfy(\.isUpload)
        else { throw V2ResourceValidationError.invalidUploadRequest }
        self.operationID = operationID
        self.mediaID = mediaID
        self.usage = usage
        self.contentType = contentType
        self.byteCount = byteCount
        self.checksum = checksum
        self.clientModes = clientModes.sorted { $0.rawValue < $1.rawValue }
    }

    private enum CodingKeys: String, CodingKey { case operationID, mediaID, usage, contentType, byteCount, checksum, clientModes }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(operationID: values.decode(MediaUploadOperationID.self, forKey: .operationID),
                      mediaID: values.decode(MediaID.self, forKey: .mediaID), usage: values.decode(V2ResourceUsage.self, forKey: .usage),
                      contentType: values.decode(String.self, forKey: .contentType), byteCount: values.decode(Int64.self, forKey: .byteCount),
                      checksum: values.decode(V2ResourceChecksum.self, forKey: .checksum), clientModes: values.decode([V2ResourceTransferMode].self, forKey: .clientModes))
    }
}

/// 分片进度的有界回执。receipt 只标识确认结果，不得包含上传目标或管理凭据。
public struct V2ResourceUploadPart: Equatable, Codable, Sendable {
    public let number: Int
    public let byteCount: Int64
    public let checksum: V2ResourceChecksum?
    public let receipt: String?

    public init(number: Int, byteCount: Int64, checksum: V2ResourceChecksum? = nil, receipt: String? = nil) throws {
        guard (1...10_000).contains(number), byteCount > 0,
              receipt.map({ !$0.isEmpty && $0.utf8.count <= 4_096 && $0.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f } }) ?? true
        else { throw V2ResourceValidationError.invalidPart }
        self.number = number
        self.byteCount = byteCount
        self.checksum = checksum
        self.receipt = receipt
    }

    private enum CodingKeys: String, CodingKey { case number, byteCount, checksum, receipt }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(number: values.decode(Int.self, forKey: .number), byteCount: values.decode(Int64.self, forKey: .byteCount),
                      checksum: values.decodeIfPresent(V2ResourceChecksum.self, forKey: .checksum), receipt: values.decodeIfPresent(String.self, forKey: .receipt))
    }
}

/// 服务端确认的上传与处理状态；completed 只表示上传结束，交接消息还要求 resourceState 为 ready。
public struct V2ResourceUploadSession: Equatable, Codable, Sendable {
    public let locator: V2ResourceUploadLocator
    public let mediaID: MediaID
    public let generation: Int64
    public let state: V2ResourceUploadSessionState
    public let resourceState: V2ResourceState
    public let expiresAtUnixMilliseconds: Int64
    public let bindableUntilUnixMilliseconds: Int64?
    public let confirmedParts: [V2ResourceUploadPart]
    public let retryNotBeforeUnixMilliseconds: Int64?

    public var expiresAt: Date { V2ResourceTime.date(expiresAtUnixMilliseconds) }
    public var bindableUntil: Date? { bindableUntilUnixMilliseconds.map(V2ResourceTime.date) }
    public var retryNotBefore: Date? { retryNotBeforeUnixMilliseconds.map(V2ResourceTime.date) }

    public init(locator: V2ResourceUploadLocator, mediaID: MediaID, generation: Int64,
                state: V2ResourceUploadSessionState, resourceState: V2ResourceState,
                expiresAt: Date, bindableUntil: Date? = nil,
                confirmedParts: [V2ResourceUploadPart] = [], retryNotBefore: Date? = nil) throws {
        try self.init(locator: locator, mediaID: mediaID, generation: generation, state: state, resourceState: resourceState,
                      expiresAtUnixMilliseconds: V2ResourceTime.milliseconds(expiresAt),
                      bindableUntilUnixMilliseconds: bindableUntil.map(V2ResourceTime.milliseconds), confirmedParts: confirmedParts,
                      retryNotBeforeUnixMilliseconds: retryNotBefore.map(V2ResourceTime.milliseconds))
    }

    private init(locator: V2ResourceUploadLocator, mediaID: MediaID, generation: Int64,
                 state: V2ResourceUploadSessionState, resourceState: V2ResourceState,
                 expiresAtUnixMilliseconds: Int64, bindableUntilUnixMilliseconds: Int64?,
                 confirmedParts: [V2ResourceUploadPart], retryNotBeforeUnixMilliseconds: Int64?) throws {
        guard generation > 0, confirmedParts.count <= 10_000,
              Set(confirmedParts.map(\.number)).count == confirmedParts.count,
              resourceState != .ready || (state == .completed && bindableUntilUnixMilliseconds != nil)
        else { throw V2ResourceValidationError.invalidUploadSession }
        if state == .cancelled || state == .expired || state == .failed {
            guard resourceState != .ready, bindableUntilUnixMilliseconds == nil
            else { throw V2ResourceValidationError.invalidUploadSession }
        }
        self.locator = locator
        self.mediaID = mediaID
        self.generation = generation
        self.state = state
        self.resourceState = resourceState
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
        self.bindableUntilUnixMilliseconds = bindableUntilUnixMilliseconds
        self.confirmedParts = confirmedParts.sorted { $0.number < $1.number }
        self.retryNotBeforeUnixMilliseconds = retryNotBeforeUnixMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case locator, mediaID, generation, state, resourceState, expiresAtUnixMilliseconds
        case bindableUntilUnixMilliseconds, confirmedParts, retryNotBeforeUnixMilliseconds
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(locator: values.decode(V2ResourceUploadLocator.self, forKey: .locator), mediaID: values.decode(MediaID.self, forKey: .mediaID),
                      generation: values.decode(Int64.self, forKey: .generation), state: values.decode(V2ResourceUploadSessionState.self, forKey: .state),
                      resourceState: values.decode(V2ResourceState.self, forKey: .resourceState),
                      expiresAtUnixMilliseconds: values.decode(Int64.self, forKey: .expiresAtUnixMilliseconds),
                      bindableUntilUnixMilliseconds: values.decodeIfPresent(Int64.self, forKey: .bindableUntilUnixMilliseconds),
                      confirmedParts: values.decode([V2ResourceUploadPart].self, forKey: .confirmedParts),
                      retryNotBeforeUnixMilliseconds: values.decodeIfPresent(Int64.self, forKey: .retryNotBeforeUnixMilliseconds))
    }
}

/// 刷新同一会话的目标，generation 是条件，不是授权证明。
public struct V2ResourceUploadTargetsRequest: Equatable, Codable, Sendable {
    public let locator: V2ResourceUploadLocator
    public let generation: Int64
    public let partNumbers: [Int]
    public let background: Bool

    public init(locator: V2ResourceUploadLocator, generation: Int64, partNumbers: [Int] = [], background: Bool = false) throws {
        guard generation > 0, partNumbers.count <= 16, Set(partNumbers).count == partNumbers.count,
              partNumbers.allSatisfy({ (1...10_000).contains($0) })
        else { throw V2ResourceValidationError.invalidPart }
        self.background = background
        self.locator = locator
        self.generation = generation
        self.partNumbers = partNumbers.sorted()
    }

    private enum CodingKeys: String, CodingKey { case locator, generation, partNumbers, background }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(locator: values.decode(V2ResourceUploadLocator.self, forKey: .locator), generation: values.decode(Int64.self, forKey: .generation),
                      partNumbers: values.decode([Int].self, forKey: .partNumbers), background: values.decode(Bool.self, forKey: .background))
    }
}

/// finalize 的稳定操作身份是 (locator, generation, finalize)，重试不能改变分片事实。
public struct V2ResourceUploadFinalizeRequest: Equatable, Codable, Sendable {
    public let locator: V2ResourceUploadLocator
    public let generation: Int64
    public let parts: [V2ResourceUploadPart]

    public init(locator: V2ResourceUploadLocator, generation: Int64, parts: [V2ResourceUploadPart] = []) throws {
        guard generation > 0, parts.count <= 10_000, Set(parts.map(\.number)).count == parts.count
        else { throw V2ResourceValidationError.invalidPart }
        self.locator = locator
        self.generation = generation
        self.parts = parts.sorted { $0.number < $1.number }
    }

    private enum CodingKeys: String, CodingKey { case locator, generation, parts }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(locator: values.decode(V2ResourceUploadLocator.self, forKey: .locator), generation: values.decode(Int64.self, forKey: .generation),
                      parts: values.decode([V2ResourceUploadPart].self, forKey: .parts))
    }
}

public struct V2ResourceUploadCancelRequest: Equatable, Codable, Sendable {
    public let locator: V2ResourceUploadLocator
    public let generation: Int64

    public init(locator: V2ResourceUploadLocator, generation: Int64) throws {
        guard generation > 0 else { throw V2ResourceValidationError.invalidUploadSession }
        self.locator = locator
        self.generation = generation
    }

    private enum CodingKeys: String, CodingKey { case locator, generation }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(locator: values.decode(V2ResourceUploadLocator.self, forKey: .locator), generation: values.decode(Int64.self, forKey: .generation))
    }
}
