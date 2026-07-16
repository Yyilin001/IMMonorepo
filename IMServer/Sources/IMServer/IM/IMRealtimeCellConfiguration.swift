import Foundation
import Vapor

struct IMRealtimeCellConfiguration: Sendable, Equatable {
    static let defaultCellID = "default"

    let cellID: String

    static let `default` = IMRealtimeCellConfiguration(cellID: defaultCellID)

    init(cellID: String) {
        self.cellID = cellID
    }

    static func load(from environment: Environment) throws -> IMRealtimeCellConfiguration {
        let rawCellID = Environment.get("IM_REALTIME_CELL_ID")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cellID: String
        if let rawCellID, !rawCellID.isEmpty {
            cellID = rawCellID
        } else {
            cellID = defaultCellID
        }
        guard isValid(cellID: cellID) else {
            throw Abort(
                .internalServerError,
                reason: "IM_REALTIME_CELL_ID must be 1-63 lowercase letters, numbers, hyphens, or underscores, starting with a letter or number."
            )
        }
        return IMRealtimeCellConfiguration(cellID: cellID)
    }

    static func isValid(cellID: String) -> Bool {
        guard cellID.count <= 63,
              let first = cellID.unicodeScalars.first,
              isLowercaseASCIIAlphaNumeric(first)
        else {
            return false
        }
        return cellID.unicodeScalars.allSatisfy { scalar in
            isLowercaseASCIIAlphaNumeric(scalar) || scalar == "-" || scalar == "_"
        }
    }

    private static func isLowercaseASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

struct IMRealtimeRedisKeyspace: Sendable, Equatable {
    private let prefix: String

    init(cellID: String) {
        self.prefix = "im:cell:\(cellID)"
    }

    func key(_ suffix: String) -> String {
        "\(prefix):\(suffix)"
    }

    /// Produces a key whose Redis Cluster hash slot is determined only by the
    /// supplied stable owner. Use this only when every operation is scoped to
    /// that owner, such as a single conversation's fixed-window limiter.
    func key(hashedBy stableOwner: String, suffix: String) -> String {
        "\(prefix):{\(stableOwner)}:\(suffix)"
    }
}
