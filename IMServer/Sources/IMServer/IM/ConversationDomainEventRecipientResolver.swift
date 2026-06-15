import Fluent
import Foundation
import Vapor

struct ConversationDomainEventRecipientResolver {
    let db: any Database
    let app: Application?

    init(db: any Database, app: Application? = nil) {
        self.db = db
        self.app = app
    }

    func recipientUserIDs(for envelope: ConversationEventEnvelope) async throws -> [UUID] {
        try await resolveRecipients(for: envelope).userIDs
    }

    func resolveRecipients(for envelope: ConversationEventEnvelope) async throws -> ConversationDomainEventResolvedRecipients {
        let startedAt = Date()
        do {
            let resolved = try await resolveRecipientsWithoutMetrics(for: envelope)
            await app?.conversationDomainEventMetrics.recordRecipientResolution(
                source: resolved.source,
                recipientCount: resolved.userIDs.count,
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
            )
            return resolved
        } catch {
            await app?.conversationDomainEventMetrics.recordRecipientResolutionError()
            throw error
        }
    }

    func filterRecipients(
        for envelope: ConversationEventEnvelope,
        candidateUserIDs: [UUID]
    ) async throws -> ConversationDomainEventResolvedRecipients {
        let startedAt = Date()
        do {
            let resolved = try await filterRecipientsWithoutMetrics(
                for: envelope,
                candidateUserIDs: candidateUserIDs
            )
            await app?.conversationDomainEventMetrics.recordRecipientResolution(
                source: resolved.source,
                recipientCount: resolved.userIDs.count,
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
            )
            return resolved
        } catch {
            await app?.conversationDomainEventMetrics.recordRecipientResolutionError()
            throw error
        }
    }

    private func resolveRecipientsWithoutMetrics(
        for envelope: ConversationEventEnvelope
    ) async throws -> ConversationDomainEventResolvedRecipients {
        switch envelope.eventType {
        case .conversationRemovedForUser:
            return ConversationDomainEventResolvedRecipients(
                userIDs: envelope.payload.affectedUserID.map { [$0] } ?? [],
                source: .affectedUser
            )
        case .messageCreated:
            let inlineRecipients = uniqueSorted(envelope.payload.recipientUserIDs)
            if !inlineRecipients.isEmpty {
                return ConversationDomainEventResolvedRecipients(userIDs: inlineRecipients, source: .inline)
            }
            if let snapshotRecipients = try await eventRecipientSnapshotUserIDs(for: envelope) {
                return ConversationDomainEventResolvedRecipients(userIDs: snapshotRecipients, source: .eventSnapshot)
            }
            if app?.streamConsumerConfiguration.streamConsumerRequiresMessageCreatedRecipientSnapshot == true {
                await app?.conversationDomainEventMetrics.recordRecipientResolutionMissingSnapshot()
                throw ConversationEventTransientProcessingError.messageCreatedRecipientSnapshotMissing(
                    eventID: envelope.eventID,
                    conversationID: envelope.conversationID
                )
            }
            return ConversationDomainEventResolvedRecipients(
                userIDs: try await conversationMemberUserIDs(conversationID: envelope.conversationID),
                source: .membershipExpansion
            )
        case .messageUpdated,
             .messageRecalled,
             .messageStreamStarted,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled,
             .readAdvanced,
             .metadataUpdated,
             .membershipAdded,
             .membershipRemoved,
             .membershipRoleUpdated,
             .directPeerUpdated,
             .messageFavoriteChanged,
             .messageVisibilityChanged,
             .conversationVisibilityChanged,
             .conversationSettingsChanged,
             .inviteChanged:
            return ConversationDomainEventResolvedRecipients(
                userIDs: uniqueSorted(envelope.payload.recipientUserIDs),
                source: .inline
            )
        }
    }

    private func filterRecipientsWithoutMetrics(
        for envelope: ConversationEventEnvelope,
        candidateUserIDs: [UUID]
    ) async throws -> ConversationDomainEventResolvedRecipients {
        let candidates = uniqueSorted(candidateUserIDs)
        guard !candidates.isEmpty else {
            return ConversationDomainEventResolvedRecipients(userIDs: [], source: .inline)
        }

        switch envelope.eventType {
        case .conversationRemovedForUser:
            let affected = envelope.payload.affectedUserID.map { Set([$0]) } ?? []
            return ConversationDomainEventResolvedRecipients(
                userIDs: candidates.filter { affected.contains($0) },
                source: .affectedUser
            )
        case .messageCreated:
            let inlineRecipients = uniqueSorted(envelope.payload.recipientUserIDs)
            if !inlineRecipients.isEmpty {
                let inlineSet = Set(inlineRecipients)
                return ConversationDomainEventResolvedRecipients(
                    userIDs: candidates.filter { inlineSet.contains($0) },
                    source: .inline
                )
            }
            if let snapshotRecipients = try await eventRecipientSnapshotUserIDs(
                for: envelope,
                candidateUserIDs: candidates
            ) {
                return ConversationDomainEventResolvedRecipients(
                    userIDs: snapshotRecipients,
                    source: .eventSnapshot
                )
            }
            if app?.streamConsumerConfiguration.streamConsumerRequiresMessageCreatedRecipientSnapshot == true {
                await app?.conversationDomainEventMetrics.recordRecipientResolutionMissingSnapshot()
                throw ConversationEventTransientProcessingError.messageCreatedRecipientSnapshotMissing(
                    eventID: envelope.eventID,
                    conversationID: envelope.conversationID
                )
            }
            return ConversationDomainEventResolvedRecipients(
                userIDs: try await conversationMemberUserIDs(
                    conversationID: envelope.conversationID,
                    candidateUserIDs: candidates
                ),
                source: .membershipExpansion
            )
        case .messageUpdated,
             .messageRecalled,
             .messageStreamStarted,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled,
             .readAdvanced,
             .metadataUpdated,
             .membershipAdded,
             .membershipRemoved,
             .membershipRoleUpdated,
             .directPeerUpdated,
             .messageFavoriteChanged,
             .messageVisibilityChanged,
             .conversationVisibilityChanged,
             .conversationSettingsChanged,
             .inviteChanged:
            let inlineSet = Set(uniqueSorted(envelope.payload.recipientUserIDs))
            return ConversationDomainEventResolvedRecipients(
                userIDs: candidates.filter { inlineSet.contains($0) },
                source: .inline
            )
        }
    }

