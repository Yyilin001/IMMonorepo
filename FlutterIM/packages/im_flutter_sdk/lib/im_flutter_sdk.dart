import 'dart:async';

import 'package:flutter/services.dart';

import 'src/messages.g.dart' as wire;

enum ImMembershipAction { add, remove, role, transfer, leave, dissolve }

enum ImContactScope { accepted, incoming, outgoing, blocked }

enum ImSocialAction { accept, reject, remove, block, unblock }

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
  preparationWaiting,
  preparationPaused,
  preparationUserPaused,
  preparationExpired,
  preparationRejected,
  preparationProcessing,
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

typedef ImReaders = ({
  String roomId,
  String messageId,
  List<String> users,
  bool hasNext,
  int remainingMilliseconds,
});
typedef ImSearchHit = ({String id, String roomId, String text});
typedef ImSearchPage = ({String status, List<ImSearchHit> hits, bool hasNext});

typedef ImTimelinePage = ({
  String windowId,
  List<ImMessage> messages,
  bool hasOlder,
  bool isLatest,
});

typedef ImSession = ({ImSessionState state, String? userId});
typedef ImConversation = ({
  String id,
  String title,
  String preview,
  int unread,
  bool isGroup,
  bool isPinned,
  bool isArchived,
  int? updatedAt,
  String? peerId,
  int? muteUntil,
});
typedef ImDirectoryEntry = ({String id, String title, bool isGroup});
typedef ImGroupNickname = ({String roomId, String? name, int? revision});
typedef ImInvite = ({
  String id,
  String url,
  int expires,
  int used,
  int maximum,
});
typedef ImJoinRequest = ({
  String id,
  String userId,
  String note,
  String state,
});
typedef ImInvitePreview = ({
  String roomId,
  String title,
  String? requestId,
  String? state,
  bool member,
  bool canSubmit,
  bool canCancel,
});
typedef ImCommunity = ({
  String? roomId,
  List<ImInvite> invites,
  List<ImJoinRequest> requests,
  bool hasMore,
  ImInvitePreview? preview,
  String? failure,
});
typedef ImProfile = ({
  String page,
  String userId,
  String name,
  String handle,
  String? alias,
  int? aliasRevision,
  String? groupNickname,
  int? groupNicknameRevision,
  int remainingMilliseconds,
  Uint8List? avatar,
});
typedef ImAvatarEditor = ({
  String? roomId,
  int revision,
  bool canManage,
  int remainingMilliseconds,
  bool hasAvatar,
  String? name,
  String? handle,
  Uint8List? image,
});
typedef ImTransfer = ({
  String id,
  String name,
  String kind,
  String phase,
  int? total,
  int? confirmed,
  List<String> actions,
});

