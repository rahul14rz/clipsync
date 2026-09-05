import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'ui/main_window.dart';
import 'ui/overlay/overlay_app.dart';
import 'ui/settings_screen.dart';

/// Main window engine.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = await AppState.boot();
  runApp(ClipSyncApp(app: app));
}

/// Second engine hosted in the native floating panel (see OverlayPanel.swift /
/// overlay_window.cpp). Must be kept as an entry point for AOT builds.
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OverlayApp());
}

class ClipSyncApp extends StatelessWidget {
  const ClipSyncApp({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClipSync',
      navigatorKey: app.navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      routes: {
        '/': (_) => MainWindow(app: app),
        '/settings': (_) => SettingsScreen(app: app),
      },
    );
  }
}
