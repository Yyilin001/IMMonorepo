import IMV2ClientKit
import Foundation
import IMV2Core

/// 列表、搜索与详情功能共用的读取侧依赖。
struct V2ConversationProjectionDependencies {
    /// 会话数据源。
    let dataSource: any V2ConversationDataSource
    /// 消息搜索实现。
    let messageSearcher: (any V2ConversationMessageSearching)?
    /// 群公告读取实现。
    let groupAnnouncementReader: (any V2GroupAnnouncementReading)?
    /// 群角色策略读取实现。
    let groupRolePolicyReader: (any V2GroupRolePolicyAccessing)?

    /// 组合读取侧依赖。
    ///
    /// - Parameters:
    ///   - dataSource: 会话数据源。
    ///   - messageSearcher: 消息搜索实现。
    ///   - groupAnnouncementReader: 群公告读取实现。
    ///   - groupRolePolicyReader: 群角色策略读取实现。
    init(
        dataSource: any V2ConversationDataSource,
        messageSearcher: (any V2ConversationMessageSearching)? = nil,
        groupAnnouncementReader: (any V2GroupAnnouncementReading)? = nil,
        groupRolePolicyReader: (any V2GroupRolePolicyAccessing)? = nil
    ) {
        self.dataSource = dataSource
        self.messageSearcher = messageSearcher
        self.groupAnnouncementReader = groupAnnouncementReader
        self.groupRolePolicyReader = groupRolePolicyReader
    }
}

/// 消息与单会话命令依赖。
///
/// 把这些命令集中在一起，使列表组合层无需了解详情存储的每一个字段。
struct V2ConversationMessageDependencies {
    let sender: (any V2ConversationSending)?
    let withdrawer: (any V2MessageWithdrawing)?
    let reactionChanger: (any V2MessageReactionChanging)?
    let editor: (any V2MessageEditing)?
    let readReceiptReporter: (any V2ConversationReadReporting)?
    let stateChanger: (any V2ConversationStateChanging)?
    let favoriter: (any V2MessageFavoriting)?
    let groupPinner: (any V2GroupMessagePinning)?
    let forwarder: (any V2MessageForwarding)?

    init(
        sender: (any V2ConversationSending)? = nil,
        withdrawer: (any V2MessageWithdrawing)? = nil,
        reactionChanger: (any V2MessageReactionChanging)? = nil,
        editor: (any V2MessageEditing)? = nil,
        readReceiptReporter: (any V2ConversationReadReporting)? = nil,
        stateChanger: (any V2ConversationStateChanging)? = nil,
        favoriter: (any V2MessageFavoriting)? = nil,
        groupPinner: (any V2GroupMessagePinning)? = nil,
        forwarder: (any V2MessageForwarding)? = nil
    ) {
        self.sender = sender
        self.withdrawer = withdrawer
        self.reactionChanger = reactionChanger
        self.editor = editor
        self.readReceiptReporter = readReceiptReporter
        self.stateChanger = stateChanger
        self.favoriter = favoriter
        self.groupPinner = groupPinner
        self.forwarder = forwarder
    }
}

/// 群生命周期、策略、成员与审核相关依赖。
struct V2ConversationGroupDependencies {
    let announcementManager: (any V2GroupAnnouncementManaging)?
    let memberRoleChanger: (any V2GroupMemberRoleChanging)?
    let rolePolicyChanger: (any V2GroupRolePolicyChanging)?
    let readReceiptReader: (any V2GroupReadReceiptReading)?
    let conversationCreator: (any V2GroupConversationCreating)?
    let memberDirectory: (any V2GroupMemberDirectoryReading)?
    let membershipChanger: (any V2GroupMembershipChanging)?
    let memberMuter: (any V2GroupMemberMuting)?
    let moderatedMemberRemover: (any V2ModeratedGroupMemberRemoving)?
    let avatarManager: (any V2GroupAvatarManaging)?

    init(
        announcementManager: (any V2GroupAnnouncementManaging)? = nil,
        memberRoleChanger: (any V2GroupMemberRoleChanging)? = nil,
        rolePolicyChanger: (any V2GroupRolePolicyChanging)? = nil,
        readReceiptReader: (any V2GroupReadReceiptReading)? = nil,
        conversationCreator: (any V2GroupConversationCreating)? = nil,
        memberDirectory: (any V2GroupMemberDirectoryReading)? = nil,
        membershipChanger: (any V2GroupMembershipChanging)? = nil,
        memberMuter: (any V2GroupMemberMuting)? = nil,
        moderatedMemberRemover: (any V2ModeratedGroupMemberRemoving)? = nil,
        avatarManager: (any V2GroupAvatarManaging)? = nil
    ) {
        self.announcementManager = announcementManager
        self.memberRoleChanger = memberRoleChanger
        self.rolePolicyChanger = rolePolicyChanger
        self.readReceiptReader = readReceiptReader
        self.conversationCreator = conversationCreator
        self.memberDirectory = memberDirectory
        self.membershipChanger = membershipChanger
        self.memberMuter = memberMuter
        self.moderatedMemberRemover = moderatedMemberRemover
        self.avatarManager = avatarManager
    }
}

