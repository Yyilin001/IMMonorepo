import Vapor

struct IMSequence: Equatable, Hashable, Sendable {
    let rawValue: UInt64

    init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(databaseValue value: Int, field: String) throws {
        guard value >= 0 else {
            throw Abort(.internalServerError, reason: "\(field) 不能为负数。")
        }
        self.rawValue = UInt64(value)
    }
}

struct IMPositiveSequence: Equatable, Hashable, Sendable {
    let rawValue: UInt64

    init(_ rawValue: UInt64, field: String) throws {
        guard rawValue > 0 else {
            throw Abort(.internalServerError, reason: "\(field) 必须是正数。")
        }
        self.rawValue = rawValue
    }

    init(databaseValue value: Int, field: String) throws {
        guard value > 0 else {
            throw Abort(.internalServerError, reason: "\(field) 必须是正数。")
        }
        self.rawValue = UInt64(value)
    }
}

func imPositiveUInt64Sequence(_ value: Int, field: String) throws -> UInt64 {
    try IMPositiveSequence(databaseValue: value, field: field).rawValue
}

func imPositiveUInt64Sequence(_ value: UInt64, field: String) throws -> UInt64 {
    try IMPositiveSequence(value, field: field).rawValue
}

func imNonNegativeUInt64Sequence(_ value: Int, field: String) throws -> UInt64 {
    try IMSequence(databaseValue: value, field: field).rawValue
}

func imIntSequence(_ value: UInt64, field: String) throws -> Int {
    guard value <= UInt64(Int.max) else {
        throw Abort(.internalServerError, reason: "\(field) 超出当前内部 Int 可表示范围。")
    }
    return Int(value)
}
