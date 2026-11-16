enum MessageType { text, image }

class ImageMessageData {
  const ImageMessageData({
    this.width = 1200,
    this.height = 900,
    this.localFileName,
  }) : assert(width > 0),
       assert(height > 0);
  final int width, height;
  final String? localFileName;
  double get aspectRatio => width / height;

  @override
  bool operator ==(Object other) =>
      other is ImageMessageData &&
      other.width == width &&
      other.height == height &&
      other.localFileName == localFileName;
  @override
  int get hashCode => Object.hash(width, height, localFileName);
}

const mockImages = [
  ImageMessageData(),
  ImageMessageData(width: 900, height: 1200),
  ImageMessageData(width: 1080, height: 1080),
];

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.text,
    required this.timestamp,
    this.isMine = false,
    this.senderId,
    this.historySequence,
  }) : type = MessageType.text,
       image = null;

  const ChatMessage.image({
    required this.id,
    required this.conversationId,
    required this.timestamp,
    this.isMine = false,
    this.senderId,
    this.historySequence,
    ImageMessageData this.image = const ImageMessageData(),
  }) : type = MessageType.image,
       text = '';

  final String id;
  final int conversationId;
  final String text;
  final DateTime timestamp;
  final bool isMine;
  final int? senderId;
  final int? historySequence;
  final MessageType type;
  final ImageMessageData? image;
  String get preview => type == MessageType.image ? '[图片]' : text;

  ChatMessage withHistorySequence(int sequence, {int? fallbackSenderId}) =>
      type == MessageType.image
      ? ChatMessage.image(
          id: id,
          conversationId: conversationId,
          timestamp: timestamp,
          isMine: isMine,
          senderId: senderId ?? fallbackSenderId,
          historySequence: sequence,
          image: image!,
        )
      : ChatMessage(
          id: id,
          conversationId: conversationId,
          text: text,
          timestamp: timestamp,
          isMine: isMine,
          senderId: senderId ?? fallbackSenderId,
          historySequence: sequence,
        );
}

/// Immutable values keep already-published UI snapshots consistent.
class Conversation {
  const Conversation({
    required this.id,
    required this.name,
    required this.preview,
    required this.updatedAt,
    this.unread = 0,
    this.pinned = false,
    this.muted = false,
    this.isGroup = false,
    this.sequence = 0,
    this.remark = '',
  });

  final int id;
  final String name;
  final String remark;
  String get displayName => remark.isEmpty ? name : remark;
  final String preview;
  final DateTime updatedAt;
  final int unread;
  final bool pinned;
  final bool muted;
  final bool isGroup;
  final int sequence;

  Conversation copyWith({
    String? remark,
    String? preview,
    DateTime? updatedAt,
    int? unread,
    bool? pinned,
    bool? muted,
    int? sequence,
  }) => Conversation(
    id: id,
    name: name,
    remark: remark ?? this.remark,
    preview: preview ?? this.preview,
    updatedAt: updatedAt ?? this.updatedAt,
    unread: unread ?? this.unread,
    pinned: pinned ?? this.pinned,
    muted: muted ?? this.muted,
    isGroup: isGroup,
    sequence: sequence ?? this.sequence,
  );
}

const mockTexts = [
  '刚更新了设计稿，来看看这个版本 👀',
  '收到，我这边已经准备好了。',
  '这个想法不错，我们可以继续细化一下。',
  '下午三点，一起同步一下进展？',
  '新版本体验很流畅，辛苦大家！',
  '文件已经整理好了，稍后一起过一遍。',
  '今天的任务已完成 ✅',
  '周末去哪里走走？我发现了一家不错的咖啡店 ☕',
  '没问题，就按这个方案推进。',
  '消息已送达，所有数据都在本地运行。',
  '我补充了几个细节，欢迎反馈。',
  '保持专注，也记得休息一下 🌿',
];
