import 'package:flutter_test/flutter_test.dart';

import 'package:diagnostic/core/mobile/self_check.dart';

void main() {
  const pkg = 'one.aml.diagnostic';

  test('hides Diagnostic when the dump is empty', () {
    final check = analyzeDiagnosticSelfCheck(
      rawLines: const [],
      myPid: 42,
      packageName: pkg,
    );
    expect(check.hasLogs, isFalse);
  });

  test('hides current-process chatter even if it errors', () {
    const raw = [
      '09-18 10:00:00.100    42    42 E flutter: Diagnostic started',
      '09-18 10:00:00.110    42    42 F flutter: boom',
    ];
    final check = analyzeDiagnosticSelfCheck(
      rawLines: raw,
      myPid: 42,
      packageName: pkg,
    );
    expect(check.hasLogs, isFalse);
  });

  test('does not treat ActivityManager as a Diagnostic process', () {
    const raw = [
      '09-18 09:00:00.000  1000  1000 I ActivityManager: Start proc 77:one.aml.diagnostic/u0a123',
      '09-18 09:00:00.200  1000  1000 E ActivityManager: Failure starting process com.android.systemui',
    ];
    final check = analyzeDiagnosticSelfCheck(
      rawLines: raw,
      myPid: 42,
      packageName: pkg,
    );
    expect(check.hasLogs, isFalse);
  });

  test('shows leftover crash and error logs from a previous Diagnostic pid', () {
    const raw = [
      '09-18 09:00:00.000  1000  1000 I ActivityManager: Start proc 77:one.aml.diagnostic/u0a123',
      '09-18 09:00:01.000    77    77 E AndroidRuntime: FATAL EXCEPTION: main',
      '09-18 09:00:01.001    77    77 E AndroidRuntime: Process: one.aml.diagnostic, PID: 77',
      '09-18 09:00:01.002    77    77 E AndroidRuntime: java.lang.RuntimeException: boom',
      '    at one.aml.diagnostic.MainActivity.onCreate(MainActivity.kt:12)',
    ];
    final check = analyzeDiagnosticSelfCheck(
      rawLines: raw,
      myPid: 42,
      packageName: pkg,
    );
    expect(check.hasLogs, isTrue);
    expect(check.errorCount, greaterThan(0));
    expect(check.lines.any((line) => line.raw.contains('FATAL EXCEPTION')), isTrue);
    expect(check.lines.any((line) => line.message.trimLeft().startsWith('at ')), isTrue);
  });

  test('shows ANR lines that name Diagnostic', () {
    const raw = [
      '09-18 11:00:00.123  1000  1100 E ActivityManager: ANR in one.aml.diagnostic',
      '09-18 11:00:00.124  1000  1100 E ActivityManager: Reason: Input dispatching timed out',
    ];
    final check = analyzeDiagnosticSelfCheck(
      rawLines: raw,
      myPid: 42,
      packageName: pkg,
    );
    expect(check.hasLogs, isTrue);
  });

  test('hides the same dump after it was dismissed', () {
    const raw = [
      '09-18 09:00:01.000    77    77 E AndroidRuntime: FATAL EXCEPTION: main',
      '09-18 09:00:01.001    77    77 E AndroidRuntime: Process: one.aml.diagnostic, PID: 77',
    ];
    final first = analyzeDiagnosticSelfCheck(
      rawLines: raw,
      myPid: 42,
      packageName: pkg,
    );
    expect(first.hasLogs, isTrue);
    final again = analyzeDiagnosticSelfCheck(
      rawLines: raw,
      myPid: 42,
      packageName: pkg,
      dismissedFingerprint: first.fingerprint,
    );
    expect(again.hasLogs, isFalse);
  });
}
