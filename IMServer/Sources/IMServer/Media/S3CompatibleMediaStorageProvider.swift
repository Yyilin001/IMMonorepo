#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Vapor

struct S3CompatibleMediaStorageProvider: MediaStorageProvider {
    struct Configuration: Sendable {
        let endpoint: URL
        let bucket: String
        let region: String
        let accessKeyID: String
        let secretAccessKey: String
        let forcePathStyle: Bool

        static func load(from environment: Environment) throws -> Configuration {
            guard let endpointRaw = Environment.get("MEDIA_STORAGE_S3_ENDPOINT"),
                  let endpoint = URL(string: endpointRaw),
                  let bucket = Environment.get("MEDIA_STORAGE_S3_BUCKET"),
                  let accessKeyID = Environment.get("MEDIA_STORAGE_S3_ACCESS_KEY_ID"),
                  let secretAccessKey = Environment.get("MEDIA_STORAGE_S3_SECRET_ACCESS_KEY")
            else {
                throw Abort(.internalServerError, reason: "S3 媒体存储配置不完整。")
            }

            let region = Environment.get("MEDIA_STORAGE_S3_REGION") ?? "us-east-1"
            let forcePathStyle = (Environment.get("MEDIA_STORAGE_S3_FORCE_PATH_STYLE") ?? "true") == "true"
            return Configuration(
                endpoint: endpoint,
                bucket: bucket,
                region: region,
                accessKeyID: accessKeyID,
                secretAccessKey: secretAccessKey,
                forcePathStyle: forcePathStyle
            )
        }
    }

    private let app: Application
    private let configuration: Configuration

    init(app: Application, configuration: Configuration) {
        if app.mediaStorageRootDirectory == nil {
            app.mediaStorageRootDirectory = LocalDiskMediaStorageProvider.makeDefaultRootDirectory(for: app.environment)
        }
        self.app = app
        self.configuration = configuration
    }

    func prepareStorage() async throws {
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    }

    func createUploadSession(
        for ownerUserID: UUID,
        kind: IMMediaAssetKind,
        mimeType: String,
        byteSize: Int64,
        filename: String,
        width: Int?,
        height: Int?,
        durationMillis: Int?,
        previewAssetID: String?
    ) async throws -> MediaStorageService.UploadSession {
        let normalizedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFilename.isEmpty else {
            throw Abort(.badRequest, reason: "文件名不能为空。")
        }
        guard byteSize > 0 else {
            throw Abort(.badRequest, reason: "文件大小必须大于 0。")
        }

        let uploadID = UUID().uuidString.lowercased()
        let session = MediaStorageService.UploadSession(
            uploadID: uploadID,
            ownerUserID: ownerUserID,
            kind: kind,
            mimeType: mimeType,
            byteSize: byteSize,
            filename: normalizedFilename,
            width: width,
            height: height,
            durationMillis: durationMillis,
            previewAssetID: previewAssetID,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(15 * 60)
        )
        try persist(session)
        return session
    }

    func writeUploadChunk(
        uploadID: String,
        for ownerUserID: UUID,
        body: Data
    ) async throws {
        let fileManager = FileManager.default
        let session = try requireSession(uploadID: uploadID, ownerUserID: ownerUserID)
        guard Int64(body.count) == session.byteSize else {
            throw Abort(.badRequest, reason: "上传文件大小与预期不一致。")
        }

        let uploadDirectory = sessionDirectory(for: session.uploadID)
        try fileManager.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
        try body.write(to: chunkFileURL(for: session.uploadID), options: .atomic)
    }

