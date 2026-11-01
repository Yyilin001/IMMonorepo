import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

/// A detail page's transient subscription, outgoing typing lease and remote TTLs.
/// The page owns `observe()`; the shared coordinator owns the wire subscription.
@MainActor
@Observable
final class V2ConversationActivityStore {
    private let roomID: String
    private let userID: String
    private let isGroupConversation: Bool
    private let conversationLiveActivity: (any V2ConversationLiveActivityManaging)?
    private let roomSubscriptions: V2RoomSubscriptionCoordinator?
    @ObservationIgnored private var typingLeaseTask: Task<Void, Never>?
    @ObservationIgnored private var typingLeaseID: UUID?
    @ObservationIgnored private var activityConsumerID: UUID?
    @ObservationIgnored private var activityConnectionID: UUID?
    /// 每个远端用户各一个到期任务。
    ///
    /// 线路上的到期时间才是权威：连接中断可能丢掉收尾的 `isTyping = false` 事件。
    @ObservationIgnored private var typingExpiryTasks: [UserID: Task<Void, Never>] = [:]
    @ObservationIgnored private var typingExpiryDates: [UserID: Date] = [:]
    private(set) var peerPresence: V2PresenceState?
    private(set) var typingUserIDs: Set<UserID> = []

    init(roomID: String, userID: String, kind: V2ConversationKind,
         activity: (any V2ConversationLiveActivityManaging)?, roomSubscriptions: V2RoomSubscriptionCoordinator?) {
        self.roomID = roomID
        self.userID = userID
        self.isGroupConversation = kind.isGroup
        self.conversationLiveActivity = activity
        self.roomSubscriptions = roomSubscriptions
    }

    deinit {
        typingLeaseTask?.cancel()
        presenceExpiryTask?.cancel()
        for task in typingExpiryTasks.values { task.cancel() }
    }

    func observe() async {
        if let roomSubscriptions {
            await observeSharedLiveActivity(roomSubscriptions)
            return
        }
        guard let conversationLiveActivity else { return }
        let includesPresence = !isGroupConversation
        do {
            peerPresence = try await conversationLiveActivity.activate(roomID: roomID, includesPresence: includesPresence)
            while !Task.isCancelled {
                switch try await conversationLiveActivity.nextEvent() {
                case .presence(let presence):
                    guard presence.roomID.rawValue == roomID else { continue }
                    peerPresence = presence
                case .typing(let typing):
                    guard typing.roomID.rawValue == roomID, typing.userID.rawValue != userID else { continue }
                    applyTypingState(typing)
                }
            }
        } catch is CancellationError {
            // Fall through to stop this view's ephemeral subscriptions.
        } catch {
            // Live activity is intentionally best-effort. The detail view and
            // durable message sync remain usable if a transient stream fails.
            peerPresence = nil
            typingUserIDs = []
        }
        let hadTypingLease = typingLeaseTask != nil
        typingLeaseTask?.cancel()
        typingLeaseTask = nil
        clearTypingStates()
        if hadTypingLease {
            // Best effort only; the receiver-side TTL remains the recovery
            // mechanism when the socket is already gone.
            try? await conversationLiveActivity.setTyping(roomID: roomID, isTyping: false)
        }
        await conversationLiveActivity.deactivate(roomID: roomID, includesPresence: includesPresence)
    }

    private func observeSharedLiveActivity(_ owner: V2RoomSubscriptionCoordinator) async {
        guard let room = try? RoomID(roomID) else { return }
        var channels: Set<V2RoomSubscriptionChannel> = [.typing]
        if !isGroupConversation { channels.insert(.presence) }
        do {
            let lease = try await owner.acquire(roomID: room, channels: channels)
            activityConsumerID = lease.id
            var observedConnectionID: UUID?
            for await snapshot in lease.updates {
                guard !Task.isCancelled else { break }
                if observedConnectionID != snapshot.connectionID || snapshot.state == .offline || snapshot.state == .revoked {
                    observedConnectionID = snapshot.connectionID
                    typingLeaseTask?.cancel()
                    typingLeaseTask = nil
                    typingLeaseID = nil
                }
                activityConnectionID = snapshot.state == .subscribed ? snapshot.connectionID : nil
                // Each snapshot replaces all transient facts, including when
                // an intermediate offline value was coalesced away.
                clearTypingStates()
                setPeerPresence(snapshot.presence)
                for typing in snapshot.typing { applyTypingState(typing) }
            }
            await owner.release(roomID: room, consumerID: lease.id)
        } catch {
            // Registration is bounded; local history remains available.
        }
        activityConsumerID = nil
        activityConnectionID = nil
        setPeerPresence(nil)
        clearTypingStates()
        typingLeaseTask?.cancel()
        typingLeaseTask = nil
    }

