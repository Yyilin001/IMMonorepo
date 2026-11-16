import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/history.dart';
import '../core/models.dart';
import 'resources.dart';
import 'conversation_preferences.dart';
import 'list_providers.dart';
import 'history_scenario.dart';

class ChatSessionState {
  const ChatSessionState({
    this.history = const HistoryState(),
    this.frozen = false,
    this.pending = 0,
    this.unloadedNewer = 0,
    this.pinned = true,
    this.muted = false,
    this.scrollOffset = 0,
    this.readingAnchor,
    this.newer = const NewerHistoryState(),
  });
  final HistoryState history;

  /// Pauses automatic scrolling; incoming messages still append immediately.
  final bool frozen;
  final bool pinned;
  final bool muted;

  /// New arrivals while automatic following is paused, including appended rows.
  final int pending;

  /// Only the suffix beyond the bounded, contiguous reading window needs paging.
  final int unloadedNewer;
  final double scrollOffset;
  final int? readingAnchor;
  final NewerHistoryState newer;
  ChatSessionState copyWith({
    HistoryState? history,
    bool? frozen,
    int? pending,
    int? unloadedNewer,
    bool? pinned,
    bool? muted,
    double? scrollOffset,
    int? readingAnchor,
    bool clearReadingAnchor = false,
    NewerHistoryState? newer,
  }) => ChatSessionState(
    history: history ?? this.history,
    frozen: frozen ?? this.frozen,
    pending: pending ?? this.pending,
    unloadedNewer: unloadedNewer ?? this.unloadedNewer,
    pinned: pinned ?? this.pinned,
    muted: muted ?? this.muted,
    scrollOffset: scrollOffset ?? this.scrollOffset,
    readingAnchor: clearReadingAnchor
        ? null
        : readingAnchor ?? this.readingAnchor,
    newer: newer ?? this.newer,
  );
}

/// Presentation equality deliberately excludes cursors and hidden fields.
class HistoryPresentation {
  const HistoryPresentation(this.value);
  final HistoryState value;
  @override
  bool operator ==(Object other) =>
      other is HistoryPresentation && value.sameDisplay(other.value);
  @override
  int get hashCode =>
      Object.hash(value.loading, value.error, value.hasExpiredGap);
}

final chatSessionProvider = NotifierProvider.autoDispose
    .family<ChatSessionNotifier, ChatSessionState, int>(
      ChatSessionNotifier.new,
    );

class ChatSessionNotifier extends Notifier<ChatSessionState> {
  ChatSessionNotifier(this.id);
  final int id;
  bool _started = false;
  bool _retired = false;
  bool get isRetired => _retired;
  void Function() retain() => ref.keepAlive().close;
  void retire() {
    _retired = true;
    _historyGeneration++;
  }

  final List<ChatMessage> _window = [];
  static const initialPageSize = 100;
  static const historyPageSize = 100;
  static const newerPageSize = 30;
  static const historyWindowLimit = 2000;
  int _historyGeneration = 0, _liveTrimVersion = 0;
  int _latestSequence = 0;
  ChatMessage? _latestLiveMessage;
  int? _before;
  int? _firstPendingSequence;
  bool _hasMore = true, _hasExpiredGap = false;
  int _windowCapacity = 200;

  @override
  ChatSessionState build() {
    _retired = false;
    _started = false;
    _windowCapacity = 200;
    _latestLiveMessage = null;
    _hasMore = true;
    _hasExpiredGap = false;
    _liveTrimVersion = 0;
    _historyGeneration++;
    final engine = ref.watch(engineProvider);
    final timeline = ref.watch(timelineStoreProvider(id));
    ref.watch(timelineStructureProvider(id).notifier);
    _window.clear();
    _window.addAll(timeline.value);
    _before = _window.isEmpty ? null : _window.last.historySequence;
    _latestSequence = _window.isEmpty ? 0 : _window.first.historySequence ?? 0;
    ref.onDispose(() => _historyGeneration++);
    return ChatSessionState(
      pinned: engine.conversation(id).pinned,
      muted: engine.conversation(id).muted,
      history: HistoryState(loaded: _window.length, before: _before),
    );
  }

  void start() {
    if (_started) return;
    _started = true;
    if (_window.length < initialPageSize) unawaited(loadOlder());
  }

  void saveScrollOffset(double offset) {
    final next = offset.isFinite ? offset : 0.0;
    if (state.scrollOffset != next) state = state.copyWith(scrollOffset: next);
  }

