import 'models.dart';

enum HistoryNetwork { normal, slow, offline, overlapping }

class HistoryPage {
  const HistoryPage({
    required this.messages,
    required this.hasMore,
    this.before,
    this.hasExpiredGap = false,
  });
  final List<ChatMessage> messages;

  /// Exclusive sequence cursor for the next older page.
  final int? before;
  final bool hasMore;
  final bool hasExpiredGap;
}

abstract class HistoryRepository {
  // History sequences are stable, including for seed messages generated on demand.
  final Map<int, List<int>> _deleted = {};

  int _upperBound(List<int> sequences, int value) {
    var low = 0, high = sequences.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (sequences[mid] <= value) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  bool delete(ChatMessage message) {
    final sequence = message.historySequence!;
    final sequences = _deleted.putIfAbsent(message.conversationId, () => []);
    final end = _upperBound(sequences, sequence);
    if (end > 0 && sequences[end - 1] == sequence) return false;
    sequences.insert(end, sequence);
    return true;
  }

  /// Number of sequence slots in (after, through] excluding local deletions.
  int visibleCount(int id, int after, int through) {
    if (through <= after) return 0;
    final deleted = _deleted[id];
    return through -
        after -
        (deleted == null
            ? 0
            : _upperBound(deleted, through) - _upperBound(deleted, after));
  }

  bool isVisible(int id, int sequence) =>
      visibleCount(id, sequence - 1, sequence) != 0;

  ChatMessage? latestAvailable(int conversationId);

  ChatMessage record(ChatMessage message);
  Future<HistoryPage> load(int conversationId, {int? before, int limit = 30});

  /// Ascending page immediately after an exclusive sequence cursor.
  Future<HistoryPage> loadNewer(
    int conversationId, {
    required int after,
    int limit = 30,
  });
  void dispose();
}

class HistoryState {
  const HistoryState({
    this.loading = false,
    this.hasMore = true,
    this.error,
    this.before,
    this.loaded = 0,
    this.hasExpiredGap = false,
    this.atWindowLimit = false,
  });
  final bool loading, hasMore, hasExpiredGap, atWindowLimit;
  final String? error;
  final int? before;
  final int loaded;

  bool sameDisplay(HistoryState other) {
    if (loading != other.loading ||
        error != other.error ||
        hasExpiredGap != other.hasExpiredGap) {
      return false;
    }
    if (loading || error != null) return true;
    if (atWindowLimit != other.atWindowLimit) return false;
    if (atWindowLimit) return true;
    if (hasMore != other.hasMore) return false;
    return hasMore
        ? loaded == other.loaded
        : (loaded == 0) == (other.loaded == 0);
  }
}

class NewerHistoryState {
  const NewerHistoryState({
    this.loading = false,
    this.error,
    this.hasExpiredGap = false,
  });
  final bool loading, hasExpiredGap;
  final String? error;
}
