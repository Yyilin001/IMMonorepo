import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pagination retains the query and its room until search is closed',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <Object?>[];
      for (final method in [
        'open',
        'searchMessages',
        'clearMessageSearch',
        'close',
      ]) {
        final channel = BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.im_flutter_sdk.ImHost.$method',
          wire.ImHost.pigeonChannelCodec,
        );
        messenger.setMockDecodedMessageHandler<Object?>(channel, (args) async {
          if (method == 'searchMessages') {
            calls.add(args);
            final next = (args as List).last == true;
            return [
              wire.SearchPage(
                status: 'ready',
                hits: [
                  wire.SearchHit(
                    id: next ? 'older' : 'newer',
                    roomId: 'room',
                    text: '正文',
                  ),
                ],
                hasNext: !next,
              ),
            ];
          }
          if (method == 'clearMessageSearch') calls.add(method);
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
      final first = await client.searchMessages('room', ' 正文 ');
      expect(first.hits.single, (id: 'newer', roomId: 'room', text: '正文'));
      expect(first.hasNext, true);
      final last = await client.searchMessages('room', '正文', next: true);
      expect(last.hits.single.id, 'older');
      expect(last.hasNext, false);
      await client.searchMessages(null, '正文');
      await client.clearMessageSearch();
      await client.close();
      expect(calls, [
        ['room', '正文', false],
        ['room', '正文', true],
        [null, '正文', false],
        'clearMessageSearch',
      ]);
    },
  );
}
