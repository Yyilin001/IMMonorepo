import Foundation
import GRDB
import IMV2Core

/// Local connection contribution only; this never claims account-wide server commitment.
public struct V2LocalPublicationPolicy:Equatable,Sendable {
    public let allowsOnlinePresence:Bool
    public let allowsTypingIndicators:Bool
}
extension GRDBV2LocalSyncStore {
    static func localPublicationPolicy(db:Database) throws -> V2LocalPublicationPolicy {
        var online=true,typing=true
        if let snapshot=try accountPreferenceAuthority(kind:.liveActivityPreference,db:db),case .liveActivity(let o,let t)=snapshot.value {online=o;typing=t}
        for row in try Row.fetchAll(db,sql:"SELECT patch FROM v2_account_preference_intents WHERE preference_kind='liveActivityPreference' AND work_id IS NULL AND state IN ('ready','paused')") {
            if case .liveActivity(let o,let t)=try JSONDecoder().decode(V2AccountPreferencePatch.self,from:row["patch"]) {if o==false {online=false};if t==false {typing=false}}
        }
        for row in try Row.fetchAll(db,sql:"SELECT s.command FROM v2_account_preference_operations s JOIN v2_operation_work w USING(work_id) WHERE preference_kind='liveActivityPreference' AND w.scheduling_state<>'finished'") {
            let command=try JSONDecoder().decode(V2AccountPreferenceCommand.self,from:row["command"])
            if case .liveActivity(let o,let t)=command.value {online=online && o;typing=typing && t}
        }
        return .init(allowsOnlinePresence:online,allowsTypingIndicators:typing)
    }
    public func localPublicationPolicy() throws -> V2LocalPublicationPolicy {try databasePool.read {try Self.localPublicationPolicy(db:$0)}}
    public nonisolated func publicationPolicyUpdates() -> AsyncThrowingStream<V2LocalPublicationPolicy,any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) {continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking {try Self.localPublicationPolicy(db:$0)}.removeDuplicates()
                    for try await value in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) {continuation.yield(value)}
                    continuation.finish()
                } catch {continuation.finish(throwing:error)}
            }
            continuation.onTermination={_ in task.cancel()}
        }
    }
}
