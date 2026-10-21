import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Device clock skew at command admission")
struct V2ClientSubmissionWindowTests {
    // The production server rejects a deadline beyond its registered maximum,
    // even if the difference comes from a device clock only 500 ms ahead.
    @Test(arguments: [-1.0, 0.0, 0.5, 4.0])
    func sendDeadlineFitsServerWindow(deviceAheadSeconds: Double) throws {
        let serverNow = Date(timeIntervalSince1970: 1_800_000_000)
        let deviceNow = serverNow.addingTimeInterval(deviceAheadSeconds)
        let deadline = try GRDBV2LocalSyncStore.messageSendDeadline(now: deviceNow)
        let serverMilliseconds = UInt64(serverNow.timeIntervalSince1970 * 1_000)
        let maximum = try #require(V2CommandPolicy.registered(for: .sendMessage).firstSubmissionWindowMilliseconds)
        #expect(deadline > serverMilliseconds)
        #expect(deadline - serverMilliseconds <= maximum)
    }

    @Test(arguments: [-1.0, 0.0, 0.5, 4.0])
    func membershipClickFitsAdmissionWindow(deviceAheadSeconds: Double) throws {
        let serverNow = Date(timeIntervalSince1970: 1_800_000_000)
        let start = ContinuousClock.now, activation = UUID()
        let confirmation = try V2MembershipConfirmationWindow(
            roomID: .init(uuid: UUID()), action: .add, expectedMembershipRevision: 0,
            activationID: activation, wallNow: serverNow.addingTimeInterval(deviceAheadSeconds), monotonicNow: start)
        let serverMilliseconds = UInt64(serverNow.timeIntervalSince1970 * 1_000)
        #expect(confirmation.confirmedUntilMilliseconds > serverMilliseconds)
        #expect(confirmation.confirmedUntilMilliseconds - serverMilliseconds <= 120_000)
        #expect(confirmation.validates(activationID: activation, now: start + .seconds(114)))
        #expect(!confirmation.validates(activationID: activation, now: start + .seconds(115)))
    }

    @Test(arguments: [-1.0, 0.0, 0.5, 4.0])
    func groupConfirmationFitsAdmissionWindow(deviceAheadSeconds: Double) throws {
        let serverNow = Date(timeIntervalSince1970: 1_800_000_000)
        let start = ContinuousClock.now, activation = UUID()
        let confirmation = try V2GroupCapabilityConfirmationWindow(
            accountID: .init(uuid: UUID()), roomID: .init(uuid: UUID()),
            action: .announcement(body: "Test notice", expectedRevision: 0), activationID: activation,
            wallNow: serverNow.addingTimeInterval(deviceAheadSeconds), monotonicNow: start)
        let serverMilliseconds = UInt64(serverNow.timeIntervalSince1970 * 1_000)
        #expect(confirmation.intent.confirmedUntilMilliseconds > serverMilliseconds)
        #expect(confirmation.intent.confirmedUntilMilliseconds - serverMilliseconds <= 120_000)
        #expect(!confirmation.validates(activationID: activation, now: start + .seconds(115)))
    }
}
