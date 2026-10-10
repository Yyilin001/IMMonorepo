import Foundation
import HTTPTypes
import IMV2Core
import IMV2ServerContracts
import Vapor

/// 操作接口共用的编解码与错误映射；身份、作用域和业务授权由各路由执行。
func v2DecodeOperationInput<T: Decodable>(_ request: Request) async throws -> T {
    do { return try await request.content.decode(T.self, using: JSONDecoder()) }
    catch is CancellationError { throw CancellationError() }
    catch { throw Abort(.badRequest, headers: [.cacheControl: "no-store"]) }
}

func v2EncodedOperationResponse<T: Encodable>(
    _ value: T, status: HTTPResponse.Status = .ok,
    headers: HTTPFields = [.cacheControl: "no-store", .contentType: "application/json"]
) throws -> Response {
    .init(status: status, headers: headers, body: .init(data: try JSONEncoder().encode(value)))
}

protocol V2HTTPOperationResult: Encodable, Sendable {
    var httpRetryHint: V2MessageOperationRetryHint? { get }
}

func v2RespondOperation<T: V2HTTPOperationResult>(
    _ operation: () async throws -> T
) async throws -> Response {
    do {
        let result = try await operation()
        var headers: HTTPFields = [.cacheControl: "no-store", .contentType: "application/json"]
        var status: HTTPResponse.Status = .ok
        if let hint = result.httpRetryHint {
            status = hint.reason == .rateLimited ? .tooManyRequests : .serviceUnavailable
            if let delay = hint.retryAfterMilliseconds { headers[.retryAfter] = String((delay + 999) / 1000) }
        }
        return try v2EncodedOperationResponse(result, status: status, headers: headers)
    } catch is CancellationError { throw CancellationError() }
    catch { throw Abort(.serviceUnavailable, headers: [.cacheControl: "no-store"]) }
}

extension V2MembershipRecoveryResult: V2HTTPOperationResult {
    var httpRetryHint: V2MessageOperationRetryHint? {
        if case .deferred(let hint) = self { return hint }
        return nil
    }
}

extension V2MemberAdministrationRecoveryResult: V2HTTPOperationResult {
    var httpRetryHint: V2MessageOperationRetryHint? {
        if case .deferred(let hint) = self { return hint }
        return nil
    }
}

extension V2MessageModerationRecoveryResult: V2HTTPOperationResult {
    var httpRetryHint: V2MessageOperationRetryHint? {
        if case .deferred(let hint) = self { return hint }
        return nil
    }
}

extension V2SocialOperationRecoveryResult: V2HTTPOperationResult {
    var httpRetryHint: V2MessageOperationRetryHint? {
        if case .deferred(let hint) = self { return hint }
        return nil
    }
}

extension V2AccountPreferenceRecoveryResult: V2HTTPOperationResult {
    var httpRetryHint: V2MessageOperationRetryHint? {
        if case .deferred(let hint) = self { return hint }
        return nil
    }
}

extension V2GroupCapabilityRecoveryResult: V2HTTPOperationResult {
    var httpRetryHint: V2MessageOperationRetryHint? {
        if case .deferred(let hint) = self { return hint }
        return nil
    }
}

extension V2GroupInvitationOperationRecoveryResult: V2HTTPOperationResult {
    var httpRetryHint: V2MessageOperationRetryHint? {
        if case .deferred(let hint) = self { return hint }
        return nil
    }
}

extension V2ForwardPlanRecoveryResult: V2HTTPOperationResult {
    var httpRetryHint: V2MessageOperationRetryHint? {
        if case .deferred(let hint) = self { return hint }
        return nil
    }
}

extension V2MessageMutationRecoveryResult: V2HTTPOperationResult {
    var httpRetryHint: V2MessageOperationRetryHint? {
        if case .deferred(let hint) = self { return hint }
        return nil
    }
}

extension V2MessageReactionRecoveryResult: V2HTTPOperationResult {
    var httpRetryHint: V2MessageOperationRetryHint? {
        if case .deferred(let hint) = self { return hint }
        return nil
    }
}

extension V2GroupCreationOperationResult: V2HTTPOperationResult {
    var httpRetryHint: V2MessageOperationRetryHint? {
        if case .deferred(let hint) = self { return hint }
        return nil
    }
}
