import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    kotlinOut: 'android/src/main/kotlin/com/xmtx/im/flutter/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.xmtx.im.flutter'),
    swiftOut: 'ios/im_flutter_sdk/Sources/im_flutter_sdk/Messages.g.swift',
    dartPackageName: 'im_flutter_sdk',
  ),
)
class ImSession {
  ImSession({required this.state, this.userId});
  String state;
  String? userId;
}

class ImConversation {
  ImConversation({
    required this.id,
    required this.title,
    required this.preview,
    required this.unread,
    required this.isGroup,
    required this.isPinned,
    required this.isArchived,
    this.updatedAt,
    this.peerId,
    this.muteUntil,
  });
  String id;
  String title;
  String preview;
  int unread;
  bool isGroup;
  bool isPinned;
  bool isArchived;
  int? updatedAt;
  String? peerId;
  int? muteUntil;
}

class Transfer {
  Transfer({
    required this.id,
    required this.name,
    required this.kind,
    required this.phase,
    this.total,
    this.confirmed,
    required this.actions,
  });
  String id;
  String name;
  String kind;
  String phase;
  int? total;
  int? confirmed;
  List<String> actions;
}

class AttachmentPreview {
  AttachmentPreview({required this.bytes, required this.remainingMilliseconds});
  Uint8List bytes;
  int remainingMilliseconds;
}

class Attachment {
  Attachment({
    required this.id,
    required this.name,
    required this.contentType,
    required this.bytes,
  });
  String id;
  String name;
  String contentType;
  int bytes;
}

class ImEntity {
  ImEntity({
    required this.kind,
    required this.offset,
    required this.length,
    this.url,
  });
  String kind;
  int offset;
  int length;
  String? url;
}

class ImMessage {
  ImMessage({
    required this.id,
    required this.senderId,
    required this.text,
    required this.withdrawn,
    required this.hasMedia,
    required this.attachments,
    required this.readByPeer,
    required this.isForwarded,
    this.revision,
    this.mutableRevision,
    this.replyPreview,
    this.pendingStatus,
    this.createdAt,
    this.preparedAttachments,
    this.totalAttachments,
    this.replyToId,
    this.mentionSummary,
    this.entities,
    this.roomSequence,
    this.isPinned,
  });
  String id;
  String senderId;
  String text;
  bool withdrawn;
  bool hasMedia;
  List<Attachment> attachments;
  bool readByPeer;
  bool isForwarded;
  int? revision;
  int? mutableRevision;
  String? replyPreview;
  String? pendingStatus;
  int? createdAt;
  int? preparedAttachments;
  int? totalAttachments;
  String? replyToId;
  String? mentionSummary;
  List<ImEntity>? entities;
  int? roomSequence;
  bool? isPinned;
}

class ImProfile {
  ImProfile({
    required this.page,
    required this.userId,
    required this.name,
    required this.handle,
    required this.remainingMilliseconds,
    this.alias,
    this.aliasRevision,
    this.groupNickname,
    this.groupNicknameRevision,
    this.avatar,
  });
  String page;
  String userId;
  String name;
  String handle;
  String? alias;
  int? aliasRevision;
  String? groupNickname;
  int? groupNicknameRevision;
  int remainingMilliseconds;
  Uint8List? avatar;
}

class ImAvatarEditor {
  ImAvatarEditor({
    required this.roomId,
    required this.revision,
    required this.canManage,
    required this.remainingMilliseconds,
    required this.hasAvatar,
    this.name,
    this.handle,
    this.image,
  });
  String? roomId;
  int revision;
  bool canManage;
  int remainingMilliseconds;
  bool hasAvatar;
  String? name;
  String? handle;
  Uint8List? image;
}

class ImAvatarImage {
  ImAvatarImage({required this.bytes, required this.remainingMilliseconds});
  Uint8List bytes;
  int remainingMilliseconds;
}

class DirectoryEntry {
  DirectoryEntry({
    required this.id,
    required this.title,
    required this.isGroup,
  });
  String id;
  String title;
  bool isGroup;
}

class SearchHit {
  SearchHit({required this.id, required this.roomId, required this.text});
  String id;
  String roomId;
  String text;
}

class SearchPage {
  SearchPage({required this.status, required this.hits, required this.hasNext});
  String status;
  List<SearchHit> hits;
  bool hasNext;
}

class DirectoryPage {
  DirectoryPage({
    required this.entries,
    required this.moreContacts,
    required this.moreGroups,
  });
  List<DirectoryEntry> entries;
  bool moreContacts;
  bool moreGroups;
}

