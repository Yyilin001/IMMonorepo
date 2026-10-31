#if os(macOS)
import CoreGraphics
import Crypto
import Foundation
import ImageIO
import IMV2Core
import Network
import Security
import Testing
import UniformTypeIdentifiers
@testable import IMV2ClientKit

/// Opt in only through verify_v2_live_resource_authors.py --author-capacity.
/// All peers use the production wire, repositories and page/room coordinators.
/// Only the initial account/member population is seeded; subsequent operations
/// go through real HTTP/TLS/Actor/database/byte-serving boundaries.
@Suite("Live ClientKit author capacity", .serialized, .timeLimit(.minutes(15)),
       .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_AUTHOR_CAPACITY"] != nil))
struct V2LiveAuthorCapacityTests {
    @Test func realClientKitAuthorFanout() async throws {
        let count = try #require(ProcessInfo.processInfo.environment["IMV2_LIVE_AUTHOR_CAPACITY"].flatMap(Int.init))
        let process = try #require(ProcessInfo.processInfo.environment["IMV2_LIVE_AUTHOR_PROCESS"].flatMap(Int.init))
        let processes = try #require(ProcessInfo.processInfo.environment["IMV2_LIVE_AUTHOR_PROCESSES"].flatMap(Int.init))
        let renewalSeconds = Int(ProcessInfo.processInfo.environment["IMV2_LIVE_AUTHOR_RENEWAL_SECONDS"] ?? "0") ?? -1
        let replaceAvatar = ProcessInfo.processInfo.environment["IMV2_LIVE_AUTHOR_AVATAR_REPLACEMENT"] == "1"
        let faults = ProcessInfo.processInfo.environment["IMV2_LIVE_AUTHOR_FAULTS"] == "1"
        try #require(processes > 0 && (0..<processes).contains(process))
        try #require(renewalSeconds == 0 || (35...120).contains(renewalSeconds))
        let fixture = try LiveAccountFixture(); defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "author-capacity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var authorControl: (client: V2HTTPOwnProfileClient, revision: V2ProfileRevision, credentials: CapacityCredentials)?
        if process == 0 {
            let account = try await fixture.register().credentials
            let author = CapacityCredentials(userID: account.userID, deviceID: account.deviceID, accessToken: account.accessToken)
            let media = try await uploadAvatar(fixture, credentials: author, directory: directory)
            let own = try V2HTTPOwnProfileClient(endpoint: fixture.url("v2/profile/me"), credentials: author,
                transport: V2URLSessionPushEndpointHTTPTransport(session: fixture.http))
            let profile = try await own.currentProfile()
            let patched = try await own.patchProfile(.init(actorUserID: author.userID, operationID: .init(uuid: UUID()),
                expectedRevision: profile.revision, patch: .init(displayName: .set("Capacity author v1"), avatar: .set(.init(mediaID: media))),
                firstSubmissionDeadlineMilliseconds: UInt64(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000)))
            authorControl = (own, try #require(patched.currentSnapshot).revision, author)
            let _: CapacityReady = try await fixtureRequest(fixture, path: "seed", body: ["author": author.userID.rawValue,
                "device": author.deviceID.rawValue, "token": author.accessToken, "media": media.rawValue])
        }
        let seeded = try await assignment(fixture, process: process)
        try #require(seeded.credentials.count == (process + 1) * count / processes - process * count / processes)
        let key = V2ProfileViewLookupKey(userID: seeded.authorUserID, context: .room(seeded.roomID))
        let counters = CapacityCounters()
        let bootstrap = CapacityBootstrapProgress()
        var peers: [CapacityPeer] = []
        do {
            // Authenticate independently before opening the pages. This keeps
            // the cold content burst separate from connection setup latency.
            let credentials = seeded.credentials
            let authenticationWidth = max(1, 32 / processes)
            let authenticationStart = ContinuousClock.now
            for start in stride(from: 0, to: credentials.count, by: authenticationWidth) {
                let batch = Array(credentials[start..<min(credentials.count, start + authenticationWidth)])
                let opened = try await withThrowingTaskGroup(of: CapacityPeer.self) { group in
                    for value in batch {
                        group.addTask {
                            try await CapacityPeer.open(value, fixture: fixture, room: seeded.roomID, counters: counters,
                                bootstrap: bootstrap, isSlow: faults && value.userID == credentials.last?.userID)
                        }
                    }
                    var values: [CapacityPeer] = []
                    do { for try await value in group { values.append(value) } }
                    catch {
                        group.cancelAll()
                        while let result = await group.nextResult() {
                            if case .success(let value) = result { values.append(value) }
                        }
                        for value in values { await value.close() }
                        throw error
                    }
                    return values
                }
                peers += opened
                if peers.count % 512 == 0 || peers.count == credentials.count {
                    print("Author capacity authentication: process=\(process), \(peers.count)/\(credentials.count), elapsed=\(authenticationStart.duration(to: .now))")
                    print("Author capacity bootstrap: \(await bootstrap.summary())")
                }
            }
            print("Author capacity: authenticated \(peers.count) distinct users/devices on real TLS.")
            let baseline = try await checkpoint(fixture, phase: "authenticated", process: process, participants: peers.count, counters: counters)
            let coldStart = ContinuousClock.now
            await counters.beginColdPhase()
            try await parallel(peers, width: peers.count) { try await $0.show(key) }
            let cold = try await checkpoint(fixture, phase: "cold", process: process, participants: peers.count, counters: counters)
            let coldAttempts = await counters.calls
            print("Author capacity first HTTP attempt: \(await counters.firstAttemptSeconds.map(String.init(describing:)) ?? "none") seconds after page burst")
            print("Author capacity stages: \(await counters.stages())")
            print("Author capacity cold: process=\(process), totalParticipants=\(cold.participants), elapsed=\(coldStart.duration(to: .now)), HTTPAttempts=\(cold.httpAttempts), HTTPResponses=\(cold.statistics.profileHTTP - baseline.statistics.profileHTTP), sourceBatches=\(cold.statistics.publicSourceBatches - baseline.statistics.publicSourceBatches), sourceRows=\(cold.statistics.publicSourceRows - baseline.statistics.publicSourceRows), controlBatches=\(cold.statistics.controlBatches - baseline.statistics.controlBatches)")
            #expect(cold.participants == count)
            #expect(cold.httpAttempts == 0)
            #expect(cold.statistics.publicSourceRows - baseline.statistics.publicSourceRows <= 4)
            #expect(cold.statistics.publicSourceRows > baseline.statistics.publicSourceRows)
            #expect(cold.statistics.controlBatches > baseline.statistics.controlBatches)
            let avatarBeforeReplacement: V2ResourceAvatarAccess?
            if replaceAvatar {
                let peer = try #require(peers.first)
                avatarBeforeReplacement = try #require(try await peer.current(key, name: "Capacity author v1").avatar)
            } else { avatarBeforeReplacement = nil }
            if process == 0 {
                let writer = try #require(peers.first { $0.credentials.userID == seeded.authorUserID })
                let command = try V2MessageSendOperationCommand(command: .init(roomID: seeded.roomID, senderUserID: seeded.authorUserID,
                    clientMessageID: .init(uuid: UUID()), text: "One message for all participants", media: [], mentions: [],
                    limits: .init(maxUTF8Bytes: 4096)), firstSubmissionDeadlineMilliseconds: UInt64(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000))
                let client = V2ProtobufMessageSendOperationClient(transport: writer.transport, connection: writer.connection)
                guard case .receipt(let receipt) = try await client.submit(command), case .accepted(let accepted) = receipt.outcome,
                      try receipt.validates(identity: command.identity, fingerprint: command.fingerprint) else { throw CapacityFailure.invalidMessage }
                let _: CapacityMessage = try await fixtureRequest(fixture, path: "message", body: ["process": "0", "sequence": String(accepted.roomSequence)])
            }
            let sequence = try await messageSequence(fixture)
            try await parallel(peers, width: max(1, 64 / processes)) { peer in
                try await peer.waitForHint(atLeast: sequence)
                let page = try await peer.transport.pullGroupEvents(roomID: seeded.roomID, afterRoomSequence: 0, pageSize: 10)
                try #require(page.events.contains { $0.roomSequence == sequence && $0.projectionKind == "message" })
                _ = try await peer.current(key, name: "Capacity author v1")
            }
            let warm = try await checkpoint(fixture, phase: "warm", process: process, participants: peers.count, counters: counters)
            // A cancelled old HTTP attempt can finish at the proxy later.
            // Count newly initiated client reads, not delayed old responses.
            #expect(await counters.calls == coldAttempts)
            #expect(warm.httpAttempts == cold.httpAttempts)
            #expect(warm.statistics.publicSourceRows == cold.statistics.publicSourceRows)
            print("Author capacity warm: all \(warm.participants) received message/history; extra profile attempts=\(warm.httpAttempts - cold.httpAttempts), extra source rows=\(warm.statistics.publicSourceRows - cold.statistics.publicSourceRows).")
            if renewalSeconds > 0 {
                // Observe every peer throughout the hold, rather than wait for
                // a new grant afterward (which would hide an expiry gap).
                try await parallel(peers, width: peers.count) {
                    try await $0.holdPresentation(key, seconds: renewalSeconds)
                }
                let renewed = try await checkpoint(fixture, phase: "renewed", process: process, participants: peers.count, counters: counters)
                #expect(renewed.httpAttempts == warm.httpAttempts)
                #expect(renewed.statistics.publicSourceRows == warm.statistics.publicSourceRows)
                print("Author capacity renewal: all \(renewed.participants) retained overlapping grants for \(renewalSeconds)s; 100ms samples; extra profile attempts=\(renewed.httpAttempts - warm.httpAttempts), extra source rows=\(renewed.statistics.publicSourceRows - warm.statistics.publicSourceRows).")
            }
            var changeBaseline = warm
            if faults {
                let writer = peers.first { $0.credentials.userID == seeded.authorUserID }
                if let writer {
                    // Distinct, poorly compressible bodies make real socket
                    // pressure observable; no synthetic transport result.
                    for _ in 0..<16 {
                        let body = String((0..<128).map { _ in UUID().uuidString }.joined().prefix(4000))
                        _ = try await sendMessage(writer, text: body)
                    }
                }
                _ = try await checkpoint(fixture, phase: "fault_ready", process: process, participants: peers.count, counters: counters)
                if let control = authorControl {
                    let _: CapacityFault = try await fixtureRequest(fixture, path: "fault", body: ["process": "0", "action": "start"])
                    let patched = try await control.client.patchProfile(.init(actorUserID: seeded.authorUserID, operationID: .init(uuid: UUID()),
                        expectedRevision: control.revision, patch: .init(displayName: .set("Capacity author during fault")),
                        firstSubmissionDeadlineMilliseconds: UInt64(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000)))
                    authorControl = (control.client, try #require(patched.currentSnapshot).revision, control.credentials)
                }
                _ = try await waitForFault(fixture) { $0.active }
                let slow = try #require(peers.first { $0.isSlow })
                let floodCounts = CapacityFaultFloodCounts()
                let flood = Task {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        // Stay below the production connection's 256 request
                        // bound while exceeding a native TCP send buffer.
                        for _ in 0..<192 {
                            group.addTask {
                                do {
                                    let page = try await slow.transport.pullGroupEvents(roomID: seeded.roomID, afterRoomSequence: 0, pageSize: 10)
                                    try #require(page.events.count == 10)
                                    await floodCounts.accepted()
                                } catch V2RealtimeTransportError.server(let code, let retryable, let delay, _)
                                    where code == "RATE_LIMITED" && retryable && (1...60).contains(delay) {
                                    // Admission may reject excess load. Drain
                                    // that explicit result without replaying it.
                                    await floodCounts.limited()
                                }
                            }
                        }
                        try await group.waitForAll()
                    }
                }
                await slow.tasks.add(flood)
                if let writer {
                    let deadline = ContinuousClock.now + .seconds(7)
                    while true {
                        let body = String((0..<128).map { _ in UUID().uuidString }.joined().prefix(4000))
                        let accepted = try await sendMessage(writer, text: body)
                        let probe: CapacityReady = try await fixtureRequest(fixture, path: "fault", body: ["process": "0", "action": "probe"])
                        if probe.ready {
                            let _: CapacityFault = try await fixtureRequest(fixture, path: "fault",
                                body: ["process": "0", "action": "message", "sequence": String(accepted)])
                            break
                        }
                        guard .now < deadline else { throw CapacityFailure.timeout }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                let faultSequence = try #require(try await waitForFault(fixture) { $0.sequence != nil }.sequence)
                let healthy = peers.filter { !$0.isSlow }
                try await parallel(healthy, width: 32) { peer in
                    try await peer.waitForHint(atLeast: faultSequence)
                    let page = try await peer.transport.pullGroupEvents(roomID: seeded.roomID, afterRoomSequence: faultSequence - 1, pageSize: 1)
                    try #require(page.events.first?.roomSequence == faultSequence)
                }
                let healthyResult = try await checkpoint(fixture, phase: "fault_healthy", process: process,
                    participants: healthy.count, counters: counters)
                try #require(healthyResult.participants == count - processes)
                if process == 0 {
                    let _: CapacityFault = try await fixtureRequest(fixture, path: "fault", body: ["process": "0", "action": "release"])
                }
                _ = try await waitForFault(fixture) { $0.released }
                try await flood.value
                let floodResult = await floodCounts.result()
                try #require(floodResult.accepted > 0 && floodResult.accepted + floodResult.limited == 192)
                print("Author capacity fault pressure: process=\(process), completed history=\(floodResult.accepted), explicit rate limits=\(floodResult.limited); all 192 requests drained.")
                try await parallel(peers, width: 32) { peer in
                    try await peer.waitForHint(atLeast: faultSequence)
                    _ = try await peer.current(key, name: "Capacity author during fault")
                }
                changeBaseline = try await checkpoint(fixture, phase: "fault_recovered", process: process,
                    participants: peers.count, counters: counters)
                print("Author capacity faults: \(healthyResult.participants) healthy peers received message/history during observed database lock and socket backpressure; all \(changeBaseline.participants) recovered current author data.")
            }
            if let control = authorControl {
                let changed = try await control.client.patchProfile(.init(actorUserID: seeded.authorUserID, operationID: .init(uuid: UUID()),
                    expectedRevision: control.revision, patch: .init(displayName: .set("Capacity author v2")),
                    firstSubmissionDeadlineMilliseconds: UInt64(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000)))
                authorControl = (control.client, try #require(changed.currentSnapshot).revision, control.credentials)
            }
            try await parallel(peers, width: 64) { _ = try await $0.current(key, name: "Capacity author v2") }
            let changed = try await checkpoint(fixture, phase: "changed", process: process, participants: peers.count, counters: counters)
            #expect(changed.statistics.publicSourceRows - changeBaseline.statistics.publicSourceRows <= 4)
            print("Author capacity change: all \(changed.participants) updated without another message; source rows=\(changed.statistics.publicSourceRows - changeBaseline.statistics.publicSourceRows).")
            let downloadMediaID: MediaID
            if replaceAvatar {
                if let control = authorControl {
                    let media = try await uploadAvatar(fixture, credentials: control.credentials, directory: directory, replacement: true)
                    let patched = try await control.client.patchProfile(.init(actorUserID: seeded.authorUserID, operationID: .init(uuid: UUID()),
                        expectedRevision: control.revision, patch: .init(avatar: .set(.init(mediaID: media))),
                        firstSubmissionDeadlineMilliseconds: UInt64(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000)))
                    try #require(patched.currentSnapshot?.avatar?.mediaID == media)
                    let _: CapacityAvatar = try await fixtureRequest(fixture, path: "avatar", body: ["process": "0", "media": media.rawValue])
                }
                downloadMediaID = try await replacementAvatar(fixture)
                let media = downloadMediaID, previous = try #require(avatarBeforeReplacement)
                try await parallel(peers, width: 64) { peer in
                    let current = try await peer.currentAvatar(key, mediaID: media)
                    try #require(current.presentation.view.publicIdentity?.displayName == "Capacity author v2")
                    try #require(current.avatar?.checksum != previous.checksum && media != previous.mediaID)
                }
                let replaced = try await checkpoint(fixture, phase: "avatar_changed", process: process, participants: peers.count, counters: counters)
                #expect(replaced.httpAttempts == changed.httpAttempts)
                #expect(replaced.statistics.publicSourceRows > changed.statistics.publicSourceRows)
                #expect(replaced.statistics.publicSourceRows - changed.statistics.publicSourceRows <= 4)
                print("Author capacity avatar replacement: all \(replaced.participants) received distinct content without another message; extra profile attempts=\(replaced.httpAttempts - changed.httpAttempts), source rows=\(replaced.statistics.publicSourceRows - changed.statistics.publicSourceRows).")
            } else { downloadMediaID = seeded.mediaID }
            try await parallel(peers, width: max(1, 16 / processes)) { peer in
                let snapshot = try await peer.current(key, name: "Capacity author v2")
                let avatar = try #require(snapshot.avatar), plan = try #require(avatar.plan)
                try #require(avatar.mediaID == downloadMediaID)
                let target = try V2ClientMediaTransferTarget(downloadPlan: plan)
                let output = directory.appending(path: peer.credentials.userID.rawValue + ".png")
                try await V2URLSessionMediaByteTransfer(session: fixture.http).download(target: target, destinationURL: output)
                let image = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
                try #require(CGImageSourceGetCount(image) == 1)
                try FileManager.default.removeItem(at: output)
            }
            print("Author capacity bytes: \(peers.count) independently authorized avatar downloads verified.")
            let bytes = try await checkpoint(fixture, phase: "bytes", process: process, participants: peers.count, counters: counters)
            #expect(bytes.statistics.successfulByteHTTP - baseline.statistics.successfulByteHTTP == count)
            #expect(bytes.httpAttempts >= bytes.statistics.profileHTTP - baseline.statistics.profileHTTP)
        } catch {
            print("Author capacity failure: retained authenticated peers=\(peers.count), errorType=\(String(reflecting: type(of: error)))")
            print("Author capacity HTTP at failure: calls=\(await counters.calls), firstSeconds=\(await counters.firstAttemptSeconds.map(String.init(describing:)) ?? "none")")
            print("Author capacity stages at failure: \(await counters.stages())")
            print("Author capacity bootstrap at failure: \(await bootstrap.summary())")
            await close(peers)
            // URLSession errors can carry signed byte capabilities in their
            // userInfo. Keep the transport code without printing those URLs.
            let transport = error as NSError
            if transport.domain == NSURLErrorDomain { throw CapacityFailure.transport(code: transport.code) }
            throw error
        }
        await close(peers)
    }

    private func close(_ peers: [CapacityPeer]) async {
        await withTaskGroup(of: Void.self) { group in
            var index = 0
            for _ in 0..<min(64, peers.count) { let peer = peers[index]; index += 1; group.addTask { await peer.close() } }
            while await group.next() != nil {
                if index < peers.count { let peer = peers[index]; index += 1; group.addTask { await peer.close() } }
            }
        }
    }

    private func parallel(_ peers: [CapacityPeer], width: Int, operation: @escaping @Sendable (CapacityPeer) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var index = 0
            for _ in 0..<min(width, peers.count) { let peer = peers[index]; index += 1; group.addTask { try await operation(peer) } }
            while try await group.next() != nil {
                if index < peers.count { let peer = peers[index]; index += 1; group.addTask { try await operation(peer) } }
            }
        }
    }

    private func fixtureRequest<T: Decodable>(_ fixture: LiveAccountFixture, path: String, body: [String: String]? = nil) async throws -> T {
        var request = URLRequest(url: fixture.url("__fixture__/author-capacity/" + path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue(try #require(ProcessInfo.processInfo.environment["IMV2_LIVE_RESOURCE_FIXTURE_TOKEN"]), forHTTPHeaderField: "X-Resource-Fixture")
        request.httpBody = try body.map { try JSONEncoder().encode($0) }
        let (data, response) = try await fixture.http.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func assignment(_ fixture: LiveAccountFixture, process: Int) async throws -> CapacitySeed {
        let deadline = ContinuousClock.now + .seconds(120)
        while .now < deadline {
            let value: CapacityAssignment = try await fixtureRequest(fixture, path: "assignment", body: ["process": String(process)])
            if value.ready { return try #require(value.seed) }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CapacityFailure.timeout
    }

    private func checkpoint(_ fixture: LiveAccountFixture, phase: String, process: Int, participants: Int,
                            counters: CapacityCounters) async throws -> CapacityCheckpoint {
        let report = ["process": String(process), "phase": phase, "participants": String(participants),
                      "httpAttempts": String(await counters.calls)]
        let deadline = ContinuousClock.now + .seconds(120)
        while .now < deadline {
            let value: CapacityCheckpointResponse = try await fixtureRequest(fixture, path: "barrier", body: report)
            if value.ready {
                return try .init(participants: #require(value.participants), httpAttempts: #require(value.httpAttempts),
                                 statistics: #require(value.statistics))
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CapacityFailure.timeout
    }

    private func messageSequence(_ fixture: LiveAccountFixture) async throws -> UInt64 {
        let deadline = ContinuousClock.now + .seconds(60)
        while .now < deadline {
            let value: CapacityMessage = try await fixtureRequest(fixture, path: "message")
            if value.ready { return try #require(value.sequence) }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CapacityFailure.timeout
    }

    private func waitForFault(_ fixture: LiveAccountFixture, until ready: (CapacityFault) -> Bool) async throws -> CapacityFault {
        let deadline = ContinuousClock.now + .seconds(30)
        while .now < deadline {
            let state: CapacityFault = try await fixtureRequest(fixture, path: "fault")
            if ready(state) { return state }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CapacityFailure.timeout
    }

    private func sendMessage(_ writer: CapacityPeer, text: String) async throws -> UInt64 {
        let command = try V2MessageSendOperationCommand(command: .init(roomID: writer.room, senderUserID: writer.credentials.userID,
            clientMessageID: .init(uuid: UUID()), text: text, media: [], mentions: [], limits: .init(maxUTF8Bytes: 4096)),
            firstSubmissionDeadlineMilliseconds: UInt64(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000))
        let client = V2ProtobufMessageSendOperationClient(transport: writer.transport, connection: writer.connection)
        guard case .receipt(let receipt) = try await client.submit(command), case .accepted(let accepted) = receipt.outcome,
              try receipt.validates(identity: command.identity, fingerprint: command.fingerprint) else { throw CapacityFailure.invalidMessage }
        return accepted.roomSequence
    }

    private func replacementAvatar(_ fixture: LiveAccountFixture) async throws -> MediaID {
        let deadline = ContinuousClock.now + .seconds(60)
        while .now < deadline {
            let value: CapacityAvatar = try await fixtureRequest(fixture, path: "avatar")
            if value.ready { return try .init(#require(value.media)) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CapacityFailure.timeout
    }

    private func uploadAvatar(_ fixture: LiveAccountFixture, credentials: CapacityCredentials, directory: URL, replacement: Bool = false) async throws -> MediaID {
        let source = directory.appending(path: replacement ? "replacement.png" : "source.png")
        let color = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: replacement ? 0.9 : 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(context.makeImage()), destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); try #require(CGImageDestinationFinalize(destination))
        let data = try Data(contentsOf: source), media = MediaID(uuid: UUID())
        let upload = try V2HTTPResourceUploadClient(endpoint: fixture.url("v2/resource-uploads"), credentials: credentials,
            transport: V2URLSessionMediaEdgeHTTPTransport(session: fixture.http))
        var session = try await upload.create(.init(operationID: .init(uuid: UUID()), mediaID: media, usage: .userAvatar,
            contentType: "image/png", byteCount: Int64(data.count), checksum: .init(value: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())))
        let plan = try #require(try await upload.target(session))
        try await V2URLSessionResourcePlanExecutor(session: fixture.http).upload(fileURL: source, plan: plan)
        session = try await upload.finalize(session)
        let deadline = ContinuousClock.now + .seconds(30)
        while session.resourceState != .ready {
            guard .now < deadline else { throw CapacityFailure.timeout }
            try await Task.sleep(for: .milliseconds(100)); session = try await upload.status(session.locator)
        }
        return media
    }
}

private struct CapacityCredentials: Decodable, Sendable, V2ClientMediaEdgeCredentialProvider, V2ClientPushEndpointCredentialProvider {
    let userID: UserID, deviceID: DeviceID, accessToken: String
    func mediaEdgeCredentials() -> V2ClientMediaEdgeCredentials { .init(accessToken: accessToken, deviceID: deviceID) }
    func pushEndpointCredentials() -> V2ClientPushEndpointCredentials { .init(accessToken: accessToken, deviceID: deviceID) }
}
private struct CapacitySeed: Decodable {
    let roomID: RoomID, authorUserID: UserID, mediaID: MediaID
    let credentials: [CapacityCredentials]
}
private struct CapacityReady: Decodable { let ready: Bool }
private struct CapacityAssignment: Decodable { let ready: Bool, seed: CapacitySeed? }
private struct CapacityMessage: Decodable { let ready: Bool, sequence: UInt64? }
private struct CapacityFault: Decodable { let started: Bool, active: Bool, released: Bool, sequence: UInt64? }
private actor CapacityFaultFloodCounts {
    private var completed = 0, rejected = 0
    func accepted() { completed += 1 }
    func limited() { rejected += 1 }
    func result() -> (accepted: Int, limited: Int) { (completed, rejected) }
}
private struct CapacityAvatar: Decodable { let ready: Bool, media: String? }
private struct CapacityCheckpointResponse: Decodable {
    let ready: Bool, statistics: CapacityStatistics?, participants: Int?, httpAttempts: Int?
}
private struct CapacityCheckpoint {
    let participants: Int, httpAttempts: Int, statistics: CapacityStatistics
}
private extension CapacityCredentials {
    init(from decoder: any Decoder) throws {
        struct Wire: Decodable { let userID: String, deviceID: String, accessToken: String }
        let wire = try Wire(from: decoder)
        self.init(userID: try .init(wire.userID), deviceID: try .init(wire.deviceID), accessToken: wire.accessToken)
    }
}
private extension CapacitySeed {
    init(from decoder: any Decoder) throws {
        struct Wire: Decodable { let roomID: String, authorUserID: String, mediaID: String; let credentials: [CapacityCredentials] }
        let wire = try Wire(from: decoder)
        self.init(roomID: try .init(wire.roomID), authorUserID: try .init(wire.authorUserID),
                  mediaID: try .init(wire.mediaID), credentials: wire.credentials)
    }
}
private struct CapacityStatistics: Decodable { let publicSourceBatches: Int, publicSourceRows: Int, controlBatches: Int, profileHTTP: Int, successfulByteHTTP: Int }
private enum CapacityFailure: Error { case timeout, invalidMessage, transport(code: Int) }
private actor CapacityCounters {
    var calls = 0
    var coldStart: ContinuousClock.Instant?
    var firstAttemptSeconds: Double?
    var counts: [String: Int] = [:], first: [String: Double] = [:], last: [String: Double] = [:]
    var grantCount = 0, grantsBelowOneSecond = 0, grantsBelowFiveSeconds = 0
    var minimumGrantSeconds = Double.infinity, maximumGrantSeconds = 0.0
    func beginColdPhase() { coldStart = .now }
    func record() {
        calls += 1
        if firstAttemptSeconds == nil, let coldStart {
            let elapsed = coldStart.duration(to: .now).components
            firstAttemptSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
    }
    func stage(_ name: String) {
        counts[name, default: 0] += 1
        if let coldStart {
            let elapsed = coldStart.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            first[name] = first[name] ?? seconds; last[name] = seconds
        }
    }
    func receivedPresentation(until deadline: ContinuousClock.Instant) {
        stage("presentation")
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        grantCount += 1
        minimumGrantSeconds = min(minimumGrantSeconds, seconds)
        maximumGrantSeconds = max(maximumGrantSeconds, seconds)
        if seconds < 1 { grantsBelowOneSecond += 1 }
        if seconds < 5 { grantsBelowFiveSeconds += 1 }
    }
    func stages() -> String {
        counts.keys.sorted().map { "\($0)=\(counts[$0, default: 0])@\(first[$0, default: 0])..\(last[$0, default: 0])s" }.joined(separator: ",")
            + ",grantCount=\(grantCount),grantSeconds=\(grantCount == 0 ? 0 : minimumGrantSeconds)..\(maximumGrantSeconds),grantsBelow1s=\(grantsBelowOneSecond),grantsBelow5s=\(grantsBelowFiveSeconds)"
    }
}
/// Observe the production author APIs without changing their results, timing,
/// subscriptions, payloads or acknowledgement ownership.
private struct CapacityAuthorWire: V2AuthorPresentationSource, V2ClientAuthorPresentationSubscriptionTransport {
    let connection: V2TLSFrameConnection, transport: V2ProtobufSyncTransport, counters: CapacityCounters
    func beginAuthorPresentationView(messageRoomIDs: [RoomID]) async throws -> V2AuthorPresentationView {
        await counters.stage("viewBegin")
        return try await connection.beginAuthorPresentationView(messageRoomIDs: messageRoomIDs)
    }
    func endAuthorPresentationView(_ view: V2AuthorPresentationView) async { await connection.endAuthorPresentationView(view) }
    func nextAuthorPresentationDelta(for view: V2AuthorPresentationView) async throws -> V2ReceivedAuthorPresentationDelta {
        let value = try await connection.nextAuthorPresentationDelta(for: view)
        for entry in value.entries {
            switch entry {
            case .presentation(_, _, let deadline, _): await counters.receivedPresentation(until: deadline)
            case .retryable: await counters.stage("retryable")
            case .unavailable: await counters.stage("unavailable")
            }
        }
        return value
    }
    func startAuthorPresentation(_ view: V2AuthorPresentationView) async throws {
        await counters.stage("startRequested")
        do { try await transport.startAuthorPresentation(view); await counters.stage("startAccepted") }
        catch { await counters.stage("startFailed"); throw error }
    }
    func stopAuthorPresentation(_ view: V2AuthorPresentationView) async throws { try await transport.stopAuthorPresentation(view) }
    func acknowledgeAuthorPresentation(_ receipt: V2AuthorPresentationReceipt) async throws {
        try await transport.acknowledgeAuthorPresentation(receipt); await counters.stage("appliedAck")
    }
    func replaceAuthorPresentationInterests(_ interests: V2AuthorPresentationInterests) async throws {
        await counters.stage("interestsRequested")
        do { try await transport.replaceAuthorPresentationInterests(interests); await counters.stage("interestsAccepted") }
        catch { await counters.stage("interestsFailed"); throw error }
    }
}
/// Aggregate phase counts only. Never inspect or record a handshake payload.
private actor CapacityBootstrapProgress {
    var counts: [String: Int] = [:]
    var maximumTLSSeconds: Double = 0
    var maximumTrustSeconds: Double = 0
    func record(_ phase: String) { counts[phase, default: 0] += 1 }
    func ready(after duration: Duration) {
        record("tlsReady")
        maximumTLSSeconds = max(maximumTLSSeconds, Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18)
    }
    func trusted(after duration: Duration) {
        record("trustFinished")
        maximumTrustSeconds = max(maximumTrustSeconds, Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18)
    }
    func summary() -> String {
        counts.keys.sorted().map { "\($0)=\(counts[$0, default: 0])" }.joined(separator: ",")
            + ",maxTLSSeconds=\(maximumTLSSeconds),maxTrustSeconds=\(maximumTrustSeconds)"
    }
}
private actor CapacityBootstrapTrace {
    let progress: CapacityBootstrapProgress
    var sends = 0, lastReceivedPhase = 0
    init(_ progress: CapacityBootstrapProgress) { self.progress = progress }
    func sent() async {
        sends += 1
        if sends <= 2 { await progress.record(sends == 1 ? "helloSent" : "authSent") }
    }
    func received() async {
        guard sends > 0, sends <= 2, lastReceivedPhase != sends else { return }
        lastReceivedPhase = sends
        await progress.record(sends == 1 ? "helloFirstByte" : "authFirstByte")
    }
}
private struct CapacityObservedByteConnection: V2TLSByteConnection {
    let underlying: V2NetworkTLSByteConnection, progress: CapacityBootstrapProgress, trace: CapacityBootstrapTrace
    func start() async throws {
        await progress.record("tlsStarted")
        let started = ContinuousClock.now
        try await underlying.start()
        await progress.ready(after: started.duration(to: .now))
    }
    func send(_ data: Data) async throws {
        try await underlying.send(data)
        await trace.sent()
    }
    func receive(maximumLength: Int) async throws -> Data {
        let data = try await underlying.receive(maximumLength: maximumLength)
        if !data.isEmpty { await trace.received() }
        return data
    }
    func cancel() { underlying.cancel() }
}
private struct CapacityReader: V2ProfilePresentationReading {
    let underlying: V2HTTPProfilePresentationClient, counters: CapacityCounters
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) async throws -> V2ProfilePresentationBatch {
        await counters.record(); return try await underlying.readPresentations(keys)
    }
}
private actor CapacityHints {
    var sequence: UInt64 = 0
    func accept(_ hint: V2GroupEventAvailabilityHint) -> Bool { sequence = max(sequence, hint.highWatermark); return true }
}
private actor CapacityPageTasks {
    var tasks: [Task<Void, Error>] = []
    func add(_ task: Task<Void, Error>) { tasks.append(task) }
    func cancel() async { for task in tasks { task.cancel() }; for task in tasks { _ = await task.result }; tasks.removeAll() }
}
private struct CapacityPeer: Sendable {
    let credentials: CapacityCredentials, connection: V2TLSFrameConnection, transport: V2ProtobufSyncTransport
    let profiles: V2ProfilePresentationRepository, rooms: V2RoomSubscriptionCoordinator, pages: V2AuthorPresentationPageCoordinator
    let activation: V2ProfilePageActivation, connectionID: UUID, room: RoomID
    let hints: CapacityHints, tasks: CapacityPageTasks
    let isSlow: Bool

    static func open(_ credentials: CapacityCredentials, fixture: LiveAccountFixture, room: RoomID, counters: CapacityCounters, bootstrap: CapacityBootstrapProgress, isSlow: Bool = false) async throws -> Self {
        let connection = try makeConnection(bootstrap: bootstrap, isSlow: isSlow)
        do {
            let session = try await connection.connectAndAuthenticate(accessToken: credentials.accessToken, deviceID: credentials.deviceID, supportedCapabilityProfiles: ["base"])
            await bootstrap.record("authenticated")
            let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
            let reader = try V2HTTPProfilePresentationClient(endpoint: fixture.url("v2/profile-presentations/batch"), credentials: credentials,
                transport: V2URLSessionMediaEdgeHTTPTransport(session: fixture.http))
            let profiles = V2ProfilePresentationRepository(actorUserID: credentials.userID, deviceID: credentials.deviceID,
                reader: CapacityReader(underlying: reader, counters: counters))
            let hints = CapacityHints()
            let rooms = V2RoomSubscriptionCoordinator(subscriptions: transport, activity: transport, groupEvents: connection,
                activityEvents: connection, isAuthorized: { $0 == room }, roomCursor: { _ in 0 },
                receiveAccountEvent: { await hints.accept($0) })
            let authors = CapacityAuthorWire(connection: connection, transport: transport, counters: counters)
            let pages = V2AuthorPresentationPageCoordinator(rooms: rooms, source: authors, subscriptions: authors, profiles: profiles)
            let tasks = CapacityPageTasks()
            await tasks.add(Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(20))
                    try await transport.sendHeartbeat(clientTime: Date())
                }
            })
            return try await .init(credentials: credentials, connection: connection, transport: transport, profiles: profiles,
                rooms: rooms, pages: pages, activation: profiles.activateVisiblePage(delivery: .authorStream), connectionID: #require(session.connectionID),
                room: room, hints: hints, tasks: tasks, isSlow: isSlow)
        } catch { await connection.disconnect(); throw error }
    }
    func show(_ key: V2ProfileViewLookupKey) async throws {
        _ = try await profiles.retainVisibleInterest(for: key, activation: activation)
        await tasks.add(Task { try await rooms.run(connectionID: connectionID) })
        await tasks.add(Task { try await pages.run(messageRoomID: room, activation: activation) })
        let deadline = ContinuousClock.now + .seconds(90)
        while true {
            do { _ = try #require(try await profiles.presentation(for: key, activation: activation)); break }
            catch V2ProfilePresentationError.throttled(let seconds) {
                guard seconds.isFinite, seconds >= 0, .now + .seconds(seconds) < deadline else { throw CapacityFailure.timeout }
                try await Task.sleep(for: .seconds(seconds))
            }
        }
        _ = try await current(key, name: "Capacity author v1")
    }
    func current(_ key: V2ProfileViewLookupKey, name: String) async throws -> V2ProfilePresentationSnapshot {
        let deadline = ContinuousClock.now + .seconds(60)
        while .now < deadline {
            try Task.checkCancellation()
            if let value = await profiles.cachedSnapshot(for: key, activation: activation), value.presentation.view.publicIdentity?.displayName == name {
                try #require(value.presentation.lease.actorUserID == credentials.userID && value.presentation.lease.deviceID == credentials.deviceID)
                return value
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CapacityFailure.timeout
    }
    func holdPresentation(_ key: V2ProfileViewLookupKey, seconds: Int) async throws {
        let initial = try #require(await profiles.cachedSnapshot(for: key, activation: activation))
        let initialAvatar = try #require(initial.avatar)
        let end = ContinuousClock.now + .seconds(seconds)
        var previousDeadline = initial.deadline
        var renewals = 0
        while .now < end {
            try Task.checkCancellation()
            // Each replacement must be observed before the prior sampled grant
            // expires. A delayed observer fails conservatively; a final valid
            // snapshot alone is never accepted as evidence of continuity.
            let value = try #require(await profiles.cachedSnapshot(for: key, activation: activation))
            try #require(ContinuousClock.now < previousDeadline)
            try #require(value.presentation.view.publicIdentity?.displayName == "Capacity author v1")
            try #require(value.presentation.lease.actorUserID == credentials.userID && value.presentation.lease.deviceID == credentials.deviceID)
            try #require(value.avatar?.mediaID == initialAvatar.mediaID && value.avatar?.checksum == initialAvatar.checksum)
            try #require(value.deadline >= previousDeadline)
            if value.deadline > previousDeadline { renewals += 1 }
            previousDeadline = value.deadline
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(renewals > 0 && ContinuousClock.now > initial.deadline && ContinuousClock.now < previousDeadline)
    }
    func currentAvatar(_ key: V2ProfileViewLookupKey, mediaID: MediaID) async throws -> V2ProfilePresentationSnapshot {
        let deadline = ContinuousClock.now + .seconds(60)
        while .now < deadline {
            try Task.checkCancellation()
            if let value = await profiles.cachedSnapshot(for: key, activation: activation),
               value.presentation.view.avatar?.mediaID == mediaID, value.avatar?.mediaID == mediaID {
                try #require(value.presentation.lease.actorUserID == credentials.userID && value.presentation.lease.deviceID == credentials.deviceID)
                return value
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CapacityFailure.timeout
    }
    func waitForHint(atLeast sequence: UInt64) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while await hints.sequence < sequence {
            guard .now < deadline else { throw CapacityFailure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func close() async {
        await pages.close(); await tasks.cancel(); await profiles.close(); await connection.disconnect()
    }
    private static func makeConnection(bootstrap: CapacityBootstrapProgress, isSlow: Bool) throws -> V2TLSFrameConnection {
        let environment = ProcessInfo.processInfo.environment
        let port = try #require(environment[isSlow ? "IMV2_LIVE_AUTHOR_SLOW_GATEWAY_PORT" : "IMV2_LIVE_RESOURCE_GATEWAY_PORT"]
            .flatMap(UInt16.init).flatMap(NWEndpoint.Port.init(rawValue:)))
        let ca = try Data(contentsOf: URL(fileURLWithPath: #require(environment["IMV2_LIVE_ACCOUNT_CA_DER"])))
        return V2TLSFrameConnection(connectionFactory: {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, "localhost")
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, protocolTrust, complete in
                let started = ContinuousClock.now
                Task { await bootstrap.record("trustStarted") }
                defer { let elapsed = started.duration(to: .now); Task { await bootstrap.trusted(after: elapsed) } }
                let trust = sec_trust_copy_ref(protocolTrust).takeRetainedValue()
                guard let anchor = SecCertificateCreateWithData(nil, ca as CFData),
                      SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                      SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "localhost" as CFString)) == errSecSuccess,
                      SecTrustEvaluateWithError(trust, nil) else { complete(false); return }
                complete(true)
            }, .global(qos: .utility))
            // The owned verifier listens on IPv4 only. Use that exact endpoint;
            // certificate policy and TLS server name still validate localhost.
            let underlying = V2NetworkTLSByteConnection(connection: NWConnection(host: "127.0.0.1", port: port,
                using: NWParameters(tls: tls, tcp: .init())), queue: .global(qos: .utility))
            return CapacityObservedByteConnection(underlying: underlying, progress: bootstrap,
                trace: CapacityBootstrapTrace(bootstrap))
        }, frameLimits: try .init(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]),
           requestTimeout: .seconds(30), supportsAuthorPresentationDelta: true)
    }
}
#endif
