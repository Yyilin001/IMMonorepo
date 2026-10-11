import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import SQLKit

// 逐条接受路径的事务、所有者与激活边界由 Store 持有。
// 这些方法只在 Store 借用的 SQLDatabase 上写入。
enum V2RoomWriteScalarPersistencePath {
    static func persist(
        _ writeSet: V2MessageAcceptanceTransaction,
        command: V2SendMessageCommand,
        mediaPresentations: [V2MediaPresentation],
        messageProjectionState: V2StoredMessageProjectionState,
        contentReviewMode: V2ContentReviewMode,
        room: RoomRow,
        sql: any SQLDatabase
    ) async throws {
        let message = writeSet.acceptedMessage
        let roomID = try scalarRoomWriteUUID(message.roomID)
        let messageID = try scalarRoomWriteUUID(message.messageID)
        let eventID = try scalarRoomWriteUUID(writeSet.eventID)
        let senderID = try scalarRoomWriteUUID(message.senderUserID)
        let clientMessageID = try scalarRoomWriteUUID(message.clientMessageID)
        let roomSequence = try scalarRoomWriteSigned(message.roomSequence)
        let timelineSequence = try scalarRoomWriteSigned(message.timelineSequence)

        guard let mediaJSON = String(data: try JSONEncoder().encode(message.media.map { $0.mediaID.rawValue }), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let entitiesJSON = String(data: try JSONEncoder().encode(message.entities), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let replyToMessageID = message.replyTo?.messageID.rawValue ?? ""
        let forwardedFromMessageID = try command.forwardedFrom.map { try scalarRoomWriteUUID($0.messageID) }
        let forwardedFromUserID = try command.forwardedFrom.map { try scalarRoomWriteUUID($0.senderUserID) }
        let mediaPresentationWire: [[String: Any]] = mediaPresentations.map { presentation in
            [
                "media_id": presentation.mediaID.rawValue,
                "kind": presentation.kind.rawValue,
                "content_type": presentation.contentType,
                "byte_count": presentation.byteCount,
            ]
        }
        guard let mediaPresentationsJSON = String(data: try JSONSerialization.data(withJSONObject: mediaPresentationWire), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let mentionedUserIDs = message.mentions.compactMap { target -> String? in
            guard case .user(let userID) = target else { return nil }
            return userID.rawValue
        }
        guard let mentionedUsersJSON = String(data: try JSONEncoder().encode(mentionedUserIDs), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let references = try message.media.enumerated().map { ordinal, reference in
            OrderedMediaReferenceInput(ordinal: ordinal, mediaID: try scalarRoomWriteUUID(reference.mediaID))
        }
        let referencesJSON = try roomWriteJSON(references)
        let mentions = try message.mentions.enumerated().map { ordinal, target in
            switch target {
            case .user(let userID):
                return OrderedMentionInput(
                    ordinal: ordinal,
                    mentionKind: "user",
                    mentionedUserID: try scalarRoomWriteUUID(userID)
                )
            case .everyone:
                return OrderedMentionInput(
                    ordinal: ordinal,
                    mentionKind: "everyone",
                    mentionedUserID: nil
                )
            }
        }
        let mentionsJSON = try roomWriteJSON(mentions)

        let usesDirectRoomLog = room.kind == "direct"
        if usesDirectRoomLog {
            try await persistRoomLogMessage(
                writeSet,
                command: command,
                room: room,
                roomID: roomID,
                messageID: messageID,
                eventID: eventID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                entitiesJSON: entitiesJSON,
                mediaJSON: mediaJSON,
                mediaPresentationsJSON: mediaPresentationsJSON,
                mentionedUsersJSON: mentionedUsersJSON,
                referencesJSON: referencesJSON,
                mentionsJSON: mentionsJSON,
                replyToMessageID: replyToMessageID,
                forwardedFromMessageID: forwardedFromMessageID,
                forwardedFromUserID: forwardedFromUserID,
                persistsRoomAdmission: true,
                contentReviewMode: contentReviewMode,
                sql: sql
            )
            return
        }

        try await sql.raw("""
            UPDATE im_v2.rooms SET room_sequence = \(bind: roomSequence), timeline_sequence = \(bind: timelineSequence)
            WHERE room_id = \(bind: roomID)
            """).run()
        let mentionTargets = hybridMentionTargetIDs(message.mentions, excluding: senderID)
        try await sql.raw("""
            WITH message_insert AS (
            INSERT INTO im_v2.messages
                (message_id, room_id, room_sequence, timeline_sequence, sender_user_id, client_message_id, text_body, rich_entities, reply_to_message_id, forwarded_from_message_id, forwarded_from_user_id, created_at)
            VALUES
                (\(bind: messageID), \(bind: roomID), \(bind: roomSequence), \(bind: timelineSequence), \(bind: senderID), \(bind: clientMessageID), \(bind: message.text), \(bind: entitiesJSON)::jsonb, NULLIF(\(bind: replyToMessageID), '')::uuid, \(bind: forwardedFromMessageID), \(bind: forwardedFromUserID), \(bind: message.createdAt))
            RETURNING *
            )
            \(v2SendCompletionCTE(fingerprint: command.fingerprint, eventID: eventID, acceptedMembershipRevision: room.membershipRevision, groupCapacityClass: room.kind == "group" ? room.capacityClass : nil))
            SELECT count(*) FROM completion_insert
            """).run()
        if contentReviewMode.enqueuesJobs {
            // 此发件箱记录与消息一同提交。因此接受与工作器唤醒之间的进程崩溃
            // 不会造成未经审核的盲区；租约会恢复工作，无须再次进入热发送路径。
            try await sql.raw("""
                INSERT INTO im_v2.content_review_jobs
                    (message_id, room_id, expected_content_revision, state, created_at)
                VALUES (\(bind: messageID), \(bind: roomID), 1, 'pending', \(bind: message.createdAt))
                """).run()
        }
        if !message.media.isEmpty {
            try await sql.raw("""
                INSERT INTO im_v2.message_media_references
                    (message_id, media_id, ordinal, referenced_at)
                SELECT \(bind: messageID), reference.media_id, reference.ordinal, \(bind: message.createdAt)
                FROM jsonb_to_recordset(\(bind: referencesJSON)::jsonb)
                     AS reference(ordinal integer, media_id uuid)
                """).run()
        }
        if !message.mentions.isEmpty {
            try await sql.raw("""
                INSERT INTO im_v2.message_mentions
                    (message_id, ordinal, mention_kind, mentioned_user_id, created_at)
                SELECT \(bind: messageID), mention.ordinal, mention.mention_kind,
                       mention.mentioned_user_id, \(bind: message.createdAt)
                FROM jsonb_to_recordset(\(bind: mentionsJSON)::jsonb)
                     AS mention(ordinal integer, mention_kind text, mentioned_user_id uuid)
                """).run()
        }
        try await sql.raw("""
            INSERT INTO im_v2.room_events
                (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
            VALUES
                (\(bind: eventID), \(bind: roomID), \(bind: roomSequence), 'message.accepted', \(bind: senderID),
                 jsonb_build_object(
                    'event_type', 'message.accepted',
                    'message_id', \(bind: messageID.uuidString),
                    'room_id', \(bind: roomID.uuidString),
                    'room_sequence', \(bind: roomSequence),
                    'timeline_sequence', \(bind: timelineSequence),
                    'sender_user_id', \(bind: senderID.uuidString),
                    'text', \(bind: message.text),
                    'media_ids', \(bind: mediaJSON)::jsonb,
                    'media_presentations', \(bind: mediaPresentationsJSON)::jsonb,
                    'mention_user_ids', \(bind: mentionedUsersJSON)::jsonb,
                    'mentions_everyone', \(bind: message.mentions.contains(.everyone)),
                    'entities', \(bind: entitiesJSON)::jsonb,
                    'reply_to_message_id', NULLIF(\(bind: replyToMessageID), ''),
                    'forwarded_from_message_id', NULLIF(\(bind: command.forwardedFrom?.messageID.rawValue ?? ""), ''),
                    'forwarded_from_user_id', NULLIF(\(bind: command.forwardedFrom?.senderUserID.rawValue ?? ""), ''),
                    'message_revision', 1,
                    'server_created_at_ms', \(bind: try roomWriteProjectionMilliseconds(message.createdAt)
                 )),
                 \(bind: room.membershipRevision), \(bind: message.createdAt))
            """).run()
        // @ 提及会唤醒客户端；内容从此房间事件恢复。
        try await v2EnqueueMentionPushWakes(
            sourceEventID: eventID,
            roomID: roomID,
            mentionedUserIDs: mentionTargets,
            now: message.createdAt,
            sql: sql
        )
        try await PostgresV2MessageProjectionStateRepository().persist(
            messageProjectionState,
            storage: .roomEvent,
            sql: sql
        )
    }

    /// 持久化规范的单聊房间事件，而不为其两名成员各制造一份多余的持久副本。
    ///
    /// 该事件及其受修订围栏保护的成员校验就是恢复契约；
    /// 前台唤醒刻意留在此事务之外，它只是一种延迟优化。
    ///
    /// - Parameters:
    ///   - writeSet: 消息接受事务写入集合。
    ///   - command: 发送消息命令。
    ///   - room: 目标房间行。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 影响行数不符或写入失败时抛出。
    private static func persistRoomLogMessage(
        _ writeSet: V2MessageAcceptanceTransaction,
        command: V2SendMessageCommand,
        room: RoomRow,
        roomID: UUID,
        messageID: UUID,
        eventID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        roomSequence: Int64,
        timelineSequence: Int64,
        entitiesJSON: String,
        mediaJSON: String,
        mediaPresentationsJSON: String,
        mentionedUsersJSON: String,
        referencesJSON: String,
        mentionsJSON: String,
        replyToMessageID: String,
        forwardedFromMessageID: UUID?,
        forwardedFromUserID: UUID?,
        persistsRoomAdmission: Bool,
        contentReviewMode: V2ContentReviewMode,
        sql: any SQLDatabase
    ) async throws {
        let message = writeSet.acceptedMessage
        let admission = writeSet.nextRoomState.admission
        // 负载测试中最常见的是普通私聊消息。为审核、媒体和提及保留下方完整路径，
        // 但不要让普通消息执行三条空的数据修改 CTE，
        // 也不要重写在私聊房间日志模式下不会变化的房间准入字段。
        if !contentReviewMode.enqueuesJobs,
           message.media.isEmpty,
           message.mentions.isEmpty {
            try await persistPlainRoomLogMessage(
                message: message,
                fingerprint: command.fingerprint,
                room: room,
                roomID: roomID,
                messageID: messageID,
                eventID: eventID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                commandWindowUsed: admission.commandWindow.used,
                entitiesJSON: entitiesJSON,
                replyToMessageID: replyToMessageID,
                forwardedFromMessageID: forwardedFromMessageID,
                forwardedFromUserID: forwardedFromUserID,
                persistsRoomAdmission: persistsRoomAdmission,
                sql: sql
            )
            return
        }
        // Plain appends validate in persistMessages. Complex direct writes
        // retain the same membership fence here before their first mutation.
        try await V2RoomWriteDirectBatchPath.assertDirectMemberships(roomIDs: [roomID], sql: sql)
        guard let mutation = try await sql.raw("""
            WITH room_update AS (
                UPDATE im_v2.rooms
                SET room_sequence = \(bind: roomSequence),
                    timeline_sequence = \(bind: timelineSequence)
                WHERE room_id = \(bind: roomID)
                RETURNING room_id
            ), admission_gate AS (
                SELECT room_id FROM room_update
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence, sender_user_id,
                     client_message_id, text_body, rich_entities, reply_to_message_id,
                     forwarded_from_message_id, forwarded_from_user_id, created_at)
                SELECT \(bind: messageID), admission_gate.room_id, \(bind: roomSequence),
                       \(bind: timelineSequence), \(bind: senderID), \(bind: clientMessageID),
                       \(bind: message.text), \(bind: entitiesJSON)::jsonb,
                       NULLIF(\(bind: replyToMessageID), '')::uuid,
                       \(bind: forwardedFromMessageID), \(bind: forwardedFromUserID),
                       \(bind: message.createdAt)
                FROM admission_gate
                RETURNING *
            ), review_insert AS (
                INSERT INTO im_v2.content_review_jobs
                    (message_id, room_id, expected_content_revision, state, created_at)
                SELECT message_id, room_id, 1, 'pending', \(bind: message.createdAt)
                FROM message_insert
                WHERE \(bind: contentReviewMode.enqueuesJobs)
                RETURNING message_id
            ), media_insert AS (
                INSERT INTO im_v2.message_media_references
                    (message_id, media_id, ordinal, referenced_at)
                SELECT message_insert.message_id, reference.media_id, reference.ordinal,
                       \(bind: message.createdAt)
                FROM message_insert
                CROSS JOIN jsonb_to_recordset(\(bind: referencesJSON)::jsonb)
                     AS reference(ordinal integer, media_id uuid)
                RETURNING message_id
            ), mention_insert AS (
                INSERT INTO im_v2.message_mentions
                    (message_id, ordinal, mention_kind, mentioned_user_id, created_at)
                SELECT message_insert.message_id, mention.ordinal, mention.mention_kind,
                       mention.mentioned_user_id, \(bind: message.createdAt)
                FROM message_insert
                CROSS JOIN jsonb_to_recordset(\(bind: mentionsJSON)::jsonb)
                     AS mention(ordinal integer, mention_kind text, mentioned_user_id uuid)
                RETURNING message_id
            ), event_insert AS (
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload,
                     committed_membership_revision, created_at)
                SELECT \(bind: eventID), message_insert.room_id, \(bind: roomSequence),
                       'message.accepted', \(bind: senderID),
                       jsonb_build_object(
                           'event_type', 'message.accepted',
                           'message_id', \(bind: messageID.uuidString),
                           'room_id', \(bind: roomID.uuidString),
                           'room_sequence', \(bind: roomSequence),
                           'timeline_sequence', \(bind: timelineSequence),
                           'sender_user_id', \(bind: senderID.uuidString),
                           'text', \(bind: message.text),
                           'media_ids', \(bind: mediaJSON)::jsonb,
                           'media_presentations', \(bind: mediaPresentationsJSON)::jsonb,
                           'mention_user_ids', \(bind: mentionedUsersJSON)::jsonb,
                           'mentions_everyone', \(bind: message.mentions.contains(.everyone)),
                           'entities', \(bind: entitiesJSON)::jsonb,
                           'reply_to_message_id', NULLIF(\(bind: replyToMessageID), ''),
                           'forwarded_from_message_id', NULLIF(\(bind: command.forwardedFrom?.messageID.rawValue ?? ""), ''),
                           'forwarded_from_user_id', NULLIF(\(bind: command.forwardedFrom?.senderUserID.rawValue ?? ""), ''),
                           'message_revision', 1,
                           'server_created_at_ms', \(bind: try roomWriteProjectionMilliseconds(message.createdAt))
                       ),
                       \(bind: room.membershipRevision), \(bind: message.createdAt)
                FROM message_insert
                RETURNING event_id
            )
            \(v2SendCompletionCTE(fingerprint: command.fingerprint, eventID: eventID, acceptedMembershipRevision: room.membershipRevision, groupCapacityClass: room.kind == "group" ? room.capacityClass : nil))
            SELECT (SELECT count(*) FROM room_update) AS room_count,
                   (SELECT count(*) FROM admission_gate) AS admission_count,
                   (SELECT count(*) FROM message_insert) AS message_count,
                   (SELECT count(*) FROM review_insert) AS review_count,
                   (SELECT count(*) FROM media_insert) AS media_count,
                   (SELECT count(*) FROM mention_insert) AS mention_count,
                   (SELECT count(*) FROM event_insert) AS event_count
            """).first(decoding: RoomLogMessageMutationRow.self),
              mutation.roomCount == 1,
              mutation.admissionCount == 1,
              mutation.messageCount == 1,
              mutation.reviewCount == (contentReviewMode.enqueuesJobs ? 1 : 0),
              mutation.mediaCount == Int64(message.media.count),
              mutation.mentionCount == Int64(message.mentions.count),
              mutation.eventCount == 1
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    /// 单命令持久化复用集合式追加 SQL，保持消息、事件和完成记录原子提交。
    ///
    /// - Parameters:
    ///   - message: 已接受消息草稿。
    ///   - fingerprint: 请求指纹。
    ///   - room: 目标房间行。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 写入失败时抛出。
    private static func persistPlainRoomLogMessage(
        message: V2AcceptedMessageDraft,
        fingerprint: V2SendMessageFingerprint,
        room: RoomRow,
        roomID: UUID,
        messageID: UUID,
        eventID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        roomSequence: Int64,
        timelineSequence: Int64,
        commandWindowUsed: Int,
        entitiesJSON: String,
        replyToMessageID: String,
        forwardedFromMessageID: UUID?,
        forwardedFromUserID: UUID?,
        persistsRoomAdmission: Bool,
        sql: any SQLDatabase
    ) async throws {
        let replyToMessageUUID: UUID?
        if replyToMessageID.isEmpty {
            replyToMessageUUID = nil
        } else {
            guard let parsed = UUID(uuidString: replyToMessageID) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            replyToMessageUUID = parsed
        }
        try await V2RoomWriteDirectBatchPath.persistMessages(
            inputs: [.init(
                ordinal: 0,
                roomID: roomID,
                messageID: messageID,
                eventID: eventID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                persistsRoomAdmission: persistsRoomAdmission,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                commandWindowUsed: commandWindowUsed,
                text: message.text,
                entities: message.entities,
                replyToMessageID: replyToMessageUUID,
                forwardedFromMessageID: forwardedFromMessageID,
                forwardedFromUserID: forwardedFromUserID,
                membershipRevision: room.membershipRevision,
                fingerprint: fingerprint,
                createdAtPostgresMicroseconds: try roomWritePostgresMicroseconds(message.createdAt)
            )],
            sql: sql
        )
    }
}

private func scalarRoomWriteUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = value.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

private func scalarRoomWriteSigned(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int64(value)
}

private func hybridMentionTargetIDs(_ mentions: [V2MentionTarget], excluding senderID: UUID) -> [UUID] {
    Array(Set(mentions.compactMap { target -> UUID? in
        guard case .user(let userID) = target, let value = UUID(uuidString: userID.rawValue), value != senderID else { return nil }
        return value
    })).sorted { $0.uuidString < $1.uuidString }
}

private struct OrderedMentionInput: Encodable {
    let ordinal: Int
    let mentionKind: String
    let mentionedUserID: UUID?

    enum CodingKeys: String, CodingKey {
        case ordinal
        case mentionKind = "mention_kind"
        case mentionedUserID = "mentioned_user_id"
    }
}
