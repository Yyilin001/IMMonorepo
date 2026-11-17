import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('directory restart and independent group and friend cursors', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final selectors = <Object?>[];
    final actions = <Object?>[];
    for (final method in [
      'open',
      'directory',
      'requestContact',
      'socialAction',
      'close',
    ]) {
      final channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.im_flutter_sdk.ImHost.$method',
        wire.ImHost.pigeonChannelCodec,
      );
      messenger.setMockDecodedMessageHandler<Object?>(channel, (args) async {
        if (method != 'directory') {
          if (method == 'requestContact' || method == 'socialAction') {
            actions.add([method, args]);
          }
          return [null];
        }
        final selector = (args as List).first;
        selectors.add([selector, args.last]);
        return [
          wire.DirectoryPage(
            entries: [
              wire.DirectoryEntry(id: '42', title: '朋友', isGroup: false),
            ],
            moreContacts: selector != false,
            moreGroups: selector != true,
          ),
        ];
      });
      addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
    }
    final client = await ImClient.open(
      accountUrl: Uri.parse('https://example.test'),
      gatewayHost: 'example.test',
      gatewayPort: 7443,
    );
    expect((await client.directory()).single.title, '朋友');
    expect((await client.directoryPage(nextGroups: false)).moreContacts, false);
    expect((await client.directoryPage(nextGroups: true)).moreGroups, false);
    await client.directoryPage(scope: ImContactScope.incoming);
    expect(selectors, [
      [null, 'accepted'],
      [false, 'accepted'],
      [true, 'accepted'],
      [null, 'incoming'],
    ]);
    await client.requestContact('handle');
    await client.socialAction('42', ImSocialAction.accept);
    expect(actions, [
      [
        'requestContact',
        ['handle'],
      ],
      [
        'socialAction',
        ['42', 'accept'],
      ],
    ]);
    await client.close();
  });
}