  int _visibleCount(int after, int through) =>
      ref.read(historyRepositoryProvider).visibleCount(id, after, through);

  ChatMessage? get newestInWindow => _window.firstOrNull;

  void deleteMessage(ChatMessage message, ChatMessage? archiveLatest) {
    final sequence = message.historySequence!;
    final oldLength = _window.length;
    _window.removeWhere((m) => m.id == message.id);
    if (_latestLiveMessage?.id == message.id) {
      _latestLiveMessage = archiveLatest;
    }
    if (state.frozen &&
        _firstPendingSequence != null &&
        sequence >= _firstPendingSequence! &&
        state.pending > 0) {
      state = state.copyWith(pending: state.pending - 1);
    }
    if (oldLength == _window.length) {
      if (state.unloadedNewer > 0 &&
          sequence > (_window.firstOrNull?.historySequence ?? 0)) {
        state = state.copyWith(unloadedNewer: state.unloadedNewer - 1);
      }
      return;
    }
    ref.read(timelineStructureProvider(id).notifier).replace(_window);
    _emitHistory(loading: state.history.loading, error: state.history.error);
    if (_window.isEmpty && _hasMore && !state.history.loading) {
      unawaited(loadOlder());
    }
  }

  void accept(ChatMessage message) {
    if (_retired || message.conversationId != id) return;
    _latestSequence = max(_latestSequence, message.historySequence ?? 0);
    _latestLiveMessage = message;
    if (state.frozen) {
      // Pause following, not publication. Grow below the stable reading origin
      // on every message until the bounded window is full. Once a suffix is
      // outside the window, never append across it and silently create a gap.
      final sequence = message.historySequence!;
      _firstPendingSequence ??= sequence;
      final contiguous =
          _window.isEmpty ||
          _visibleCount(_window.first.historySequence!, sequence) == 1;
      final append = contiguous && _window.length < historyWindowLimit;
      if (append) _window.insert(0, message);
      state = state.copyWith(
        pending: state.pending + 1,
        unloadedNewer: append
            ? 0
            : _visibleCount(_window.first.historySequence!, _latestSequence),
        readingAnchor: state.readingAnchor ?? sequence - 1,
      );
      if (append) {
        ref
            .read(timelineStructureProvider(id).notifier)
            .replace(_window, liveMessageId: message.id);
        _emitHistory(
          loading: state.history.loading,
          error: state.history.error,
        );
      }
      return;
    }
    _window.insert(0, message);
    if (_window.length > _windowCapacity) {
      _window.removeLast();
      _liveTrimVersion++;
      _before = _window.last.historySequence;
      _hasMore = true;
    }
    ref
        .read(timelineStructureProvider(id).notifier)
        .replace(_window, liveMessageId: message.id);
    _emitHistory(loading: state.history.loading, error: state.history.error);
  }

  void freeze(bool freeze) {
    if (!freeze) {
      returnToLatest();
      return;
    }
    if (state.frozen) return;
    _firstPendingSequence = null;
    state = state.copyWith(
      frozen: true,
      readingAnchor: _window.isEmpty ? null : _window.first.historySequence,
    );
  }

  /// Explicit navigation uses already received data, never a history request.
  /// Keep the existing list when it reaches the latest message. If its bounded
  /// window fell behind, join a contiguous cached suffix where possible.
  void returnToLatest() {
    if (!state.frozen) return;
    var changed = false;
    if (state.unloadedNewer > 0) {
      final recent = ref
          .read(engineProvider)
          .messages(id, limit: historyWindowLimit);
      // A retained session can outlive the global engine cache. Keep one latest
      // live record independently so even that case can navigate immediately.
      final latest = _latestLiveMessage;
      final available =
          recent.isNotEmpty &&
              _visibleCount(recent.first.historySequence!, _latestSequence) == 0
          ? recent
          : latest == null
          ? <ChatMessage>[]
          : [latest];
      final head = _window.isEmpty ? 0 : _window.first.historySequence!;
      final suffix = available
          .takeWhile((message) => message.historySequence! > head)
          .toList();
      if (suffix.isNotEmpty) {
        if (_visibleCount(head, suffix.last.historySequence!) == 1) {
          _window.insertAll(0, suffix);
        } else {
          // An explicit jump may skip an unloaded interval; never splice two
          // disconnected ranges together as if they were consecutive messages.
          _window
            ..clear()
            ..addAll(suffix);
          _hasExpiredGap = false;
        }
        if (_window.length > historyWindowLimit) {
          _window.removeRange(historyWindowLimit, _window.length);
        }
        _before = _window.last.historySequence;
        _hasMore = true;
        changed = true;
      }
    }
    _windowCapacity = max(200, _window.length);
    // Keep an initial request if no message has loaded yet. Otherwise invalidate
    // pending pages without starting a replacement request or showing a spinner.
    final keepInitialRequest = _window.isEmpty && state.history.loading;
    if (!keepInitialRequest) _historyGeneration++;
    state = state.copyWith(
      frozen: false,
      pending: 0,
      unloadedNewer: 0,
      clearReadingAnchor: true,
      scrollOffset: 0,
      newer: const NewerHistoryState(),
    );
    if (changed) {
      ref.read(timelineStructureProvider(id).notifier).replace(_window);
    }
    _emitHistory(loading: keepInitialRequest);
  }

