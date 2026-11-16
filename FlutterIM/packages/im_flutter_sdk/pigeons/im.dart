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
    this.pendingStatus,
    this.createdAt,
  });
  String id;
  String senderId;
  String text;
  bool withdrawn;
  bool hasMedia;
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

class WindowView {
  WindowView({required this.conversations, required this.messages});
  List<ImConversation> conversations;
  List<ImMessage> messages;
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
  List<DirectoryEntry> directory();
  @async
  void closeWindow(String windowId);
  @async
  void sendText(String roomId, String text);
  @async
  void signOut();
  @async
  void close();
}
