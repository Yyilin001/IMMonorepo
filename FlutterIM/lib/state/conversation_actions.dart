import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'list_providers.dart';
import 'conversation_preferences.dart';
import 'resources.dart';
import 'session_cache.dart';

final conversationActionsProvider = Provider<ConversationActions>(
  ConversationActions.new,
);

/// List actions never open a chat or allocate an unread conversation's timeline.
class ConversationActions {
  ConversationActions(this.ref);
  final Ref ref;

  void setPinned(int id, bool pinned) {
    final engine = ref.read(engineProvider);
    if (engine.conversation(id).pinned == pinned) return;
    final session = ref.read(chatSessionsProvider).lookup(id);
    if (session != null) {
      session.togglePinned();
    } else {
      engine.togglePinned(id);
      ref.invalidate(conversationPreferencesProvider(id));
      ref
          .read(conversationListProvider.notifier)
          .refresh(engine.takeChangedConversationIds());
    }
  }

  void setMuted(int id, bool muted) {
    final session = ref.read(chatSessionsProvider).lookup(id);
    if (session != null) {
      session.setMuted(muted);
    } else {
      final engine = ref.read(engineProvider)..setMuted(id, muted);
      ref.invalidate(conversationPreferencesProvider(id));
      ref
          .read(conversationListProvider.notifier)
          .refresh(engine.takeChangedConversationIds());
    }
  }

  void markRead(int id) {
    final engine = ref.read(engineProvider)..markRead(id);
    ref
        .read(conversationListProvider.notifier)
        .refresh(engine.takeChangedConversationIds());
  }
}
