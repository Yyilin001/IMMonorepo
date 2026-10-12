import Foundation
import IMV2ActorContracts

/// Identifies all SQL sessions opened by one native Host process. This marker
/// is an observation key, never evidence of process exclusion or permission
/// to publish a successor. An exclusion backend must first stop reconnection
/// and then settle the marked backends on every database the Host can access.
public enum V2ActorPostgresSessionIdentity {
    public static func applicationName(_ host: V2ActorHostIdentity) -> String {
        // PostgreSQL truncates application_name at 63 bytes. The complete
        // incarnation fits in 37 ASCII bytes; no process identity is truncated.
        "imva:" + host.incarnationID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
