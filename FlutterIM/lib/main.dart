import 'dart:io';

import 'package:flutter/widgets.dart';

import 'mock_main.dart' as demo;
import 'ui/workspace.dart';
import 'state/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid || Platform.isIOS) {
    final settings = await SettingsPersistence.load();
    runApp(demo.LocalImApp(home: SdkWorkspace(settings: settings)));
  } else {
    await demo.main();
  }
}
