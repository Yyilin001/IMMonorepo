import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_session.dart';
import 'resources.dart';

final chatSessionsProvider = Provider<ChatSessions>((ref) {
  final sessions = ChatSessions(
    ref,
    ref.watch(imConfigProvider).maxRetainedSessions,
  );
  ref.onDispose(sessions.dispose);
  return sessions;
});

/// Keeps only recently opened sessions alive; incoming traffic never grows it.
class ChatSessions {
  ChatSessions(this.ref, this.capacity) {
    if (capacity < 1) throw ArgumentError.value(capacity);
  }
  final Ref ref;
  final int capacity;
  final _entries =
      <int, ({ChatSessionNotifier session, void Function() release})>{};
  int get length => _entries.length;
  Iterable<int> get retainedIds => _entries.keys;
  ChatSessionNotifier? lookup(int id) => _entries[id]?.session;

  ChatSessionNotifier open(int id) {
    var entry = _entries.remove(id);
    if (entry == null) {
      var session = ref.read(chatSessionProvider(id).notifier);
      if (session.isRetired) {
        ref.invalidate(timelineStoreProvider(id));
        ref.invalidate(chatSessionProvider(id));
        session = ref.read(chatSessionProvider(id).notifier);
      }
      entry = (session: session, release: session.retain());
    }
    _entries[id] = entry;
    while (_entries.length > capacity) {
      final old = _entries.remove(_entries.keys.first)!;
      // Retire immediately so an old page cannot commit before autoDispose.
      old.session.retire();
      old.release();
    }
    entry.session.start();
    return entry.session;
  }

  void dispose() {
    for (final entry in _entries.values) {
      entry.release();
    }
    _entries.clear();
  }
}
