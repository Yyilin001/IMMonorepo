import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;
import 'package:local_im/ui/workspace.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('long press pins the live conversation and opens hidden chats', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final states = <Object?>[];
    final opened = <Object?>[];
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
            opened.add(args);
            final archived = list[1] == true;
            final id = archived ? 'archived-window' : 'main-window';
            queues[id] = [
              wire.WindowView(
                conversations: [
                  wire.ImConversation(
                    id: archived ? 'hidden' : 'room',
                    title: archived ? '隐藏会话' : '会话',
                    preview: '正文',
                    unread: 0,
                    isGroup: false,
                    isPinned: false,
                    isArchived: archived,
                    updatedAt: 1000,
                    peerId: 'peer',
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
          case 'setConversationState':
            states.add(args);
        }
        return [null];
      });
      addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
    }

    await tester.pumpWidget(const MaterialApp(home: SdkWorkspace()));
    await tester.pumpAndSettle();
    expect(find.text('会话'), findsOneWidget);

    await tester.longPress(find.text('会话'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('sdk-conversation-action-sheet')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('sdk-conversation-menu-pin')));
    await tester.pumpAndSettle();
    expect(states, [
      ['room', true, null, null],
    ]);

    await tester.tap(find.byKey(const Key('open-archived-conversations')));
    await tester.pumpAndSettle();
    expect(find.text('隐藏的聊天'), findsOneWidget);
    expect(find.text('隐藏会话'), findsOneWidget);
    expect(opened, [
      [null, false],
      [null, true],
    ]);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
