import Foundation
import IMV2ActorContracts
import IMV2Core

/// Account-side port: every preparation/query/close is a source RoomRef command.
/// Existing durable export delivery workers perform target-owner imports.
public struct V2OwnerAwareForwardPlanPort:Sendable {
    private let router:any V2RoomShardRouting
    private let execute:@Sendable (V2RoomForwardCommand,ContinuousClock.Instant) async throws -> V2RoomForwardResult
    public init(router:any V2RoomShardRouting,rooms:V2RoomRefForwardPort) {
        self.init(router:router,execute:{try await rooms.execute($0,deadline:$1)})
    }
    public init(router:any V2RoomShardRouting,execute:@escaping @Sendable (V2RoomForwardCommand,ContinuousClock.Instant) async throws -> V2RoomForwardResult) { self.router=router;self.execute=execute }
    public func reconcile(actor:UserID,command:V2ForwardMessagesCommand,cancelling:Bool) async throws -> [V2ForwardPlanItemResult]? {
        let deadline=ContinuousClock.now + .seconds(10)
        guard let target=command.targetRoomIDs.first,command.targetRoomIDs.count==1 else { throw V2ForwardPlanValidationError.invalidPlan }
        var results:[V2ForwardPlanItemResult]=[]
        for source in command.sources {
            let pair=V2ActorForwardPairWire(actorUserID:actor,operationID:command.operationID,source:source,targetRoomID:target)
            var response=try await execute(.recoverExport(pair,action:cancelling ? .closeIfAbsent:.query),deadline)
            if case .unresolvedExport=response {
                do {
                    let targetRoute=try await router.route(for:target)
                    response=try await execute(.prepareExport(.init(actorUserID:actor,operationID:command.operationID,source:source,targetRoomID:target,targetShardID:targetRoute.shardID,targetEpoch:targetRoute.epoch)),deadline)
                } catch V2RoomShardRouteError.roomNotFound {
                    // A missing current route is not an original rejection. Ask source authority
                    // to close only if it can prove no export was handed to that target.
                    response=try await execute(.recoverExport(pair,action:.closeIfAbsent),deadline)
                }
            }
            if case .preparedExport(let export)=response {
                // Reconcile through target RoomRef even when a delivery job was paused or its ACK
                // was lost. The target inbox serializes this with the existing delivery worker.
                let imported=try await execute(.importExport(export),deadline)
                guard case .imported(let outcome)=imported else { throw V2ForwardPlanValidationError.invalidReceipt }
                if case .pending=outcome { continue }
                _=try await execute(.recordReceipt(.init(sourceRoomID:source.roomID,actorUserID:actor,exportID:export.intent.exportID,payloadDigest:export.digest,outcome:outcome)),deadline)
                response = .terminalExport(outcome)
            }
            guard case .terminalExport(let proof)=response else { continue }
            let outcome:V2ForwardPlanItemOutcome
            switch proof {
            case .accepted(let message,let sequence):outcome = .accepted(try .init(messageID:message,roomSequence:sequence))
            case .rejected(let code):
                let rejection:V2ForwardPlanItemRejection
                switch code {
                case "NOT_FOUND":rejection = .sourceUnavailable
                case "SOURCE_CHANGED":rejection = .sourceRevisionConflict
                case "MEDIA_UNAVAILABLE":rejection = .resourceUnavailable
                case "INVALID_ARGUMENT":rejection = .contentRejected
                case "CLOSED_BEFORE_EXECUTION":rejection = .closedBeforeExecution
                case "IDEMPOTENCY_CONFLICT":rejection = .identityConflict
                case "FORBIDDEN","DIRECT_MESSAGE_RESTRICTED","ACTOR_MUTED","ROOM_FROZEN":rejection = .permissionDenied
                case "TARGET_NOT_FOUND":rejection = .targetUnavailable
                default:throw V2ForwardPlanValidationError.invalidReceipt
                }
                outcome = .rejected(rejection)
            case .pending:continue
            }
            results.append(try .init(sourceMessageID:source.messageID,targetRoomID:target,outcome:outcome))
        }
        return results.count==command.sources.count ? results:nil
    }
}

public struct V2ForwardPlanService:Sendable {
    public let store:PostgresV2ForwardPlanStore
    private let reconcile:@Sendable (UserID,V2ForwardMessagesCommand,Bool) async throws -> [V2ForwardPlanItemResult]?
    private let clock:@Sendable () -> Date
    public init(store:PostgresV2ForwardPlanStore,port:V2OwnerAwareForwardPlanPort,clock:@escaping @Sendable () -> Date=Date.init) {
        self.init(store:store,reconcile: { try await port.reconcile(actor:$0,command:$1,cancelling:$2) },clock:clock)
    }
    public init(store:PostgresV2ForwardPlanStore,reconcile:@escaping @Sendable (UserID,V2ForwardMessagesCommand,Bool) async throws -> [V2ForwardPlanItemResult]?,clock:@escaping @Sendable () -> Date=Date.init) {
        self.store=store;self.reconcile=reconcile;self.clock=clock
    }
    public func submit(_ command:V2ForwardPlanOperationCommand) async throws -> V2ForwardPlanRecoveryResult {
        do { return try await store.submit(command) }
        catch V2ForwardPlanStoreError.admissionUnavailable {
            return .deferred(try .init(identity:command.identity,fingerprint:command.fingerprint,reason:.admissionUnavailable,retryAfterMilliseconds:5000))
        }
    }
    public func recover(_ request:V2ForwardPlanRecoveryRequest) async throws -> V2ForwardPlanRecoveryResult { try await store.recover(request) }
    public func runOnce(limit:Int=16) async throws {
        for command in try await store.dueCommands(limit:limit) {
            try Task.checkCancellation()
            do { try await advance(command) }
            catch is CancellationError { throw CancellationError() }
            catch { /* Unknown remains processing; the next bounded round checks original proofs. */ }
            try await store.deferNextAction(command)
        }
    }
    public func advance(_ command:V2ForwardPlanOperationCommand) async throws {
        guard case .processing(var progress)=try await store.recover(.init(command:command,action:.query)) else { return }
        if !progress.children.contains(where:{if case .processing=$0.state { return true };return false}) {
            _=try await store.claimNext(command)
            guard case .processing(let claimed)=try await store.recover(.init(command:command,action:.query)) else { return }
            progress=claimed
        }
        guard let child=progress.children.first(where:{if case .processing=$0.state { return true };return false}) else { return }
        let frozen=try command.childCommand(index:child.index)
        guard let results=try await reconcile(command.actorUserID,frozen,progress.executionState == .cancelling) else { return }
        let milliseconds=clock().timeIntervalSince1970*1000
        guard milliseconds.isFinite,milliseconds>0,milliseconds<Double(Int64.max) else { throw V2ForwardPlanValidationError.invalidReceipt }
        let receipt=try V2ForwardPlanChildReceipt(parentIdentity:command.identity,parentFingerprint:command.fingerprint,index:child.index,operationID:frozen.operationID,outcome:.completed(results),resolvedAtMilliseconds:UInt64(milliseconds))
        _=try await store.record(receipt,command:command)
    }
}
