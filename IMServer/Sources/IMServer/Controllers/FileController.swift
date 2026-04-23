import Vapor

struct FileController: RouteCollection {
    private let maxUploadSize: ByteCount = "256mb"

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped("api", "files")
            .grouped(
                AccessTokenAuthenticator(),
                User.guardMiddleware(throwing: Abort(.unauthorized, reason: "用户未登录。"))
            )

        protected.on(.POST, "upload", body: .collect(maxSize: maxUploadSize), use: upload)
        protected.get("download", use: download)
    }

    func upload(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        guard let body = try await req.body.collect(max: maxUploadSize.value).get(),
              body.readableBytes > 0
        else {
            throw Abort(.badRequest, reason: "上传内容不能为空。")
        }

        let data = Data(body.readableBytesView)

        try FileStorageService(app: req.application).saveLatestUpload(
            for: userID,
            body: data,
            contentType: req.headers.contentType?.serialize()
        )

        return .ok
    }

    func download(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let storedFile = try FileStorageService(app: req.application).latestFile(for: try user.requireID())

        let totalSize = storedFile.data.count
        guard totalSize > 0 else {
            let response = Response(status: .ok)
            response.headers.replaceOrAdd(name: .contentType, value: storedFile.contentType)
            response.headers.replaceOrAdd(name: .contentDisposition, value: contentDisposition(for: storedFile.fileName))
            response.headers.replaceOrAdd(name: .acceptRanges, value: "bytes")
            response.body = .init()
            return response
        }

        if let rangeHeader = req.headers.first(name: .range) {
            let byteRange = try parseRange(rangeHeader, totalSize: totalSize)
            let slice = storedFile.data[byteRange.lowerBound...byteRange.upperBound]

            let response = Response(
                status: .partialContent,
                body: .init(data: Data(slice))
            )
            response.headers.replaceOrAdd(name: .contentType, value: storedFile.contentType)
            response.headers.replaceOrAdd(name: .contentDisposition, value: contentDisposition(for: storedFile.fileName))
            response.headers.replaceOrAdd(name: .acceptRanges, value: "bytes")
            response.headers.replaceOrAdd(name: .contentLength, value: String(slice.count))
            response.headers.replaceOrAdd(
                name: .contentRange,
                value: "bytes \(byteRange.lowerBound)-\(byteRange.upperBound)/\(totalSize)"
            )
            return response
        }

        let response = Response(
            status: .ok,
            body: .init(data: storedFile.data)
        )
        response.headers.replaceOrAdd(name: .contentType, value: storedFile.contentType)
        response.headers.replaceOrAdd(name: .contentDisposition, value: contentDisposition(for: storedFile.fileName))
        response.headers.replaceOrAdd(name: .acceptRanges, value: "bytes")
        response.headers.replaceOrAdd(name: .contentLength, value: String(totalSize))
        return response
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
        var abort = Abort(.rangeNotSatisfiable, reason: "请求的文件区间无效。")
        abort.headers.replaceOrAdd(name: .contentRange, value: "bytes */\(totalSize)")
        return abort
    }

    private func contentDisposition(for fileName: String) -> String {
        "attachment; filename=\"\(fileName)\""
    }
}