  /// Rebase before trimming could remove the current scroll origin.
  bool get needsNewerRebase {
    final anchor = state.readingAnchor;
    if (anchor == null ||
        _window.length <= historyWindowLimit - newerPageSize) {
      return false;
    }
    return anchor <=
        _window[historyWindowLimit - newerPageSize].historySequence!;
  }

  /// The UI rebases its offset at the same visible edge in the same frame.
  void anchorAtNewerEdge() {
    if (_window.isEmpty) return;
    state = state.copyWith(
      readingAnchor: _window.first.historySequence,
      scrollOffset: 0,
    );
  }

  /// Resume at the actual newest edge, keeping its contiguous messages. Trim
  /// only distant older rows so live updates return to the 200-message budget.
  /// Explicit jump-to-latest preserves loaded history via returnToLatest().
  void followFromNewerEdge() {
    if (state.unloadedNewer != 0 || state.newer.loading) return;
    _windowCapacity = 200;
    final trimmed = _window.length > _windowCapacity;
    if (trimmed) {
      _window.removeRange(_windowCapacity, _window.length);
      _before = _window.last.historySequence;
      _hasMore = true;
      _historyGeneration++;
    }
    state = state.copyWith(
      frozen: false,
      pending: 0,
      clearReadingAnchor: true,
      scrollOffset: 0,
    );
    if (trimmed) {
      ref.read(timelineStructureProvider(id).notifier).replace(_window);
      _emitHistory();
    }
  }

  Future<void> loadNewer() async {
    if (!ref.mounted ||
        _retired ||
        !state.frozen ||
        state.unloadedNewer == 0 ||
        state.newer.loading ||
        state.history.loading) {
      return;
    }
    final generation = _historyGeneration;
    final after = _window.isEmpty ? 0 : _window.first.historySequence!;
    state = state.copyWith(newer: const NewerHistoryState(loading: true));
    ref.read(historyScenarioProvider.notifier).consumeFailure();
    try {
      final archive = ref.read(historyRepositoryProvider);
      final page = await archive.loadNewer(
        id,
        after: after,
        limit: newerPageSize,
      );
      if (!ref.mounted || _retired || generation != _historyGeneration) return;
      final byId = <String, ChatMessage>{};
      for (final message in page.messages) {
        if (message.conversationId == id &&
            (message.historySequence ?? 0) > after &&
            archive.isVisible(id, message.historySequence!)) {
          byId.putIfAbsent(message.id, () => message);
        }
      }
      final next = byId.values.toList()
        ..sort((a, b) => a.historySequence!.compareTo(b.historySequence!));
      var previous = after;
      var gap = page.hasExpiredGap;
      for (final message in next) {
        if (_visibleCount(previous, message.historySequence!) != 1) gap = true;
        previous = message.historySequence!;
      }
      if (next.isEmpty && state.unloadedNewer == 0) {
        state = state.copyWith(newer: const NewerHistoryState());
        return;
      }
      if (gap || next.isEmpty) {
        state = state.copyWith(
          newer: const NewerHistoryState(
            hasExpiredGap: true,
            error: '部分新消息已过期，无法连续补齐；可点击回到最新。',
          ),
        );
        return;
      }
      _window.insertAll(0, next.reversed);
      if (_window.length > historyWindowLimit) {
        _window.removeRange(historyWindowLimit, _window.length);
        _hasMore = true;
        _historyGeneration++;
      }
      _windowCapacity = max(200, _window.length);
      _before = _window.last.historySequence;
      _latestSequence = max(_latestSequence, _window.first.historySequence!);
      state = state.copyWith(
        unloadedNewer: _visibleCount(
          _window.first.historySequence!,
          _latestSequence,
        ),
        readingAnchor: state.readingAnchor ?? after,
        newer: const NewerHistoryState(),
      );
      ref.read(timelineStructureProvider(id).notifier).replace(_window);
      _emitHistory();
    } catch (e) {
      if (!ref.mounted || _retired || generation != _historyGeneration) return;
      state = state.copyWith(
        newer: NewerHistoryState(
          error: e.toString().replaceFirst('Bad state: ', ''),
        ),
      );
    }
  }

