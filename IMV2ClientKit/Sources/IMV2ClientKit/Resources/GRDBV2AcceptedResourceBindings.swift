import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    /// Acceptance can reuse verified upload bytes, but cannot manufacture
    /// catalog metadata or grant a new business reference.
    static func bindAcceptedUploadBytes(command: V2SendMessageCommand, db: Database) throws {
        for media in command.media {
            guard let raw = try String.fetchOne(db, sql: "SELECT job_id FROM v2_resource_transfer_jobs WHERE media_id=? AND stage='ready'",
                arguments: [media.mediaID.rawValue]), let jobID = UUID(uuidString: raw),
                  let job = try Self.readResourceTransfer(jobID, db: db), let session = job.session,
                  job.request.usage == .messageAttachment(command.roomID), session.resourceState == .ready,
                  session.locator.home == .room(command.roomID) else { continue }
            // The receipt accepts a message identity; it carries no trusted
            // dimensions, duration or complete resource descriptor. Bind only
            // verified bytes here. The authoritative message/directory page
            // publishes the catalog and business reference independently.
            let key = V2ResourceKey(home: session.locator.home, mediaID: media.mediaID)
            // A verified original can become the local copy of the accepted
            // resource without a second download. Missing/corrupt local cache
            // must never prevent the authoritative message ACK from settling.
            if let asset = try V2ResourceFileJournal.readAsset(job.localAssetID, db: db), let file = asset.fileID,
               try String.fetchOne(db, sql: "SELECT state FROM v2_resource_files WHERE file_id=?", arguments: [file.value.uuidString]) == "published" {
                try Self.bindResourceVariant(.init(key: .init(resource: key), checksum: job.request.checksum, byteCount: job.request.byteCount), fileID: file, db: db)
            }
        }
    }
}
