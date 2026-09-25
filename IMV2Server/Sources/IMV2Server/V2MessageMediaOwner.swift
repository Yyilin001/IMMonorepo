import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 单个房间归属所需的媒体数据库与提供方组合。
public struct V2MessageMediaOwner: Sendable {
    /// 归属侧数据库。
    let database: any Database
    /// 归属侧媒体提供方。
    let provider: any V2MediaObjectProvider

    /// 组合数据库与提供方。
    ///
    /// - Parameters:
    ///   - database: 归属侧数据库。
    ///   - provider: 归属侧媒体提供方。
    public init(database: any Database, provider: any V2MediaObjectProvider) {
        self.database = database; self.provider = provider
    }
}
