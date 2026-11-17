import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'creation uses resolved member IDs and paging stays in the requested room',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final pages = <Object?>[];
      for (final method in [
        'open',
        'resolveUserId',
        'createGroup',
        'groupMembers',
        'close',
      ]) {
        final channel = BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.im_flutter_sdk.ImHost.$method',
          wire.ImHost.pigeonChannelCodec,
        );
        messenger.setMockDecodedMessageHandler<Object?>(channel, (args) async {
          switch (method) {
            case 'resolveUserId':
              expect(args, ['@friend']);
              return ['user-1'];
            case 'createGroup':
              expect(args, [
                '读书会',
                ['user-1'],
              ]);
            case 'groupMembers':
              pages.add(args);
              final next = (args as List).last == true;
              return [
                wire.GroupPage(
                  announcement: '周六见',
                  members: [
                    wire.GroupMember(
                      userId: next ? 'user-2' : 'user-1',
                      role: next ? 'member' : 'owner',
                    ),
                  ],
                  hasMore: !next,
                ),
              ];
          }
          return [null];
        });
        addTearDown(
          () => messenger.setMockDecodedMessageHandler(channel, null),
        );
      }
      final client = await ImClient.open(
        accountUrl: Uri.parse('https://example.test'),
        gatewayHost: 'example.test',
        gatewayPort: 7443,
      );
      await client.createGroup('读书会', [await client.resolveUserId('@friend')]);
      final first = await client.groupMembers('room');
      expect(first.members, {'user-1': 'owner'});
      expect(first.announcement, '周六见');
      expect(first.hasMore, true);
      final second = await client.groupMembers('room', next: true);
      expect(second.members, {'user-2': 'member'});
      expect(second.hasMore, false);
      expect(pages, [
        ['room', false],
        ['room', true],
      ]);
      await client.close();
    },
  );
}
