import Foundation
import IMV2Core
import NIOCore

/// Own the payload across actor/task boundaries; borrow it only while decoding.
/// The header has no payload and is used by the connection state machine.
struct V2GatewayInboundFrame: Sendable {
    var heartbeatProbe: V2GatewayHeartbeatProbe?
    let header: V2Frame
    private enum Storage: Sendable { case data(Data), buffer(ByteBuffer) }
    private let storage: Storage
    var version: UInt8 { header.version }
    var flags: V2FrameFlags { header.flags }
    var command: V2FrameCommand { header.command }
    var requestID: UInt64 { header.requestID }
    var payloadCount: Int {
        switch storage {
        case .data(let data): data.count
        case .buffer(let buffer): buffer.readableBytes
        }
    }
    init(_ frame: V2Frame) {
        header = .init(version: frame.version, flags: frame.flags, command: frame.command,
            requestID: frame.requestID, payload: Data())
        storage = .data(frame.payload)
    }
    init(header: V2Frame, payload: ByteBuffer) {
        self.header = header
        storage = .buffer(payload)
    }
    func withPayload<R>(_ body: (borrowing RawSpan) throws -> R) rethrows -> R {
        switch storage {
        case .data(let data): try body(data.bytes)
        case .buffer(let buffer): try body(buffer.readableBytesSpan)
        }
    }
}

/// Channel-confined framing. Advancing readerIndex doesn't copy the suffix.
/// A complete payload slice owns its storage until its business task finishes.
struct V2NIOInboundFrameDecoder {
    private let limits: V2FrameLimits
    private var allowsLargeMessageSendFrames = false
    private var buffered = ByteBuffer()
    init(limits: V2FrameLimits) { self.limits = limits }
    var hasBufferedBytes: Bool { buffered.readableBytes > 0 }
    mutating func setAllowsLargeMessageSendFrames(_ allowed: Bool) {
        allowsLargeMessageSendFrames = allowed
    }
    mutating func append(_ bytes: ByteBuffer) throws -> [V2GatewayInboundFrame] {
        if buffered.readableBytes == 0 { buffered = bytes }
        else if bytes.readableBytes > 0 {
            // Only fragmented/coalesced remainder needs accumulation. Compact
            // occasionally, rather than rebuilding the suffix after each batch.
            if buffered.readerIndex >= 16_384 { buffered.discardReadBytes() }
            var bytes = bytes
            buffered.writeBuffer(&bytes)
        }
        var frames: [V2GatewayInboundFrame] = []
        while frames.count < limits.maximumFramesPerAppend,
              buffered.readableBytes >= V2Frame.headerLength {
            let start = buffered.readerIndex
            guard buffered.getInteger(at: start, as: UInt16.self) == V2Frame.magic else {
                throw V2FrameCodecError.invalidMagic
            }
            let version = buffered.getInteger(at: start + 2, as: UInt8.self)!
            guard limits.acceptedVersions.contains(version) else {
                throw V2FrameCodecError.unsupportedVersion(version)
            }
            let command = V2FrameCommand(rawValue: buffered.getInteger(at: start + 4, as: UInt16.self)!)
            if command.isMessageSendOperation && version < 45 {
                throw V2FrameCodecError.unsupportedVersion(version)
            }
            let length = Int(buffered.getInteger(at: start + 14, as: UInt32.self)!)
            let maximum = allowsLargeMessageSendFrames
                ? limits.maximumPayloadBytes(for: command, version: version) : limits.maximumPayloadBytes
            guard length <= maximum else { throw V2FrameCodecError.declaredPayloadTooLarge(length) }
            guard buffered.readableBytes - V2Frame.headerLength >= length else { break }
            let header = V2Frame(version: version,
                flags: .init(rawValue: buffered.getInteger(at: start + 3, as: UInt8.self)!),
                command: command,
                requestID: buffered.getInteger(at: start + 6, as: UInt64.self)!, payload: Data())
            let capacity = buffered.storageCapacity
            buffered.moveReaderIndex(forwardBy: V2Frame.headerLength)
            var payload = buffered.readSlice(length: length)!
            // A delayed small request must not pin an oversized receive buffer.
            if capacity > max(16_384, length * 4) {
                var owned = ByteBufferAllocator().buffer(capacity: length)
                owned.writeBuffer(&payload)
                payload = owned
            }
            frames.append(.init(header: header, payload: payload))
        }
        if buffered.readableBytes == 0 { buffered = ByteBuffer() }
        return frames
    }
    func finish() throws {
        guard !hasBufferedBytes else { throw V2FrameCodecError.trailingPartialFrame }
    }
}
