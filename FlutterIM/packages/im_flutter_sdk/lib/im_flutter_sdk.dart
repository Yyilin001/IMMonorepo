import 'dart:async';

import 'package:flutter/services.dart';

import 'src/messages.g.dart' as wire;

enum ImSessionState {
  signedOut,
  signingOut,
  ready,
  connecting,
  connected,
  offline,
  closed,
}

enum ImSendStatus {
  preparing,
  pending,
  waitingForNetwork,
  waitingForAuthentication,
  acceptedAwaitingProjection,
  confirmingOutcome,
  needsAttention,
  expiredUnsubmitted,
  closed,
  rejected,
  unknown,
}

typedef ImSession = ({ImSessionState state, String? userId});
typedef ImConversation = ({
  String id,
  String title,
  String preview,
  int unread,
  bool isGroup,
  int? updatedAt,
  String? peerId,
});
typedef ImDirectoryEntry = ({String id, String title, bool isGroup});
typedef ImMessage = ({
  String id,
  String senderId,
  String text,
  bool withdrawn,
  bool hasMedia,
  bool readByPeer,
  bool isForwarded,
  String? replyPreview,
  ImSendStatus? pendingStatus,
  int? createdAt,
});

extension on wire.ImSession {
  ImSession get value =>
      (state: ImSessionState.values.byName(state), userId: userId);
}

extension on wire.ImMessage {
  ImMessage get value => (
    id: id,
    senderId: senderId,
    text: text,
    withdrawn: withdrawn,
    hasMedia: hasMedia,
    readByPeer: readByPeer,
    isForwarded: isForwarded,
    replyPreview: replyPreview,
    createdAt: createdAt,
    pendingStatus: pendingStatus == null
        ? null
        : ImSendStatus.values.firstWhere(
            (status) => status.name == pendingStatus,
            orElse: () => ImSendStatus.unknown,
          ),
  );
}

/// One standalone mobile host owns one client per Flutter engine.
final class ImClient {
  ImClient._();
  final _host = wire.ImHost();
  final _sessions = StreamController<ImSession>.broadcast();
  final _windows = <Future<void> Function()>{};
  Future<void> _tail = Future.value();
  Timer? _timer;
  bool _foreground = true;
  bool _closed = false;
  bool _signingOut = false;
  ImSession _session = (state: ImSessionState.signedOut, userId: null);
  ImSession get session => _session;
  Stream<ImSession> get sessions => _sessions.stream;

  static Future<ImClient> open({
    required Uri accountUrl,
    required String gatewayHost,
    required int gatewayPort,
  }) async {
    if (accountUrl.scheme != 'https' ||
        accountUrl.host.isEmpty ||
        accountUrl.userInfo.isNotEmpty ||
        accountUrl.hasQuery ||
        accountUrl.hasFragment ||
        !{'', '/'}.contains(accountUrl.path) ||
        gatewayHost.trim().isEmpty ||
        gatewayPort < 1 ||
        gatewayPort > 65535) {
      throw ArgumentError('Invalid IM endpoint');
    }
    final client = ImClient._();
    await client._host.open(accountUrl.origin, gatewayHost, gatewayPort);
    return client;
  }

  // A failed action must not prevent a later sign-out or close.
  Future<T> _ordered<T>(Future<T> Function() operation) {
    if (_closed) return Future.error(StateError('IM client closed'));
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _publish(ImSession value) {
    if (_session.state == value.state && _session.userId == value.userId) {
      return;
    }
    _session = value;
    _sessions.add(value);
  }

  Future<void> restoreSession() => _ordered(() async {
    _publish((await _host.restore()).value);
    _schedule(Duration.zero);
  });
  Future<void> signIn(String account, String password) => _ordered(() async {
    _publish((await _host.signIn(account, password)).value);
    _schedule(Duration.zero);
  });

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (!_foreground || _closed || _session.userId == null) return;
    _timer = Timer(delay, () async {
      if (_closed) return;
      await _ordered(() async {
        if (!_foreground || _session.userId == null) return;
        var retry = const Duration(seconds: 2);
        try {
          var value = await _host.status();
          if (value.userId != null && value.state != 'connected') {
            value = await _host.connect();
          }
          _publish(value.value);
        } on PlatformException catch (e) {
          if (e.code == 'authenticationRequired') {
            // Consult durable session ownership before presenting a sign-in screen.
            _publish((await _host.status()).value);
          } else {
            _publish((state: ImSessionState.offline, userId: _session.userId));
          }
          retry = const Duration(seconds: 4);
        } finally {
          _schedule(retry);
        }
      }).catchError((Object error, StackTrace stack) {
        if (!_closed) _sessions.addError(error, stack);
      });
    });
  }