class GroupMember {
  GroupMember({required this.userId, required this.role});
  String userId;
  String role;
}

class ImPrivacy {
  ImPrivacy({
    this.allowsStrangerMessages,
    this.allowsUserAdd,
    this.allowsDirectReadReceipts,
    this.allowsGroupReadReceipts,
    this.allowsOnlinePresence,
    this.allowsTypingIndicators,
    required this.blockedUsers,
  });
  bool? allowsStrangerMessages;
  bool? allowsUserAdd;
  bool? allowsDirectReadReceipts;
  bool? allowsGroupReadReceipts;
  bool? allowsOnlinePresence;
  bool? allowsTypingIndicators;
  List<String> blockedUsers;
}

class ImDeviceSession {
  ImDeviceSession({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.createdAt,
    required this.lastActiveAt,
    required this.isCurrentDevice,
  });
  String deviceId;
  String deviceName;
  String platform;
  int createdAt;
  int lastActiveAt;
  bool isCurrentDevice;
}

class ImDeviceSessions {
  ImDeviceSessions({required this.sessions, this.nextCursor});
  List<ImDeviceSession> sessions;
  String? nextCursor;
}

class ImGroupNickname {
  ImGroupNickname({required this.roomId, this.name, this.revision});
  String roomId;
  String? name;
  int? revision;
}

class ImGroupPolicy {
  ImGroupPolicy({
    required this.role,
    required this.permissions,
    required this.revision,
  });
  String role;
  List<String> permissions;
  int revision;
}

class GroupPage {
  GroupPage({
    required this.announcement,
    this.editableAnnouncementRevision,
    required this.membershipRevision,
    required this.actorRole,
    required this.permissions,
    required this.members,
    required this.policies,
    required this.policiesReady,
    required this.hasMore,
  });
  String announcement;
  int? editableAnnouncementRevision;
  int membershipRevision;
  String actorRole;
  List<String> permissions;
  List<GroupMember> members;
  List<ImGroupPolicy> policies;
  bool policiesReady;
  bool hasMore;
}

class ImInvite {
  ImInvite({
    required this.id,
    required this.url,
    required this.expires,
    required this.used,
    required this.maximum,
  });
  String id;
  String url;
  int expires;
  int used;
  int maximum;
}

class ImJoinRequest {
  ImJoinRequest({
    required this.id,
    required this.userId,
    required this.note,
    required this.state,
  });
  String id;
  String userId;
  String note;
  String state;
}

class ImInvitePreview {
  ImInvitePreview({
    required this.roomId,
    required this.title,
    this.requestId,
    this.state,
    required this.member,
    required this.canSubmit,
    required this.canCancel,
  });
  String roomId;
  String title;
  String? requestId;
  String? state;
  bool member;
  bool canSubmit;
  bool canCancel;
}

class ImCommunity {
  ImCommunity({
    this.roomId,
    required this.invites,
    required this.requests,
    required this.hasMore,
    this.preview,
    this.failure,
  });
  String? roomId;
  List<ImInvite> invites;
  List<ImJoinRequest> requests;
  bool hasMore;
  ImInvitePreview? preview;
  String? failure;
}

class ImFavoriteMessage {
  ImFavoriteMessage({
    required this.id,
    required this.roomId,
    required this.roomTitle,
    required this.senderId,
    required this.text,
    this.createdAt,
    required this.attachmentNames,
  });
  String id;
  String roomId;
  String roomTitle;
  String senderId;
  String text;
  int? createdAt;
  List<String> attachmentNames;
}

class ImFavorites {
  ImFavorites({required this.messages, required this.hasMore});
  List<ImFavoriteMessage> messages;
  bool hasMore;
}

class ImReaders {
  ImReaders({
    required this.roomId,
    required this.messageId,
    required this.users,
    required this.hasNext,
    required this.remainingMilliseconds,
  });
  String roomId;
  String messageId;
  List<String> users;
  bool hasNext;
  int remainingMilliseconds;
}

class WindowView {
  WindowView({
    required this.conversations,
    required this.messages,
    required this.hasOlder,
    required this.isLatest,
  });
  List<ImConversation> conversations;
  List<ImMessage> messages;
  bool hasOlder;
  bool isLatest;
}