    @ObservationIgnored private var presenceExpiryTask: Task<Void, Never>?
    private func setPeerPresence(_ presence: V2PresenceState?) {
        presenceExpiryTask?.cancel()
        presenceExpiryTask = nil
        guard let presence, presence.expiresAt > Date() else { peerPresence = nil; return }
        peerPresence = presence
        presenceExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, presence.expiresAt.timeIntervalSinceNow))) }
            catch { return }
            guard let self, self.peerPresence == presence else { return }
            self.peerPresence = nil
            self.presenceExpiryTask = nil
        }
    }

    /// 应用一次线路事件并负责接收端的到期处理。
    ///
    /// 它与流循环分离，使测试无需真实套接字即可覆盖租约边界。
    ///
    /// - Parameters:
    ///   - typing: 正在输入状态。
    ///   - now: 本次判定时刻。
    func applyTypingState(_ typing: V2TypingState, now: Date = Date()) {
        guard typing.roomID.rawValue == roomID, typing.userID.rawValue != userID else { return }
        typingExpiryTasks[typing.userID]?.cancel()
        typingExpiryTasks.removeValue(forKey: typing.userID)
        typingExpiryDates.removeValue(forKey: typing.userID)
        guard typing.isTyping, typing.expiresAt > now else {
            typingUserIDs.remove(typing.userID)
            return
        }
        typingUserIDs.insert(typing.userID)
        let userID = typing.userID
        let expiry = typing.expiresAt
        typingExpiryDates[userID] = expiry
        typingExpiryTasks[userID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expireTypingState(for: userID, expectedExpiry: expiry)
        }
    }

    func expireTypingState(for userID: UserID, expectedExpiry: Date) {
        guard typingExpiryDates[userID] == expectedExpiry else { return }
        typingExpiryTasks[userID] = nil
        typingExpiryDates[userID] = nil
        typingUserIDs.remove(userID)
    }

    private func clearTypingStates() {
        for task in typingExpiryTasks.values { task.cancel() }
        typingExpiryTasks.removeAll()
        typingExpiryDates.removeAll()
        typingUserIDs.removeAll()
    }

    func updateTyping(for draft: String) {
        let sendTyping: @Sendable (Bool) async throws -> Void
        if let roomSubscriptions {
            guard let consumerID = activityConsumerID, let connectionID = activityConnectionID,
                  let room = try? RoomID(roomID) else { return }
            sendTyping = { value in
                try await roomSubscriptions.setTyping(roomID: room, consumerID: consumerID, connectionID: connectionID, isTyping: value)
            }
        } else if let activity = conversationLiveActivity {
            let room = roomID
            sendTyping = { value in try await activity.setTyping(roomID: room, isTyping: value) }
        } else { return }
        let shouldType = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if shouldType, typingLeaseTask == nil {
            let leaseID = UUID()
            typingLeaseID = leaseID
            typingLeaseTask = Task { [weak self] in
                defer {
                    if self?.typingLeaseID == leaseID {
                        self?.typingLeaseTask = nil
                        self?.typingLeaseID = nil
                    }
                }
                while !Task.isCancelled {
                    do {
                        try await sendTyping(true)
                        try await Task.sleep(for: .seconds(4))
                    } catch is CancellationError {
                        return
                    } catch {
                        return
                    }
                }
            }
        } else if !shouldType, let typingLeaseTask {
            typingLeaseTask.cancel()
            self.typingLeaseTask = nil
            typingLeaseID = nil
            Task { try? await sendTyping(false) }
        }
    }

}
