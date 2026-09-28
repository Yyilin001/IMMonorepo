import IMV2Core

public enum V2NetworkEntryBoundary: String, Hashable, Sendable { case accountHTTP, authentication, objectBytes, tcp, configuration }
public enum V2NetworkEntryRegistry {
    /// Explicit source ownership catches a newly introduced request builder or
    /// wire adapter that has not declared its capability boundary.
    public static let sources: [String: Set<V2NetworkEntryBoundary>] = [
        "V2RegisteredAccountHTTPTransport.swift": [.accountHTTP],
        "V2AccountAuthentication.swift": [.authentication],
        "V2HTTPAuthTransport.swift": [.authentication],
        "V2HTTPDeviceCredentialIssuer.swift": [.authentication],
        "V2HTTPDeviceRegistrationCancellationClient.swift": [.authentication],
        "V2HTTPDeviceRevocationClient.swift": [.authentication],
        "V2PasskeyAccountAssertion.swift": [.authentication],
        "V2PasswordLifecycleClient.swift": [.authentication],
        "V2HTTPDeviceSessionClient.swift": [.accountHTTP],
        "V2HTTPDirectRoomOperationClient.swift": [.accountHTTP],
        "V2HTTPMessageModerationClient.swift": [.accountHTTP],
        "V2HTTPRemoteDeviceRevocationClient.swift": [.accountHTTP],
        "V2HTTPForwardPlanOperationClient.swift": [.accountHTTP],
        "V2HTTPMemberAdministrationClient.swift": [.accountHTTP],
        "V2HTTPMembershipOperationClient.swift": [.accountHTTP],
        "V2HTTPGroupCapabilityOperationClient.swift": [.accountHTTP],
        "V2HTTPGroupCreationOperationClient.swift": [.accountHTTP],
        "V2HTTPSocialOperationClient.swift": [.accountHTTP],
        "V2HTTPAccountPreferenceOperationClient.swift": [.accountHTTP],
        "V2HTTPGroupAvatarCommandClient.swift": [.accountHTTP],
        "V2HTTPGroupAvatarPresentationClient.swift": [.accountHTTP],
        "V2HTTPInvitationOperationClient.swift": [.accountHTTP],
        "V2HTTPGroupInvitationClient.swift": [.accountHTTP],
        "V2HTTPGroupNicknamePresentationClient.swift": [.accountHTTP],
        "V2HTTPMessageMutationOperationClient.swift": [.accountHTTP],
        "V2HTTPMessageReactionOperationClient.swift": [.accountHTTP],
        "V2HTTPMessageSendOperationClient.swift": [.accountHTTP],
        "V2ProtobufSyncTransport+MessageSendOperations.swift": [.tcp],
        "V2HTTPNameOperationClient.swift": [.accountHTTP],
        "V2HTTPOwnProfileClient.swift": [.accountHTTP],
        "V2HTTPPersonalPreferenceRecoveryClient.swift": [.accountHTTP],
        "V2HTTPProfilePresentationClient.swift": [.accountHTTP],
        "V2HTTPPublicIdentityDirectory.swift": [.accountHTTP],
        "V2HTTPPushEndpointClient.swift": [.accountHTTP],
        "V2HTTPResourceUploadClient.swift": [.accountHTTP, .objectBytes],
        "V2MediaTransfer.swift": [.accountHTTP, .objectBytes],
        "V2ReadReceiptOperationClient.swift": [.accountHTTP],
        "V2ResourceImportClient.swift": [.accountHTTP],
        "V2SessionHTTPAuthorization.swift": [.accountHTTP, .authentication],
        "V2BackgroundTransferCoordinator.swift": [.objectBytes],
        "V2NativeBackgroundSession.swift": [.objectBytes],
        "V2RangeDownloadTransport.swift": [.objectBytes],
        "V2BoundedFileUpload.swift": [.objectBytes],
        "V2SecureURLSession.swift": [.configuration]
    ]
    /// A new Core kind makes this switch non-exhaustive. HTTP recovery does not
    /// turn a TCP domain command into a generic HTTP replay.
    public static func boundaries(for kind: V2OperationKind) -> Set<V2NetworkEntryBoundary> {
        switch kind {
        case .withdrawMessage, .editMessage, .reaction, .forwardMessage,
             .profileUpdate, .contactAlias, .groupNickname, .groupInvite, .groupJoinRequest,
             .groupJoinDecision, .mediaUpload, .groupAvatar, .memberMute, .moderatedMemberRemoval, .membership, .pinnedMessage, .groupAnnouncement, .groupPermission, .groupRole, .groupRoom, .relationship, .userBlock, .strangerMessagePreference, .userAddPreference, .readReceiptPreference, .liveActivityPreference, .directRoom, .moderation: [.accountHTTP]
        case .sendMessage, .readReceipt, .conversationPreference, .messageFavorite: [.tcp, .accountHTTP]
        }
    }
}
