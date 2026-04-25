import Foundation
import Vapor

enum UserAvatarPreset: String, Codable, Content, Sendable, CaseIterable {
    case sunrise
    case ocean
    case forest
    case graphite
    case rose
    case slate
}
