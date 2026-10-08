//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import Foundation  // for Codable
import Logging
import NIO
import NIOFoundationCompat
import SwiftProtobuf

/// An explicitly opted-in argument can avoid a Codable wrapping allocation.
/// The declared distributed target type owns decoding, never a wire type hint.
/// Return nil only for a legacy encoding; malformed recognized bytes must throw.
public protocol ClusterBinaryInvocationArgument: Codable {
    func encodeClusterInvocationArgument() throws -> Data
    static func decodeClusterInvocationArgument(_ bytes: Data) throws -> Self?
}

public struct ClusterInvocationEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = any Codable

    var arguments: [Data] = []
    var genericSubstitutions: [String] = []
    var throwing: Bool = false

    let system: ClusterSystem

    init(system: ClusterSystem) {
        self.system = system
    }

    init(system: ClusterSystem, arguments: [Data]) {
        self.system = system
        self.arguments = arguments
        self.throwing = false
    }

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        let typeName = _mangledTypeName(type) ?? _typeName(type)
        self.genericSubstitutions.append(typeName)
    }

    public mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws {
        if self.system.settings.serialization.binaryDistributedInvocations,
            let binary = argument.value as? any ClusterBinaryInvocationArgument {
            self.arguments.append(try binary.encodeClusterInvocationArgument())
            return
        }
        let serialized = try self.system.serialization.serialize(argument.value)
        let data = serialized.buffer.readData()
        self.arguments.append(data)
    }

    public mutating func recordReturnType<Success: Codable>(_ returnType: Success.Type) throws {}

    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {
        self.throwing = true
    }

    public mutating func doneRecording() throws {
        // noop
    }
}

public struct ClusterInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = any Codable

    let system: ClusterSystem
    let state: _State
    enum _State {
        case remoteCall(message: InvocationMessage)
        // Potentially used by interceptors, when invoking a local target directly
        case localProxyCall(ClusterSystem.InvocationEncoder)
    }

    var argumentIdx = 0

    public init(system: ClusterSystem, message: InvocationMessage) {
        self.system = system
        self.state = .remoteCall(message: message)
    }

    init(system: ClusterSystem, invocation: ClusterSystem.InvocationEncoder) {
        self.system = system
        self.state = .localProxyCall(invocation)
    }

    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        let genericSubstitutions: [String]
        switch self.state {
        case .remoteCall(let message):
            genericSubstitutions = message.genericSubstitutions
        case .localProxyCall(let invocation):
            genericSubstitutions = invocation.genericSubstitutions
        }

        return try genericSubstitutions.map {
            guard let type = _typeByName($0) else {
                throw SerializationError(.notAbleToDeserialize(hint: $0))
            }
            return type
        }
    }

    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        let argumentData: Data

        switch self.state {
        case .remoteCall(let message):
            guard self.argumentIdx < message.arguments.count else {
                throw SerializationError(.notEnoughArgumentsEncoded(expected: self.argumentIdx + 1, have: message.arguments.count))
            }

            argumentData = message.arguments[self.argumentIdx]
            self.argumentIdx += 1

        case .localProxyCall(let invocation):
            // TODO: potentially able to optimize and avoid serialization round trip for such calls
            guard self.argumentIdx < invocation.arguments.count else {
                throw SerializationError(.notEnoughArgumentsEncoded(expected: self.argumentIdx + 1, have: invocation.arguments.count))
            }

            argumentData = invocation.arguments[self.argumentIdx]
            self.argumentIdx += 1
        }

        // Accept opted-in binary arguments independently of our outbound mode.
        // Legacy arguments still use their original Codable serializer.
        if let binaryType = Argument.self as? any ClusterBinaryInvocationArgument.Type,
            let decoded = try binaryType.decodeClusterInvocationArgument(argumentData) {
            guard let argument = decoded as? Argument else {
                throw SerializationError(.notAbleToDeserialize(hint: String(reflecting: Argument.self)))
            }
            return argument
        }

        // FIXME: make incoming manifest
        let manifest = try self.system.serialization.outboundManifest(Argument.self)

        let serialized = Serialization.Serialized(
            manifest: manifest,
            buffer: Serialization.Buffer.data(argumentData)
        )
        let argument = try self.system.serialization.deserialize(as: Argument.self, from: serialized)
        return argument
    }

    public mutating func decodeErrorType() throws -> Any.Type? {
        nil  // TODO(distributed): might need this
    }

    public mutating func decodeReturnType() throws -> Any.Type? {
        nil  // TODO(distributed): might need this
    }
}