  void setMuted(bool muted) {
    if (state.muted == muted) return;
    final engine = ref.read(engineProvider)..setMuted(id, muted);
    state = state.copyWith(muted: muted);
    ref.invalidate(conversationPreferencesProvider(id));
    ref
        .read(conversationListProvider.notifier)
        .refresh(engine.takeChangedConversationIds());
  }

  void togglePinned() {
    final engine = ref.read(engineProvider)..togglePinned(id);
    state = state.copyWith(pinned: engine.conversation(id).pinned);
    ref.invalidate(conversationPreferencesProvider(id));
    ref
        .read(conversationListProvider.notifier)
        .refresh(engine.takeChangedConversationIds());
  }

  void _emitHistory({bool loading = false, String? error}) {
    state = state.copyWith(
      history: HistoryState(
        loading: loading,
        error: error,
        before: _before,
        loaded: _window.length,
        hasMore: _hasMore,
        hasExpiredGap: _hasExpiredGap,
        atWindowLimit: _window.length >= historyWindowLimit,
      ),
    );
  }

  Future<void> loadOlder() async {
    if (!ref.mounted ||
        _retired ||
        state.history.loading ||
        state.newer.loading ||
        !_hasMore ||
        _window.length >= historyWindowLimit) {
      return;
    }
    final limit = min(
      _window.length < initialPageSize
          ? initialPageSize - _window.length
          : historyPageSize,
      historyWindowLimit - _window.length,
    );
    final generation = _historyGeneration;
    final requestedBefore = _before;
    final trimVersion = _liveTrimVersion;
    _emitHistory(loading: true);
    ref.read(historyScenarioProvider.notifier).consumeFailure();
    try {
      final archive = ref.read(historyRepositoryProvider);
      final page = await archive.load(
        id,
        before: requestedBefore,
        limit: limit,
      );
      if (!ref.mounted || generation != _historyGeneration || _retired) {
        return;
      }
      if (trimVersion != _liveTrimVersion) {
        // Live traffic moved the bounded window while this request was in
        // flight. Keep its contiguous cursor; attaching the old page would
        // silently skip the intervening live records.
        _emitHistory();
        return;
      }
      final byId = {for (final m in _window) m.id: m};
      for (final message in page.messages) {
        if (message.conversationId == id &&
            message.historySequence != null &&
            archive.isVisible(id, message.historySequence!) &&
            (requestedBefore == null ||
                message.historySequence! < requestedBefore)) {
          byId.putIfAbsent(message.id, () => message);
        }
      }
      final ordered = byId.values.toList()
        ..sort((a, b) => b.historySequence!.compareTo(a.historySequence!));
      _window
        ..clear()
        ..addAll(ordered.take(historyWindowLimit));
      _windowCapacity = max(200, _window.length);
      if (_window.isNotEmpty) {
        _latestSequence = max(_latestSequence, _window.first.historySequence!);
      }
      _before = _window.isEmpty ? page.before : _window.last.historySequence;
      _hasMore = ordered.length > historyWindowLimit || page.hasMore;
      _hasExpiredGap |= page.hasExpiredGap;
      if (state.frozen && state.readingAnchor == null && _window.isNotEmpty) {
        state = state.copyWith(readingAnchor: _window.first.historySequence);
      }
      // Backfilling history updates only this view, never unread, preview,
      // conversation recency or incoming throughput counters.
      ref.read(timelineStructureProvider(id).notifier).replace(_window);
      _emitHistory();
    } catch (e) {
      if (ref.mounted && generation == _historyGeneration && !_retired) {
        _emitHistory(error: e.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }
}
