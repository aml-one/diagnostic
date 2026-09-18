import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'core/diagnostics/app_log.dart';
import 'core/mobile/phone_diagnostic.dart';
import 'screens/android/android_home_screen.dart';
import 'screens/home_screen.dart';
import 'theme/desktop_theme.dart';
import 'widgets/desktop_title_bar.dart';

Future<void> main() async {
  // WidgetsFlutterBinding.ensureInitialized() and runApp() must share a zone.
  await runZonedGuarded(() async {
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

    if (kDesktopCustomTitleBar) {
      await windowManager.ensureInitialized();
      const options = WindowOptions(
        size: Size(1100, 720),
        minimumSize: Size(840, 560),
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.hidden,
        title: 'AOW Diagnostic tool for Android',
      );
      await windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: Platform.isMacOS,
        );
        await windowManager.show();
        await windowManager.focus();
      });
    }

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
      title: 'AOW Diagnostic tool for Android',
      navigatorKey: diagnosticNavigatorKey,
      navigatorObservers: [diagnosticNavObserver],
      theme: diagnosticLightTheme(),
      darkTheme: diagnosticDarkTheme(),
      builder: (context, child) {
        if (kIsPhoneDiagnostic) return child ?? const SizedBox.shrink();
        return DesktopAppFrame(child: child ?? const SizedBox.shrink());
      },
      home: kIsPhoneDiagnostic
          ? const AndroidHomeScreen()
          : const HomeScreen(),
    );
  }
}
