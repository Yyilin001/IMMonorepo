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
    this.updatedAt,
    this.peerId,
  });
  String id;
  String title;
  String preview;
  int unread;
  bool isGroup;
  int? updatedAt;
  String? peerId;
}

class ImMessage {
  ImMessage({
    required this.id,
    required this.senderId,
    required this.text,
    required this.withdrawn,
    required this.hasMedia,
    required this.readByPeer,
    required this.isForwarded,
    this.mutableRevision,
    this.replyPreview,
    this.pendingStatus,
    this.createdAt,
  });
  String id;
  String senderId;
  String text;
  bool withdrawn;
  bool hasMedia;
  bool readByPeer;
  bool isForwarded;
  int? mutableRevision;
  String? replyPreview;
  String? pendingStatus;
  int? createdAt;
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

class GroupPage {
  GroupPage({
    required this.announcement,
    required this.members,
    required this.hasMore,
  });
  String announcement;
  List<GroupMember> members;
  bool hasMore;
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
  ImSession connect();
  @async
  ImSession status();
  @async
  void disconnect();
  @async
  String openWindow(String? roomId);
  @async
  WindowView nextUpdate(String windowId);
  @async
  DirectoryPage directory(bool? nextGroups, String scope);
  @async
  String resolveUserId(String handle);
  @async
  GroupPage groupMembers(String roomId, bool next);
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
  void sendText(String roomId, String text, String? replyToMessageId);
  @async
  void editMessage(String roomId, String messageId, int revision, String text);
  @async
  void withdrawMessage(String roomId, String messageId, int revision);
  @async
  void signOut();
  @async
  void close();
}
