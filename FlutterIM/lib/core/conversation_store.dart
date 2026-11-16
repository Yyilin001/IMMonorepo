import 'dart:collection';

import 'chat_engine.dart';
import 'conversation_index.dart';
import 'models.dart';

/// A row's visible state, excluding sort sequence and sub-minute timestamps.
class ConversationRowState {
  const ConversationRowState(this.item, this.selected);
  final Conversation item;
  final bool selected;

  bool sameDisplay(ConversationRowState other) =>
      selected == other.selected &&
      item.id == other.item.id &&
      item.name == other.item.name &&
      item.remark == other.item.remark &&
      item.preview == other.item.preview &&
      item.unread == other.item.unread &&
      item.pinned == other.item.pinned &&
      item.muted == other.item.muted &&
      item.isGroup == other.item.isGroup &&
      item.updatedAt.hour == other.item.updatedAt.hour &&
      item.updatedAt.minute == other.item.updatedAt.minute;
}

/// Pure indexed projection. It stores no listeners and never publishes state.
/// Riverpod notifiers own mutations and all UI notifications.
class ConversationStore {
  ConversationStore(this.engine) {
    rowCount = engine.conversationCount;
    _view = _ConversationView(this);
  }
  final ChatEngine engine;
  late int rowCount;
  late final List<Conversation> _view;
  String _query = '';
  bool _unreadOnly = false;
  Map<int, int>? _frozenRanks;
  ConversationIndex? _projection;
  final Map<int, Conversation> _members = {};

  List<Conversation> get value => _view;

  Conversation _at(int index) =>
      _projection?.at(index) ?? engine.conversationAt(index);
  Iterable<Conversation> get _values =>
      _projection?.values ?? engine.orderedConversations;

  bool _matches(Conversation item) =>
      (!_unreadOnly || item.unread > 0) &&
      (_query.isEmpty ||
          item.name.toLowerCase().contains(_query) ||
          item.remark.toLowerCase().contains(_query) ||
          item.id.toString().contains(_query));

  void setFilter({required String query, required bool unreadOnly}) {
    final normalized = query.trim().toLowerCase();
    if (normalized == _query && unreadOnly == _unreadOnly) return;
    _query = normalized;
    _unreadOnly = unreadOnly;
    _rebuildProjection();
  }

  void setOrderFrozen(bool frozen) {
    if (frozen == (_frozenRanks != null)) return;
    if (frozen) {
      var position = 0;
      _frozenRanks = {
        for (final item in engine.orderedConversations) item.id: position++,
      };
    } else {
      _frozenRanks = null;
    }
    _rebuildProjection();
  }

  void _rebuildProjection() {
    _members.clear();
    if (_query.isEmpty && !_unreadOnly && _frozenRanks == null) {
      _projection = null;
    } else {
      final ranks = _frozenRanks;
      _projection = ConversationIndex(
        compare: ranks == null
            ? null
            : (a, b) => ranks[a.id]!.compareTo(ranks[b.id]!),
      );
      for (final item in engine.orderedConversations) {
        if (_matches(item)) {
          _members[item.id] = item;
          _projection!.insert(item);
        }
      }
    }
    _updateCount();
  }

  /// Update the projection using only dirty IDs. No list-wide copying.
  void refresh(Set<int> changedIds) {
    final projection = _projection;
    if (projection != null) {
      for (final id in changedIds) {
        if (!engine.isListed(id)) continue;
        final ranks = _frozenRanks;
        if (ranks != null) ranks.putIfAbsent(id, () => ranks.length);
        final old = _members.remove(id);
        if (old != null) projection.remove(old);
        final next = engine.conversation(id);
        if (_matches(next)) {
          _members[id] = next;
          projection.insert(next);
        }
      }
    }
    _updateCount();
  }

  ConversationRowState? _stateAt(int index) {
    if (index >= rowCount) return null;
    final item = _at(index);
    return ConversationRowState(item, item.id == engine.activeId);
  }

  void _updateCount() {
    rowCount = _projection?.length ?? engine.conversationCount;
  }

  ConversationRowState? rowAt(int index) => _stateAt(index);
}

class _ConversationView extends ListBase<Conversation> {
  _ConversationView(this.feed);
  final ConversationStore feed;
  @override
  int get length => feed.rowCount;
  @override
  set length(int value) =>
      throw UnsupportedError('Read-only conversation view');
  @override
  Conversation operator [](int index) => feed._at(index);
  @override
  void operator []=(int index, Conversation value) =>
      throw UnsupportedError('Read-only conversation view');
  @override
  Iterator<Conversation> get iterator => feed._values.iterator;
}
