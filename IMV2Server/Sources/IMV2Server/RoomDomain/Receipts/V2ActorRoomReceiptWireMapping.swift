import Foundation
import IMV2ActorContracts
import IMV2Core

public extension V2ActorRecordReadReceiptWire {
    init(_ value: V2AuthenticatedReadReceipt) throws {
        try self.init(roomID: value.roomID, actorUserID: value.actorUserID,
                      operationID: value.operationID,
                      readThroughRoomSequence: value.readThroughRoomSequence)
    }
    init(_ value: V2RecordReadReceiptCommand) throws {
        try self.init(roomID: value.roomID, actorUserID: value.actorUserID,
                      operationID: value.operationID,
                      readThroughRoomSequence: value.readThroughRoomSequence)
    }
    func authenticatedValue() -> V2AuthenticatedReadReceipt {
        .init(roomID: roomID, actorUserID: actorUserID, operationID: operationID,
              readThroughRoomSequence: readThroughRoomSequence)
    }
    func commandValue() throws -> V2RecordReadReceiptCommand {
        try .init(roomID: roomID, actorUserID: actorUserID, operationID: operationID,
                  readThroughRoomSequence: readThroughRoomSequence)
    }
}

public extension V2ActorReadReceiptWire {
    init(_ value: V2ReadReceipt) {
        self.init(roomID: value.roomID, userID: value.userID,
                  readThroughRoomSequence: value.readThroughRoomSequence,
                  recordedAt: value.recordedAt)
    }
    func domainValue() throws -> V2ReadReceipt {
        guard recordedAt.timeIntervalSince1970.isFinite else {
            throw V2ActorRoomReceiptWireError.invalidResult
        }
        return try .init(roomID: roomID, userID: userID,
                         readThroughRoomSequence: readThroughRoomSequence, recordedAt: recordedAt)
    }
}

public extension V2ActorRecordReadReceiptResultWire {
    init(_ value: V2ReadReceiptOutcome) {
        switch value {
        case .recorded(let receipt): self = .recorded(.init(receipt))
        case .idempotent(let receipt): self = .idempotent(.init(receipt))
        case .idempotencyConflict: self = .idempotencyConflict
        }
    }
    func domainValue() throws -> V2ReadReceiptOutcome {
        switch self {
        case .recorded(let receipt): return .recorded(try receipt.domainValue())
        case .idempotent(let receipt): return .idempotent(try receipt.domainValue())
        case .idempotencyConflict: return .idempotencyConflict
        }
    }
}

public extension V2ActorReadReceiptReaderWire {
    init(_ value: V2ReadReceiptReader) {
        self.init(userID: value.userID)
    }
    func domainValue() throws -> V2ReadReceiptReader {
        .init(userID: userID)
    }
}

public extension V2ActorReadReceiptReadersPageWire {
    init(_ value: V2ReadReceiptReadersPage) {
        self.init(roomID: value.roomID, messageID: value.messageID,
                  readers: value.readers.map(V2ActorReadReceiptReaderWire.init),
                  nextCursor: value.nextCursor)
    }
    func domainValue() throws -> V2ReadReceiptReadersPage {
        guard readers.count <= 100 else { throw V2ActorRoomReceiptWireError.invalidResult }
        return try .init(roomID: roomID, messageID: messageID,
                         readers: readers.map { try $0.domainValue() }, nextCursor: nextCursor)
    }
}

public extension V2ActorReadReceiptStoreErrorWire {
    init(_ value: V2ReadReceiptStoreError) {
        switch value {
        case .ownerChanged: self = .ownerChanged
        case .roomNotFound: self = .roomNotFound
        case .messageNotFound: self = .messageNotFound
        case .actorNotMember: self = .actorNotMember
        case .roomSequenceNotFound: self = .roomSequenceNotFound
        case .invalidRequest: self = .invalidRequest
        case .corruptPersistenceState: self = .corruptPersistenceState
        }
    }
    func domainValue() -> V2ReadReceiptStoreError {
        switch self {
        case .ownerChanged: .ownerChanged
        case .roomNotFound: .roomNotFound
        case .messageNotFound: .messageNotFound
        case .actorNotMember: .actorNotMember
        case .roomSequenceNotFound: .roomSequenceNotFound
        case .invalidRequest: .invalidRequest
        case .corruptPersistenceState: .corruptPersistenceState
        }
    }
}

public extension V2ActorReadReceiptBatchItemResultWire {
    init(_ value: V2ReadReceiptRecordResult) {
        switch value {
        case .success(let outcome): self = .success(.init(outcome))
        case .failure(let error): self = .failure(.init(error))
        }
    }
    func domainValue() throws -> V2ReadReceiptRecordResult {
        switch self {
        case .success(let outcome): return .success(try outcome.domainValue())
        case .failure(let error): return .failure(error.domainValue())
        }
    }
}

public extension V2ActorReadReceiptRecordBatchWire {
    /// 执行器在本地记录接收时间，绝不以线路传入的时间戳为权威。
    func recordRequests(now: Date) throws -> [V2ReadReceiptRecordRequest] {
        guard now.timeIntervalSince1970.isFinite else { throw V2ActorRoomReceiptWireError.invalidRequest }
        return try requests.map { try .init(command: $0.commandValue(), now: now) }
    }
}

public extension V2ActorReadReceiptRecordBatchResultWire {
    init(_ values: [V2ReadReceiptRecordResult], expectedCount: Int) throws {
        guard (1...128).contains(expectedCount), values.count == expectedCount else {
            throw V2ActorRoomReceiptWireError.invalidResult
        }
        self.init(results: values.map(V2ActorReadReceiptBatchItemResultWire.init))
    }
    func domainValue(expectedCount: Int) throws -> [V2ReadReceiptRecordResult] {
        guard (1...128).contains(expectedCount), results.count == expectedCount else {
            throw V2ActorRoomReceiptWireError.invalidResult
        }
        return try results.map { try $0.domainValue() }
    }
}

public enum V2ActorRoomReceiptDomainFailure: Error, Equatable, Sendable {
    case store(V2ReadReceiptStoreError)
    case serverBusy
}

public extension V2ActorRoomReceiptFailureWire {
    init(_ value: V2ReadReceiptStoreError) { self = .store(.init(value)) }
    init(_ value: V2ReadReceiptBatcherError) { self = .serverBusy }
    func domainValue() -> V2ActorRoomReceiptDomainFailure {
        switch self {
        case .store(let error): .store(error.domainValue())
        case .serverBusy: .serverBusy
        }
    }
}

public extension V2ActorReadReceiptCandidatePageWire {
    init(_ value: V2GroupReadReceiptReaderCandidatePage) {
        self.init(roomID: value.roomID, messageID: value.messageID,
            candidates: value.candidates.map {
                .init(userID: $0.userID, readThroughRoomSequence: $0.readThroughRoomSequence)
            }, nextCursor: value.nextCursor)
    }
    func domainValue() throws -> V2GroupReadReceiptReaderCandidatePage {
        guard candidates.count <= 100,
              Set(candidates.map(\.userID)).count == candidates.count,
              candidates.allSatisfy({ $0.readThroughRoomSequence <= UInt64(Int64.max) }) else {
            throw V2ActorRoomReceiptWireError.invalidResult
        }
        return .init(roomID: roomID, messageID: messageID,
            candidates: candidates.map { .init(userID: $0.userID,
                readThroughRoomSequence: $0.readThroughRoomSequence) }, nextCursor: nextCursor)
    }
}
