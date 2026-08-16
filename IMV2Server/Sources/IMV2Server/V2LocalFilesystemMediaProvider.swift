import Crypto
import Foundation
import IMV2Core

/// Opaque authorization for one local-development upload. The HTTP adapter may
/// write only to the random staging URL; signed-target claims and the final
/// object path remain owned and revalidated by the provider actor.
public struct V2LocalFilesystemStagedUpload: Sendable {
    package let fileURL: URL
    fileprivate let mediaID: MediaID
    fileprivate let targetURL: URL
    fileprivate let contentType: String
    fileprivate let expectedByteCount: Int64
}

/// File metadata returned after a signed local-development download target has
/// been authorized. The byte edge streams this file instead of materializing
/// its contents in process memory.
public struct V2LocalFilesystemDownloadedObject: Sendable {
    package let fileURL: URL
    package let byteCount: Int64
}

/// A local-only object provider for repeatable developer and isolated-test
/// verification. It is intentionally not composed by a production runtime:
/// the URL host, TLS termination, durable object store and malware scanner
/// remain deployment-owned concerns.
///
/// The provider keeps opaque media bytes under a caller-selected private
/// directory and signs short-lived, exact-object targets. No local file URL
/// or filesystem path is returned to the IM domain or client protocol.
public actor V2LocalFilesystemMediaProvider: V2MediaObjectProvider, V2MediaUploadObjectProvider, V2MediaPurgeProvider {
    private let rootDirectory: URL
    private let targetBaseURL: URL
    private let signingKey: Data
    private let now: @Sendable () -> Date
    private var didPrepare = false

    public init(
        rootDirectory: URL,
        targetBaseURL: URL,
        signingKey: Data,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard signingKey.count >= 32,
              targetBaseURL.scheme?.lowercased() == "https",
              targetBaseURL.host != nil,
              targetBaseURL.query == nil,
              targetBaseURL.fragment == nil
        else { throw V2LocalFilesystemMediaProviderError.invalidConfiguration }
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.targetBaseURL = targetBaseURL
        self.signingKey = signingKey
        self.now = now
    }

    /// Establishes the private directory at process start and removes upload
    /// fragments left by a previous process crash. A repeated call on this
    /// provider is a no-op so it cannot delete a currently streaming upload.
    public func prepare() async throws {
        guard !didPrepare else { return }
        let rootDirectory = self.rootDirectory
        let stagingDirectory = self.stagingDirectory
        try await Self.performBlocking {
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if FileManager.default.fileExists(atPath: stagingDirectory.path) {
                try FileManager.default.removeItem(at: stagingDirectory)
            }
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        didPrepare = true
    }

    public func issueUploadTarget(
        mediaID: MediaID,
        contentType: String,
        byteCount: Int64,
        expiresAt: Date
    ) async throws -> V2MediaProviderObjectTarget {
        guard byteCount >= 0, expiresAt > now(), !contentType.isEmpty else {
            throw V2LocalFilesystemMediaProviderError.invalidTarget
        }
        _ = try objectURL(for: mediaID)
        let url = try signedTarget(
            kind: .upload,
            mediaID: mediaID,
            contentType: contentType,
            byteCount: byteCount,
            expiresAt: expiresAt
        )
        return .init(
            url: url,
            headers: ["Content-Type": contentType],
            expiresAt: expiresAt,
            expectedByteCount: byteCount
        )
    }

    public func issueDownloadTarget(mediaID: MediaID, expiresAt: Date) async throws -> V2MediaProviderObjectTarget {
        guard expiresAt > now() else { throw V2LocalFilesystemMediaProviderError.invalidTarget }
        let objectURL = try objectURL(for: mediaID)
        let byteCount = try await Self.performBlocking { () throws -> Int64 in
            guard FileManager.default.fileExists(atPath: objectURL.path) else {
                throw V2LocalFilesystemMediaProviderError.objectUnavailable
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: objectURL.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw V2LocalFilesystemMediaProviderError.objectUnavailable
            }
            return size.int64Value
        }
        let url = try signedTarget(
            kind: .download,
            mediaID: mediaID,
            contentType: nil,
            byteCount: byteCount,
            expiresAt: expiresAt
        )
        return .init(url: url, expiresAt: expiresAt, expectedByteCount: byteCount)
    }

    /// Validates the signed upload claims before the HTTP body is accepted and
    /// reserves a random file in the provider's private staging directory.
    /// The returned path does not identify the final object.
    public func beginUploadedObject(
        mediaID: MediaID,
        targetURL: URL,
        contentType: String,
        declaredByteCount: Int64
    ) async throws -> V2LocalFilesystemStagedUpload {
        let claims = try verify(targetURL: targetURL, kind: .upload, mediaID: mediaID)
        guard claims.contentType == contentType,
              claims.byteCount == declaredByteCount,
              declaredByteCount >= 0
        else { throw V2LocalFilesystemMediaProviderError.byteCountMismatch }
        let stagingDirectory = self.stagingDirectory
        try await Self.performBlocking {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return .init(
            fileURL: stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false),
            mediaID: mediaID,
            targetURL: targetURL,
            contentType: contentType,
            expectedByteCount: declaredByteCount
        )
    }

    /// Revalidates target expiry and exact byte count, then atomically moves
    /// the staged file into its immutable object location on the same volume.
    public func commitUploadedObject(
        _ upload: V2LocalFilesystemStagedUpload,
        actualByteCount: Int64
    ) async throws {
        let claims = try verify(targetURL: upload.targetURL, kind: .upload, mediaID: upload.mediaID)
        guard claims.contentType == upload.contentType,
              claims.byteCount == upload.expectedByteCount,
              actualByteCount == upload.expectedByteCount,
              isValidStagingURL(upload.fileURL)
        else { throw V2LocalFilesystemMediaProviderError.byteCountMismatch }
        let rootDirectory = self.rootDirectory
        let objectURL = try objectURL(for: upload.mediaID)
        try await Self.performBlocking {
            let attributes = try FileManager.default.attributesOfItem(atPath: upload.fileURL.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.int64Value == actualByteCount
            else { throw V2LocalFilesystemMediaProviderError.byteCountMismatch }
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: upload.fileURL.path
            )
            try FileManager.default.moveItem(at: upload.fileURL, to: objectURL)
        }
    }

    public func discardUploadedObject(_ upload: V2LocalFilesystemStagedUpload) async {
        guard isValidStagingURL(upload.fileURL) else { return }
        let fileURL = upload.fileURL
        try? await Self.performBlocking {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Accepts bytes only when they are presented with the exact signed local
    /// upload target. This is used by local HTTP-free tests; a production
    /// object edge must validate its own provider-native target instead.
    public func storeUploadedObject(
        mediaID: MediaID,
        targetURL: URL,
        contentType: String,
        bytes: Data
    ) async throws {
        let upload = try await beginUploadedObject(
            mediaID: mediaID,
            targetURL: targetURL,
            contentType: contentType,
            declaredByteCount: Int64(bytes.count)
        )
        do {
            try await Self.performBlocking {
                try bytes.write(to: upload.fileURL, options: .withoutOverwriting)
            }
            try await commitUploadedObject(upload, actualByteCount: Int64(bytes.count))
        } catch {
            await discardUploadedObject(upload)
            throw error
        }
    }

    public func downloadedObject(
        mediaID: MediaID,
        targetURL: URL
    ) async throws -> V2LocalFilesystemDownloadedObject {
        let claims = try verify(targetURL: targetURL, kind: .download, mediaID: mediaID)
        let objectURL = try objectURL(for: mediaID)
        let byteCount = try await Self.performBlocking { () throws -> Int64 in
            guard FileManager.default.fileExists(atPath: objectURL.path) else {
                throw V2LocalFilesystemMediaProviderError.objectUnavailable
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: objectURL.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.int64Value == claims.byteCount
            else { throw V2LocalFilesystemMediaProviderError.objectUnavailable }
            return size.int64Value
        }
        return .init(fileURL: objectURL, byteCount: byteCount)
    }

    /// Reads bytes only when they are presented with the exact signed local
    /// download target. The returned data is intended solely for a local
    /// object-edge test, never for chat event serialization.
    public func readDownloadedObject(mediaID: MediaID, targetURL: URL) async throws -> Data {
        let object = try await downloadedObject(mediaID: mediaID, targetURL: targetURL)
        return try await Self.performBlocking {
            try Data(contentsOf: object.fileURL, options: [.mappedIfSafe])
        }
    }

    public func purge(mediaID: MediaID) async throws {
        let objectURL = try objectURL(for: mediaID)
        try await Self.performBlocking {
            guard FileManager.default.fileExists(atPath: objectURL.path) else { return }
            try FileManager.default.removeItem(at: objectURL)
        }
    }

    /// Development-only inspection hook used by `V2LocalEICARMediaScanner`.
    /// Missing objects are retryable scanner failures, not clean scans.
    public func localBytesForScanning(mediaID: MediaID) async throws -> Data {
        let objectURL = try objectURL(for: mediaID)
        return try await Self.performBlocking {
            guard FileManager.default.fileExists(atPath: objectURL.path) else {
                throw V2LocalFilesystemMediaProviderError.objectUnavailable
            }
            return try Data(contentsOf: objectURL, options: [.mappedIfSafe])
        }
    }

    private func signedTarget(
        kind: TargetKind,
        mediaID: MediaID,
        contentType: String?,
        byteCount: Int64,
        expiresAt: Date
    ) throws -> URL {
        let milliseconds = Int64((expiresAt.timeIntervalSince1970 * 1_000).rounded(.towardZero))
        let claims = TargetClaims(
            kind: kind.rawValue,
            mediaID: mediaID.rawValue,
            contentType: contentType,
            byteCount: byteCount,
            expiresAtMilliseconds: milliseconds
        )
        let payload = try JSONEncoder().encode(claims)
        let encodedPayload = Self.base64URL(payload)
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(encodedPayload.utf8),
            using: SymmetricKey(data: signingKey)
        )
        guard var components = URLComponents(url: targetBaseURL, resolvingAgainstBaseURL: false) else {
            throw V2LocalFilesystemMediaProviderError.invalidTarget
        }
        components.path += "/v2/local-media/" + kind.rawValue + "/" + mediaID.rawValue
        components.queryItems = [
            .init(name: "target", value: "v2lm1.\(encodedPayload).\(Self.base64URL(Data(signature)))"),
        ]
        guard let url = components.url else { throw V2LocalFilesystemMediaProviderError.invalidTarget }
        return url
    }

    private func verify(targetURL: URL, kind: TargetKind, mediaID: MediaID) throws -> TargetClaims {
        guard targetURL.scheme?.lowercased() == targetBaseURL.scheme?.lowercased(),
              targetURL.host == targetBaseURL.host,
              targetURL.port == targetBaseURL.port,
              let token = URLComponents(url: targetURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "target" })?
                .value
        else { throw V2LocalFilesystemMediaProviderError.invalidTarget }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "v2lm1",
              let payload = Self.decodeBase64URL(String(parts[1])),
              let signature = Self.decodeBase64URL(String(parts[2])),
              HMAC<SHA256>.isValidAuthenticationCode(
                signature,
                authenticating: Data(parts[1].utf8),
                using: SymmetricKey(data: signingKey)
              ),
              let claims = try? JSONDecoder().decode(TargetClaims.self, from: payload),
              claims.kind == kind.rawValue,
              claims.mediaID == mediaID.rawValue,
              Double(claims.expiresAtMilliseconds) > now().timeIntervalSince1970 * 1_000
        else { throw V2LocalFilesystemMediaProviderError.invalidTarget }
        return claims
    }

    private func objectURL(for mediaID: MediaID) throws -> URL {
        guard UUID(uuidString: mediaID.rawValue) != nil else {
            throw V2LocalFilesystemMediaProviderError.invalidMediaID
        }
        return rootDirectory.appendingPathComponent(mediaID.rawValue, isDirectory: false)
    }

    private var stagingDirectory: URL {
        rootDirectory.appendingPathComponent(".upload-staging", isDirectory: true)
    }

    private func isValidStagingURL(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        return standardized.deletingLastPathComponent() == stagingDirectory.standardizedFileURL
            && UUID(uuidString: standardized.lastPathComponent) != nil
    }

    private nonisolated static func performBlocking<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await Task.detached(priority: .utility, operation: operation).value
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func decodeBase64URL(_ value: String) -> Data? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
    }

    private enum TargetKind: String { case upload, download }
    private struct TargetClaims: Codable {
        let kind: String
        let mediaID: String
        let contentType: String?
        let byteCount: Int64
        let expiresAtMilliseconds: Int64
    }
}

public enum V2LocalFilesystemMediaProviderError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidMediaID
    case invalidTarget
    case byteCountMismatch
    case objectUnavailable
}

/// Local scanner for a real, harmless EICAR test signature. It is useful for
/// exercising the `passed` and `failed` scan-state transitions without a
/// third-party daemon, but it is not malware protection and must never be
/// selected for a production deployment.
public struct V2LocalEICARMediaScanner: V2MediaScanProvider, Sendable {
    private let provider: V2LocalFilesystemMediaProvider

    public init(provider: V2LocalFilesystemMediaProvider) { self.provider = provider }

    public func scan(mediaID: MediaID) async throws -> V2MediaScanResult {
        let bytes = try await provider.localBytesForScanning(mediaID: mediaID)
        return bytes.range(of: Self.eicarTestSignature) == nil ? .passed : .failed
    }

    private static let eicarTestSignature = Data(
        "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*".utf8
    )
}
