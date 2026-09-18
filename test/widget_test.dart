import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:diagnostic/core/adb/adb_client.dart';
import 'package:diagnostic/main.dart';
import 'package:diagnostic/state/adb_providers.dart';

void main() {
  testWidgets('home shows AOW Diagnostic tool for Android', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adbAvailableProvider.overrideWith((ref) async => true),
          devicesProvider.overrideWith(
            (ref) => Stream.value(const <AdbDevice>[]),
          ),
        ],
        child: const DiagnosticApp(),
      ),
    );
    await tester.pump();
    expect(find.text('AOW Diagnostic tool for Android'), findsOneWidget);
    expect(find.text('Connect a device'), findsOneWidget);
  });
}
