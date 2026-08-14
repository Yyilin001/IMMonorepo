import Foundation
import IMV2Core

/// Read-side dependencies shared by the list, search, and detail features.
struct V2ConversationProjectionDependencies {
    let dataSource: any V2ConversationDataSource
    let messageSearcher: (any V2ConversationMessageSearching)?
    let groupAnnouncementReader: (any V2GroupAnnouncementReading)?
    let groupRolePolicyReader: (any V2GroupRolePolicyReading)?

    init(
        dataSource: any V2ConversationDataSource,
        messageSearcher: (any V2ConversationMessageSearching)? = nil,
        groupAnnouncementReader: (any V2GroupAnnouncementReading)? = nil,
        groupRolePolicyReader: (any V2GroupRolePolicyReading)? = nil
    ) {
        self.dataSource = dataSource
        self.messageSearcher = messageSearcher
        self.groupAnnouncementReader = groupAnnouncementReader
        self.groupRolePolicyReader = groupRolePolicyReader
    }
}

/// Message and per-conversation command dependencies. Keeping these commands
/// together prevents list composition from knowing every detail-store field.
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

/// Group lifecycle, policy, membership, and moderation dependencies.
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

    init(
        announcementManager: (any V2GroupAnnouncementManaging)? = nil,
        memberRoleChanger: (any V2GroupMemberRoleChanging)? = nil,
        rolePolicyChanger: (any V2GroupRolePolicyChanging)? = nil,
        readReceiptReader: (any V2GroupReadReceiptReading)? = nil,
        conversationCreator: (any V2GroupConversationCreating)? = nil,
        memberDirectory: (any V2GroupMemberDirectoryReading)? = nil,
        membershipChanger: (any V2GroupMembershipChanging)? = nil,
        memberMuter: (any V2GroupMemberMuting)? = nil,
        moderatedMemberRemover: (any V2ModeratedGroupMemberRemoving)? = nil
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
    let attachmentUploader: (any V2ConversationAttachmentUploading)?
    let downloader: (any V2ConversationMediaDownloading)?

    init(
        attachmentStager: (any V2ConversationAttachmentStaging)? = nil,
        attachmentUploader: (any V2ConversationAttachmentUploading)? = nil,
        downloader: (any V2ConversationMediaDownloading)? = nil
    ) {
        self.attachmentStager = attachmentStager
        self.attachmentUploader = attachmentUploader
        self.downloader = downloader
    }
}

struct V2ConversationRuntimeDependencies {
    let liveActivity: (any V2ConversationLiveActivityManaging)?
    let projectionChangeNotifier: V2ProjectionChangeNotifier?
    let activeHybridGroupSynchronizer: (any V2ActiveHybridGroupSynchronizing)?

    init(
        liveActivity: (any V2ConversationLiveActivityManaging)? = nil,
        projectionChangeNotifier: V2ProjectionChangeNotifier? = nil,
        activeHybridGroupSynchronizer: (any V2ActiveHybridGroupSynchronizing)? = nil
    ) {
        self.liveActivity = liveActivity
        self.projectionChangeNotifier = projectionChangeNotifier
        self.activeHybridGroupSynchronizer = activeHybridGroupSynchronizer
    }
}

/// The authenticated conversation feature boundary. App composition creates
/// this once; list and detail stores receive cohesive capability groups rather
/// than forwarding dozens of unrelated constructor arguments.
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
    let roomID: String
    let title: String
    let isGroupConversation: Bool
    let directAccountKind: V2AccountKind
    let forwardTargets: [V2ConversationForwardTarget]
    let initialDraft: String?
    let initialMentionHandles: String?

    init(
        roomID: String,
        title: String = "会话",
        isGroupConversation: Bool = false,
        directAccountKind: V2AccountKind = .regular,
        forwardTargets: [V2ConversationForwardTarget] = [],
        initialDraft: String? = nil,
        initialMentionHandles: String? = nil
    ) {
        self.roomID = roomID
        self.title = title
        self.isGroupConversation = isGroupConversation
        self.directAccountKind = directAccountKind
        self.forwardTargets = forwardTargets
        self.initialDraft = initialDraft
        self.initialMentionHandles = initialMentionHandles
    }
}
