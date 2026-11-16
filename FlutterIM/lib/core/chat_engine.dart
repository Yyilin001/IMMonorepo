import 'dart:collection';

import '../mock/group_members.dart';
import '../mock/traffic_pattern.dart';
import 'models.dart';
import 'conversation_index.dart';

/// Pure Dart data layer: immediate indexed ordering and bounded history.
class ChatEngine {
  ChatEngine({
    int conversationCount = 10000,
    this.maxCachedMessages = 40000,
    this.maxMessagesPerConversation = 500,
  }) : initialConversationCount = conversationCount {
    if (conversationCount < 1 ||
        maxCachedMessages < 1 ||
        maxMessagesPerConversation < 1) {
      throw ArgumentError('Counts and cache limits must be positive');
    }
    final now = DateTime.now();
    const names = [
      '产品设计小组',
      '林知夏',
      'Flutter 技术交流',
      '陈一舟',
      '周末出逃计划',
      '许清禾',
      '项目协作空间',
      '陆星野',
    ];
    for (var i = 0; i < conversationCount; i++) {
      final name = i < names.length
          ? names[i]
          : (i % 4 == 0
                ? '协作小组 ${i.toString().padLeft(5, '0')}'
                : '本地好友 ${i.toString().padLeft(5, '0')}');
      _conversations[i] = Conversation(
        id: i,
        name: name,
        preview: mockTexts[i % mockTexts.length],
        updatedAt: now.subtract(Duration(minutes: i)),
        unread: i % 7 == 0 ? i % 9 + 1 : 0,
        pinned: i < 3,
        isGroup: isMockGroup(i),
      );
      totalUnread += _conversations[i]!.unread;
      _index.insert(_conversations[i]!);
    }
    _order = List.generate(conversationCount, (i) => i);
  }

  final int initialConversationCount;
  int get conversationCount => _index.length;
  late final int directoryContactCount =
      initialConversationCount + firstContactPoolSize(initialConversationCount);
  int _reservedSenders = 0;
  int get contactCount => directoryContactCount + _reservedSenders;
  int reserveFirstContactIds(int count) {
    RangeError.checkNotNegative(count, 'count');
    final first = contactCount;
    _reservedSenders += count;
    return first;
  }

  bool hasContact(int id) => id >= 0 && id < contactCount;
  bool isListed(int id) =>
      (id >= 0 && id < initialConversationCount) || _introduced.contains(id);
  final Set<int> _introduced = {};
  final int maxCachedMessages;
  final int maxMessagesPerConversation;
  final Map<int, Conversation> _conversations = {};
  // The same message is referenced from both indexes. Removing an entry from
  // either cache also removes it from the other: no hidden unbounded queue.
  final LinkedList<_CachedMessage> _history = LinkedList();
  final Map<int, Queue<_CachedMessage>> _byConversation = {};
  final ConversationIndex _index = ConversationIndex();
  final Set<int> _changedIds = {};
  final Map<int, int> _previewSequences = {};
  late List<int> _order;
  int? activeId;
  int received = 0;
  int sent = 0;
  int evicted = 0;
  int totalUnread = 0;
  int revision = 0;
  int timelineRevision = 0;
  int _sequence = 0;

