import Foundation
import IMV2Core

package protocol V2GatewayReadReceiptHandling: Sendable {
    var managesForegroundWriteAdmission: Bool { get }
    func record(_ request: V2AuthenticatedReadReceipt) async throws -> V2ReadReceiptOutcome
    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage
}

package protocol V2GatewayMessageSendOperationHandling: V2MessageSendOperationHandling {
    var managesForegroundWriteAdmission: Bool { get }
    var usesReadOnlySendRecovery: Bool { get }
}

extension V2GatewayMessageSendOperationHandling {
    package var usesReadOnlySendRecovery: Bool { false }
}

extension V2GatewayReadReceiptHandling {
    package var managesForegroundWriteAdmission: Bool { false }
}

package protocol V2GatewayLiveActivityHandling: Sendable {
    func preferences(userID: UserID, now: Date) async throws -> V2LiveActivityPreferences
    func presence(roomID: RoomID, viewerUserID: UserID, now: Date) async throws -> V2PresenceState
    func authorizeTyping(roomID: RoomID, actorUserID: UserID, now: Date) async throws
}

package protocol V2GatewayRoomMembershipDirectoryHandling: Sendable {
    func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage
}



public protocol V2GatewayConversationCapabilitiesHandling: Sendable {
    func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand) async throws -> V2PersonalPreferenceReceipt
    func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand) async throws -> V2PersonalPreferenceReceipt
}

package protocol V2GatewayGroupEventLogHandling: Sendable {
    func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage
    func pullPrepared(
        roomID: RoomID,
        actorUserID: UserID,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) async throws -> V2PreparedGroupEventPullResult
    func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription
    func recordCommittedDirectRoomLogMessage(_ message: V2AcceptedMessage) async
    func recordCommittedDirectRoomLogEvent(_ event: V2DirectRoomLiveEvent) async
}

extension V2GatewayGroupEventLogHandling {
    package func pullPrepared(
        roomID: RoomID,
        actorUserID: UserID,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context _: V2PreparedGroupEventPageEncodingContext
    ) async throws -> V2PreparedGroupEventPullResult {
        .page(try await pull(
            roomID: roomID,
            actorUserID: actorUserID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize
        ))
    }

    package func recordCommittedDirectRoomLogMessage(_: V2AcceptedMessage) async {}
    package func recordCommittedDirectRoomLogEvent(_: V2DirectRoomLiveEvent) async {}
}
