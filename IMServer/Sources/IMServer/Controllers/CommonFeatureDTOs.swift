import Vapor

struct UserBlockCreateRequest: Content {
    let reason: String?
}

struct UserBlockResponse: Content, Equatable {
    let blockedUserID: UUID
    let reason: String?
    let createdAt: Date
}

struct ReportCreateRequest: Content {
    let targetType: String
    let targetID: String
    let conversationID: UUID?
    let messageID: UUID?
    let reason: String
    let detail: String?
}

struct ReportResponse: Content, Equatable {
    let id: UUID
    let targetType: String
    let targetID: String
    let reporterUserID: UUID?
    let conversationID: UUID?
    let messageID: UUID?
    let reason: String
    let detail: String?
    let status: String
    let handledNote: String?
    let messageSnapshotJSON: String?
    let createdAt: Date
}

struct ReportPageQuery: Content {
    let status: String?
    let targetType: String?
    let cursor: String?
    let limit: Int?
}

struct ReportPageResponse: Content, Equatable {
    let items: [ReportResponse]
    let nextCursor: String?
    let hasMore: Bool
}

struct ReportUpdateRequest: Content {
    let status: String
    let handledNote: String?
}

struct ReportMessageSnapshot: Codable, Equatable, Sendable {
    let conversationID: UUID
    let messageID: UUID
    let senderUserID: UUID
    let serverSequence: UInt64
    let content: IMMessageContent
    let derivedState: IMMessageDerivedState
    let createdAt: Date?
}

struct PushDeviceTokenRegisterRequest: Content {
    let platform: String
    let token: String
}

struct PushDeviceTokenResponse: Content, Equatable {
    let id: String
    let platform: String
    let token: String
    let isActive: Bool
    let updatedAt: Date
}
