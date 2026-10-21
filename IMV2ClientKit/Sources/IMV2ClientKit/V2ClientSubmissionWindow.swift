import Foundation

/// Keep locally minted deadlines inside the server's maximum window even when
/// the device clock is slightly ahead. This only shortens a new user action;
/// persisted commands and server-issued admissions retain their original cutoff.
enum V2ClientSubmissionWindow {
    static let clockSkewAllowanceMilliseconds: UInt64 = 5_000
    static func milliseconds(maximum: UInt64) -> UInt64 {
        precondition(maximum > clockSkewAllowanceMilliseconds)
        return maximum - clockSkewAllowanceMilliseconds
    }
    static let confirmationMilliseconds = milliseconds(maximum: 120_000)
    static let confirmationSeconds = Double(confirmationMilliseconds) / 1_000
}
