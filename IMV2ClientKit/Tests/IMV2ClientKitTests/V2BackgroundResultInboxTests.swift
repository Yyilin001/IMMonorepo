import Foundation
import Testing
@testable import IMV2ClientKit

@Suite("Opaque background results stay inside their owned directory", .timeLimit(.minutes(1)))
struct V2BackgroundResultInboxTests {
    @Test func roundTripReplacementAndRemovalKeepTheSameMapping() throws {
        let f = try Fixture(); defer { f.remove() }
        let inbox = try f.inbox()
        try inbox.write(f.result())
        try inbox.write(f.result(status: 503))
        #expect(try inbox.results() == [f.result(status: 503)])
        try inbox.remove(f.mapping)
        try inbox.remove(f.mapping)
        #expect(try inbox.results().isEmpty)
    }

    @Test func aSessionDirectorySymlinkCannotRedirectTheCallbackWrite() throws {
        let f = try Fixture(); defer { f.remove() }
        try FileManager.default.createSymbolicLink(at: f.sessionDirectory, withDestinationURL: f.external)
        #expect(throws: V2ResourceStorageError.unsafeFile) {
            let inbox = try f.inbox()
            try inbox.write(f.result())
        }
        #expect(!FileManager.default.fileExists(atPath: f.externalResult.path))
    }

    @Test(arguments: [Action.read, .write, .remove])
    func aReplacedSessionDirectoryCannotReadChangeOrDeleteOutsideFiles(_ action: Action) throws {
        let f = try Fixture(); defer { f.remove() }
        let inbox = try f.inbox(), original = try JSONEncoder().encode(f.result(status: 418))
        try original.write(to: f.externalResult)
        try FileManager.default.removeItem(at: f.sessionDirectory)
        try FileManager.default.createSymbolicLink(at: f.sessionDirectory, withDestinationURL: f.external)
        #expect(throws: V2ResourceStorageError.unsafeFile) { try action.perform(on: inbox, result: f.result()) }
        #expect((try? Data(contentsOf: f.externalResult)) == original)
    }

    @Test(arguments: [Action.read, .write, .remove])
    func resultFileSymlinksAreRejectedBeforeTheyAreReadOrChanged(_ action: Action) throws {
        let f = try Fixture(); defer { f.remove() }
        let inbox = try f.inbox(), original = try JSONEncoder().encode(f.result(status: 418))
        try original.write(to: f.externalResult)
        try FileManager.default.createSymbolicLink(at: f.resultFile, withDestinationURL: f.externalResult)
        #expect(throws: V2ResourceStorageError.unsafeFile) { try action.perform(on: inbox, result: f.result()) }
        #expect((try? Data(contentsOf: f.externalResult)) == original)
    }

    @Test func aFailedWriteMustNotDeleteAnUnexpectedDirectory() throws {
        let f = try Fixture(); defer { f.remove() }
        let inbox = try f.inbox()
        try FileManager.default.createDirectory(at: f.resultFile, withIntermediateDirectories: false)
        let marker = f.resultFile.appending(path: "keep-this-file")
        try Data([1, 2, 3]).write(to: marker)
        #expect(throws: V2ResourceStorageError.unsafeFile) { try inbox.write(f.result()) }
        #expect((try? Data(contentsOf: marker)) == Data([1, 2, 3]))
    }

    @Test(arguments: [true, false])
    func resultsRequireACanonicalFilenameMatchingTheDecodedMapping(_ useAnotherID: Bool) throws {
        let f = try Fixture(); defer { f.remove() }
        let inbox = try f.inbox()
        let name = useAnotherID ? UUID().uuidString : "not-a-mapping"
        try JSONEncoder().encode(f.result()).write(to: f.sessionDirectory.appending(path: name + ".result"))
        #expect(throws: V2BackgroundTransferError.mappingConflict) { _ = try inbox.results() }
    }

    @Test func scanningUnrelatedEntriesIsBounded() throws {
        let f = try Fixture(); defer { f.remove() }
        let inbox = try f.inbox()
        for index in 0..<257 { try Data().write(to: f.sessionDirectory.appending(path: "other-\(index)")) }
        #expect(throws: V2BackgroundTransferError.capacityExceeded) { _ = try inbox.results() }
    }

    @Test func fullInboxStillAcceptsADuplicateButCannotAdmitAnotherMapping() throws {
        let f = try Fixture(); defer { f.remove() }
        let inbox = try f.inbox()
        for index in 0..<128 {
            let result = index == 0 ? f.result() : f.result(mapping: UUID())
            try JSONEncoder().encode(result).write(to: f.sessionDirectory.appending(path: result.mappingID.uuidString + ".result"))
        }
        try inbox.write(f.result(status: 503))
        let another = f.result(mapping: UUID())
        #expect(throws: V2BackgroundTransferError.capacityExceeded) { try inbox.write(another) }
        #expect(try inbox.results().count == 128)
        #expect(try inbox.results().first(where: { $0.mappingID == f.mapping })?.statusCode == 503)
        #expect(!FileManager.default.fileExists(atPath: f.sessionDirectory.appending(path: another.mappingID.uuidString + ".result").path))
    }

    enum Action: Sendable {
        case read, write, remove
        func perform(on inbox: V2BackgroundResultInbox, result: V2BackgroundTransferResult) throws {
            switch self {
            case .read: _ = try inbox.results()
            case .write: try inbox.write(result)
            case .remove: try inbox.remove(result.mappingID)
            }
        }
    }

    private struct Fixture {
        let root: URL
        let session = UUID(), mapping = UUID()
        var owned: URL { root.appending(path: "owned") }
        var external: URL { root.appending(path: "external") }
        var sessionDirectory: URL { owned.appending(path: session.uuidString) }
        var resultFile: URL { sessionDirectory.appending(path: mapping.uuidString + ".result") }
        var externalResult: URL { external.appending(path: mapping.uuidString + ".result") }
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "background-result-ownership-\(UUID())")
            for directory in [owned, external] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        func inbox() throws -> V2BackgroundResultInbox { try .init(root: owned, sessionID: session) }
        func result(status: Int = 200, mapping: UUID? = nil) -> V2BackgroundTransferResult {
            .init(mappingID: mapping ?? self.mapping, taskIdentifier: 1, statusCode: status, errorCode: nil, sentBytes: 4)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
