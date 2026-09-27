import Foundation
import IMV2Server
import Vapor
import HTTPTypes

public struct V2VaporResourceByteRoutes:Sendable {
    let delivery:V2LocalResourceDelivery
    public init(delivery:V2LocalResourceDelivery) { self.delivery=delivery }
    public func register(on routes:RoutesBuilder) {
        routes.get("v2","resource-bytes",":placementID") { request async throws -> Response in
            guard let raw=request.parameters.get("placementID"),let id=UUID(uuidString:raw),
                  let cap=request.query[String.self,at:"cap"] else { throw Abort(.notFound) }
            do {
                let stream=try await delivery.stream(placementID:id,capability:cap)
                var headers=HTTPFields()
                headers[.contentType]="application/octet-stream"
                headers[HTTPField.Name("X-Content-Type-Options")!]="nosniff"
                // The shared cache lives behind capability validation, not in an unauthenticated proxy.
                headers[.cacheControl]="private, no-store"
                return try .init(status:.ok,headers:headers,body:.init(stream:{ writer in
                    while let chunk=try await stream.bytes.next() {
                        try Task.checkCancellation()
                        try await writer.write(chunk)
                    }
                },count:Int(stream.byteCount)))
            } catch V2ResourceProviderError.throttled { throw Abort(.tooManyRequests)
            } catch { throw Abort(.notFound) }
        }
    }
}
