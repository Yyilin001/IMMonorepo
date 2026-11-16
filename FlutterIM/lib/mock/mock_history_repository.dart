import 'dart:async';
import 'dart:collection';
import 'dart:math';

import '../core/history.dart';
import '../core/models.dart';
import 'group_members.dart';

/// A deterministic, cursor-paged mock server. Seed history is generated on
/// demand, not preallocated for 10,000 conversations. Live archive retention is
/// independent from the smaller UI cache and expires explicitly when bounded.
class MockHistoryRepository extends HistoryRepository {
  MockHistoryRepository({
    this.latency = const Duration(milliseconds: 100),
    this.slowLatency = const Duration(milliseconds: 1500),
    this.conversationCount = 10000,
    this.maxLiveMessages = 100000,
    this.maxLivePerConversation = 5000,
    DateTime? epoch,
  }) : epoch = epoch ?? DateTime.now() {
    if (maxLiveMessages < 1 || maxLivePerConversation < 1) {
      throw ArgumentError('Archive limits must be positive');
    }
  }

  final Duration latency, slowLatency;
  final DateTime epoch;
  final int conversationCount;
  final int maxLiveMessages, maxLivePerConversation;
  HistoryNetwork network = HistoryNetwork.normal;
  bool failNext = false;
  bool _disposed = false;
  final Map<int, int> _lastSequence = {};
  final Map<int, int> _expiredThrough = {};
  final LinkedList<_Archived> _all = LinkedList();
  final Map<int, Queue<_Archived>> _live = {};
  final Map<Timer, Completer<void>> _requests = {};

  int seedCount(int id) => id >= conversationCount || id == 7
      ? 0
      : id == 1
      ? 8
      : id == 2
      ? 12000
      : 360 + id % 10 * 30;
  int get retainedLiveCount => _all.length;

  @override
  ChatMessage record(ChatMessage message) {
    final id = message.conversationId;
    final sequence = (_lastSequence[id] ?? seedCount(id)) + 1;
    _lastSequence[id] = sequence;
    final stored = message.withHistorySequence(
      sequence,
      fallbackSenderId: message.isMine || message.senderId != null
          ? null
          : mockSenderId(id, sequence, conversationCount),
    );
    final entry = _Archived(stored);
    _all.add(entry);
    final queue = _live.putIfAbsent(id, Queue.new)..add(entry);
    if (queue.length > maxLivePerConversation) _evict(queue.first);
    while (_all.length > maxLiveMessages) {
      _evict(_all.first);
    }
    return stored;
  }

  void _evict(_Archived entry) {
    final message = entry.message;
    final queue = _live[message.conversationId]!;
    queue.removeFirst();
    if (queue.isEmpty) _live.remove(message.conversationId);
    entry.unlink();
    _expiredThrough[message.conversationId] = message.historySequence!;
  }

  ChatMessage _seed(int id, int sequence) {
    final sender = sequence % 3 == 1
        ? null
        : mockSenderId(id, sequence, conversationCount);
    return sequence % 7 == 0
        ? ChatMessage.image(
            id: 'history-$id-$sequence',
            conversationId: id,
            timestamp: epoch.subtract(
              Duration(minutes: seedCount(id) - sequence + 1),
            ),
            isMine: sender == null,
            senderId: sender,
            historySequence: sequence,
            image: mockImages[(sequence ~/ 7 + id) % mockImages.length],
          )
        : ChatMessage(
            id: 'history-$id-$sequence',
            conversationId: id,
            text:
                '历史 #$sequence · ${mockTexts[(id + sequence) % mockTexts.length]}',
            timestamp: epoch.subtract(
              Duration(minutes: seedCount(id) - sequence + 1),
            ),
            isMine: sender == null,
            senderId: sender,
            historySequence: sequence,
          );
  }

  @override
  ChatMessage? latestAvailable(int conversationId) {
    final live = _live[conversationId];
    if (live != null && live.isNotEmpty) return live.last.message;
    for (var sequence = seedCount(conversationId); sequence > 0; sequence--) {
      if (isVisible(conversationId, sequence)) {
        return _seed(conversationId, sequence);
      }
    }
    return null;
  }

  @override
  bool delete(ChatMessage message) {
    if (!super.delete(message)) return false;
    final queue = _live[message.conversationId];
    queue?.removeWhere((entry) {
      if (entry.message.historySequence != message.historySequence) {
        return false;
      }
      entry.unlink();
      return true;
    });
    if (queue != null && queue.isEmpty) _live.remove(message.conversationId);
    return true;
  }