struct V2ConversationDiscoveryDependencies {
    let directConversationOpener: (any V2DirectConversationOpening)?
    let publicIdentityResolver: (any V2ConversationPublicIdentityResolving)?

    init(
        directConversationOpener: (any V2DirectConversationOpening)? = nil,
        publicIdentityResolver: (any V2ConversationPublicIdentityResolving)? = nil
    ) {
        self.directConversationOpener = directConversationOpener
        self.publicIdentityResolver = publicIdentityResolver
    }
}

struct V2ConversationMediaDependencies {
    let attachmentStager: (any V2ConversationAttachmentStaging)?
    let resourceSender: (any V2DurableConversationSending)?
    let downloader: (any V2ConversationMediaDownloading)?

    init(
        attachmentStager: (any V2ConversationAttachmentStaging)? = nil,
        resourceSender: (any V2DurableConversationSending)? = nil,
        downloader: (any V2ConversationMediaDownloading)? = nil
    ) {
        self.attachmentStager = attachmentStager
        self.resourceSender = resourceSender
        self.downloader = downloader
    }
}

struct V2ConversationRuntimeDependencies {
    let roomSubscriptions: V2RoomSubscriptionCoordinator?
    let liveActivity: (any V2ConversationLiveActivityManaging)?
    let projectionChangeNotifier: V2ProjectionChangeNotifier?
    let activeHybridGroupSynchronizer: (any V2ActiveHybridGroupSynchronizing)?

    init(
        liveActivity: (any V2ConversationLiveActivityManaging)? = nil,
        projectionChangeNotifier: V2ProjectionChangeNotifier? = nil,
        activeHybridGroupSynchronizer: (any V2ActiveHybridGroupSynchronizing)? = nil,
        roomSubscriptions: V2RoomSubscriptionCoordinator? = nil
    ) {
        self.liveActivity = liveActivity
        self.roomSubscriptions = roomSubscriptions
        self.projectionChangeNotifier = projectionChangeNotifier
        self.activeHybridGroupSynchronizer = activeHybridGroupSynchronizer
    }
}

/// 已认证的会话功能边界。
///
/// 应用组合层只创建一次该环境，列表与详情存储收到的是内聚的能力分组，
/// 而不是几十个彼此无关的构造参数。
struct V2ConversationFeatureEnvironment {
    let userID: String
    let projections: V2ConversationProjectionDependencies
    let messages: V2ConversationMessageDependencies
    let groups: V2ConversationGroupDependencies
    let discovery: V2ConversationDiscoveryDependencies
    let media: V2ConversationMediaDependencies
    let runtime: V2ConversationRuntimeDependencies

    init(
        userID: String,
        projections: V2ConversationProjectionDependencies,
        messages: V2ConversationMessageDependencies = .init(),
        groups: V2ConversationGroupDependencies = .init(),
        discovery: V2ConversationDiscoveryDependencies = .init(),
        media: V2ConversationMediaDependencies = .init(),
        runtime: V2ConversationRuntimeDependencies = .init()
    ) {
        self.userID = userID
        self.projections = projections
        self.messages = messages
        self.groups = groups
        self.discovery = discovery
        self.media = media
        self.runtime = runtime
    }
}

struct V2ConversationDetailContext {
    let presentationKey: V2ProfileViewLookupKey?
    let roomID: String
    let title: String
    let kind: V2ConversationKind
    let forwardTargets: [V2ConversationForwardTarget]
    let initialDraft: String?
    let initialMentionHandles: String?

    init(
        roomID: String,
        title: String = "会话",
        kind: V2ConversationKind,
        forwardTargets: [V2ConversationForwardTarget] = [],
        initialDraft: String? = nil,
        initialMentionHandles: String? = nil,
        presentationKey: V2ProfileViewLookupKey? = nil
    ) {
        self.presentationKey = presentationKey
        self.roomID = roomID
        self.title = title
        self.kind = kind
        self.forwardTargets = forwardTargets
        self.initialDraft = initialDraft
        self.initialMentionHandles = initialMentionHandles
    }
}
