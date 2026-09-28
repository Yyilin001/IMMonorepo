import Foundation
import IMV2Core

/// The transport owns this ephemeral control; ordinary domain commands retain
/// their existing handler and prepared-page capabilities.
struct V2PresencePublicationGatewayHandler:V2GatewayCommandHandler,V2PreparedGroupEventCommandHandling {
    let delegate:any V2GatewayCommandHandler
    let registry:V2DeviceConnectionRegistry
    let connectionID:UUID
    func handle(envelope:IMV2Envelope,identity:V2AuthenticatedConnection) async throws -> IMV2Envelope {
        try await handle(envelope:envelope,identity:identity,originatingConnectionID:connectionID)
    }
    func handle(envelope:IMV2Envelope,identity:V2AuthenticatedConnection,originatingConnectionID:UUID?) async throws -> IMV2Envelope {
        guard case .presencePublicationControl(let input)=envelope.body else {
            return try await delegate.handle(envelope:envelope,identity:identity,originatingConnectionID:originatingConnectionID)
        }
        let mode:V2PresencePublicationMode
        switch input.mode {case .suppressed:mode = .suppressed;case .allowWhenAuthorized:mode = .allowWhenAuthorized;default:return failure("INVALID_ARGUMENT",retryable:false)}
        do {
            try await registry.setPresencePublication(connectionID:connectionID,identity:identity,mode:mode)
            var result=IMV2Envelope();result.presencePublicationControlled = .init();result.presencePublicationControlled.mode=input.mode
            return result
        } catch {return failure("UNAVAILABLE",retryable:true)}
    }
    func handlePreparedGroupEventPull(_ request:IMV2GroupEventPull,identity:V2AuthenticatedConnection,
        originatingConnectionID:UUID?,context:V2PreparedGroupEventCommandContext) async throws -> V2PreparedGroupEventGatewayResponse {
        if let prepared=delegate as? any V2PreparedGroupEventCommandHandling {
            return try await prepared.handlePreparedGroupEventPull(request,identity:identity,originatingConnectionID:originatingConnectionID,context:context)
        }
        var envelope=IMV2Envelope();envelope.requestID=context.requestID;envelope.protocolVersion=UInt32(context.frameVersion);envelope.groupEventPull=request
        return .envelope(try await delegate.handle(envelope:envelope,identity:identity,originatingConnectionID:originatingConnectionID))
    }
    private func failure(_ code:String,retryable:Bool)->IMV2Envelope {
        var result=IMV2Envelope();result.error = .init();result.error.code=code;result.error.retryable=retryable;return result
    }
}
