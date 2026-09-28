import Foundation
import IMV2Core

public enum V2ClientCommandError: Error, Equatable, Sendable {
    /// 内容不满足入队条件，包括无文本且无媒体、媒体或提及超量及重复。
    case invalidText
    /// 相同客户端命令标识对应的内容冲突。
    case commandConflict
    /// 请求修改的命令不存在或已不处于待处理状态，具体由存储操作决定。
    case commandNotPending
}