    func completeUpload(
        uploadID: String,
        for ownerUserID: UUID
    ) async throws -> IMMediaAsset {
        let session = try requireSession(uploadID: uploadID, ownerUserID: ownerUserID)
        let chunkURL = chunkFileURL(for: session.uploadID)
        guard FileManager.default.fileExists(atPath: chunkURL.path) else {
            throw Abort(.badRequest, reason: "上传内容不存在，无法完成上传。")
        }

        let body = try Data(contentsOf: chunkURL)
        guard Int64(body.count) == session.byteSize else {
            throw Abort(.badRequest, reason: "上传文件大小与预期不一致。")
        }

        let storedAsset = MediaStorageService.StoredAsset(
            assetID: session.uploadID,
            ownerUserID: ownerUserID,
            kind: session.kind,
            mimeType: session.mimeType,
            byteSize: session.byteSize,
            filename: session.filename,
            width: session.width,
            height: session.height,
            durationMillis: session.durationMillis,
            previewAssetID: session.previewAssetID,
            createdAt: session.createdAt,
            storedAt: Date()
        )

        try await putObject(data: body, key: objectKey(for: storedAsset))
        try await putObject(data: try JSONEncoder().encode(storedAsset), key: metadataKey(for: storedAsset))
        try removeSessionFiles(uploadID: session.uploadID)

        return IMMediaAsset(
            assetID: storedAsset.assetID,
            kind: storedAsset.kind,
            mimeType: storedAsset.mimeType,
            byteSize: storedAsset.byteSize,
            filename: storedAsset.filename,
            width: storedAsset.width,
            height: storedAsset.height,
            durationMillis: storedAsset.durationMillis,
            previewAssetID: storedAsset.previewAssetID
        )
    }

    func assetExists(ownerUserID: UUID, assetID: String) async -> Bool {
        let metadata = MediaStorageService.StoredAsset(
            assetID: assetID,
            ownerUserID: ownerUserID,
            kind: .file,
            mimeType: "application/octet-stream",
            byteSize: 0,
            filename: "",
            width: nil,
            height: nil,
            durationMillis: nil,
            previewAssetID: nil,
            createdAt: .distantPast,
            storedAt: .distantPast
        )
        do {
            _ = try await objectData(for: metadataKey(for: metadata))
            return true
        } catch {
            return false
        }
    }

    func storedAsset(ownerUserID: UUID, assetID: String) async throws -> MediaStorageService.StoredAsset {
        let placeholder = MediaStorageService.StoredAsset(
            assetID: assetID,
            ownerUserID: ownerUserID,
            kind: .file,
            mimeType: "application/octet-stream",
            byteSize: 0,
            filename: "",
            width: nil,
            height: nil,
            durationMillis: nil,
            previewAssetID: nil,
            createdAt: .distantPast,
            storedAt: .distantPast
        )
        let metadataData = try await objectData(for: metadataKey(for: placeholder))
        return try JSONDecoder().decode(MediaStorageService.StoredAsset.self, from: metadataData)
    }

    func storedAssetFile(ownerUserID: UUID, assetID: String) async throws -> MediaStorageService.StoredAssetFile {
        let metadata = try await storedAsset(ownerUserID: ownerUserID, assetID: assetID)
        let data = try await objectData(for: objectKey(for: metadata))
        let fileURL = downloadCacheDirectory
            .appendingPathComponent(metadata.ownerUserID.uuidString, isDirectory: true)
            .appendingPathComponent("\(metadata.assetID).bin", isDirectory: false)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return MediaStorageService.StoredAssetFile(metadata: metadata, fileURL: fileURL, data: data)
    }

    private var rootDirectory: URL {
        app.mediaStorageRootDirectory ?? LocalDiskMediaStorageProvider.makeDefaultRootDirectory(for: app.environment)
    }

    private var sessionsDirectory: URL {
        rootDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    private var downloadCacheDirectory: URL {
        rootDirectory.appendingPathComponent("downloads", isDirectory: true)
    }

    private func sessionDirectory(for uploadID: String) -> URL {
        sessionsDirectory.appendingPathComponent(uploadID, isDirectory: true)
    }

    private func sessionMetadataURL(for uploadID: String) -> URL {
        sessionDirectory(for: uploadID).appendingPathComponent("session.json", isDirectory: false)
    }

    private func chunkFileURL(for uploadID: String) -> URL {
        sessionDirectory(for: uploadID).appendingPathComponent("chunk.bin", isDirectory: false)
    }

    private func persist(_ session: MediaStorageService.UploadSession) throws {
        let directory = sessionDirectory(for: session.uploadID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: sessionMetadataURL(for: session.uploadID), options: .atomic)
    }

    private func requireSession(uploadID: String, ownerUserID: UUID) throws -> MediaStorageService.UploadSession {
        let session = try loadSession(uploadID: uploadID)
        guard session.ownerUserID == ownerUserID else {
            throw Abort(.notFound, reason: "上传会话不存在。")
        }
        guard session.expiresAt > Date() else {
            try? removeSessionFiles(uploadID: uploadID)
            throw Abort(.gone, reason: "上传会话已过期。")
        }
        return session
    }

    private func loadSession(uploadID: String) throws -> MediaStorageService.UploadSession {
        let metadataURL = sessionMetadataURL(for: uploadID)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw Abort(.notFound, reason: "上传会话不存在。")
        }
        return try JSONDecoder().decode(MediaStorageService.UploadSession.self, from: Data(contentsOf: metadataURL))
    }

