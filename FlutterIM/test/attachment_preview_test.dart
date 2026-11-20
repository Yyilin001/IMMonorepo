import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/ui/workspace.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'preview expires and ignores a load completed after backgrounding',
    (tester) async {
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jmS8AAAAASUVORK5CYII=',
      );
      final preview = (
        bytes: bytes,
        remaining: const Duration(milliseconds: 300),
      );
      var pending = Completer<({Uint8List bytes, Duration remaining})>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentImagePreview(
              name: '照片',
              load: () => pending.future,
            ),
          ),
        ),
      );
      await tester.tap(find.text('查看图片'));
      pending.complete(preview);
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 301));
      expect(find.byType(Image), findsNothing);
      pending = Completer();
      await tester.tap(find.text('查看图片'));
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.inactive,
      );
      pending.complete(preview);
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
    },
  );
}