  Future<void> setForeground(bool active) => _ordered(() async {
    _foreground = active;
    _timer?.cancel();
    if (!active && _session.userId != null) {
      await _host.disconnect();
      _publish((await _host.status()).value);
    } else {
      _schedule(Duration.zero);
    }
  });

  Stream<List<ImConversation>> watchConversations() => _watch(
    null,
    (value) => value.conversations.map(
      (c) => (
        id: c.id,
        title: c.title,
        preview: c.preview,
        unread: c.unread,
        isGroup: c.isGroup,
        updatedAt: c.updatedAt,
        peerId: c.peerId,
      ),
    ),
  );
  Future<List<ImDirectoryEntry>> directory() => _ordered(
    () async => (await _host.directory())
        .map((item) => (id: item.id, title: item.title, isGroup: item.isGroup))
        .toList(growable: false),
  );

  Stream<List<ImMessage>> watchMessages(String roomId) =>
      _watch(roomId, (value) => value.messages.map((m) => m.value));

  Stream<List<T>> _watch<T>(
    String? room,
    Iterable<T> Function(wire.WindowView) select,
  ) {
    late final StreamController<List<T>> stream;
    Future<String>? opening;
    Future<void>? stopping;
    var stopped = false;
    late Future<void> Function() stop;
    Future<void> read() async {
      try {
        final id = await (opening = _host.openWindow(room));
        while (!stopped) {
          final view = await _host.nextUpdate(id);
          if (!stopped) stream.add(List.unmodifiable(select(view)));
        }
      } catch (error, stack) {
        if (!stopped) stream.addError(error, stack);
      } finally {
        await stop();
      }
    }

    Future<void> startRelease() async {
      stopped = true;
      try {
        final pending = opening;
        if (pending != null) {
          String id;
          try {
            id = await pending;
          } catch (_) {
            return;
          }
          try {
            await _host.closeWindow(id);
          } on PlatformException catch (e) {
            if (e.code != 'closed' && e.code != 'authenticationRequired') {
              rethrow;
            }
          }
        }
      } finally {
        _windows.remove(stop);
        unawaited(stream.close());
      }
    }

    stop = () => stopping ??= startRelease();
    stream = StreamController<List<T>>(
      onListen: () {
        if (_closed || _signingOut || _session.userId == null) {
          stream.addError(StateError('No active IM session'));
          unawaited(stream.close());
          return;
        }
        _windows.add(stop);
        unawaited(read());
      },
      onCancel: stop,
    );
    return stream.stream;
  }

  Future<void> sendText(
    String roomId,
    String text, {
    String? replyToMessageId,
  }) => _ordered(() => _host.sendText(roomId, text, replyToMessageId));
  Future<void> _stopWindows() async {
    await Future.wait(_windows.toList().map((stop) => stop()));
  }

  Future<void> signOut() => _ordered(() async {
    _timer?.cancel();
    _signingOut = true;
    try {
      try {
        await _stopWindows();
      } finally {
        await _host.signOut();
        _publish((state: ImSessionState.signedOut, userId: null));
      }
    } finally {
      _signingOut = false;
      _schedule(Duration.zero);
    }
  });
  Future<void>? _closing;
  Future<void> close() =>
      _closing ??= _close().onError((Object error, StackTrace stack) {
        _closing = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<void> _close() async {
    _closed = true;
    _timer?.cancel();
    await _tail;
    try {
      await _stopWindows();
    } finally {
      await _host.close();
      await _sessions.close();
    }
  }
}
