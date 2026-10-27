import Foundation
import Testing
@testable import IMV2ClientKit

@Suite("Minimal background-session routing without business SQL", .timeLimit(.minutes(1)))
struct V2BackgroundSessionDirectoryTests {
    @Test func validInjectedStorageElsewhereInContainerIsStillRoutable() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let directory = try V2BackgroundSessionDirectory(directory: f.routes, allowedRoot: f.root)
        let injected = f.root.appending(path: "tmp").appending(path: UUID().uuidString + ".background")
        try FileManager.default.createDirectory(at: injected, withIntermediateDirectories: true)
        let id = UUID()
        try directory.register(session: id, kind: .download, root: injected)
        #expect(try directory.resolve(session: id, kind: .download).path == injected.path)
        let outside = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".background")
        #expect(throws: V2ResourceStorageError.unsafeFile) { try directory.register(session: UUID(), kind: .upload, root: outside) }
    }
    @Test func authenticatedFactoryRepairsItsCorruptIndexButEventResolutionDoesNot() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), directory = try f.directory()
        try directory.register(session: id, kind: .upload, root: f.account)
        try directory.register(session: id, kind: .download, root: f.account)
        try Data("invalid-index".utf8).write(to: f.route(id))
        #expect(throws: (any Error).self) { try directory.resolve(session: id, kind: .download) }
        #expect(try Data(contentsOf: f.route(id)) == Data("invalid-index".utf8))
        try directory.register(session: id, kind: .upload, root: f.account)
        #expect(try directory.resolve(session: id, kind: .download).path == f.account.path)
        #expect(try directory.resolve(session: id, kind: .upload).path == f.account.path)
    }
    @Test func resolvesBothKindsAfterColdReconstructionWithoutBusinessDirectory() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), directory = try f.directory()
        try directory.register(session: id, kind: .upload, root: f.account)
        #expect(throws: V2BackgroundTransferError.mappingConflict) { try directory.resolve(session: id, kind: .download) }
        try directory.register(session: id, kind: .download, root: f.account)
        let protected = f.account.deletingPathExtension()
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: false)
        try Data("private message / auth token / signed https://object.invalid".utf8).write(to: protected.appending(path: "V2.sqlite"))
        try FileManager.default.removeItem(at: protected)
        let cold = try f.directory()
        for kind in [V2BackgroundSessionKind.upload,.download] { #expect(try cold.resolve(session: id, kind: kind).path == f.account.path) }
        let text = try String(contentsOf: f.route(id), encoding: .utf8)
        #expect(!text.contains("private message") && !text.contains("auth token") && !text.contains("https://") && !text.contains("V2.sqlite"))
        #expect(!text.contains(f.root.path))
        #expect(try f.route(id).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func removingOneKindDoesNotDisableTheOtherAndCloseIsIdempotent() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), directory = try f.directory()
        try directory.register(session: id, kind: .upload, root: f.account)
        try directory.register(session: id, kind: .download, root: f.account)
        try directory.unregister(session: id, kind: .upload, root: f.account)
        #expect(throws: V2BackgroundTransferError.mappingConflict) { try directory.resolve(session: id, kind: .upload) }
        #expect(try directory.resolve(session: id, kind: .download).path == f.account.path)
        try directory.unregister(session: id, kind: .download, root: f.account)
        try directory.unregister(session: id, kind: .download, root: f.account)
        #expect(!FileManager.default.fileExists(atPath: f.route(id).path))
        #expect(throws: (any Error).self) { try directory.resolve(session: id, kind: .download) }
    }

    @Test func retiredRootIsNeverRecreatedOrRetargetedAndDanglingIndexIsPruned() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), directory = try f.directory()
        try directory.register(session: id, kind: .upload, root: f.account)
        try FileManager.default.removeItem(at: f.account)
        #expect(throws: (any Error).self) { try directory.resolve(session: id, kind: .upload) }
        #expect(!FileManager.default.fileExists(atPath: f.account.path))
        let replacement = f.account.deletingLastPathComponent().appending(path: UUID().uuidString + ".background")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        #expect(throws: V2BackgroundTransferError.mappingConflict) { try directory.register(session: id, kind: .upload, root: replacement) }
        try directory.register(session: UUID(), kind: .download, root: replacement)
        #expect(!FileManager.default.fileExists(atPath: f.route(id).path))
        #expect(!FileManager.default.fileExists(atPath: f.account.path))
        #expect(FileManager.default.fileExists(atPath: replacement.path))
    }

    @Test(arguments: [["..","outside"],["/absolute"],["a\\b"],["."]])
    func malformedRelativePathCannotEscapeOrSelectAnotherAccount(parts: [String]) throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), directory = try f.directory()
        try directory.register(session: id, kind: .download, root: f.account)
        var body = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.route(id))) as? [String: Any])
        body["components"] = parts
        try JSONSerialization.data(withJSONObject: body).write(to: f.route(id))
        #expect(throws: V2ResourceStorageError.unsafeFile) { try directory.resolve(session: id, kind: .download) }
        #expect(FileManager.default.fileExists(atPath: f.account.path))
    }

    @Test func sourceSymlinkAndReplacedAnchorCannotRedirectEvents() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), directory = try f.directory()
        try directory.register(session: id, kind: .download, root: f.account)
        let moved = f.account.appendingPathExtension("saved"), foreign = f.root.appending(path: "foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: f.account, to: moved)
        try FileManager.default.createSymbolicLink(at: f.account, withDestinationURL: foreign)
        #expect(throws: V2ResourceStorageError.unsafeFile) { try directory.resolve(session: id, kind: .download) }
        try FileManager.default.removeItem(at: f.account)
        try FileManager.default.moveItem(at: moved, to: f.account)
        let anchor = f.account.appending(path: ".session-" + id.uuidString)
        var body = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: anchor)) as? [String: Any])
        body["session"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: body).write(to: anchor)
        #expect(throws: V2BackgroundTransferError.mappingConflict) { try directory.resolve(session: id, kind: .download) }
    }

    @Test func oversizedAndSymlinkedIndexFailWithoutReadingForeignBytes() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), directory = try f.directory()
        try directory.register(session: id, kind: .upload, root: f.account)
        try Data(repeating: 65, count: 2049).write(to: f.route(id))
        #expect(throws: V2BackgroundTransferError.mappingConflict) { try directory.resolve(session: id, kind: .upload) }
        let foreign = f.root.appending(path: "foreign.json")
        try Data("preserve".utf8).write(to: foreign)
        try FileManager.default.removeItem(at: f.route(id))
        try FileManager.default.createSymbolicLink(at: f.route(id), withDestinationURL: foreign)
        #expect(throws: V2BackgroundTransferError.mappingConflict) { try directory.resolve(session: id, kind: .upload) }
        #expect(try Data(contentsOf: foreign) == Data("preserve".utf8))
    }

    @Test func recordCountIsBoundedAndExistingSessionCanAddItsOtherKindAtCapacity() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let directory = try f.directory(), ids = (0..<128).map { _ in UUID() }
        for id in ids { try directory.register(session: id, kind: .upload, root: f.account) }
        #expect(throws: V2BackgroundTransferError.capacityExceeded) { try directory.register(session: UUID(), kind: .upload, root: f.account) }
        let first = try #require(ids.first)
        try directory.register(session: first, kind: .download, root: f.account)
        #expect(try directory.resolve(session: first, kind: .download).path == f.account.path)
    }

    private struct Fixture {
        let root: URL, allowed: URL, routes: URL, account: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "background-route-\(UUID())")
            allowed = root.appending(path: "support"); routes = allowed.appending(path: "routes")
            account = allowed.appending(path: "accounts").appending(path: UUID().uuidString + ".background")
            try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        }
        func directory() throws -> V2BackgroundSessionDirectory { try .init(directory: routes, allowedRoot: allowed) }
        func route(_ id: UUID) -> URL { routes.appending(path: id.uuidString + ".route") }
    }
}
