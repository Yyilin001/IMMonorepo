import Fluent
import Vapor

struct IMGroupMemberLimitConfiguration: Sendable {
    static let environmentKey = "IM_GROUP_MEMBER_LIMIT"
    static let defaultLimit = 500

    let limit: Int

    static func load(from _: Environment) -> IMGroupMemberLimitConfiguration {
        IMGroupMemberLimitConfiguration(
            limit: max(2, Environment.get(environmentKey).flatMap(Int.init(_:)) ?? defaultLimit)
        )
    }
}

enum IMGroupMemberLimitGuard {
    static func validateGroupMemberCount(
        _ count: Int,
        configuration: IMGroupMemberLimitConfiguration = .load(from: .development)
    ) throws {
        guard count <= configuration.limit else {
            throw Abort(.badRequest, reason: "小群成员数不能超过 \(configuration.limit) 人。")
        }
    }
}
