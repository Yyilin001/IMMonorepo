//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2026 IMV2 contributors
// Licensed under Apache License v2.0
// See LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

/// An untrusted peer declared a frame too large to buffer or deserialize.
internal enum ClusterInboundFrameError: Error, Equatable {
    case declaredLengthExceedsLimit(declared: Int, maximum: Int)
    case incompleteFrame
}

/// Both transport directions use this same reader and close-on-error handler.
/// The magic validator and TLS handler (when configured) precede it.
internal enum ClusterTransportFraming {
    static func accepting(limit: ClusterInboundFrameLimit) -> [(String?, ChannelHandler)] {
        self.handlers(limit: limit)
    }

    static func initiating(limit: ClusterInboundFrameLimit) -> [(String?, ChannelHandler)] {
        self.handlers(limit: limit)
    }

    private static func handlers(limit: ClusterInboundFrameLimit) -> [(String?, ChannelHandler)] {
        [
            ("framing reader", ByteToMessageHandler(
                BoundedLengthFieldFrameDecoder(maximumFrameBytes: limit.bytes),
                maximumBufferSize: limit.bytes + MemoryLayout<UInt32>.size
            )),
            ("framing failure closer", InboundFrameFailureCloser()),
        ]
    }
}

/// Reads the existing four-byte big-endian payload length. Inspecting the
/// complete header before waiting for any body bytes is the security boundary.
internal struct BoundedLengthFieldFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    let maximumFrameBytes: Int

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let headerBytes = MemoryLayout<UInt32>.size
        guard let declared: UInt32 = buffer.getInteger(at: buffer.readerIndex, endianness: .big) else {
            return .needMoreData
        }
        guard Int(declared) <= maximumFrameBytes else {
            throw ClusterInboundFrameError.declaredLengthExceedsLimit(
                declared: Int(declared), maximum: maximumFrameBytes
            )
        }
        let frameBytes = Int(declared)
        guard buffer.readableBytes >= headerBytes + frameBytes else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: headerBytes)
        // The guard above guarantees a complete slice, including zero length.
        let frame = buffer.readSlice(length: frameBytes)!
        context.fireChannelRead(self.wrapInboundOut(frame))
        return .continue
    }

    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        let result = try self.decode(context: context, buffer: &buffer)
        if seenEOF && result == .needMoreData && buffer.readableBytes > 0 {
            throw ClusterInboundFrameError.incompleteFrame
        }
        return result
    }
}

/// NIO's cumulation bound also raises errors for malformed buffering patterns.
/// Closing here handles both the declared-length and cumulation failure paths.
private final class InboundFrameFailureCloser: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}
