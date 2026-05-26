import Fluent
import Vapor

struct MediaController: RouteCollection {
    private let maxUploadSize: ByteCount = "256mb"

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped("api", "media")
            .grouped(
                AccessTokenAuthenticator(),
                User.guardMiddleware(throwing: Abort(.unauthorized, reason: "用户未登录。"))
            )

        protected.post("uploads", use: createUploadSession)
        protected.on(.PUT, "uploads", ":uploadID", "chunk", body: .collect(maxSize: maxUploadSize), use: uploadChunk)
        protected.post("uploads", ":uploadID", "complete", use: completeUpload)
        protected.get("assets", ":assetID", use: downloadAsset)
    }

    func createUploadSession(req: Request) async throws -> MediaUploadSessionResponse {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(MediaUploadCreateRequest.self)
        let session = try await MediaStorageService(app: req.application).createUploadSession(
            for: try user.requireID(),
            kind: body.kind,
            mimeType: body.mimeType,
            byteSize: body.byteSize,
            filename: body.filename,
            width: body.width,
            height: body.height,
            durationMillis: body.durationMillis,
            previewAssetID: body.previewAssetID
        )

        return MediaUploadSessionResponse(
            uploadID: session.uploadID,
            uploadPath: "/api/media/uploads/\(session.uploadID)/chunk",
            completePath: "/api/media/uploads/\(session.uploadID)/complete",
            expiresAt: session.expiresAt
        )
    }

    func uploadChunk(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let uploadID = try uploadID(from: req)
        guard let body = try await req.body.collect(max: maxUploadSize.value).get(),
              body.readableBytes > 0
        else {
            throw Abort(.badRequest, reason: "上传内容不能为空。")
        }

        try await MediaStorageService(app: req.application).writeUploadChunk(
            uploadID: uploadID,
            for: try user.requireID(),
            body: Data(body.readableBytesView)
        )
        return .ok
    }

    func completeUpload(req: Request) async throws -> IMMediaAsset {
        let user = try req.auth.require(User.self)
        let uploadID = try uploadID(from: req)
        return try await MediaStorageService(app: req.application).completeUpload(
            uploadID: uploadID,
            for: try user.requireID()
        )
    }

    func downloadAsset(req: Request) async throws -> Response {
        let userID = try req.auth.require(User.self).requireID()
        let assetID = try assetID(from: req)
        let storedAsset = try await authorizedAsset(
            assetID: assetID,
            for: userID,
            on: req
        )
        let responseEntityTag = entityTag(for: storedAsset.metadata)
        let totalSize = storedAsset.data.count

        if totalSize == 0 {
            let response = Response(status: .ok)
            response.headers.replaceOrAdd(name: .contentType, value: storedAsset.metadata.mimeType)
            response.headers.replaceOrAdd(name: .contentDisposition, value: contentDisposition(for: storedAsset.metadata.filename))
            response.headers.replaceOrAdd(name: .acceptRanges, value: "bytes")
            response.headers.replaceOrAdd(name: .eTag, value: responseEntityTag)
            response.body = .init()
            return response
        }

        if let rangeHeader = req.headers.first(name: .range),
           shouldHonorRangeRequest(req: req, entityTag: responseEntityTag)
        {
            let byteRange = try parseRange(rangeHeader, totalSize: totalSize)
            let slice = storedAsset.data[byteRange.lowerBound...byteRange.upperBound]
            let response = Response(
                status: .partialContent,
                body: .init(data: Data(slice))
            )
            response.headers.replaceOrAdd(name: .contentType, value: storedAsset.metadata.mimeType)
            response.headers.replaceOrAdd(name: .contentDisposition, value: contentDisposition(for: storedAsset.metadata.filename))
            response.headers.replaceOrAdd(name: .acceptRanges, value: "bytes")
            response.headers.replaceOrAdd(name: .contentLength, value: String(slice.count))
            response.headers.replaceOrAdd(name: .eTag, value: responseEntityTag)
            response.headers.replaceOrAdd(
                name: .contentRange,
                value: "bytes \(byteRange.lowerBound)-\(byteRange.upperBound)/\(totalSize)"
            )
            return response
        }

        let response = Response(status: .ok, body: .init(data: storedAsset.data))
        response.headers.replaceOrAdd(name: .contentType, value: storedAsset.metadata.mimeType)
        response.headers.replaceOrAdd(name: .contentDisposition, value: contentDisposition(for: storedAsset.metadata.filename))
        response.headers.replaceOrAdd(name: .acceptRanges, value: "bytes")
        response.headers.replaceOrAdd(name: .contentLength, value: String(totalSize))
        response.headers.replaceOrAdd(name: .eTag, value: responseEntityTag)
        return response
    }

    private func uploadID(from req: Request) throws -> String {
        guard let uploadID = req.parameters.get("uploadID")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uploadID.isEmpty
        else {
            throw Abort(.badRequest, reason: "上传 ID 无效。")
        }
        return uploadID
    }

    private func assetID(from req: Request) throws -> String {
        guard let assetID = req.parameters.get("assetID")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !assetID.isEmpty
        else {
            throw Abort(.badRequest, reason: "附件 ID 无效。")
        }
        return assetID
    }

    private func authorizedAsset(
        assetID: String,
        for userID: UUID,
        on req: Request
    ) async throws -> MediaStorageService.StoredAssetFile {
        let storage = try MediaStorageService(app: req.application)
        if await storage.assetExists(ownerUserID: userID, assetID: assetID) {
            return try await storage.storedAssetFile(ownerUserID: userID, assetID: assetID)
        }

        if let cachedOwnerUserID = await req.application.conversationMediaAccessCache.ownerUserID(
            assetID: assetID,
            userID: userID
        ) {
            do {
                return try await storage.storedAssetFile(ownerUserID: cachedOwnerUserID, assetID: assetID)
            } catch {
                await req.application.conversationMediaAccessCache.invalidate(assetID: assetID)
            }
        }

        let directoryReferences = try await ConversationMediaAssetReferenceDirectoryService(db: req.application.imSummaryDB)
            .references(assetID: assetID, on: req.application.imSummaryDB)
        if let storedAsset = try await authorizedSharedAsset(
            assetID: assetID,
            userID: userID,
            references: directoryReferences,
            storage: storage,
            app: req.application
        ) {
            return storedAsset
        }

        throw Abort(.notFound, reason: "附件不存在。")
    }

    private func authorizedSharedAsset(
        assetID: String,
        userID: UUID,
        references: [ConversationMediaAssetReferenceDirectory],
        storage: MediaStorageService,
        app: Application
    ) async throws -> MediaStorageService.StoredAssetFile? {
        let membershipsByConversationID = try await sharedAssetMembershipsByConversationID(
            references: references,
            userID: userID,
            app: app
        )

        for reference in references {
            guard let membership = membershipsByConversationID[reference.conversationID],
                  reference.serverSequence >= membership.visibleFromSequence
            else {
                continue
            }
            await app.conversationMediaAccessCache.store(
                assetID: assetID,
                userID: userID,
                conversationID: reference.conversationID,
                ownerUserID: reference.ownerUserID
            )
            return try await storage.storedAssetFile(
                ownerUserID: reference.ownerUserID,
                assetID: assetID
            )
        }
        return nil
    }

    private func sharedAssetMembershipsByConversationID(
        references: [ConversationMediaAssetReferenceDirectory],
        userID: UUID,
        app: Application
    ) async throws -> [UUID: ConversationMember] {
        let referencesByShard = Dictionary(grouping: references, by: \.shardID)
        var result: [UUID: ConversationMember] = [:]
        for (shardID, shardReferences) in referencesByShard {
            let conversationIDs = Array(Set(shardReferences.map(\.conversationID)))
            guard !conversationIDs.isEmpty else {
                continue
            }
            let shardDB = app.conversationShardRouter.eventualReadDatabase(forShardID: shardID)
            let memberships = try await ConversationMember.query(on: shardDB)
                .filter(\.$conversation.$id ~~ conversationIDs)
                .filter(\.$user.$id == userID)
                .all()
            for membership in memberships {
                result[membership.$conversation.id] = membership
            }
        }
        return result
    }

    private func shouldHonorRangeRequest(req: Request, entityTag: String) -> Bool {
        guard let ifRange = req.headers.first(name: "If-Range")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ifRange.isEmpty
        else {
            return true
        }

        return ifRange == entityTag
    }

    private func parseRange(_ header: String, totalSize: Int) throws -> ClosedRange<Int> {
        guard header.hasPrefix("bytes=") else {
            throw invalidRange(totalSize: totalSize)
        }

        let rawValue = String(header.dropFirst("bytes=".count))
        guard !rawValue.contains(",") else {
            throw invalidRange(totalSize: totalSize)
        }

        let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw invalidRange(totalSize: totalSize)
        }

        if parts[0].isEmpty {
            guard let suffixLength = Int(parts[1]), suffixLength > 0 else {
                throw invalidRange(totalSize: totalSize)
            }
            let lowerBound = max(totalSize - suffixLength, 0)
            return lowerBound...(totalSize - 1)
        }

        guard let lowerBound = Int(parts[0]), lowerBound >= 0, lowerBound < totalSize else {
            throw invalidRange(totalSize: totalSize)
        }

        if parts[1].isEmpty {
            return lowerBound...(totalSize - 1)
        }

        guard let requestedUpperBound = Int(parts[1]), requestedUpperBound >= lowerBound else {
            throw invalidRange(totalSize: totalSize)
        }

        return lowerBound...min(requestedUpperBound, totalSize - 1)
    }

    private func invalidRange(totalSize: Int) -> Abort {
        var abort = Abort(.rangeNotSatisfiable, reason: "请求的附件区间无效。")
        abort.headers.replaceOrAdd(name: .contentRange, value: "bytes */\(totalSize)")
        return abort
    }

    private func contentDisposition(for fileName: String) -> String {
        "attachment; filename=\"\(fileName)\""
    }

    private func entityTag(for asset: MediaStorageService.StoredAsset) -> String {
        "\"\(asset.assetID)-\(asset.byteSize)-\(Int(asset.storedAt.timeIntervalSince1970))\""
    }
}

private struct MediaUploadCreateRequest: Content {
    let kind: IMMediaAssetKind
    let mimeType: String
    let byteSize: Int64
    let filename: String
    let width: Int?
    let height: Int?
    let durationMillis: Int?
    let previewAssetID: String?
}

struct MediaUploadSessionResponse: Content {
    let uploadID: String
    let uploadPath: String
    let completePath: String
    let expiresAt: Date
}
