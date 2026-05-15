import Fluent
import Foundation
import Vapor

struct ContactChangesResponse: Content, Equatable, Sendable {
    let contactUpserts: [ContactResponse]
    let removedContactIDs: [UUID]
    let requestUpserts: [FriendRequestResponse]
    let removedRequestIDs: [UUID]
    let nextCursor: String?
    let hasMore: Bool
    let targetToken: String
}

struct ContactChangesService {
    private struct ChangeToken: Codable {
        let updatedAt: Date
        let recordID: String
    }

    func recordContactUpsert(ownerUserID: UUID, contactUserID: UUID, on database: any Database) async throws {
        try await upsertChange(
            ownerUserID: ownerUserID,
            entityType: .contact,
            entityID: contactUserID,
            updatedAt: Date(),
            isRemoved: false,
            on: database
        )
    }

    func recordContactRemoval(ownerUserID: UUID, contactUserID: UUID, on database: any Database) async throws {
        try await upsertChange(
            ownerUserID: ownerUserID,
            entityType: .contact,
            entityID: contactUserID,
            updatedAt: Date(),
            isRemoved: true,
            on: database
        )
    }

    func recordRequestUpsert(ownerUserID: UUID, requestID: UUID, on database: any Database) async throws {
        try await upsertChange(
            ownerUserID: ownerUserID,
            entityType: .request,
            entityID: requestID,
            updatedAt: Date(),
            isRemoved: false,
            on: database
        )
    }

    func listChanges(
        for userID: UUID,
        afterToken rawAfterToken: String?,
        cursor rawCursor: String?,
        limit requestedLimit: Int?,
        on database: any Database
    ) async throws -> ContactChangesResponse {
        let afterToken = try rawAfterToken.map(Self.decodeToken)
            ?? ChangeToken(updatedAt: .distantPast, recordID: "")
        let cursor = try rawCursor.map(Self.decodeToken)
        let limit = normalizedLimit(requestedLimit)

        let query = ContactChangeLogEntry.query(on: database)
            .filter(\.$ownerUserID == userID)
            .sort(\.$updatedAt, .ascending)
            .sort(\.$id, .ascending)
        applyLowerBound(afterToken, to: query)
        if let cursor {
            applyLowerBound(cursor, to: query)
        }

        let rows = try await query.limit(limit + 1).all()
        let hasMore = rows.count > limit
        let pageRows = Array(rows.prefix(limit))

        let contactIDs = pageRows
            .filter { $0.entityType == ContactChangeEntityType.contact.rawValue && !$0.isRemoved }
            .map(\.entityID)
        let contacts = try await UserContact.query(on: database)
            .filter(\.$owner.$id == userID)
            .filter(\.$contact.$id ~~ contactIDs)
            .with(\.$contact)
            .all()
        let contactsByID = Dictionary(uniqueKeysWithValues: try contacts.map { contact in
            (try contact.contact.requireID(), try ContactResponse(contact: contact))
        })

        let requestIDs = pageRows
            .filter { $0.entityType == ContactChangeEntityType.request.rawValue && !$0.isRemoved }
            .map(\.entityID)
        let requests = try await FriendRequest.query(on: database)
            .filter(\.$id ~~ requestIDs)
            .group(.or) { group in
                group.filter(\.$requester.$id == userID)
                group.filter(\.$addressee.$id == userID)
            }
            .with(\.$requester)
            .with(\.$addressee)
            .all()
        let requestsByID = Dictionary(uniqueKeysWithValues: try requests.map { request in
            (try request.requireID(), try FriendRequestResponse(request: request))
        })

        let nextCursor = pageRows.last.map {
            Self.encodeToken(ChangeToken(updatedAt: $0.updatedAt, recordID: $0.id ?? ""))
        }
        let targetToken = try await latestToken(for: userID, on: database)
            ?? rawAfterToken
            ?? Self.encodeToken(ChangeToken(updatedAt: .distantPast, recordID: ""))

        return ContactChangesResponse(
            contactUpserts: pageRows.compactMap { row in
                guard row.entityType == ContactChangeEntityType.contact.rawValue, !row.isRemoved else {
                    return nil
                }
                return contactsByID[row.entityID]
            },
            removedContactIDs: pageRows.compactMap { row in
                guard row.entityType == ContactChangeEntityType.contact.rawValue, row.isRemoved else {
                    return nil
                }
                return row.entityID
            },
            requestUpserts: pageRows.compactMap { row in
                guard row.entityType == ContactChangeEntityType.request.rawValue, !row.isRemoved else {
                    return nil
                }
                return requestsByID[row.entityID]
            },
            removedRequestIDs: pageRows.compactMap { row in
                guard row.entityType == ContactChangeEntityType.request.rawValue, row.isRemoved else {
                    return nil
                }
                return row.entityID
            },
            nextCursor: hasMore ? nextCursor : nil,
            hasMore: hasMore,
            targetToken: targetToken
        )
    }

    private func upsertChange(
        ownerUserID: UUID,
        entityType: ContactChangeEntityType,
        entityID: UUID,
        updatedAt: Date,
        isRemoved: Bool,
        on database: any Database
    ) async throws {
        let recordID = ContactChangeLogEntry.recordID(
            ownerUserID: ownerUserID,
            entityType: entityType,
            entityID: entityID
        )
        let entry = try await ContactChangeLogEntry.find(recordID, on: database)
            ?? ContactChangeLogEntry(
                ownerUserID: ownerUserID,
                entityType: entityType,
                entityID: entityID,
                updatedAt: updatedAt,
                isRemoved: isRemoved
            )
        entry.ownerUserID = ownerUserID
        entry.entityType = entityType.rawValue
        entry.entityID = entityID
        entry.updatedAt = updatedAt
        entry.isRemoved = isRemoved

        if try await ContactChangeLogEntry.find(recordID, on: database) == nil {
            try await entry.create(on: database)
        } else {
            try await entry.update(on: database)
        }
    }

    private func latestToken(for userID: UUID, on database: any Database) async throws -> String? {
        guard let latest = try await ContactChangeLogEntry.query(on: database)
            .filter(\.$ownerUserID == userID)
            .sort(\.$updatedAt, .descending)
            .sort(\.$id, .descending)
            .first()
        else {
            return nil
        }
        return Self.encodeToken(ChangeToken(updatedAt: latest.updatedAt, recordID: latest.id ?? ""))
    }

    private func applyLowerBound(_ token: ChangeToken, to query: QueryBuilder<ContactChangeLogEntry>) {
        query.group(.or) { group in
            group.filter(\.$updatedAt > token.updatedAt)
            group.group(.and) { tieBreaker in
                tieBreaker.filter(\.$updatedAt == token.updatedAt)
                tieBreaker.filter(\.$id > token.recordID)
            }
        }
    }

    private func normalizedLimit(_ requestedLimit: Int?) -> Int {
        max(1, min(requestedLimit ?? 100, 200))
    }

    private static func encodeToken(_ token: ChangeToken) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(token)) ?? Data()
        return data.base64EncodedString()
    }

    private static func decodeToken(_ value: String) throws -> ChangeToken {
        guard let data = Data(base64Encoded: value) else {
            throw Abort(.badRequest, reason: "联系人变更游标无效。")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChangeToken.self, from: data)
    }
}
