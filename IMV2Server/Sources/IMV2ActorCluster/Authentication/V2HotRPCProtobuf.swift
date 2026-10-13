import Foundation
import IMV2ActorContracts
import SwiftProtobuf

extension V2ActorRPCRequest: V2ActorProtobufMessage {
    package var usesHotProtobuf: Bool { switch self { case .invoke, .lookup: true; default: false } }
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotRPCRequest()
        switch self {
        case .invoke(let token, let request): var value = Im_Actor_V1_HotInvoke(); value.token = .init(token); value.request = try request.hotWire(); wire.invoke = value
        case .lookup(let token): wire.lookup = .init(token)
        default: wire.coldValue = try V2ActorProtobuf.encodeValue(self)
        }
        return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotRPCRequest(serializedBytes: copy bytes); try V2HotPB.check(wire)
        switch wire.operation {
        case .invoke(let value): try V2HotPB.check(value, value.hasToken && value.hasRequest); return .invoke(token: try value.token.model(), request: try value.request.model())
        case .lookup(let value): return .lookup(try value.model())
        case .coldValue(let bytes): let value = try V2ActorProtobuf.decodeValue(Self.self, from: bytes); guard !value.usesHotProtobuf else { throw V2HotPB.Invalid.value }; return value
        default: throw V2HotPB.Invalid.value
        }
    }
}
extension V2ActorRPCResponse: V2ActorProtobufMessage {
    package var usesHotProtobuf: Bool { switch self { case .result, .ready, .completed, .acknowledged: true; default: false } }
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotRPCResponse()
        switch self {
        case .result(let response): wire.response = try response.hotWire()
        case .ready(let token, let reference): var value = Im_Actor_V1_HotReady(); value.token = .init(token); value.physicalReference = reference; wire.ready = value
        case .completed(let value): wire.completed = value
        case .acknowledged: wire.acknowledged = .init()
        default: wire.coldValue = try V2ActorProtobuf.encodeValue(self)
        }
        return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotRPCResponse(serializedBytes: copy bytes); try V2HotPB.check(wire)
        switch wire.result {
        case .response(let value): return .result(try value.model())
        case .ready(let value): try V2HotPB.check(value, value.hasToken); return .ready(token: try value.token.model(), physicalReference: value.physicalReference)
        case .completed(let value): return .completed(value)
        case .acknowledged(let value): try V2HotPB.check(value); return .acknowledged
        case .coldValue(let bytes): let value = try V2ActorProtobuf.decodeValue(Self.self, from: bytes); guard !value.usesHotProtobuf else { throw V2HotPB.Invalid.value }; return value
        default: throw V2HotPB.Invalid.value
        }
    }
}
