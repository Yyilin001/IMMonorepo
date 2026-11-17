import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registration forwards the public identity and publishes the session', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <Object?>[];
    final lifecycle = <Object?>[];
    final devices = <Object?>[];
    for (final method in ['open', 'register', 'passwordLifecycle', 'deviceSessions', 'revokeDevice', 'privacy', 'setPrivacy', 'favorites', 'setFavorite', 'close']) {
      final channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.im_flutter_sdk.ImHost.$method',
        wire.ImHost.pigeonChannelCodec,
      );
      messenger.setMockDecodedMessageHandler<Object?>(channel, (args) async {
        switch (method) {
          case 'register':
            calls.add(args);
            return [wire.ImSession(state: 'ready', userId: 'user')];
          case 'passwordLifecycle':
            lifecycle.add(args);
          case 'favorites':
            return [
              wire.ImFavorites(
                messages: [
                  wire.ImFavoriteMessage(
                    id: 'message',
                    roomId: 'room',
                    roomTitle: '会话',
                    senderId: 'peer',
                    text: '收藏内容',
                    attachmentNames: ['a.txt'],
                  ),
                ],
                hasMore: true,
              ),
            ];
          case 'setFavorite':
            devices.add(args);
          case 'privacy':
          case 'setPrivacy':
            devices.add(args as List<Object?>? ?? const []);
            return [
              wire.ImPrivacy(
                allowsStrangerMessages: false,
                allowsUserAdd: true,
                allowsDirectReadReceipts: true,
                allowsGroupReadReceipts: false,
                allowsOnlinePresence: true,
                allowsTypingIndicators: false,
                blockedUsers: ['peer'],
              ),
            ];
          case 'revokeDevice':
            devices.add(args as List<Object?>? ?? const []);
          case 'deviceSessions':
            devices.add(args as List<Object?>? ?? const []);
            return [
              wire.ImDeviceSessions(
                sessions: [
                  wire.ImDeviceSession(
                    deviceId: 'device',
                    deviceName: 'iPhone',
                    platform: 'iOS',
                    createdAt: 1000,
                    lastActiveAt: 2000,
                    isCurrentDevice: true,
                  ),
                ],
                nextCursor: 'next',
              ),
            ];
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
    await client.register('alice', 'a-long-password', '@alice', 'Alice');
    expect(calls.single, ['alice', 'a-long-password', '@alice', 'Alice']);
    expect(client.session.userId, 'user');
    await client.passwordLifecycle(
      account: 'alice',
      action: 'change',
      currentPassword: 'old-password',
      newPassword: 'new-password',
    );
    expect(lifecycle.single, [
      'alice',
      'change',
      'old-password',
      'new-password',
      null,
    ]);
    final page = await client.deviceSessions();
    expect(page.sessions.single.deviceName, 'iPhone');
    expect(page.sessions.single.isCurrentDevice, true);
    expect(page.nextCursor, 'next');
    expect(devices.first, [null]);
    await client.revokeDevice(deviceId: 'device');
    expect(devices.last, ['device', false]);
    await client.revokeDevice(all: true);
    expect(devices.last, [null, true]);

    final privacy = await client.privacy();
    expect(privacy?.allowsStrangerMessages, false);
    expect(privacy?.blockedUsers, ['peer']);
    expect(devices.last, isEmpty);
    final updated = await client.setPrivacy('readReceipt', flag1: true, flag2: false);
    expect(updated?.allowsGroupReadReceipts, false);
    expect(devices.last, ['readReceipt', true, false]);

    final favorites = await client.favorites();
    expect(favorites.messages.single.text, '收藏内容');
    expect(favorites.hasMore, true);
    await client.setFavorite('room', 'message', favorited: true);
    expect(devices.last, ['room', 'message', true]);
    await client.close();
  });
}
