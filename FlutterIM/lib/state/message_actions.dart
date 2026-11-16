import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../mock/group_members.dart';
import 'resources.dart';
import 'list_providers.dart';
import 'chat_session.dart';
import 'selection.dart';
import 'session_cache.dart';
import 'metrics.dart';
import 'contact_notes.dart';

final messageActionsProvider = Provider<MessageActions>((ref) {
  final actions = MessageActions(ref);
  ref.onDispose(actions.dispose);
  return actions;
});

/// Commands commit every accepted message before returning; deleted contacts
/// are rejected synchronously before any write. No scheduling,
/// debounce, time window or frame callback exists in the receive path.
class MessageActions {
  MessageActions(this.ref);
  final Ref ref;
  int _localSequence = 0;
  final Map<Timer, int> _replies = {};
  bool _deleted(int id) =>
      ref.read(contactNotesStoreProvider)[id]?.deleted ?? false;
  void cancelRepliesFor(int id) {
    final timers = _replies.entries
        .where((entry) => entry.value == id)
        .map((entry) => entry.key)
        .toList();
    for (final timer in timers) {
      timer.cancel();
      _replies.remove(timer);
    }
  }

  void receive(ChatMessage message) {
    if (!ref.mounted) return;
    final engine = ref.read(engineProvider);
    final id = message.conversationId;
    if (!engine.hasContact(id) || _deleted(id)) return;
    final clock = Stopwatch()..start();
    final sessions = ref.read(chatSessionsProvider);
    // Open the active session before ingestion so its initial cache excludes
    // this message. Background traffic only updates sessions already retained.
    final session =
        message.conversationId == ref.read(selectedConversationProvider)
        ? sessions.lookup(message.conversationId) ??
              sessions.open(message.conversationId)
        : sessions.lookup(message.conversationId);
    final stored = ref.read(historyRepositoryProvider).record(message);
    final previousCount = engine.conversationCount;
    engine.receive(stored);
    if (engine.conversationCount != previousCount) {
      ref.invalidate(totalConversationCountProvider);
    }
    final processing = clock.elapsedMicroseconds / 1000;
    clock.reset();
    session?.accept(stored);
    ref
        .read(conversationListProvider.notifier)
        .refresh(engine.takeChangedConversationIds());
    ref
        .read(metricsProvider.notifier)
        .record(
          messageMs: processing,
          notificationMs: clock.elapsedMicroseconds / 1000,
        );
  }

  void deleteMessage(ChatMessage target) {
    if (!ref.mounted) return;
    final id = target.conversationId;
    final archive = ref.read(historyRepositoryProvider);
    final engine = ref.read(engineProvider);
    final current =
        engine.previewSequence(id) ??
        archive.latestAvailable(id)?.historySequence;
    if (!archive.delete(target)) return;
    final latest = archive.latestAvailable(id);
    final session = ref.read(chatSessionsProvider).lookup(id);
    session?.deleteMessage(target, latest);
    final visible = session?.newestInWindow;
    final replacement =
        (visible?.historySequence ?? 0) > (latest?.historySequence ?? 0)
        ? visible
        : latest;
    engine.deleteMessage(
      target,
      updatePreview: current == target.historySequence,
      latest: replacement,
    );
    final changes = engine.takeChangedConversationIds();
    if (changes.isNotEmpty) {
      ref.read(conversationListProvider.notifier).refresh(changes);
    }
  }

  void send(String text) {
    final id = ref.read(selectedConversationProvider);
    if (id == null || text.trim().isEmpty || _deleted(id)) return;
    ref.read(chatSessionProvider(id).notifier).returnToLatest();
    final number = _localSequence++;
    receive(
      ChatMessage(
        id: 'local-$number',
        conversationId: id,
        text: text.trim(),
        timestamp: DateTime.now(),
        isMine: true,
      ),
    );
    _scheduleReply(
      number,
      '收到你的消息了：「${text.trim().length > 32 ? '${text.trim().substring(0, 32)}…' : text.trim()}」 ✓',
      id,
    );
  }

  bool sendImage(int id, ImageMessageData image) {
    if (_deleted(id)) return false;
    if (id == ref.read(selectedConversationProvider)) {
      ref.read(chatSessionProvider(id).notifier).returnToLatest();
    }
    final number = _localSequence++;
    receive(
      ChatMessage.image(
        id: 'local-$number',
        conversationId: id,
        timestamp: DateTime.now(),
        isMine: true,
        image: image,
      ),
    );
    _scheduleReply(number, '收到你发来的图片了。', id);
    return true;
  }

  void _scheduleReply(int number, String text, int id) {
    final sender = mockSenderId(
      id,
      number,
      ref.read(engineProvider).initialConversationCount,
    );
    if (sender == null) return;
    late final Timer reply;
    reply = Timer(const Duration(milliseconds: 650), () {
      _replies.remove(reply);
      receive(
        ChatMessage(
          id: 'reply-$number',
          senderId: sender,
          conversationId: id,
          text: text,
          timestamp: DateTime.now(),
        ),
      );
    });
    _replies[reply] = id;
  }

  void dispose() {
    for (final reply in _replies.keys) {
      reply.cancel();
    }
    _replies.clear();
  }
}
