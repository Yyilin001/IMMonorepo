import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/conversation_store.dart';
import '../core/models.dart';
import 'resources.dart';

final totalUnreadProvider =
    NotifierProvider.autoDispose<TotalUnreadNotifier, int>(
      TotalUnreadNotifier.new,
    );

class TotalUnreadNotifier extends Notifier<int> {
  @override
  int build() => ref.watch(engineProvider).totalUnread;
  void _commit(int value) {
    if (state != value) state = value;
  }
}

typedef MessageKey = ({int conversationId, String messageId});

/// Handles to live Riverpod notifiers, maintained by their build/onDispose.
/// No user listeners or notification callbacks are stored here. Caching handles
/// avoids repeated temporary Riverpod subscriptions in the per-message hot path.
class ListProviderRegistry {
  final Map<int, ConversationRowNotifier> _rows = {};
  final Map<int, Map<String, MessageNotifier>> _messages = {};
  int get rowCount => _rows.length;
  int messageCount(int conversationId) =>
      _messages[conversationId]?.length ?? 0;
}

final listProviderRegistryProvider = Provider<ListProviderRegistry>(
  (ref) => ListProviderRegistry(),
);

final conversationRowProvider = NotifierProvider.autoDispose
    .family<ConversationRowNotifier, ConversationRowState?, int>(
      ConversationRowNotifier.new,
    );

class ConversationRowNotifier extends Notifier<ConversationRowState?> {
  ConversationRowNotifier(this.index);
  final int index;
  ConversationRowState? _display;
  @override
  ConversationRowState? build() {
    final store = ref.watch(conversationStoreProvider);
    final registry = ref.watch(listProviderRegistryProvider);
    registry._rows[index] = this;
    ref.onDispose(() {
      if (identical(registry._rows[index], this)) registry._rows.remove(index);
    });
    return _display = store.rowAt(index);
  }

  void _commit(ConversationRowState? next) {
    // Compare the last published snapshot without flushing Riverpod state for
    // every mounted row on every incoming message.
    final previous = _display;
    if (next == null
        ? previous != null
        : previous == null || !previous.sameDisplay(next)) {
      _display = next;
      state = next;
    }
  }
}

// The heading counts all listed chats even when search or unread filters are active.
final totalConversationCountProvider = Provider<int>(
  (ref) => ref.watch(engineProvider).conversationCount,
);

final conversationCountProvider =
    NotifierProvider.autoDispose<ConversationCountNotifier, int>(
      ConversationCountNotifier.new,
    );

class ConversationCountNotifier extends Notifier<int> {
  @override
  int build() => ref.watch(conversationStoreProvider).rowCount;
  void _commit(int next) => state = next;
}

final messageProvider = NotifierProvider.autoDispose
    .family<MessageNotifier, ChatMessage?, MessageKey>(MessageNotifier.new);

class MessageNotifier extends Notifier<ChatMessage?> {
  MessageNotifier(this.key);
  final MessageKey key;
  @override
  ChatMessage? build() {
    final store = ref.watch(timelineStoreProvider(key.conversationId));
    final registry = ref.watch(listProviderRegistryProvider);
    registry._messages.putIfAbsent(
      key.conversationId,
      () => {},
    )[key.messageId] = this;
    ref.onDispose(() {
      final messages = registry._messages[key.conversationId];
      if (identical(messages?[key.messageId], this)) {
        messages?.remove(key.messageId);
      }
      if (messages?.isEmpty ?? false) {
        registry._messages.remove(key.conversationId);
      }
    });
    return store.message(key.messageId);
  }

  void _commit(ChatMessage? next) => state = next;
}

/// All timeline writes go through this notifier. Its public state is only the
/// structural revision; content-only changes update the matching message family.
final timelineStructureProvider = NotifierProvider.autoDispose
    .family<TimelineStructureNotifier, int, int>(TimelineStructureNotifier.new);

class TimelineStructureNotifier extends Notifier<int> {
  TimelineStructureNotifier(this.id);
  final int id;
  String? lastLiveMessageId;
  @override
  int build() {
    lastLiveMessageId = null;
    return ref.watch(timelineStoreProvider(id)).structure;
  }

  void replace(List<ChatMessage> messages, {String? liveMessageId}) {
    final store = ref.read(timelineStoreProvider(id));
    final delta = store.replace(messages);
    lastLiveMessageId = liveMessageId;
    final registry = ref.read(listProviderRegistryProvider);
    for (final messageId in delta.changedIds) {
      registry._messages[id]?[messageId]?._commit(store.message(messageId));
    }
    if (delta.structureChanged) state = store.structure;
  }
}

class ConversationListState {
  const ConversationListState({
    this.query = '',
    this.unreadOnly = false,
    this.frozen = false,
  });
  final String query;
  final bool unreadOnly, frozen;
}

final conversationListProvider =
    NotifierProvider<ConversationListNotifier, ConversationListState>(
      ConversationListNotifier.new,
    );

class ConversationListNotifier extends Notifier<ConversationListState> {
  @override
  ConversationListState build() => const ConversationListState();

  void _publishRows(int previousCount) {
    if (ref.read(totalUnreadProvider.exists)) {
      ref
          .read(totalUnreadProvider.notifier)
          ._commit(ref.read(engineProvider).totalUnread);
    }
    final store = ref.read(conversationStoreProvider);
    if (store.rowCount != previousCount &&
        ref.read(conversationCountProvider.exists)) {
      ref.read(conversationCountProvider.notifier)._commit(store.rowCount);
    }
    // Only existing row providers are examined. Reordering necessarily changes
    // the occupants of affected visible/cache positions, not just the sender.
    final registry = ref.read(listProviderRegistryProvider);
    final rows = registry._rows.entries.toList(growable: false);
    for (final entry in rows) {
      // A preceding synchronous listener may invalidate another row.
      if (identical(registry._rows[entry.key], entry.value)) {
        entry.value._commit(store.rowAt(entry.key));
      }
    }
  }

  void refresh(Set<int> changedIds) {
    final store = ref.read(conversationStoreProvider);
    final previousCount = store.rowCount;
    store.refresh(changedIds);
    _publishRows(previousCount);
  }

  void filter({String? query, bool? unreadOnly}) {
    final next = ConversationListState(
      query: (query ?? state.query).trim().toLowerCase(),
      unreadOnly: unreadOnly ?? state.unreadOnly,
      frozen: state.frozen,
    );
    final store = ref.read(conversationStoreProvider);
    final previousCount = store.rowCount;
    store.setFilter(query: next.query, unreadOnly: next.unreadOnly);
    _publishRows(previousCount);
    state = next;
  }

  void freeze(bool frozen) {
    if (state.frozen == frozen) return;
    final store = ref.read(conversationStoreProvider);
    final previousCount = store.rowCount;
    store.setOrderFrozen(frozen);
    _publishRows(previousCount);
    state = ConversationListState(
      query: state.query,
      unreadOnly: state.unreadOnly,
      frozen: frozen,
    );
  }

  void markAllRead() {
    final engine = ref.read(engineProvider)..markAllRead();
    refresh(engine.takeChangedConversationIds());
  }
}
