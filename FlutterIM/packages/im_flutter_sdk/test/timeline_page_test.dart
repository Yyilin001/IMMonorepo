import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('history and reset update the same observed timeline window', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var update = Completer<Object?>();
    final calls = <Object?>[];
    for (final method in [
      'open',
      'restore',
      'openWindow',
      'nextUpdate',
      'changeWindowPage',
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
            expect(args, ['room']);
            return ['timeline'];
          case 'nextUpdate':
            expect(args, ['timeline']);
            final result = await update.future;
            update = Completer<Object?>();
            return result;
          case 'changeWindowPage':
            calls.add(args);
            final latest = (args as List).last as bool;
            update.complete([
              wire.WindowView(
                conversations: [],
                messages: [],
                hasOlder: latest,
                isLatest: latest,
              ),
            ]);
          case 'closeWindow':
            update.complete(['closed', null, null]);
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
    await client.setForeground(false);
    await client.restoreSession();
    final iterator = StreamIterator(client.watchTimeline('room'));
    var next = iterator.moveNext();
    update.complete([
      wire.WindowView(
        conversations: [],
        messages: [],
        hasOlder: true,
        isLatest: true,
      ),
    ]);
    expect(await next, true);
    expect(iterator.current.hasOlder, true);
    for (final latest in [false, true]) {
      final id = iterator.current.windowId;
      next = iterator.moveNext();
      await client.changeWindowPage(id, latest: latest);
      expect(await next, true);
      expect(iterator.current.isLatest, latest);
    }
    expect(calls, [
      ['timeline', false],
      ['timeline', true],
    ]);
    await iterator.cancel();
    await client.close();
  });
}