  @override
  Future<HistoryPage> load(
    int conversationId, {
    int? before,
    int limit = 30,
  }) async {
    if (_disposed) throw StateError('History repository disposed');
    if (limit < 1 || (before != null && before < 1)) {
      throw ArgumentError('Invalid page request');
    }
    // Capture the cursor/data at request time: messages arriving during this
    // request belong to the live stream, not a moving offset-based page.
    final upper =
        before ??
        (_lastSequence[conversationId] ?? seedCount(conversationId)) + 1;
    final live = (_live[conversationId] ?? Queue<_Archived>()).toList(
      growable: false,
    );
    final records = live.reversed
        .map((e) => e.message)
        .where((m) => m.historySequence! < upper)
        .take(limit)
        .toList();
    var expiredGap = false;
    if (records.length < limit) {
      expiredGap =
          upper > seedCount(conversationId) + 1 &&
          _expiredThrough.containsKey(conversationId);
      for (
        var sequence = min(seedCount(conversationId), upper - 1);
        sequence >= 1 && records.length < limit;
        sequence--
      ) {
        if (isVisible(conversationId, sequence)) {
          records.add(_seed(conversationId, sequence));
        }
      }
    }
    final cursor = records.isEmpty ? before : records.last.historySequence;
    final hasMore =
        cursor != null &&
        (visibleCount(
                  conversationId,
                  0,
                  min(seedCount(conversationId), cursor - 1),
                ) >
                0 ||
            live.any((entry) => entry.message.historySequence! < cursor));
    final mode = network;
    final shouldFail = failNext;
    failNext = false;
    if (mode == HistoryNetwork.overlapping && records.isNotEmpty) {
      if (before != null && before <= seedCount(conversationId)) {
        records.add(_seed(conversationId, before));
      }
      records.add(records.first);
      records.shuffle(Random(upper));
    }
    await _waitForRequest(mode, shouldFail);
    return HistoryPage(
      messages: List.unmodifiable(
        records.where((m) => isVisible(conversationId, m.historySequence!)),
      ),
      before: cursor,
      hasMore: hasMore,
      hasExpiredGap: expiredGap,
    );
  }

  @override
  Future<HistoryPage> loadNewer(
    int conversationId, {
    required int after,
    int limit = 30,
  }) async {
    if (_disposed) throw StateError('History repository disposed');
    if (after < 0 || limit < 1) throw ArgumentError('Invalid page request');
    final last = _lastSequence[conversationId] ?? seedCount(conversationId);
    final records = <ChatMessage>[];
    for (
      var sequence = after + 1;
      sequence <= seedCount(conversationId) && records.length < limit;
      sequence++
    ) {
      if (isVisible(conversationId, sequence)) {
        records.add(_seed(conversationId, sequence));
      }
    }
    for (final entry in _live[conversationId] ?? Queue<_Archived>()) {
      if (records.length >= limit) break;
      if (entry.message.historySequence! > after) records.add(entry.message);
    }
    var previous = after;
    var expiredGap =
        records.isEmpty && visibleCount(conversationId, after, last) > 0;
    for (final message in records) {
      if (visibleCount(conversationId, previous, message.historySequence!) !=
          1) {
        expiredGap = true;
      }
      previous = message.historySequence!;
    }
    final cursor = records.isEmpty ? after : records.last.historySequence!;
    final mode = network;
    final shouldFail = failNext;
    failNext = false;
    if (mode == HistoryNetwork.overlapping && records.isNotEmpty) {
      if (after > 0 && after <= seedCount(conversationId)) {
        records.add(_seed(conversationId, after));
      }
      records.add(records.first);
      records.shuffle(Random(after));
    }
    await _waitForRequest(mode, shouldFail);
    return HistoryPage(
      messages: List.unmodifiable(
        records.where((m) => isVisible(conversationId, m.historySequence!)),
      ),
      hasMore: visibleCount(conversationId, cursor, last) > 0,
      hasExpiredGap: expiredGap,
    );
  }

  Future<void> _waitForRequest(HistoryNetwork mode, bool shouldFail) async {
    final completer = Completer<void>();
    late final Timer timer;
    timer = Timer(mode == HistoryNetwork.slow ? slowLatency : latency, () {
      _requests.remove(timer);
      completer.complete();
    });
    _requests[timer] = completer;
    await completer.future;
    if (_disposed) throw StateError('History repository disposed');
    if (mode == HistoryNetwork.offline || network == HistoryNetwork.offline) {
      throw StateError('历史服务离线，请切换为正常网络后重试');
    }
    if (shouldFail) throw StateError('模拟请求失败，请重试');
  }

  @override
  void dispose() {
    _disposed = true;
    for (final entry in _requests.entries) {
      entry.key.cancel();
      entry.value.complete();
    }
    _requests.clear();
  }
}

final class _Archived extends LinkedListEntry<_Archived> {
  _Archived(this.message);
  final ChatMessage message;
}
