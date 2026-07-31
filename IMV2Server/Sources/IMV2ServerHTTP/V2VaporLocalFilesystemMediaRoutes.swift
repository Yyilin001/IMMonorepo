import Foundation
import IMV2Core
import IMV2Server
import Vapor

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
            body: .collect(maxSize: .init(value: maximumUploadBytes))
        ) { request async throws -> Response in
            guard let rawMediaID = request.parameters.get("mediaID"),
                  let mediaID = try? MediaID(rawMediaID),
                  let targetURL = targetURL(for: request),
                  let contentType = request.headers.first(name: .contentType),
                  let body = request.body.data
            else { throw Abort(.forbidden) }
            let bytes = Data(buffer: body)
            do {
                try await provider.storeUploadedObject(
                    mediaID: mediaID,
                    targetURL: targetURL,
                    contentType: contentType,
                    bytes: bytes
                )
            } catch is V2LocalFilesystemMediaProviderError {
                // A signed target is an opaque capability; do not reveal why
                // one was rejected or whether its object exists.
                throw Abort(.forbidden)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            return noStoreResponse(status: .noContent)
        }

        routes.get("v2", "local-media", "download", ":mediaID") { request async throws -> Response in
            guard let rawMediaID = request.parameters.get("mediaID"),
                  let mediaID = try? MediaID(rawMediaID),
                  let targetURL = targetURL(for: request)
            else { throw Abort(.notFound) }
            let bytes: Data
            do {
                bytes = try await provider.readDownloadedObject(mediaID: mediaID, targetURL: targetURL)
            } catch is V2LocalFilesystemMediaProviderError {
                // Do not distinguish expiration, a malformed capability, and
                // an absent object from the public object-byte boundary.
                throw Abort(.notFound)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            var headers = noStoreHeaders()
            headers.replaceOrAdd(name: .contentType, value: "application/octet-stream")
            headers.replaceOrAdd(name: .contentLength, value: String(bytes.count))
            return .init(status: .ok, headers: headers, body: .init(data: bytes))
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
