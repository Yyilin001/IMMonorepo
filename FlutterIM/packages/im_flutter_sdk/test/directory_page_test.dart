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
    for (final method in ['open', 'directory', 'close']) {
      final channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.im_flutter_sdk.ImHost.$method',
        wire.ImHost.pigeonChannelCodec,
      );
      messenger.setMockDecodedMessageHandler<Object?>(channel, (args) async {
        if (method != 'directory') return [null];
        final selector = (args as List).single;
        selectors.add(selector);
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
    expect(selectors, [null, false, true]);
    await client.close();
  });
}