@HostApi()
abstract class ImHost {
  @async
  void open(String accountUrl, String gatewayHost, int gatewayPort);
  @async
  ImSession restore();
  @async
  ImSession signIn(String account, String password);
  @async
  ImSession register(
    String account,
    String password,
    String publicHandle,
    String displayName,
  );
  @async
  ImPrivacy? privacy();
  @async
  ImPrivacy? setPrivacy(String kind, bool? flag1, bool? flag2);
  @async
  ImDeviceSessions deviceSessions(String? cursor);
  @async
  void revokeDevice(String? deviceId, bool all);
  @async
  void passwordLifecycle(
    String account,
    String action,
    String? currentPassword,
    String? newPassword,
    String? recoveryCode,
  );
  @async
  ImSession connect();
  @async
  ImSession status();
  @async
  void disconnect();
  @async
  String openWindow(String? roomId, bool archived);
  @async
  void setConversationState(
    String roomId,
    bool? isPinned,
    bool? isArchived,
    int? muteUntil,
  );
  @async
  WindowView nextUpdate(String windowId);
  @async
  DirectoryPage directory(bool? nextGroups, String scope);
  @async
  List<ImProfile> profiles(
    String page,
    String context,
    String? roomId,
    List<String> userIds,
  );
  @async
  List<ImProfile> openProfile(String userId, String context, String? roomId);
  @async
  void saveAlias(String userId, String? alias, int? revision);
  @async
  void clearProfiles(String page);
  @async
  ImAvatarImage? avatar(
    String page,
    String userId,
    String context,
    String? roomId,
  );
  @async
  ImAvatarEditor? openAvatarEditor(String? roomId);
  @async
  void changeAvatar(
    String? roomId,
    int revision,
    Uint8List? jpeg,
    int? width,
    int? height,
    String? displayName,
    String? action,
  );
  @async
  String resolveUserId(String handle);
  @async
  void changeMembership(
    String roomId,
    int revision,
    String action,
    String? target,
    String? role,
  );
  @async
  void updateAnnouncement(String roomId, int revision, String text);
  @async
  ImGroupNickname? groupNickname(String roomId);
  @async
  void saveGroupNickname(String roomId, String? name, int? revision);
  @async
  void updateGroupPermissions(
    String roomId,
    int revision,
    String role,
    List<String> permissions,
  );
  @async
  void moderateMemberRemoval(String roomId, String userId, int revision);
  @async
  GroupPage groupMembers(String roomId, bool next);
  @async
  ImCommunity invitations(String roomId);
  @async
  ImCommunity nextInvitations(String roomId);
  @async
  ImCommunity previewInvite(String text);
  @async
  ImCommunity refreshInvite();
  @async
  void inviteAction(
    String roomId,
    int revision,
    String action,
    String? intentId,
    String? note,
  );
  @async
  void submitJoin(String note);
  @async
  void cancelJoin(String roomId);
  @async
  void muteMember(String roomId, String userId, int revision);
  @async
  void createGroup(String title, List<String> members);
  @async
  void requestContact(String handle);
  @async
  void socialAction(String userId, String action);
  @async
  void changeWindowPage(String windowId, bool latest);
  @async
  void closeWindow(String windowId);
  @async
  void cancelPendingSend(String intentId);
  @async
  WindowView locateMessage(String roomId, String messageId);
  @async
  SearchPage searchMessages(String? roomId, String query, bool next);
  @async
  ImReaders messageReaders(String roomId, String messageId, bool next);
  @async
  ImFavorites favorites(bool next);
  @async
  void setFavorite(String roomId, String messageId, bool favorited);
  @async
  void moderateMessage(String roomId, String messageId);
  @async
  void pinMessage(
    String roomId,
    String messageId,
    int roomSequence,
    bool isPinned,
  );
  @async
  void clearMessageSearch();
  @async
  void recoverSend(String intentId, bool resend);
  @async
  void sendText(
    String roomId,
    String text,
    String? replyToMessageId,
    List<String>? mentions,
  );
  @async
  void sendAttachment(
    String roomId,
    String path,
    String name,
    String contentType,
    String text,
  );
  @async
  List<Transfer> transfers();
  @async
  void transferAction(String id, String action);
  @async
  void exportAttachment(
    String roomId,
    String messageId,
    String mediaId,
    String destination,
  );
  @async
  AttachmentPreview previewAttachment(
    String roomId,
    String messageId,
    String mediaId,
  );
  @async
  void downloadAttachment(String roomId, String messageId, String mediaId);
  @async
  void forwardMessage(
    String roomId,
    String messageId,
    int revision,
    List<String> targetRoomIds,
  );
  @async
  void editMessage(String roomId, String messageId, int revision, String text);
  @async
  void withdrawMessage(String roomId, String messageId, int revision);
  @async
  void signOut();
  @async
  void close();
}