    private func conversationMemberUserIDs(conversationID: UUID) async throws -> [UUID] {
        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
        return uniqueSorted(memberships.map(\.$user.id))
    }

    private func conversationMemberUserIDs(
        conversationID: UUID,
        candidateUserIDs: [UUID]
    ) async throws -> [UUID] {
        let candidates = uniqueSorted(candidateUserIDs)
        guard !candidates.isEmpty else {
            return []
        }
        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id ~~ candidates)
            .all()
        return uniqueSorted(memberships.map(\.$user.id))
    }

    private func eventRecipientSnapshotUserIDs(for envelope: ConversationEventEnvelope) async throws -> [UUID]? {
        guard let eventID = envelope.eventID,
              let snapshot = try await ConversationDomainEventRecipientSnapshot.find(eventID, on: db)
        else {
            return nil
        }
        let startedAt = Date()
        let inlineRecipients = try snapshot.recipientUserIDs()
        if !inlineRecipients.isEmpty || snapshot.recipientCount == 0 {
            await app?.conversationDomainEventMetrics.recordRecipientSnapshotResolved(
                usedSharedSet: false,
                recipientCount: inlineRecipients.count,
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
            )
            return uniqueSorted(inlineRecipients)
        }
        guard let recipientHash = snapshot.recipientHash,
              let recipientSet = try await ConversationDomainEventRecipientSet.find(recipientHash, on: db)
        else {
            await app?.conversationDomainEventMetrics.recordRecipientSnapshotSharedSetMissing(
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
            )
            throw ConversationProjectionCodingError.missingRecipientSet
        }
        let sharedRecipients = try recipientSet.recipientUserIDs()
        await app?.conversationDomainEventMetrics.recordRecipientSnapshotResolved(
            usedSharedSet: true,
            recipientCount: sharedRecipients.count,
            elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
        )
        return uniqueSorted(sharedRecipients)
    }

    private func eventRecipientSnapshotUserIDs(
        for envelope: ConversationEventEnvelope,
        candidateUserIDs: [UUID]
    ) async throws -> [UUID]? {
        let candidates = uniqueSorted(candidateUserIDs)
        guard !candidates.isEmpty else {
            return []
        }
        guard let eventID = envelope.eventID,
              let snapshot = try await ConversationDomainEventRecipientSnapshot.find(eventID, on: db)
        else {
            return nil
        }
        let startedAt = Date()
        let inlineRecipients = try snapshot.recipientUserIDs()
        if !inlineRecipients.isEmpty || snapshot.recipientCount == 0 {
            let inlineSet = Set(uniqueSorted(inlineRecipients))
            let filtered = candidates.filter { inlineSet.contains($0) }
            await app?.conversationDomainEventMetrics.recordRecipientSnapshotResolved(
                usedSharedSet: false,
                recipientCount: filtered.count,
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
            )
            return filtered
        }
        guard let recipientHash = snapshot.recipientHash,
              let recipientSet = try await ConversationDomainEventRecipientSet.find(recipientHash, on: db)
        else {
            await app?.conversationDomainEventMetrics.recordRecipientSnapshotSharedSetMissing(
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
            )
            throw ConversationProjectionCodingError.missingRecipientSet
        }

        let indexedRecipients = try await ConversationDomainEventRecipientSetMember.matchingUserIDs(
            recipientHash: recipientHash,
            candidateUserIDs: candidates,
            on: db
        )
        let hasMemberIndex = try await ConversationDomainEventRecipientSetMember.hasMemberIndex(
                recipientHash: recipientHash,
                on: db
            )
        if !indexedRecipients.isEmpty || hasMemberIndex {
            await app?.conversationDomainEventMetrics.recordRecipientSnapshotResolved(
                usedSharedSet: true,
                recipientCount: indexedRecipients.count,
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
            )
            return indexedRecipients
        }

        let sharedSet = Set(try recipientSet.recipientUserIDs())
        let filtered = candidates.filter { sharedSet.contains($0) }
        await app?.conversationDomainEventMetrics.recordRecipientSnapshotResolved(
            usedSharedSet: true,
            recipientCount: filtered.count,
            elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
        )
        return filtered
    }

    private func uniqueSorted(_ ids: [UUID]) -> [UUID] {
        Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }
}

struct ConversationDomainEventResolvedRecipients: Sendable {
    enum Source: String, Sendable {
        case inline
        case eventSnapshot = "event_snapshot"
        case membershipExpansion = "membership_expansion"
        case affectedUser = "affected_user"
    }

    let userIDs: [UUID]
    let source: Source
}
