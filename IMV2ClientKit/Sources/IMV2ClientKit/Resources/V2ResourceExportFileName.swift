import Foundation

/// A single filesystem component for a disposable exported copy. Unlike a
/// display name, this value explicitly grants use as a basename, never a path.
public struct V2ResourceExportFileName: Hashable, Sendable {
    public let value: String
    public init(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 255,
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw V2ResourceStorageError.invalidRecord
        }
        self.value = value
    }
}
