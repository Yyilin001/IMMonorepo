import Foundation
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts

// Only concrete spies opt into these scalar compositions. No protocol gets a default implementation.
func v2FixtureAdmitConnectionRefresh(store: any V2LivePresenceLeaseManaging, identity: V2AuthenticatedConnection, connectionID: UUID,
        publicationSuppressed: Bool, policy: V2AuthenticatedConnectionAdmissionPolicy, now: Date)
        async throws -> V2LivePresenceLeaseRefresh {
        let outcome = try await store.admitConnection(identity: identity, connectionID: connectionID,
            publicationSuppressed: publicationSuppressed, policy: policy, now: now)
        return .init(outcome: outcome, allowsOnlinePresence: try await store.allowsOnlinePresence(userID: identity.userID))
    }

func v2FixtureRenewConnections(store: any V2LivePresenceLeaseManaging,
        _ requests: [V2LivePresenceLeaseRenewalRequest]
    ) async throws -> [UUID: V2LivePresenceLeaseRefresh] {
        var refreshed: [UUID: V2LivePresenceLeaseRefresh] = [:]
        refreshed.reserveCapacity(requests.count)
        for request in requests {
            let outcome = try await store.renewConnection(
                identity: request.identity,
                connectionID: request.connectionID,
                now: request.now
            )
            let allowsOnlinePresence = try await store.allowsOnlinePresence(
                userID: request.identity.userID
            )
            refreshed[request.connectionID] = .init(
                outcome: outcome,
                allowsOnlinePresence: allowsOnlinePresence
            )
        }
        return refreshed
    }

func v2FixturePresenceBatch(store: any V2LiveActivityStore, _ requests: [V2PresenceObservationRequest], now: Date) async throws
        -> [V2PresenceObservationRequest: V2PresenceObservationOutcome] {
        guard requests.count <= 128 else { throw V2LiveActivityStoreError.corruptPersistenceState }
        let unique = Set(requests)
        guard unique.count <= 128 else { throw V2LiveActivityStoreError.corruptPersistenceState }
        var result: [V2PresenceObservationRequest: V2PresenceObservationOutcome] = [:]
        for request in unique {
            do {
                let value = try await store.presence(roomID: request.roomID, viewerUserID: request.viewerUserID, now: now)
                result[request] = value.targetUserID == request.targetUserID ? .observed(value) : .denied(.actorNotMember)
            } catch let error as V2LiveActivityStoreError {
                switch error {
                case .roomNotFound: result[request] = .denied(.roomNotFound)
                case .notDirectRoom: result[request] = .denied(.notDirectRoom)
                case .actorNotMember: result[request] = .denied(.actorNotMember)
                case .interactionBlocked: result[request] = .denied(.interactionBlocked)
                case .typingNotAllowed, .corruptPersistenceState: throw error
                }
            }
        }
        return result
    }
