/// appmanager: a small desktop app for managing AppImages. It gives
/// installed AppImages a command-line alias on PATH, finds and installs new
/// ones from AppImageHub or GitHub, keeps them up to date and adds them to
/// the application menu.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/controller.dart';
import 'src/core.dart';
import 'src/ui.dart';
import 'ui/kit.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppController(loadConfig());
  // Files the desktop opens with us while we're running arrive here; the
  // ones that started us are our arguments.
  const MethodChannel('appmanager/open').setMethodCallHandler((call) async {
    if (call.method == 'open' && call.arguments is List) {
      app.openFiles([for (final a in call.arguments as List) '$a']);
    }
  });
  if (args.isNotEmpty) app.openFiles(args);
  app.redoOldMenuEntries();
  runApp(AppManagerApp(app));
}

class AppManagerApp extends StatelessWidget {
  final AppController app;
  const AppManagerApp(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    // Material stays only as the host for text fields and the navigator;
    // everything visible comes from the kit in lib/ui.
    return MaterialApp(
      title: 'AppImage Manager',
      debugShowCheckedModeBanner: false,
      theme: KitTheme.material(KitColors.light),
      darkTheme: KitTheme.material(KitColors.dark),
      builder: (context, child) {
        final colors = MediaQuery.platformBrightnessOf(context) == Brightness.dark
            ? KitColors.dark
            : KitColors.light;
        return KitTheme(
          colors: colors,
          child: Material(
            color: colors.background,
            child: DefaultTextStyle(
              style: TextStyle(color: colors.text, fontSize: 14, height: 1.3),
              child: child!,
            ),
          ),
        );
      },
      home: HomePage(app),
    );
  }
}
