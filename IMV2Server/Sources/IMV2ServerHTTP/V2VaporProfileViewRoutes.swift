import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// 用户资料视图查询路由。
///
/// 该接口以 POST 批量查询为主，对外隐藏了内部查询上下文细节。
/// 输入必须显式声明 context；当 context 为 `room` 时必须带 roomID。
public struct V2VaporProfileViewRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let profiles: V2ProfileViewService

    /// 初始化路由。
    ///
    /// - Parameters:
    ///   - authenticator: 鉴权器，获取调用者身份。
    ///   - profiles: 资料视图读取服务。
    public init(authenticator: any V2GatewayAuthenticator, profiles: V2ProfileViewService) {
        self.authenticator = authenticator
        self.profiles = profiles
    }

    /// 注册 `POST /v2/profile-views/batch`。
    ///
    /// 服务端对每个 key 做上下文权限校验后返回查询结果。
    /// 找不到数据时返回可见性标记，而不是泄露不同错误语义。
    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "profile-views", "batch") { request async throws -> Response in
            let actor = try await authenticate(request)
            let input = try request.content.decode(V2ProfileViewBatchHTTPRequest.self)
            let keys: [V2ProfileViewLookupKey]
            do {
                keys = try input.keys.map { try $0.lookupKey() }
                let read = try V2ProfileViewReadRequest(actorUserID: actor.userID, keys: keys)
                let results = try await profiles.read(read)
                return try noStoreJSONResponse(.init(results: results.map(V2ProfileViewBatchHTTPResult.init)))
            } catch V2ProfileViewReadError.invalidRequest {
                throw Abort(.badRequest)
            } catch V2ProfileViewReadError.corruptPersistenceState {
                throw Abort(.serviceUnavailable)
            }
        }
    }

    /// 解析鉴权连接。
    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }

    /// 统一 no-store JSON 响应。
    private func noStoreJSONResponse(_ result: V2ProfileViewBatchHTTPResponse) throws -> Response {
        let data = try JSONEncoder().encode(result)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }
}

/// 批量 profile-view 请求体。
public struct V2ProfileViewBatchHTTPRequest: Content, Sendable {
    /// 查询 key 列表。
    public let keys: [V2ProfileViewLookupHTTPKey]

    public init(keys: [V2ProfileViewLookupHTTPKey]) {
        self.keys = keys
    }
}

/// 单条查询 key，携带显示上下文。
public struct V2ProfileViewLookupHTTPKey: Content, Sendable {
    /// 目标用户 ID。
    public let userID: String
    /// 查询上下文：`direct`、`relationship`、`room`。
    ///
    /// - Note: context 为 `room` 时，`roomID` 必须存在。
    public let context: String
    /// room 上下文时必填。
    public let roomID: String?

    public init(userID: String, context: String = "direct", roomID: String? = nil) {
        self.userID = userID
        self.context = context
        self.roomID = roomID
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case context
        case roomID = "room_id"
    }

    fileprivate func lookupKey() throws -> V2ProfileViewLookupKey {
        let userID = try UserID(userID)
        switch context {
        case "direct":
            guard roomID == nil else { throw V2ProfileViewReadError.invalidRequest }
            return .init(userID: userID, context: .directConversation)
        case "relationship":
            guard roomID == nil else { throw V2ProfileViewReadError.invalidRequest }
            return .init(userID: userID, context: .relationship)
        case "room":
            guard let roomID else { throw V2ProfileViewReadError.invalidRequest }
            return .init(userID: userID, context: .room(try RoomID(roomID)))
        default:
            throw V2ProfileViewReadError.invalidRequest
        }
    }
}

/// 批量 profile-view 响应体。
public struct V2ProfileViewBatchHTTPResponse: Content, Sendable {
    /// 查询结果。
    public let results: [V2ProfileViewBatchHTTPResult]

    public init(results: [V2ProfileViewBatchHTTPResult]) {
        self.results = results
    }
}

/// 单条 profile-view 返回结构。
public struct V2ProfileViewBatchHTTPResult: Content, Sendable {
    /// 目标用户。
    public let userID: String
    /// 请求上下文。
    public let context: String
    /// room context 的 room id。
    public let roomID: String?
    /// 对外可见性。`true` 表示未命中或不可见。
    public let unavailable: Bool
    /// 账号 handle。
    public let handle: String?
    /// 显示名。
    public let displayName: String?
    /// 账号类型。
    public let accountKind: V2AccountKind?
    /// 头像 mediaID。
    public let avatarMediaID: String?
    /// 状态。
    public let state: String?
    /// 版本。
    public let revision: UInt64?
    /// 可见性版本。
    public let visibilityRevision: UInt64?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case context
        case roomID = "room_id"
        case unavailable
        case handle
        case displayName = "display_name"
        case accountKind = "account_kind"
        case avatarMediaID = "avatar_media_id"
        case state
        case revision
        case visibilityRevision = "visibility_revision"
    }

    init(_ result: V2ProfileViewLookupResult) {
        switch result {
        case .unavailable(let key):
            userID = key.userID.rawValue
            context = Self.context(for: key.context)
            roomID = Self.roomID(for: key.context)
            unavailable = true
            handle = nil
            displayName = nil
            accountKind = nil
            avatarMediaID = nil
            state = nil
            revision = nil
            visibilityRevision = nil
        case .profile(let key, let view):
            userID = key.userID.rawValue
            context = Self.context(for: key.context)
            roomID = Self.roomID(for: key.context)
            unavailable = false
            handle = view.publicIdentity?.handle.rawValue
            displayName = view.publicIdentity?.displayName
            accountKind = view.publicIdentity?.accountKind
            avatarMediaID = view.avatar?.mediaID.rawValue
            state = view.state.rawValue
            revision = view.revision.rawValue
            visibilityRevision = view.visibilityRevision.rawValue
        }
    }

    private static func roomID(for context: V2ProfileViewContext) -> String? {
        switch context {
        case .directConversation: nil
        case .relationship: nil
        case .room(let roomID): roomID.rawValue
        }
    }

    private static func context(for context: V2ProfileViewContext) -> String {
        switch context {
        case .directConversation: "direct"
        case .relationship: "relationship"
        case .room: "room"
        }
    }
}
