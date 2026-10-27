@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HTTPTypes
import IMV2Core
import IMV2ActorContracts
import IMV2ServerHTTP
import SQLKit
import Testing
import Vapor
import VaporTesting
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

// Each scanner claims from the same isolated database, so fixtures must not race.
@Suite(.serialized)
struct V2ResourceHTTPPostgresTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil && ProcessInfo.processInfo.environment["IM_V2_OSS_LIVE_TEST"] == "1"))
    func realOSSHTTPPipeline() async throws {
        try await pipeline(mode: .httpPut, cloud: true)
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil), arguments: [V2ResourceTransferMode.httpPut, .httpPartPut])
    func persistentHTTPUploadRenewFinalizeAndHomeIsolation(mode: V2ResourceTransferMode) async throws {
        try await pipeline(mode: mode, cloud: false)
    }

    private func pipeline(mode: V2ResourceTransferMode, cloud: Bool) async throws {
        let resources=makeV2DatabaseTestResources()
        var cloudClient: V2OSSClient?
        let app=try await Application(.testing)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        do {
            resources.databases.use(try .postgres(url:#require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])),as:.psql,isDefault:true)
            let database=resources.database(.psql)
            let user=UserID(uuid:UUID()),device=DeviceID(uuid:UUID()),room=RoomID(uuid:UUID())
            let binding=try V2StorageBinding(id:"http-test",configurationRevision:1)
            let localStorage=try V2LocalResourceStorage(root:root.appendingPathComponent("sealed"),binding:binding)
            if cloud {
                let values = ProcessInfo.processInfo.environment
                let bucket = try #require(values["IM_V2_OSS_BUCKET"])
                let region = try #require(values["IM_V2_OSS_REGION"])
                let config = try V2OSSConfiguration(bucket: bucket, region: region,
                    endpoint: #require(URL(string: "https://\(bucket).oss-\(region).aliyuncs.com")),
                    prefix: "validation/\(UUID().uuidString.lowercased())/", binding: binding)
                cloudClient = V2OSSClient(configuration: config, credentials: .init(environment: V2DictionaryRuntimeEnvironment(values)))
                try await cloudClient?.verifyReadiness()
            }
            let cloudStorage = cloudClient.map { V2OSSObjectStorage(client: $0) }
            let storage: any V2ObjectStorage
            if let cloudStorage { storage = cloudStorage } else { storage = localStorage }
            let allocate: @Sendable () throws -> V2StoredObjectReference = {
                if let cloudStorage { return try cloudStorage.allocate() }
                return try localStorage.allocate()
            }
            let provider=try V2LocalFilesystemMediaProvider(rootDirectory:root.appendingPathComponent("uploads"),targetBaseURL:URL(string:"https://resource.test")!,signingKey:Data(repeating:1,count:32))
            try await provider.prepare()
            let transport: any V2UploadTransport
            if let cloudClient { transport = V2OSSUploadTransport(client: cloudClient) }
            else { transport = V2LocalResourceUploadTransport(binding: binding, provider: provider) }
            let registry=try V2ResourceStorageRegistry(storages:[storage],defaultBinding:binding)
            let service=try V2ResourceService(resolve:{_,_,_,_ in PostgresV2ResourceLifecycleStore(database:database,authorize:{_ in})},registry:registry,
                transports:[transport],maximumBytes:1_000_000,allocate:{_ in try allocate()})
            V2VaporResourceRoutes(authenticator:ResourceHTTPAuthentication(user:user),service:service).register(on:app)
            let byteDelivery=try V2LocalResourceDelivery(registry:registry,baseURL:URL(string:"https://resource.test")!,keyID:"test",keys:["test":Data(repeating:4,count:32)])
            V2VaporResourceByteRoutes(delivery:byteDelivery).register(on:app)
            let bytes=Data("verified resource HTTP pipeline".utf8)
            let request=try V2ResourceUploadRequest(operationID:.init(uuid:UUID()),mediaID:.init(uuid:UUID()),usage:.messageAttachment(room),contentType:"text/plain",byteCount:Int64(bytes.count),checksum:.init(value:SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined()),clientModes:[mode],displayName:.init("验证附件.txt"))
            let headers:HTTPFields=[.authorization:"Bearer test",HTTPField.Name("X-IM-Device-ID")!:device.rawValue]
            let session=try await app.testing { client in
                let response=try await client.send(.post,headers:headers,to:"v2/resource-uploads",beforeSend:{ try $0.content.encode(request,using:JSONEncoder()) })
                #expect(response.status == .ok);#expect(response.headers[.cacheControl]=="no-store")
                return try await response.content.decode(V2ResourceUploadSession.self)
            }
            let metadataSQL = try #require(database as? any SQLDatabase)
            let storedName = try await metadataSQL.raw("SELECT display_name FROM im_v2.resource_catalog WHERE media_id=\(bind: request.mediaID.uuidValue!)").first(decoding: ResourceHTTPDisplayName.self)
            #expect(storedName?.displayName == request.displayName.value)
            let again=try await service.create(request,actor:user,device:device)
            #expect(again.locator==session.locator)
            // Changing the default and its limits must not invalidate a lost create response.
            let secondBinding=try V2StorageBinding(id:"replacement",configurationRevision:2)
            let secondStorage=try V2LocalResourceStorage(root:root.appendingPathComponent("second-sealed"),binding:secondBinding)
            let switchedRegistry=try V2ResourceStorageRegistry(storages:[storage,secondStorage],defaultBinding:secondBinding)
            let transports:[any V2UploadTransport] = [transport,V2LocalResourceUploadTransport(binding:secondBinding,provider:provider)]
            let switched=try V2ResourceService(resolve:{_,_,_,_ in PostgresV2ResourceLifecycleStore(database:database,authorize:{_ in})},registry:switchedRegistry,
                transports:transports,maximumBytes:1,allocate:{_ in try secondStorage.allocate()})
            #expect(try await switched.create(request,actor:user,device:device).locator==session.locator)
            let newRequest=try V2ResourceUploadRequest(operationID:.init(uuid:UUID()),mediaID:.init(uuid:UUID()),usage:request.usage,
                contentType:request.contentType,byteCount:request.byteCount,checksum:request.checksum,clientModes:request.clientModes)
            await #expect(throws:V2ResourceProviderError.unsupportedCapability) { _ = try await switched.create(newRequest,actor:user,device:device) }
            let plan=try #require(try await switched.targets(.init(locator:session.locator,generation:1),actor:user,device:device).first)
            if cloud {
                var upload = URLRequest(url: plan.url)
                upload.httpMethod = plan.httpMethod
                for header in plan.headers { upload.setValue(header.value, forHTTPHeaderField: header.name) }
                // Never include a signed URL in a propagated transport error.
                do {
                    let (_, first) = try await URLSession.shared.upload(for: upload, from: bytes)
                    #expect((first as? HTTPURLResponse)?.statusCode == 200)
                    let (_, retry) = try await URLSession.shared.upload(for: upload, from: bytes)
                    #expect((retry as? HTTPURLResponse)?.statusCode == 409)
                } catch { throw V2ResourceProviderError.temporarilyUnavailable }
            } else {
                let providerID = try MediaID(plan.url.lastPathComponent)
                try await provider.storeUploadedObject(mediaID:providerID,targetURL:plan.url,contentType:request.contentType,bytes:bytes)
                try await provider.storeUploadedObject(mediaID:providerID,targetURL:plan.url,contentType:request.contentType,bytes:bytes)
            }
            let uploaded = try await service.status(session.locator,actor:user,device:device)
            #expect(mode == .httpPut || uploaded.confirmedParts.count == 1)
            let completed=try await app.testing { client in
                let response=try await client.send(.post,headers:headers,to:"v2/resource-uploads/finalize",beforeSend:{ try $0.content.encode(V2ResourceUploadFinalizeRequest(locator:session.locator,generation:1,parts:uploaded.confirmedParts),using:JSONEncoder()) })
                #expect(response.status == .ok)
                return try await response.content.decode(V2ResourceUploadSession.self)
            }
            #expect(completed.state == .completed && completed.resourceState == .scanning)
            let scanner=try V2MediaScanWorker(store:PostgresV2MediaScanStore(database:database),provider:V2PlacementMediaScanner(database:database,registry:registry,scanner:V2LocalResourceScanner()))
            _ = try await scanner.runOnce(limit:100)
            let ready=try await service.status(session.locator,actor:user,device:device)
            #expect(ready.resourceState == .ready)
            #expect(ready.bindableUntil != nil)
            #expect(try await switched.finalize(.init(locator:session.locator,generation:1),actor:user,device:device).resourceState == .ready)
            let delivery=try V2LocalResourceDelivery(registry:switchedRegistry,baseURL:URL(string:"https://resource.test")!,keyID:"test",keys:["test":Data(repeating:4,count:32)])
            let downloads=try V2BoundMediaProvider(database:database,registry:switchedRegistry,delivery:delivery,transports:transports)
            let target=try await downloads.issueDownloadTarget(mediaID:request.mediaID,expiresAt:Date().addingTimeInterval(60))
            // Ready-resource downloads use the verified placement even when staging is gone.
            try await transports[0].abort(mediaID:request.mediaID)
            try await app.testing { client in
                let components=try #require(URLComponents(url:target.url,resolvingAgainstBaseURL:false))
                let uri=URI(string:components.percentEncodedPath+"?"+(components.percentEncodedQuery ?? ""))
                let etag="\""+SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()+"\""
                let response=try await client.send(.get,to:uri)
                #expect(response.status == .ok)
                #expect(response.headers[.eTag] == etag)
                #expect(response.headers[.acceptRanges] == "bytes")
                #expect(try await response.body.data() == bytes)
                let partial=try await client.send(.get,headers:[.range:"bytes=2-7",.ifRange:etag],to:uri)
                #expect(partial.status == .partialContent)
                #expect(partial.headers[.eTag] == etag)
                #expect(partial.headers[.contentRange] == "bytes 2-7/\(bytes.count)")
                #expect(partial.headers[.contentLength] == "6")
                #expect(try await partial.body.data() == bytes.subdata(in:2..<8))
                // If-Range is checked before range satisfiability: an old validator
                // restarts the full object, even when the saved offset is too large.
                let restarted=try await client.send(.get,headers:[.range:"bytes=999-",.ifRange:"\"old-content\""],to:uri)
                #expect(restarted.status == .ok)
                #expect(restarted.headers[.contentRange] == nil)
                #expect(try await restarted.body.data() == bytes)
                let beyond=try await client.send(.get,headers:[.range:"bytes=999-",.ifRange:etag],to:uri)
                #expect(beyond.status == .rangeNotSatisfiable)
                #expect(beyond.headers[.contentRange] == "bytes */\(bytes.count)")
                let beyondBytes=try await beyond.body.data() ?? Data()
                #expect(beyondBytes.isEmpty)
                let denied=try await client.send(.get,headers:[.range:"bytes=999-"],
                    to:URI(string:components.percentEncodedPath+"?cap=invalid"))
                #expect(denied.status == .notFound)
                #expect(denied.headers[.eTag] == nil && denied.headers[.contentRange] == nil)
                #expect(denied.headers[.acceptRanges] == nil)
            }
            await #expect(throws:V2MediaStoreError.uploadNotAuthorized) {
                _ = try await service.status(.init(home:.room(.init(uuid:UUID())),sessionID:session.locator.sessionID),actor:user,device:device)
            }
            let sourceTime=Date()
            let port=V2ActorRoomMediaAuthorizationPort { query,_ in
                guard case .messageVisibility(let value)=query else { return .notVisible }
                return .visible(.init(roomID:value.roomID,messageID:value.messageID,mediaID:value.mediaID,membershipRevision:1,contentRevision:1,mediaUpdatedAt:sourceTime,uploadSessionID:session.locator.sessionID.uuidValue!))
            }
            let importSources=V2ResourceImportSourceResolver(controlDatabase:database,rooms:ResourceHTTPRoomRouter(),
                ownerDatabases:["test":database],authorization:port,
                avatarAuthorization:{_,_,_,_,_ in throw V2ResourceProviderError.unsupportedCapability})
            let importStore=PostgresV2ResourceImportStore(resolve:{_,_,_,_ in
                PostgresV2ResourceLifecycleStore(database:database,authorize:{_ in})
            },sources:importSources,recoveryDatabases:["test":database])
            let imports=V2ResourceImportService(resources:service,resolve:{_,_,_,_ in
                PostgresV2ResourceLifecycleStore(database:database,authorize:{_ in})
            },persistence:importStore,registry:registry,
                transports:[transport])
            let imported=try V2ResourceImportRequest(operationID:.init(uuid:UUID()),
                source:.message(location:.init(roomID:room,messageID:.init(uuid:UUID())),mediaID:request.mediaID,variantID:nil),
                targetUsage:.messageAttachment(.init(uuid:UUID())),targetMediaID:.init(uuid:UUID()))
            let importResult=try await imports.create(imported,actor:user,device:device)
            #expect(importResult.state == .processing)
            _ = try await scanner.runOnce(limit:100)
            let importReady=try await imports.status(importResult.locator,actor:user,device:device)
            #expect(importReady.state == .ready)
            let sql=try #require(database as? any SQLDatabase)
            let copied=try #require(try await sql.raw("SELECT COUNT(DISTINCT placement_id)::bigint AS count FROM im_v2.resource_blob_placements WHERE media_id IN (\(bind: request.mediaID.uuidValue!),\(bind: imported.targetMediaID.uuidValue!))").first(decoding:ResourceHTTPCount.self))
            #expect(copied.count==2)
            let held=try #require(try await sql.raw("SELECT COUNT(*)::bigint AS count FROM im_v2.resource_import_holds WHERE actor_user_id=\(bind: user.uuidValue!) AND operation_id=\(bind: imported.operationID.uuidValue!) AND released_at IS NULL").first(decoding:ResourceHTTPCount.self))
            #expect(held.count==0)
            if cloud {
                let rows = try await sql.raw("SELECT reference_json::text AS reference FROM im_v2.resource_blob_placements WHERE media_id IN (\(bind: request.mediaID.uuidValue!),\(bind: imported.targetMediaID.uuidValue!))").all(decoding: ResourceHTTPReference.self)
                for row in rows {
                    try await storage.delete(JSONDecoder().decode(V2StoredObjectReference.self, from: Data(row.reference.utf8)))
                }
                try await transport.abort(mediaID: imported.targetMediaID)
            }
            try await cloudClient?.shutdown()
            try await app.shutdown();try await resources.shutdown()
        } catch {try? await cloudClient?.shutdown();try? await app.shutdown();try? await resources.shutdown();throw error}
    }
}
private struct ResourceHTTPAuthentication:V2GatewayAuthenticator {
    let user:UserID
    func authenticateSession(accessToken:String,deviceID:DeviceID) async throws -> V2GatewayAuthentication { .init(userID:user,expiresAt:nil) }
}

private struct ResourceHTTPRoomRouter:V2RoomShardRouting {
    func route(for roomID:RoomID) async throws -> V2RoomShardRoute { try .init(shardID:"test",epoch:1) }
}
private struct ResourceHTTPCount:Decodable {let count:Int64}

private struct ResourceHTTPReference: Decodable { let reference: String }
private struct ResourceHTTPDisplayName: Decodable {
    let displayName: String
    enum CodingKeys: String, CodingKey { case displayName = "display_name" }
}
