import Foundation
import IMV2Core

public enum V2ForwardPlanStoreError: Error, Sendable {
    case admissionUnavailable
}

public protocol V2ForwardPlanStoring: Sendable {
    func submit(_ command: V2ForwardPlanOperationCommand) async throws -> V2ForwardPlanRecoveryResult
    func recover(_ request: V2ForwardPlanRecoveryRequest) async throws -> V2ForwardPlanRecoveryResult
    func dueCommands(limit: Int) async throws -> [V2ForwardPlanOperationCommand]
    func deferNextAction(_ command: V2ForwardPlanOperationCommand) async throws
    func claimNext(_ command: V2ForwardPlanOperationCommand) async throws -> V2ForwardMessagesCommand?
    func record(_ child: V2ForwardPlanChildReceipt, command: V2ForwardPlanOperationCommand) async throws -> V2ForwardPlanRecoveryResult
}
