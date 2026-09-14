import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/diagnostics/app_log.dart';
import 'screens/home_screen.dart';
import 'theme/desktop_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    AppLog.e(
      'flutter',
      details.exceptionAsString(),
      details.exception,
      details.stack,
    );
    FlutterError.presentError(details);
  };
  runZonedGuarded(() {
    runApp(const ProviderScope(child: DiagnosticApp()));
  }, (error, stack) {
    AppLog.e('zone', '$error', error, stack);
  });
}

class DiagnosticApp extends StatelessWidget {
  const DiagnosticApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AmL Diagnostic',
      // Local desktop chrome over AmlTheme — tighter radii and rows than the
      // shared phone styling (see lib/theme/desktop_theme.dart).
      theme: diagnosticLightTheme(),
      darkTheme: diagnosticDarkTheme(),
      home: const HomeScreen(),
    );
  }
}
