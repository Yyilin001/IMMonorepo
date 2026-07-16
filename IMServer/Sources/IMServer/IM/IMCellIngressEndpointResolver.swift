import Foundation
import Vapor

private actor IMCellIngressEndpointCache {
    private struct Entry: Sendable {
        let endpoint: String
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]

    func endpoint(for key: String) -> String? {
        guard let entry = entries[key], entry.expiresAt > Date() else {
            entries[key] = nil
            return nil
        }
        return entry.endpoint
    }

    func store(_ endpoint: String, for key: String, ttlSeconds: Int) {
        entries[key] = Entry(
            endpoint: endpoint,
            expiresAt: Date().addingTimeInterval(TimeInterval(max(1, ttlSeconds)))
        )
    }

    func invalidate(cellID: String) {
        for purpose in IMCellIngressEndpointPurpose.allCases {
            entries[Self.key(cellID: cellID, purpose: purpose)] = nil
        }
    }

    static func key(cellID: String, purpose: IMCellIngressEndpointPurpose) -> String {
        "\(cellID):\(purpose.rawValue)"
    }
}

private struct IMCellIngressEndpointCacheStorageKey: StorageKey {
    typealias Value = IMCellIngressEndpointCache
}

extension Application {
    fileprivate var cellIngressEndpointCache: IMCellIngressEndpointCache {
        if let cache = storage[IMCellIngressEndpointCacheStorageKey.self] {
            return cache
        }
        let cache = IMCellIngressEndpointCache()
        storage[IMCellIngressEndpointCacheStorageKey.self] = cache
        return cache
    }

    var cellIngressEndpointResolver: IMCellIngressEndpointResolver {
        IMCellIngressEndpointResolver(app: self)
    }
}

struct IMCellIngressEndpointResolver: Sendable {
    let app: Application

    func endpoint(
        for cellID: String,
        purpose: IMCellIngressEndpointPurpose
    ) async throws -> String? {
        let configuration = app.cellIngressRegistryConfiguration
        switch configuration.mode {
        case .staticEndpoints:
            return app.cellIngressConfiguration.endpoint(for: cellID, purpose: purpose)
        case .database:
            let key = IMCellIngressEndpointCache.key(cellID: cellID, purpose: purpose)
            if let cached = await app.cellIngressEndpointCache.endpoint(for: key) {
                return cached
            }
            guard let entry = try await IMRealtimeCellRegistryEntry.find(cellID, on: app.db),
                  entry.statusEnum != .disabled
            else {
                return nil
            }
            let endpoint = entry.endpoint(for: purpose)
            await app.cellIngressEndpointCache.store(
                endpoint,
                for: key,
                ttlSeconds: configuration.cacheTTLSeconds
            )
            return endpoint
        }
    }
}

struct IMCellIngressRegistryService {
    let app: Application

    func upsert(
        cellID rawCellID: String,
        status: IMRealtimeCellRegistryStatus,
        commandEndpoint: String,
        queryEndpoint: String,
        realtimeEndpoint: String
    ) async throws -> IMRealtimeCellRegistryEntry {
        let cellID = rawCellID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IMRealtimeCellConfiguration.isValid(cellID: cellID) else {
            throw Abort(.badRequest, reason: "Invalid realtime Cell ID.")
        }
        let commandEndpoint = try validateEndpoint(commandEndpoint, purpose: .command)
        let queryEndpoint = try validateEndpoint(queryEndpoint, purpose: .query)
        let realtimeEndpoint = try validateEndpoint(realtimeEndpoint, purpose: .realtime)

        let entry = try await IMRealtimeCellRegistryEntry.find(cellID, on: app.db)
            ?? IMRealtimeCellRegistryEntry(
                cellID: cellID,
                status: status,
                commandEndpoint: commandEndpoint,
                queryEndpoint: queryEndpoint,
                realtimeEndpoint: realtimeEndpoint
            )
        entry.statusEnum = status
        entry.commandEndpoint = commandEndpoint
        entry.queryEndpoint = queryEndpoint
        entry.realtimeEndpoint = realtimeEndpoint
        if try await IMRealtimeCellRegistryEntry.find(cellID, on: app.db) == nil {
            try await entry.create(on: app.db)
        } else {
            try await entry.update(on: app.db)
        }
        await app.cellIngressEndpointCache.invalidate(cellID: cellID)
        return entry
    }

    private func validateEndpoint(
        _ rawEndpoint: String,
        purpose: IMCellIngressEndpointPurpose
    ) throws -> String {
        let endpoint = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: endpoint),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty
        else {
            throw Abort(.badRequest, reason: "Cell \(purpose.rawValue) ingress endpoint must use https and include a host.")
        }
        return endpoint
    }
}
