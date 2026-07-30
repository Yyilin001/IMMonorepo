import Foundation

/// Frame-safe audience page limit shared by the durable outbox and protobuf
/// adapter. One append page is one fair-scheduler quantum, so UUID payloads
/// remain well below the 64 KiB realtime frame limit without letting one large
/// group monopolize a reconnect flush.
public enum V2GroupAudienceImportLimits {
    public static let maximumMembersPerAppend = 512
}
