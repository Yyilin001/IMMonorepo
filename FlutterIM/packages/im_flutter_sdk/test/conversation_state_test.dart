import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('conversation state and archived list flow through the bridge', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final opened = <Object?>[];
    final stateCalls = <Object?>[];
    for (final method in [
      'open',
      'restore',
      'openWindow',
      'nextUpdate',
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
          case 'openWindow':
            final list = args as List;
            opened.add(args);
            return [list[1] == true ? 'archived-window' : 'main-window'];
          case 'nextUpdate':
            return [
              wire.WindowView(
                conversations: [
                  wire.ImConversation(
                    id: 'room',
                    title: '会话',
                    preview: '正文',
                    unread: 2,
                    isGroup: false,
                    isPinned: true,
                    isArchived: (args as List)[0] == 'archived-window',
                    updatedAt: 1000,
                    peerId: 'peer',
                    muteUntil: 9000,
                  ),
                ],
                messages: [],
                hasOlder: false,
                isLatest: true,
              ),
            ];
          case 'setConversationState':
            stateCalls.add(args);
        }
        return [null];
      });
      addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
    }
    final client = await ImClient.open(
      accountUrl: Uri.parse('https://example.test'),
      gatewayHost: 'example.test',
      gatewayPort: 7443,
    );
    await client.restoreSession();

    final main = await client.watchConversations().first;
    expect(main.single.isPinned, true);
    expect(main.single.isArchived, false);
    expect(main.single.muteUntil, 9000);
    expect(main.single.peerId, 'peer');

    final archived = await client.watchConversations(archived: true).first;
    expect(archived.single.isArchived, true);
    expect(opened, [
      [null, false],
      [null, true],
    ]);

    await client.setConversationState(
      'room',
      isPinned: true,
      muteUntil: 123000,
    );
    await client.setConversationState('room', isArchived: false);
    expect(stateCalls, [
      ['room', true, null, 123000],
      ['room', null, false, null],
    ]);
    await client.close();
  });
}
