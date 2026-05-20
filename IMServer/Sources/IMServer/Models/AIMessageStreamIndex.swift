import Fluent
import Foundation

final class AIMessageStreamIndex: Model, @unchecked Sendable {
    static let schema = "im_ai_message_streams"

    @ID(custom: "stream_id", generatedBy: .user)
    var id: String?

    @Field(key: "message_id")
    var messageID: UUID

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "state")
    var state: String

    @Field(key: "last_chunk_index")
    var lastChunkIndex: Int

    @Field(key: "created_at")
    var createdAt: Date

    @Field(key: "updated_at")
    var updatedAt: Date

    @OptionalField(key: "terminal_at")
    var terminalAt: Date?

    @OptionalField(key: "error_code")
    var errorCode: String?

    init() { }

    init(
        streamID: String,
        messageID: UUID,
        conversationID: UUID,
        userID: UUID,
        state: MessageStreamLifecycleState,
        lastChunkIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        terminalAt: Date? = nil,
        errorCode: String? = nil
    ) {
        self.id = streamID
        self.messageID = messageID
        self.conversationID = conversationID
        self.userID = userID
        self.state = state.rawValue
        self.lastChunkIndex = lastChunkIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.terminalAt = terminalAt
        self.errorCode = errorCode
    }

    var streamID: String {
        get { id ?? "" }
        set { id = newValue }
    }

    var lifecycleState: MessageStreamLifecycleState {
        get { MessageStreamLifecycleState(rawValue: state) ?? .failed }
        set { state = newValue.rawValue }
    }
}
