import Foundation
import IMV2Core
import IMV2Server
import Vapor
import _NIOFileSystem

/// Development-only object-byte edge for `V2LocalFilesystemMediaProvider`.
/// The signed target is the capability: this adapter never accepts a raw file
/// path, media storage key, or long-lived application credential. Production
/// deployments must compose a provider-native object edge instead.
public struct V2VaporLocalFilesystemMediaRoutes: Sendable {
    private let provider: V2LocalFilesystemMediaProvider
    private let publicBaseURL: URL
    private let maximumUploadBytes: Int

    public init(
        provider: V2LocalFilesystemMediaProvider,
        publicBaseURL: URL,
        maximumUploadBytes: Int64
    ) throws {
        guard publicBaseURL.scheme?.lowercased() == "https",
              publicBaseURL.host != nil,
              publicBaseURL.query == nil,
              publicBaseURL.fragment == nil,
              maximumUploadBytes > 0,
              maximumUploadBytes <= Int64(Int.max)
        else { throw V2VaporLocalFilesystemMediaRoutesError.invalidConfiguration }
        self.provider = provider
        self.publicBaseURL = publicBaseURL
        self.maximumUploadBytes = Int(maximumUploadBytes)
    }

    /// Registers the short-lived signed targets emitted by the local provider:
    /// `PUT /v2/local-media/upload/{mediaID}` and
    /// `GET /v2/local-media/download/{mediaID}`.
    public func register(on routes: RoutesBuilder) {
        routes.on(
            .PUT,
            "v2", "local-media", "upload", ":mediaID",
            body: .stream
        ) { request async throws -> Response in
            guard let rawMediaID = request.parameters.get("mediaID"),
                  let mediaID = try? MediaID(rawMediaID),
                  let targetURL = targetURL(for: request),
                  let contentType = request.headers.first(name: .contentType),
                  let rawContentLength = request.headers.first(name: .contentLength),
                  let contentLength = Int64(rawContentLength),
                  contentLength >= 0
            else { throw Abort(.forbidden) }
            guard contentLength <= Int64(maximumUploadBytes) else {
                throw Abort(.payloadTooLarge)
            }
            let upload: V2LocalFilesystemStagedUpload
            do {
                upload = try await provider.beginUploadedObject(
                    mediaID: mediaID,
                    targetURL: targetURL,
                    contentType: contentType,
                    declaredByteCount: contentLength
                )
            } catch is V2LocalFilesystemMediaProviderError {
                // A signed target is an opaque capability; do not reveal why
                // one was rejected or whether its object exists.
                throw Abort(.forbidden)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            do {
                let written = try await request.body
                    .map { Data($0.readableBytesView) }
                    .write(
                    toFileAt: .init(upload.fileURL.path),
                    options: .newFile(replaceExisting: false)
                )
                guard written == contentLength else {
                    throw V2LocalFilesystemMediaProviderError.byteCountMismatch
                }
                try await provider.commitUploadedObject(upload, actualByteCount: written)
            } catch let abort as AbortError {
                await provider.discardUploadedObject(upload)
                throw abort
            } catch is V2LocalFilesystemMediaProviderError {
                await provider.discardUploadedObject(upload)
                throw Abort(.forbidden)
            } catch {
                await provider.discardUploadedObject(upload)
                throw Abort(.serviceUnavailable)
            }
            return noStoreResponse(status: .noContent)
        }

        routes.get("v2", "local-media", "download", ":mediaID") { request async throws -> Response in
            guard let rawMediaID = request.parameters.get("mediaID"),
                  let mediaID = try? MediaID(rawMediaID),
                  let targetURL = targetURL(for: request)
            else { throw Abort(.notFound) }
            let object: V2LocalFilesystemDownloadedObject
            do {
                object = try await provider.downloadedObject(mediaID: mediaID, targetURL: targetURL)
            } catch is V2LocalFilesystemMediaProviderError {
                // Do not distinguish expiration, a malformed capability, and
                // an absent object from the public object-byte boundary.
                throw Abort(.notFound)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            guard object.byteCount <= Int64(Int.max) else { throw Abort(.serviceUnavailable) }
            let response = try await request.fileio.asyncStreamFile(
                at: object.fileURL.path,
                mediaType: .init(type: "application", subType: "octet-stream")
            )
            for header in noStoreHeaders() {
                response.headers.replaceOrAdd(name: header.name, value: header.value)
            }
            response.headers.replaceOrAdd(name: .contentType, value: "application/octet-stream")
            return response
        }
    }

    private func targetURL(for request: Request) -> URL? {
        guard var components = URLComponents(url: publicBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = request.url.path
        components.percentEncodedQuery = request.url.query
        return components.url
    }

    private func noStoreResponse(status: HTTPResponseStatus) -> Response {
        .init(status: status, headers: noStoreHeaders())
    }

    private func noStoreHeaders() -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return headers
    }
}

public enum V2VaporLocalFilesystemMediaRoutesError: Error, Equatable, Sendable {
    case invalidConfiguration
}
