import Foundation
import Synchronization

enum V2BackgroundSessionKind: String, Codable, Sendable { case upload, download }

/// Reconnects a system identifier before Complete-protected business SQL can
/// open. Only opaque ids and a validated relative directory are persisted.
/// Resolving never creates an account directory or repairs a missing anchor.
struct V2BackgroundSessionDirectory: Sendable {
    private struct Route: Codable, Equatable {
        let version: Int
        let session: UUID
        let incarnation: UUID
        let components: [String]
        var kinds: Set<V2BackgroundSessionKind>
    }
    private struct Anchor: Codable, Equatable {
        let version: Int
        let session: UUID
        let incarnation: UUID
        let kinds: Set<V2BackgroundSessionKind>
    }
    private let directory: URL
    private let allowedRoot: URL
    private let protection: any V2ResourceFileProtectionWriting
    private static let io = Mutex(())
    init(directory: URL, allowedRoot: URL,
         protection: any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter()) throws {
        guard directory.isFileURL, allowedRoot.isFileURL else { throw V2ResourceStorageError.unsafeFile }
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.allowedRoot = allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.protection = protection
    }
    static func production() throws -> Self {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let base = support.appending(path: "IMV2BackgroundTransfers")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try V2SystemResourceFileProtectionWriter().apply(.untilFirstAuthentication, to: base)
        try V2LocalBackupExclusion.apply(to: base)
        // Account storage may legitimately be injected under Library, Documents
        // or tmp. Routes remain relative to this app container, never an
        // absolute path and never a path outside the sandbox.
        let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        return try .init(directory: base.appending(path: "session-routes"), allowedRoot: container)
    }
    func register(session: UUID, kind: V2BackgroundSessionKind, root: URL) throws {
        try Self.io.withLock { _ in
            try prepare()
            let components = try relativeComponents(root)
            guard root.pathExtension == "background", let incarnation = UUID(uuidString: root.deletingPathExtension().lastPathComponent),
                  root.deletingPathExtension().lastPathComponent == incarnation.uuidString else {
                throw V2BackgroundTransferError.mappingConflict
            }
            try requireDirectory(root)
            var route = Route(version: 1, session: session, incarnation: incarnation, components: components, kinds: [kind])
            if FileManager.default.fileExists(atPath: routeURL(session).path) {
                var previous: Route?
                do { previous = try readRoute(session) }
                catch {
                    // This trusted account factory may rebuild its corrupt
                    // small index. Event resolution itself never repairs it.
                    let facts = try routeURL(session).resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
                    guard facts.isRegularFile == true, facts.isSymbolicLink == false else { throw V2ResourceStorageError.unsafeFile }
                    if let anchor: Anchor = try? read(anchorURL(root, session)), anchor.version == 1,
                       anchor.session == session, anchor.incarnation == incarnation { route.kinds.formUnion(anchor.kinds) }
                }
                if let prior = previous {
                    guard prior.incarnation == incarnation, prior.components == components else { throw V2BackgroundTransferError.mappingConflict }
                    route.kinds.formUnion(prior.kinds)
                }
            } else {
                try pruneMissingRoots()
                guard try entries().count < 128 else { throw V2BackgroundTransferError.capacityExceeded }
            }
            // Anchor first: an interrupted index write is safely repairable by
            // the authenticated account factory, never by the event resolver.
            try write(Anchor(version: 1, session: session, incarnation: incarnation, kinds: route.kinds), to: anchorURL(root, session))
            try write(route, to: routeURL(session))
        }
    }
    func resolve(session: UUID, kind: V2BackgroundSessionKind) throws -> URL {
        try Self.io.withLock { _ in
            let route = try readRoute(session)
            guard route.kinds.contains(kind) else { throw V2BackgroundTransferError.mappingConflict }
            let root = try root(for: route)
            try requireDirectory(root)
            let anchor: Anchor = try read(anchorURL(root, session))
            guard anchor.version == 1, anchor.session == session, anchor.incarnation == route.incarnation,
                  anchor.kinds.contains(kind) else { throw V2BackgroundTransferError.mappingConflict }
            return root
        }
    }
    func unregister(session: UUID, kind: V2BackgroundSessionKind, root: URL) throws {
        try Self.io.withLock { _ in
            guard FileManager.default.fileExists(atPath: routeURL(session).path) else { return }
            var route = try readRoute(session)
            guard try self.root(for: route).path == root.standardizedFileURL.path else { throw V2BackgroundTransferError.mappingConflict }
            route.kinds.remove(kind)
            if route.kinds.isEmpty {
                try remove(routeURL(session)); try remove(anchorURL(root, session))
            } else {
                try write(Anchor(version: 1, session: session, incarnation: route.incarnation, kinds: route.kinds), to: anchorURL(root, session))
                try write(route, to: routeURL(session))
            }
        }
    }
    private func relativeComponents(_ root: URL) throws -> [String] {
        let base = allowedRoot.pathComponents, path = root.standardizedFileURL.pathComponents
        guard path.count > base.count, Array(path.prefix(base.count)) == base,
              root.resolvingSymlinksInPath().path == root.standardizedFileURL.path else { throw V2ResourceStorageError.unsafeFile }
        let parts = Array(path.dropFirst(base.count))
        try validate(parts)
        return parts
    }
    private func validate(_ parts: [String]) throws {
        guard (1...12).contains(parts.count), parts.reduce(0, { $0 + $1.utf8.count }) <= 1024,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 &&
                  !$0.contains("/") && !$0.contains("\\") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw V2ResourceStorageError.unsafeFile
        }
    }
    private func root(for route: Route) throws -> URL {
        try validate(route.components)
        let root = route.components.reduce(allowedRoot) { $0.appendingPathComponent($1) }
        guard root.pathExtension == "background", root.deletingPathExtension().lastPathComponent == route.incarnation.uuidString,
              root.resolvingSymlinksInPath().path == root.standardizedFileURL.path else { throw V2ResourceStorageError.unsafeFile }
        return root
    }
    private func readRoute(_ session: UUID) throws -> Route {
        let route: Route = try read(routeURL(session))
        guard route.version == 1, route.session == session, !route.kinds.isEmpty else { throw V2BackgroundTransferError.mappingConflict }
        _ = try root(for: route)
        return route
    }
    private func prepare() throws {
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw V2ResourceStorageError.unsafeFile }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireDirectory(directory)
        try protection.apply(.untilFirstAuthentication, to: directory)
        try V2LocalBackupExclusion.apply(to: directory)
    }
    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink == false,
              url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw V2ResourceStorageError.unsafeFile }
    }
    private func read<T: Decodable>(_ file: URL) throws -> T {
        guard file.deletingLastPathComponent().resolvingSymlinksInPath().path == file.deletingLastPathComponent().standardizedFileURL.path else { throw V2ResourceStorageError.unsafeFile }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false, let bytes = values.fileSize, bytes > 0, bytes <= 2048 else {
            throw V2BackgroundTransferError.mappingConflict
        }
        let data = try Data(contentsOf: file, options: .uncached)
        guard data.count <= 2048 else { throw V2BackgroundTransferError.mappingConflict }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 2048 else { throw V2BackgroundTransferError.mappingConflict }
        guard file.deletingLastPathComponent().resolvingSymlinksInPath().path == file.deletingLastPathComponent().standardizedFileURL.path else { throw V2ResourceStorageError.unsafeFile }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try protection.apply(.untilFirstAuthentication, to: file)
        try V2LocalBackupExclusion.apply(to: file)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
        try V2ResourceDirectoryIO.synchronize(file.deletingLastPathComponent())
    }
    private func entries() throws -> [URL] {
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]) else { throw V2ResourceStorageError.unavailable }
        var files: [URL] = [], scanned = 0
        for case let file as URL in iterator {
            guard scanned < 256 else { throw V2BackgroundTransferError.capacityExceeded }
            scanned += 1
            if file.pathExtension == "route" {
                guard files.count < 128 else { throw V2BackgroundTransferError.capacityExceeded }
                files.append(file)
            }
        }
        return files
    }
    private func pruneMissingRoots() throws {
        let files = try entries()
        guard files.count <= 128 else { throw V2BackgroundTransferError.capacityExceeded }
        for file in files {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), let route = try? readRoute(id),
                  let root = try? root(for: route) else { try remove(file); continue }
            if !FileManager.default.fileExists(atPath: root.path) { try remove(file) }
        }
    }
    private func remove(_ file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false,
              file.deletingLastPathComponent().resolvingSymlinksInPath().path == file.deletingLastPathComponent().standardizedFileURL.path else { throw V2ResourceStorageError.unsafeFile }
        try FileManager.default.removeItem(at: file)
        try V2ResourceDirectoryIO.synchronize(file.deletingLastPathComponent())
    }
    private func routeURL(_ session: UUID) -> URL { directory.appending(path: session.uuidString + ".route") }
    private func anchorURL(_ root: URL, _ session: UUID) -> URL { root.appending(path: ".session-" + session.uuidString) }
}
