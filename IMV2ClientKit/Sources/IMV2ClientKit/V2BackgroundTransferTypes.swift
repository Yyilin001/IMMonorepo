import Foundation
import IMV2Core
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum V2BackgroundTransferError: Error, Equatable, Sendable {
    case unsupported, invalidAuthorization, closed, capacityExceeded, protectedDataUnavailable, mappingConflict
}
public struct V2BackgroundSystemTask: Sendable, Equatable {
    public let identifier: Int
    public let mappingID: UUID?
    public let suspended: Bool
    public init(identifier:Int,mappingID:UUID?,suspended:Bool=false) { self.identifier=identifier;self.mappingID=mappingID;self.suspended=suspended }
}
/// A durable inbox entry contains no request, URL, credential, headers or response body.
public struct V2BackgroundTransferResult: Codable, Sendable, Equatable {
    public let mappingID: UUID
    public let taskIdentifier: Int
    public let statusCode: Int?
    public let errorCode: Int?
    public let sentBytes: Int64
    public let receivedBytes: Int64?
    public let originDigest: String?
    public let retryNotBefore: Date?
    public init(mappingID:UUID,taskIdentifier:Int,statusCode:Int?,errorCode:Int?,sentBytes:Int64,
                originDigest:String?=nil,retryNotBefore:Date?=nil,receivedBytes:Int64?=nil) {
        self.mappingID=mappingID;self.taskIdentifier=taskIdentifier;self.statusCode=statusCode;self.errorCode=errorCode
        self.receivedBytes=receivedBytes;self.sentBytes=sentBytes;self.originDigest=originDigest;self.retryNotBefore=retryNotBefore
    }
}
public protocol V2BackgroundSessionDriving: Sendable {
    func tasks() async -> [V2BackgroundSystemTask]
    func create(request: URLRequest, file: URL, mappingID: UUID) async throws -> Int
    func resume(_ identifier: Int) async throws
    /// Returns only after the real system task completion callback.
    func cancelAndDrain(_ identifiers: [Int]) async
    func installWake(_ wake: @escaping @Sendable () async -> Void) async
}
public struct V2BackgroundTaskMapping: Sendable, Equatable {
    public let id:UUID,sessionID:UUID,jobID:UUID,activationID:UUID,sourceToken:UUID
    public let taskIdentifier:Int,partNumber:Int
    public let expectedBytes:Int64
    public let expiresAt:Date
    public let originDigest:String
}

public protocol V2BackgroundProtectedDataChecking:Sendable {
    func protectedDataAvailable() async -> Bool
}
