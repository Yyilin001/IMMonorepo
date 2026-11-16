import 'models.dart';

/// The result of one synchronous data mutation, not an event stream.
class TimelineDelta {
  const TimelineDelta({
    required this.structureChanged,
    required this.changedIds,
  });
  final bool structureChanged;
  final Set<String> changedIds;
}

/// Pure message window and ID/position index. No observers or callbacks.
class TimelineStore {
  List<ChatMessage> _value = const [];
  Map<String, ChatMessage> _byId = {};
  Map<String, int> _positions = {};
  int structure = 0;

  List<ChatMessage> get value => _value;
  int? positionOf(String id) => _positions[id];

  TimelineDelta replace(List<ChatMessage> messages) {
    final next = List<ChatMessage>.unmodifiable(messages);
    var sameOrder = next.length == _value.length;
    if (sameOrder) {
      for (var i = 0; i < next.length; i++) {
        if (next[i].id != _value[i].id) {
          sameOrder = false;
          break;
        }
      }
    }
    final byId = {for (final message in next) message.id: message};
    if (byId.length != next.length) {
      throw ArgumentError('Duplicate message IDs');
    }
    final changed = next
        .where((m) => !_sameMessage(_byId[m.id], m))
        .toList(growable: false);
    final removed = _byId.keys.where((id) => !byId.containsKey(id)).toList();
    _value = next;
    _byId = byId;
    if (!sameOrder) {
      _positions = {for (var i = 0; i < next.length; i++) next[i].id: i};
    }
    if (!sameOrder) structure++;
    return TimelineDelta(
      structureChanged: !sameOrder,
      changedIds: {for (final message in changed) message.id, ...removed},
    );
  }

  static bool _sameMessage(ChatMessage? a, ChatMessage b) =>
      identical(a, b) ||
      (a != null &&
          a.id == b.id &&
          a.conversationId == b.conversationId &&
          a.text == b.text &&
          a.type == b.type &&
          a.image == b.image &&
          a.timestamp == b.timestamp &&
          a.isMine == b.isMine &&
          a.senderId == b.senderId &&
          a.historySequence == b.historySequence);

  ChatMessage? message(String id) => _byId[id];
}