    private func removeSessionFiles(uploadID: String) throws {
        let directory = sessionDirectory(for: uploadID)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func objectKey(for asset: MediaStorageService.StoredAsset) -> String {
        "im-media/\(asset.ownerUserID.uuidString)/\(asset.assetID)/\(asset.filename)"
    }

    private func metadataKey(for asset: MediaStorageService.StoredAsset) -> String {
        "im-media/\(asset.ownerUserID.uuidString)/\(asset.assetID)/metadata.json"
    }

    private func putObject(data: Data, key: String) async throws {
        var request = try signedRequest(method: "PUT", key: key, payload: data)
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw Abort(.badGateway, reason: "对象存储上传失败。")
        }
    }

    private func objectData(for key: String) async throws -> Data {
        let request = try signedRequest(method: "GET", key: key, payload: Data())
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Abort(.badGateway, reason: "对象存储响应无效。")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404 {
                throw Abort(.notFound, reason: "附件不存在。")
            }
            throw Abort(.badGateway, reason: "对象存储下载失败。")
        }
        return data
    }

    private func signedRequest(method: String, key: String, payload: Data) throws -> URLRequest {
        let timestamp = S3MediaSigningSupport.timestampFormatter.string(from: Date())
        let datestamp = String(timestamp.prefix(8))
        let payloadHash = S3MediaSigningSupport.sha256Hex(of: payload)
        let url = try objectURL(for: key)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = method == "PUT" ? payload : nil
        request.setValue(Self.hostHeader(for: url), forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        let canonicalURI = canonicalURI(for: url)
        let canonicalQuery = url.query ?? ""
        let canonicalHeaders = [
            "host:\(Self.hostHeader(for: url))",
            "x-amz-content-sha256:\(payloadHash)",
            "x-amz-date:\(timestamp)"
        ].joined(separator: "\n") + "\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")
        let credentialScope = "\(datestamp)/\(configuration.region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            credentialScope,
            S3MediaSigningSupport.sha256Hex(of: canonicalRequest.data(using: String.Encoding.utf8) ?? Data())
        ].joined(separator: "\n")
        let signingKey = S3MediaSigningSupport.signingKey(
            secret: configuration.secretAccessKey,
            date: datestamp,
            region: configuration.region,
            service: "s3"
        )
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: signingKey
        ).hexString

        let authorization = "AWS4-HMAC-SHA256 Credential=\(configuration.accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    private func objectURL(for key: String) throws -> URL {
        let encodedSegments = key
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")

        guard var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false) else {
            throw Abort(.internalServerError, reason: "对象存储 endpoint 无效。")
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if configuration.forcePathStyle {
            components.percentEncodedPath = "/" + [basePath, configuration.bucket, encodedSegments]
                .filter { !$0.isEmpty }
                .joined(separator: "/")
        } else {
            guard let host = components.host, !host.isEmpty else {
                throw Abort(.internalServerError, reason: "对象存储 host 无效。")
            }
            components.host = "\(configuration.bucket).\(host)"
            components.percentEncodedPath = "/" + [basePath, encodedSegments]
                .filter { !$0.isEmpty }
                .joined(separator: "/")
        }

        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "对象存储 URL 无效。")
        }
        return url
    }

    private func canonicalURI(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "/"
        }
        return components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    }

    private static func hostHeader(for url: URL) -> String {
        if let port = url.port {
            return "\(url.host() ?? ""):\(port)"
        }
        return url.host() ?? ""
    }
}
