import Foundation
import IMClientKit
import UniformTypeIdentifiers

@MainActor
extension FileTransferManager {
    func normalizedPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func progressMessage(prefix: String, progress: FileTransferProgress) -> String {
        if let total = progress.totalBytes, total > 0 {
            let percentage = Int((Double(progress.transferredBytes) / Double(total)) * 100)
            return "\(prefix)：\(percentage)% (\(progress.transferredBytes)/\(total) 字节)"
        }
        return "\(prefix)：已传输 \(progress.transferredBytes) 字节"
    }

    static func downloadsDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static func mimeType(for fileURL: URL) -> String {
        guard let type = UTType(filenameExtension: fileURL.pathExtension),
              let mimeType = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mimeType
    }
}

extension IMTransferSnapshot {
    var imBackgroundProgress: FileTransferProgress? {
        switch state {
        case .running(let progress), .waitingForConnectivity(let progress), .cancelled(let progress):
            return progress?.progress
        case .completed, .failed:
            return nil
        }
    }
}
