import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;
import 'package:local_im/ui/workspace.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('conversation rows expose unread, pinned and muted semantics', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final queues = <String, List<Object?>>{};
    for (final method in [
      'open',
      'setForeground',
      'restore',
      'status',
      'connect',
      'openWindow',
      'nextUpdate',
      'avatar',
      'setConversationState',
      'closeWindow',
      'close',
    ]) {
      final channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.im_flutter_sdk.ImHost.$method',
        wire.ImHost.pigeonChannelCodec,
      );
      messenger.setMockDecodedMessageHandler<Object?>(channel, (args) async {
        switch (method) {
          case 'restore':
            return [wire.ImSession(state: 'ready', userId: 'user')];
          case 'status':
            return [wire.ImSession(state: 'connected', userId: 'user')];
          case 'openWindow':
            final list = args as List;
            final archived = list[1] == true;
            final id = archived ? 'archived-window' : 'main-window';
            queues[id] = [
              wire.WindowView(
                conversations: [
                  wire.ImConversation(
                    id: archived ? 'hidden' : 'room',
                    title: archived ? '隐藏会话' : '产品群',
                    preview: '正文',
                    unread: archived ? 0 : 3,
                    isGroup: !archived,
                    isPinned: !archived,
                    isArchived: archived,
                    muteUntil: archived
                        ? null
                        : DateTime.now()
                              .add(const Duration(hours: 1))
                              .millisecondsSinceEpoch,
                    updatedAt: 1000,
                  ),
                ],
                messages: [],
                hasOlder: false,
                isLatest: true,
              ),
            ];
            return [id];
          case 'nextUpdate':
            final id = (args as List).first as String;
            final queue = queues[id];
            if (queue != null && queue.isNotEmpty) return [queue.removeAt(0)];
            return Completer<Object?>().future;
        }
        return [null];
      });
      addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
    }

    final semantics = tester.ensureSemantics();
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(const MaterialApp(home: SdkWorkspace()));
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(RegExp(r'产品群[\s\S]*3 条未读[\s\S]*已置顶[\s\S]*已静音')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