  int get cachedMessageCount => _history.length;
  Conversation conversation(int id) {
    RangeError.checkValueInInterval(id, 0, contactCount - 1, 'id');
    return _conversations[id] ??= Conversation(
      id: id,
      name: id >= directoryContactCount ? '压测会话 $id' : '本地好友 ${id.toString().padLeft(5, '0')}',
      preview: '暂无消息',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  void ingest(Iterable<ChatMessage> messages) {
    for (final message in messages) {
      receive(message);
    }
  }

  /// The model and its sorted position are updated before this call returns.
  void receive(ChatMessage message) {
    final id = message.conversationId;
    if (!hasContact(id)) return;
    final old = conversation(id);
    _cache(message);
    final sequence = message.historySequence;
    if (sequence != null) _previewSequences[old.id] = sequence;
    final unread = message.isMine || activeId == old.id ? 0 : 1;
    totalUnread += unread;
    _replace(
      old,
      old.copyWith(
        preview: message.preview,
        updatedAt: message.timestamp,
        unread: old.unread + unread,
        sequence: ++_sequence,
      ),
      listOnFirstMessage: true,
    );
    if (message.isMine) {
      sent++;
    } else {
      received++;
    }
    if (activeId == old.id) timelineRevision++;
    revision++;
  }

  void _replace(
    Conversation old,
    Conversation next, {
    bool listOnFirstMessage = false,
  }) {
    _changedIds.add(next.id);
    _conversations[next.id] = next;
    if (isListed(old.id)) {
      _index.remove(old);
    } else if (listOnFirstMessage) {
      _introduced.add(next.id);
      _order.add(next.id);
    } else {
      return;
    }
    _index.insert(next);
  }

  Set<int> takeChangedConversationIds() {
    final changed = Set<int>.of(_changedIds);
    _changedIds.clear();
    return changed;
  }

  Conversation conversationAt(int index) => _index.at(index);
  Iterable<Conversation> get orderedConversations => _index.values;

  void _cache(ChatMessage message) {
    final entry = _CachedMessage(message);
    _history.add(entry);
    final queue = _byConversation.putIfAbsent(
      message.conversationId,
      Queue.new,
    );
    queue.addLast(entry);
    if (queue.length > maxMessagesPerConversation) {
      final removed = queue.removeFirst();
      removed.unlink();
      evicted++;
    }
    while (_history.length > maxCachedMessages) {
      final entry = _history.first;
      final oldest = entry.message;
      entry.unlink();
      final messages = _byConversation[oldest.conversationId]!;
      messages.removeFirst();
      if (messages.isEmpty) _byConversation.remove(oldest.conversationId);
      if (oldest.conversationId == activeId) timelineRevision++;
      evicted++;
    }
  }

  int? previewSequence(int id) => _previewSequences[id];

  void deleteMessage(
    ChatMessage target, {
    required bool updatePreview,
    ChatMessage? latest,
  }) {
    final id = target.conversationId;
    final queue = _byConversation[id];
    queue?.removeWhere((entry) {
      if (entry.message.id != target.id) return false;
      entry.unlink();
      return true;
    });
    if (queue != null && queue.isEmpty) _byConversation.remove(id);
    if (activeId == id) timelineRevision++;
    if (updatePreview) {
      final old = conversation(id);
      _previewSequences[id] = latest?.historySequence ?? 0;
      _replace(
        old,
        old.copyWith(
          preview: latest?.preview ?? '暂无消息',
          updatedAt: latest?.timestamp,
        ),
      );
    }
    revision++;
  }

  void select(int? id) {
    if (id != null && !hasContact(id)) {
      throw ArgumentError.value(id, 'id');
    }
    activeId = id;
    if (id != null) {
      final item = conversation(id);
      totalUnread -= item.unread;
      _replace(item, item.copyWith(unread: 0));
    }
    revision++;
    timelineRevision++;
  }

  void setRemark(int id, String remark) {
    final old = conversation(id);
    if (old.remark == remark) return;
    _replace(old, old.copyWith(remark: remark));
    revision++;
  }

  void togglePinned(int id) {
    final item = conversation(id);
    _replace(item, item.copyWith(pinned: !item.pinned));
    revision++;
  }

  void setMuted(int id, bool muted) {
    final item = conversation(id);
    if (item.muted == muted) return;
    _replace(item, item.copyWith(muted: muted));
    revision++;
  }

  void markAllRead() {
    for (final item in _conversations.values.toList(growable: false)) {
      if (item.unread != 0) {
        _replace(item, item.copyWith(unread: 0));
      }
    }
    totalUnread = 0;
    revision++;
  }

  void markRead(int id) {
    final item = conversation(id);
    if (item.unread == 0) return;
    totalUnread -= item.unread;
    _replace(item, item.copyWith(unread: 0));
    revision++;
  }

  /// Explicit immutable copy for exports/tests. The UI uses indexed live reads,
  /// so incoming messages never need to copy all 10,000 rows.
  List<Conversation> snapshot({bool freezeOrder = false}) {
    if (!freezeOrder) {
      _order = _index.values.map((item) => item.id).toList();
    }
    return List.unmodifiable(_order.map((id) => _conversations[id]!));
  }

  /// Newest first for a reverse, lazily built timeline.
  List<ChatMessage> messages(int id, {int limit = 200}) {
    final messages = _byConversation[id];
    if (messages == null) return const [];
    return List.unmodifiable(
      messages
          .toList(growable: false)
          .reversed
          .take(limit)
          .map((entry) => entry.message),
    );
  }
}

// Intrusive links allow constant-time eviction from both the global FIFO and
// a hot conversation. Iterating HashMap.keys.first after repeated deletion
// would scan tombstones and degrade at the cache limit.
final class _CachedMessage extends LinkedListEntry<_CachedMessage> {
  _CachedMessage(this.message);
  final ChatMessage message;
}
