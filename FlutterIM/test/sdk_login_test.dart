import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/ui/workspace.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('startup and login retry use the iOS device endpoints', (
    tester,
  ) async {
    const open = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.im_flutter_sdk.ImHost.open',
      StandardMessageCodec(),
    );
    final messenger = tester.binding.defaultBinaryMessenger;
    final attempts = <Object?>[];
    messenger.setMockDecodedMessageHandler<Object?>(open, (args) async {
      attempts.add(args);
      return ['networkUnavailable', null, null];
    });
    addTearDown(() => messenger.setMockDecodedMessageHandler(open, null));

    await tester.pumpWidget(const MaterialApp(home: SdkWorkspace()));
    await tester.pumpAndSettle();
    const endpoint = ['https://120.77.66.38', '120.77.66.38', 7443];
    expect(attempts, [endpoint]);
    expect(find.byKey(const Key('main-navigation')), findsOneWidget);
    expect(find.byKey(const Key('open-chat-search')), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-login')));
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsNWidgets(2));

    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pumpAndSettle();
    expect(attempts, [endpoint, endpoint]);
  });
}
