import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;
import 'package:local_im/ui/workspace.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('contacts and aliases use authorized profile cards', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final profileCalls = <Object?>[];
    final opened = <Object?>[];
    final aliasCalls = <Object?>[];
    final queues = <String, List<Object?>>{};
    for (final method in [
      'open',
      'setForeground',
      'restore',
      'status',
      'connect',
      'openWindow',
      'nextUpdate',
      'directory',
      'profiles',
      'openProfile',
      'saveAlias',
      'clearProfiles',
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
            final id = list[1] == true ? 'archived-window' : 'main-window';
            queues[id] = [
              wire.WindowView(
                conversations: [
                  wire.ImConversation(
                    id: 'room',
                    title: '会话',
                    preview: '正文',
                    unread: 0,
                    isGroup: false,
                    isPinned: false,
                    isArchived: false,
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
          case 'directory':
            opened.add(args);
            return [
              wire.DirectoryPage(
                entries: [
                  wire.DirectoryEntry(
                    id: 'peer',
                    title: 'peer',
                    isGroup: false,
                  ),
                ],
                moreContacts: false,
                moreGroups: false,
              ),
            ];
          case 'profiles':
            profileCalls.add(args);
            return [
              [
                wire.ImProfile(
                  page: 'contacts-ui',
                  userId: 'peer',
                  name: '张三',
                  handle: '@peer',
                  remainingMilliseconds: 60000,
                ),
              ],
            ];
          case 'openProfile':
            opened.add(args);
            return [
              [
                wire.ImProfile(
                  page: 'selected',
                  userId: 'peer',
                  name: '张三',
                  handle: '@peer',
                  alias: '老张',
                  remainingMilliseconds: 60000,
                ),
              ],
            ];
          case 'saveAlias':
            aliasCalls.add(args);
        }
        return [null];
      });
      addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
    }

    await tester.pumpWidget(const MaterialApp(home: SdkWorkspace()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-contacts')));
    await tester.pumpAndSettle();

    expect(find.text('张三'), findsOneWidget);
    expect((profileCalls.single as List)[0], 'contacts-ui');
    expect((profileCalls.single as List)[1], 'relationship');

    await tester.tap(find.text('张三'));
    await tester.pumpAndSettle();
    expect(find.text('老张'), findsWidgets);
    expect(opened.last, ['peer', 'relationship', null]);

    await tester.tap(find.byKey(const Key('contact-alias')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('contact-alias-input')), '新备注');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(aliasCalls.single, ['peer', '新备注', null]);
    expect(find.text('新备注'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