typedef ImAttachment = ({
  String id,
  String name,
  String contentType,
  int bytes,
});
typedef ImMessage = ({
  String id,
  String senderId,
  String text,
  bool withdrawn,
  bool hasMedia,
  List<ImAttachment> attachments,
  bool readByPeer,
  int? revision,
  int? mutableRevision,
  bool isForwarded,
  String? replyPreview,
  String? replyToId,
  ImSendStatus? pendingStatus,
  int? createdAt,
  int? preparedAttachments,
  int? totalAttachments,
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
    attachments: List<ImAttachment>.unmodifiable(
      attachments.map(
        (a) => (
          id: a.id,
          name: a.name,
          contentType: a.contentType,
          bytes: a.bytes,
        ),
      ),
    ),
    readByPeer: readByPeer,
    revision: revision,
    mutableRevision: mutableRevision,
    isForwarded: isForwarded,
    replyPreview: replyPreview,
    replyToId: replyToId,
    createdAt: createdAt,
    preparedAttachments: preparedAttachments,
    totalAttachments: totalAttachments,
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

  Stream<List<ImConversation>> watchConversations({bool archived = false}) =>
      _watch(
        null,
        (_, value) => List<ImConversation>.unmodifiable(
          value.conversations.map(
            (c) => (
              id: c.id,
              title: c.title,
              preview: c.preview,
              unread: c.unread,
              isGroup: c.isGroup,
              isPinned: c.isPinned,
              isArchived: c.isArchived,
              updatedAt: c.updatedAt,
              peerId: c.peerId,
              muteUntil: c.muteUntil,
            ),
          ),
        ),
        archived: archived,
      );

  /// 更新会话置顶、归档（隐藏聊天）和免打扰截止时间；空值表示保留当前字段。
  Future<void> setConversationState(
    String roomId, {
    bool? isPinned,
    bool? isArchived,
    int? muteUntil,
  }) => _ordered(
    () => _host.setConversationState(roomId, isPinned, isArchived, muteUntil),
  );
  Future<List<ImDirectoryEntry>> directory() async =>
      (await directoryPage()).entries;

  /// A null selector restarts both lists. Otherwise advance only the selected list.
  Future<({List<ImDirectoryEntry> entries, bool moreContacts, bool moreGroups})>
  directoryPage({
    bool? nextGroups,
    ImContactScope scope = ImContactScope.accepted,
  }) => _ordered(() async {
    final page = await _host.directory(nextGroups, scope.name);
    return (
      entries: page.entries
          .map(
            (item) => (id: item.id, title: item.title, isGroup: item.isGroup),
          )
          .toList(growable: false),
      moreContacts: page.moreContacts,
      moreGroups: page.moreGroups,
    );
  });

  Future<({Uint8List bytes, Duration remaining})?> avatar(
    String userId, {
    String context = 'relationship',
    String? roomId,
  }) async {
    final value = await _host.avatar('avatar', userId, context, roomId);
    if (value == null) return null;
    return (
      bytes: value.bytes,
      remaining: Duration(milliseconds: value.remainingMilliseconds),
    );
  }

  Future<ImAvatarEditor?> openAvatarEditor({String? roomId}) =>
      _ordered(() async {
        final value = await _host.openAvatarEditor(roomId);
        return value == null
            ? null
            : (
                roomId: value.roomId,
                revision: value.revision,
                canManage: value.canManage,
                remainingMilliseconds: value.remainingMilliseconds,
                hasAvatar: value.hasAvatar,
                name: value.name,
                handle: value.handle,
                image: value.image,
              );
      });

  Future<void> changeAvatar({
    String? roomId,
    required int revision,
    Uint8List? jpeg,
    int? width,
    int? height,
    String? displayName,
    String? action,
  }) => _ordered(
    () => _host.changeAvatar(
      roomId,
      revision,
      jpeg,
      width,
      height,
      displayName,
      action,
    ),
  );

  Future<List<ImProfile>> profiles({
    required String page,
    required String context,
    String? roomId,
    required List<String> userIds,
  }) => _ordered(() async {
    final rows = await _host.profiles(page, context, roomId, userIds);
    return rows.map(_profile).toList(growable: false);
  });

  Future<List<ImProfile>> openProfile(
    String userId, {
    String context = 'relationship',
    String? roomId,
  }) => _ordered(() async {
    final rows = await _host.openProfile(userId, context, roomId);
    return rows.map(_profile).toList(growable: false);
  });

  Future<void> saveAlias(
    String userId, {
    String? alias,
    int? revision,
  }) => _ordered(() => _host.saveAlias(userId, alias, revision));

  Future<void> clearProfiles(String page) =>
      _ordered(() => _host.clearProfiles(page));

  Future<String> resolveUserId(String handle) =>
      _ordered(() => _host.resolveUserId(handle));
  Future<void> changeMembership(
    String roomId,
    int revision,
    ImMembershipAction action, {
    String? target,
    String? role,
  }) => _ordered(
    () => _host.changeMembership(roomId, revision, action.name, target, role),
  );

  Future<ImGroupNickname?> groupNickname(String roomId) =>
      _ordered(() async {
        final value = await _host.groupNickname(roomId);
        return value == null
            ? null
            : (
                roomId: value.roomId,
                name: value.name,
                revision: value.revision,
              );
      });
  Future<void> saveGroupNickname(
    String roomId,
    String? name, {
    int? revision,
  }) => _ordered(() => _host.saveGroupNickname(roomId, name, revision));
  Future<void> updateGroupPermissions(
    String roomId,
    int revision,
    String role,
    Set<String> permissions,
  ) => _ordered(
    () => _host.updateGroupPermissions(
      roomId,
      revision,
      role,
      permissions.toList(growable: false),
    ),
  );
  Future<void> moderateMemberRemoval(
    String roomId,
    String userId,
    int revision,
  ) => _ordered(
    () => _host.moderateMemberRemoval(roomId, userId, revision),
  );
  Future<void> updateAnnouncement(String roomId, int revision, String text) =>
      _ordered(() => _host.updateAnnouncement(roomId, revision, text));

  Future<
    ({
      String announcement,
      int? editableAnnouncementRevision,
      int membershipRevision,
      String actorRole,
      Set<String> permissions,
      Map<String, String> members,
      List<({String role, Set<String> permissions, int revision})> policies,
      bool policiesReady,
      bool hasMore,
    })
  >
  groupMembers(String roomId, {bool next = false}) => _ordered(() async {
    final page = await _host.groupMembers(roomId, next);
    return (
      announcement: page.announcement,
      editableAnnouncementRevision: page.editableAnnouncementRevision,
      membershipRevision: page.membershipRevision,
      actorRole: page.actorRole,
      permissions: page.permissions.toSet(),
      members: {for (final member in page.members) member.userId: member.role},
      policies: [
        for (final policy in page.policies)
          (
            role: policy.role,
            permissions: policy.permissions.toSet(),
            revision: policy.revision,
          ),
      ],
      policiesReady: page.policiesReady,
      hasMore: page.hasMore,
    );
  });
  Future<ImCommunity> invitations(String roomId) =>
      _ordered(() async => _community(await _host.invitations(roomId)));
  Future<ImCommunity> nextInvitations(String roomId) =>
      _ordered(() async => _community(await _host.nextInvitations(roomId)));
  Future<ImCommunity> previewInvite(String text) =>
      _ordered(() async => _community(await _host.previewInvite(text.trim())));
  Future<ImCommunity> refreshInvite() =>
      _ordered(() async => _community(await _host.refreshInvite()));
  Future<void> inviteAction(
    String roomId,
    int revision,
    String action, {
    String? intentId,
    String? note,
  }) => _ordered(
    () => _host.inviteAction(roomId, revision, action, intentId, note),
  );
  Future<void> submitJoin(String note) =>
      _ordered(() => _host.submitJoin(note));
  Future<void> cancelJoin(String roomId) =>
      _ordered(() => _host.cancelJoin(roomId));
  Future<void> muteMember(String roomId, String userId, int revision) =>
      _ordered(() => _host.muteMember(roomId, userId, revision));

  ImCommunity _community(wire.ImCommunity value) => (
    roomId: value.roomId,
    invites: value.invites
        .map(
          (invite) => (
            id: invite.id,
            url: invite.url,
            expires: invite.expires,
            used: invite.used,
            maximum: invite.maximum,
          ),
        )
        .toList(growable: false),
    requests: value.requests
        .map(
          (request) => (
            id: request.id,
            userId: request.userId,
            note: request.note,
            state: request.state,
          ),
        )
        .toList(growable: false),
    hasMore: value.hasMore,
    preview: value.preview == null
        ? null
        : (
            roomId: value.preview!.roomId,
            title: value.preview!.title,
            requestId: value.preview!.requestId,
            state: value.preview!.state,
            member: value.preview!.member,
            canSubmit: value.preview!.canSubmit,
            canCancel: value.preview!.canCancel,
          ),
    failure: value.failure,
  );

  Future<void> createGroup(String title, List<String> members) =>
      _ordered(() => _host.createGroup(title, members));

  Future<void> requestContact(String handle) =>
      _ordered(() => _host.requestContact(handle));

  Future<void> socialAction(String userId, ImSocialAction action) =>
      _ordered(() => _host.socialAction(userId, action.name));

  Stream<List<ImMessage>> watchMessages(String roomId) =>
      watchTimeline(roomId).map((page) => page.messages);

  Stream<ImTimelinePage> watchTimeline(String roomId) => _watch(
    roomId,
    (id, view) => (
      windowId: id,
      messages: List<ImMessage>.unmodifiable(view.messages.map((m) => m.value)),
      hasOlder: view.hasOlder,
      isLatest: view.isLatest,
    ),
  );

  Future<void> changeWindowPage(String windowId, {required bool latest}) =>
      _ordered(() => _host.changeWindowPage(windowId, latest));

  Stream<T> _watch<T>(
    String? room,
    T Function(String, wire.WindowView) select, {
    bool archived = false,
  }) {
    late final StreamController<T> stream;
    Future<String>? opening;
    Future<void>? stopping;
    var stopped = false;
    late Future<void> Function() stop;
    Future<void> read() async {
      try {
        final id = await (opening = _host.openWindow(room, archived));
        while (!stopped) {
          final view = await _host.nextUpdate(id);
          if (!stopped) stream.add(select(id, view));
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
    stream = StreamController<T>(
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

  Future<void> sendAttachment(
    String roomId, {
    required String path,
    required String name,
    required String contentType,
    String text = '',
  }) => _ordered(
    () => _host.sendAttachment(roomId, path, name, contentType, text),
  );

  Future<List<ImTransfer>> transfers() => _ordered(
    () async => (await _host.transfers())
        .map(
          (row) => (
            id: row.id,
            name: row.name,
            kind: row.kind,
            phase: row.phase,
            total: row.total,
            confirmed: row.confirmed,
            actions: List<String>.unmodifiable(row.actions),
          ),
        )
        .toList(growable: false),
  );
  Future<void> transferAction(String id, String action) =>
      _ordered(() => _host.transferAction(id, action));

  Future<({Uint8List bytes, Duration remaining})> previewAttachment(
    String roomId,
    String messageId,
    String mediaId,
  ) => _ordered(() async {
    final elapsed = Stopwatch()..start();
    final view = await _host.previewAttachment(roomId, messageId, mediaId);
    final remaining =
        Duration(milliseconds: view.remainingMilliseconds) - elapsed.elapsed;
    if (remaining <= Duration.zero || view.bytes.isEmpty) {
      throw PlatformException(code: 'previewUnavailable');
    }
    return (bytes: view.bytes, remaining: remaining);
  });

  Future<void> exportAttachment(
    String roomId,
    String messageId,
    String mediaId,
    String destination,
  ) => _ordered(
    () => _host.exportAttachment(roomId, messageId, mediaId, destination),
  );

  Future<void> downloadAttachment(
    String roomId,
    String messageId,
    String mediaId,
  ) => _ordered(() => _host.downloadAttachment(roomId, messageId, mediaId));

  Future<void> forwardMessage(
    String roomId,
    String messageId,
    int revision,
    String targetRoomId,
  ) => forwardMessageToRooms(roomId, messageId, revision, [targetRoomId]);

  Future<void> forwardMessageToRooms(
    String roomId,
    String messageId,
    int revision,
    List<String> targetRoomIds,
  ) {
    final targets = List<String>.unmodifiable(targetRoomIds);
    return _ordered(
      () => _host.forwardMessage(roomId, messageId, revision, targets),
    );
  }

  Future<void> editMessage(
    String roomId,
    String messageId,
    int revision,
    String text,
  ) => _ordered(() => _host.editMessage(roomId, messageId, revision, text));
  Future<void> withdrawMessage(String roomId, String messageId, int revision) =>
      _ordered(() => _host.withdrawMessage(roomId, messageId, revision));

  Future<void> cancelPendingSend(String intentId) =>
      _ordered(() => _host.cancelPendingSend(intentId));

  Future<List<ImMessage>> locateMessage(String roomId, String messageId) =>
      _ordered(() async {
        final view = await _host.locateMessage(roomId, messageId);
        return view.messages
            .map((message) => message.value)
            .toList(growable: false);
      });

  Future<ImSearchPage> searchMessages(
    String? roomId,
    String query, {
    bool next = false,
  }) => _ordered(() async {
    final page = await _host.searchMessages(roomId, query.trim(), next);
    return (
      status: page.status,
      hits: page.hits
          .map((hit) => (id: hit.id, roomId: hit.roomId, text: hit.text))
          .toList(growable: false),
      hasNext: page.hasNext,
    );
  });
  Future<void> clearMessageSearch() => _ordered(_host.clearMessageSearch);
  Future<ImReaders> messageReaders(
    String roomId,
    String messageId, {
    bool next = false,
  }) => _ordered(() async {
    final value = await _host.messageReaders(roomId, messageId, next);
    return (
      roomId: value.roomId,
      messageId: value.messageId,
      users: List<String>.unmodifiable(value.users),
      hasNext: value.hasNext,
      remainingMilliseconds: value.remainingMilliseconds,
    );
  });

  Future<void> recoverSend(String intentId, {required bool resend}) =>
      _ordered(() => _host.recoverSend(intentId, resend));

  Future<void> sendText(
    String roomId,
    String text, {
    String? replyToMessageId,
  }) => _ordered(() => _host.sendText(roomId, text, replyToMessageId));
  ImProfile _profile(wire.ImProfile value) => (
    page: value.page,
    userId: value.userId,
    name: value.name,
    handle: value.handle,
    alias: value.alias,
    aliasRevision: value.aliasRevision,
    groupNickname: value.groupNickname,
    groupNicknameRevision: value.groupNicknameRevision,
    remainingMilliseconds: value.remainingMilliseconds,
    avatar: value.avatar,
  );

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
