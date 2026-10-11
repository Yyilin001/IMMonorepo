import Foundation
import IMV2ActorContracts
import SwiftProtobuf

extension V2ActorRPCRequest: V2ActorProtobufMessage {
    package var usesHotProtobuf: Bool { switch self { case .invoke, .lookup, .subscriptionRenewBatch: true; default: false } }
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotRPCRequest()
        switch self {
        case .invoke(let token, let request): var value = Im_Actor_V1_HotInvoke(); value.token = .init(token); value.request = try request.hotWire(); wire.invoke = value
        case .lookup(let token): wire.lookup = .init(token)
        case .subscriptionRenewBatch(let items):
            var value = Im_Actor_V1_HotRenewBatch()
            value.items = items.map { item in var v = Im_Actor_V1_HotRenewItem(); v.token = .init(item.token); v.command = .init(.renew(item.command)); return v }; wire.renew = value
        default: wire.coldValue = try V2ActorProtobuf.encodeValue(self)
        }
        return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotRPCRequest(serializedBytes: copy bytes); try V2HotPB.check(wire)
        switch wire.operation {
        case .invoke(let value): try V2HotPB.check(value, value.hasToken && value.hasRequest); return .invoke(token: try value.token.model(), request: try value.request.model())
        case .lookup(let value): return .lookup(try value.model())
        case .renew(let value):
            try V2HotPB.check(value)
            return .subscriptionRenewBatch(try value.items.map { item in
                try V2HotPB.check(item, item.hasToken && item.hasCommand)
                guard case .renew(let command) = try item.command.model() else { throw V2HotPB.Invalid.value }
                return try .init(token: item.token.model(), command: command)
            })
        case .coldValue(let bytes): let value = try V2ActorProtobuf.decodeValue(Self.self, from: bytes); guard !value.usesHotProtobuf else { throw V2HotPB.Invalid.value }; return value
        default: throw V2HotPB.Invalid.value
        }
    }
}
extension V2ActorRPCResponse: V2ActorProtobufMessage {
    package var usesHotProtobuf: Bool { switch self { case .result, .ready, .subscriptionRenewBatch, .completed, .acknowledged: true; default: false } }
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotRPCResponse()
        switch self {
        case .result(let response): wire.response = try response.hotWire()
        case .ready(let token, let reference): var value = Im_Actor_V1_HotReady(); value.token = .init(token); value.physicalReference = reference; wire.ready = value
        case .subscriptionRenewBatch(let items):
            var value = Im_Actor_V1_HotRenewResults()
            value.items = try items.map { item in
                var v = Im_Actor_V1_HotRenewOutcome(); v.token = .init(item.token)
                switch item.outcome { case .result(let result): v.result = .init(result); case .failure(let failure): v.coldFailure = try V2ActorProtobuf.encodeValue(failure) }; return v
            }; wire.renew = value
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
        case .renew(let value):
            try V2HotPB.check(value)
            return .subscriptionRenewBatch(try value.items.map { item in
                try V2HotPB.check(item, item.hasToken)
                let outcome: V2RoomSubscriptionRenewBatchOutcome.Outcome
                switch item.outcome { case .result(let result): outcome = .result(try result.model()); case .coldFailure(let bytes): outcome = .failure(try V2ActorProtobuf.decodeValue(V2RoomCallFailure.self, from: bytes)); default: throw V2HotPB.Invalid.value }
                return try .init(token: item.token.model(), outcome: outcome)
            })
        case .completed(let value): return .completed(value)
        case .acknowledged(let value): try V2HotPB.check(value); return .acknowledged
        case .coldValue(let bytes): let value = try V2ActorProtobuf.decodeValue(Self.self, from: bytes); guard !value.usesHotProtobuf else { throw V2HotPB.Invalid.value }; return value
        default: throw V2HotPB.Invalid.value
        }
    }
}
