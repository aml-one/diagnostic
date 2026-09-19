import 'dart:io';

import '../app_version.dart';
import '../logcat/logcat_parser.dart';
import '../mobile/mdx_file.dart';
import 'device_bridge.dart';
import 'phone_diagnostic.dart';

/// Diagnostic as it appears on the AOW shelf when a self-check capture exists.
const kDiagnosticShelfApp = PhoneInstalledApp(
  packageName: kDiagnosticAndroidPackage,
  label: 'Diagnostic',
);

const _selfCheckFile = 'diagnostic-self.mdx';
const _dismissedFile = 'self-check.dismissed';

final _pidInMessage = RegExp(
  r'(?:Start proc |pid:?\s+|PID:\s+)(\d+)',
  caseSensitive: false,
);

const _diagnosticProcessTags = {
  'AndroidRuntime',
  'flutter',
  'DEBUG',
  'crash_dump',
  'libc',
  'DiagLogcat',
  'DiagDumpsys',
  'Diagnostic',
};

bool _looksLikeIssue(LogcatLine line) {
  final level = line.level;
  if (level == 'E' || level == 'F') return true;
  final text = line.raw;
  return text.contains('FATAL EXCEPTION') ||
      text.contains('Fatal signal') ||
      text.contains('*** *** ***') ||
      text.contains('crash_dump') ||
      text.contains('ANR in');
}

bool _mentionsPackage(String raw, String packageName) {
  return raw.contains(packageName);
}

Set<int> diagnosticPidsFromDump({
  required List<LogcatLine> parsed,
  required String packageName,
}) {
  final pids = <int>{};
  for (final line in parsed) {
    if (!_mentionsPackage(line.raw, packageName)) continue;
    for (final match in _pidInMessage.allMatches(line.message)) {
      final found = int.tryParse(match.group(1) ?? '');
      if (found != null && found > 0) pids.add(found);
    }
    final pid = line.pid;
    if (pid != null &&
        pid > 0 &&
        _diagnosticProcessTags.contains(line.tag)) {
      pids.add(pid);
    }
  }
  return pids;
}

bool _keepSelfCheckLine({
  required LogcatLine line,
  required int myPid,
  required String packageName,
  required Set<int> diagnosticPids,
}) {
  if (line.pid == myPid) return false;
  if (diagnosticPids.contains(line.pid)) return true;
  if (_mentionsPackage(line.raw, packageName)) return true;
  if (!line.isParsed && line.message.trimLeft().startsWith('at ')) {
    return diagnosticPids.isNotEmpty;
  }
  return false;
}

String selfCheckFingerprint(List<LogcatLine> lines) {
  if (lines.isEmpty) return '';
  return '${lines.length}:${lines.first.raw}:${lines.last.raw}';
}

/// Lines from previous Diagnostic processes plus crash/ANR text. Current PID
/// is dropped so this launch does not always light up the shelf.
class DiagnosticSelfCheck {
  const DiagnosticSelfCheck({
    required this.lines,
    required this.fingerprint,
    this.path,
  });

  static const empty = DiagnosticSelfCheck(lines: [], fingerprint: '');

  final List<LogcatLine> lines;
  final String fingerprint;
  final String? path;

  bool get hasLogs => lines.isNotEmpty;

  int get errorCount =>
      lines.where((line) => line.level == 'E' || line.level == 'F').length;

  int get fatalCount => lines.where((line) => line.level == 'F').length;
}

DiagnosticSelfCheck analyzeDiagnosticSelfCheck({
  required List<String> rawLines,
  required int myPid,
  required String packageName,
  String? dismissedFingerprint,
}) {
  if (rawLines.isEmpty) return DiagnosticSelfCheck.empty;
  final parsed = [
    for (final raw in rawLines)
      if (raw.isNotEmpty) LogcatParser.parse(raw),
  ];
  final pids = diagnosticPidsFromDump(parsed: parsed, packageName: packageName)
    ..remove(myPid);
  final kept = <LogcatLine>[];
  for (final line in parsed) {
    if (_keepSelfCheckLine(
      line: line,
      myPid: myPid,
      packageName: packageName,
      diagnosticPids: pids,
    )) {
      kept.add(line);
    }
  }
  if (kept.isEmpty || !kept.any(_looksLikeIssue)) {
    return DiagnosticSelfCheck.empty;
  }
  final fingerprint = selfCheckFingerprint(kept);
  if (dismissedFingerprint != null &&
      dismissedFingerprint.isNotEmpty &&
      dismissedFingerprint == fingerprint) {
    return DiagnosticSelfCheck.empty;
  }
  return DiagnosticSelfCheck(lines: kept, fingerprint: fingerprint);
}

Future<DiagnosticSelfCheck> runDiagnosticSelfCheck({
  DeviceBridge? bridge,
  String packageName = kDiagnosticAndroidPackage,
}) async {
  final device = bridge ?? deviceBridge;
  try {
    final dump = await device.selfCheckDump();
    if (dump.lines.isEmpty) {
      await _deleteSelfCheckFiles(device);
      return DiagnosticSelfCheck.empty;
    }
    final dir = await device.mdxDirectory();
    final dismissed = await _readDismissed(dir);
    final analyzed = analyzeDiagnosticSelfCheck(
      rawLines: dump.lines,
      myPid: dump.pid,
      packageName: packageName,
      dismissedFingerprint: dismissed,
    );
    if (!analyzed.hasLogs) {
      await _deleteCapture(dir);
      return DiagnosticSelfCheck.empty;
    }
    final identity = await device.deviceIdentity();
    final path = await _writeCapture(
      dir: dir,
      identity: identity,
      body: analyzed.lines.map((line) => line.raw).join('\n'),
    );
    return DiagnosticSelfCheck(
      lines: analyzed.lines,
      fingerprint: analyzed.fingerprint,
      path: path,
    );
  } catch (_) {
    return DiagnosticSelfCheck.empty;
  }
}

Future<void> dismissDiagnosticSelfCheck(
  DiagnosticSelfCheck check, {
  DeviceBridge? bridge,
}) async {
  if (!check.hasLogs) return;
  final device = bridge ?? deviceBridge;
  try {
    final dir = await device.mdxDirectory();
    if (dir.isEmpty) return;
    await File('$dir${Platform.pathSeparator}$_dismissedFile')
        .writeAsString(check.fingerprint);
    await _deleteCapture(dir);
  } catch (_) {
    // Shelf hide is in-memory even if the stamp file fails.
  }
}

Future<String?> _writeCapture({
  required String dir,
  required Map<String, String> identity,
  required String body,
}) async {
  if (dir.isEmpty) return null;
  final folder = Directory(dir);
  if (!folder.existsSync()) {
    await folder.create(recursive: true);
  }
  final path = '$dir${Platform.pathSeparator}$_selfCheckFile';
  final now = DateTime.now().toUtc().toIso8601String();
  final header = MdxHeader(
    toolVersion: kAppVersion,
    device: identity['model'] ?? identity['deviceName'] ?? '',
    manufacturer: identity['manufacturer'] ?? '',
    brand: identity['brand'] ?? '',
    model: identity['model'] ?? '',
    deviceName: identity['deviceName'] ?? '',
    appLabel: 'Diagnostic',
    packages: const [kDiagnosticAndroidPackage],
    levels: 'WEF',
    startedAt: now,
    stoppedAt: now,
    source: 'self-check',
  );
  await File(path).writeAsString(composeMdx(header: header, body: body));
  return path;
}

Future<void> _deleteSelfCheckFiles(DeviceBridge device) async {
  final dir = await device.mdxDirectory();
  await _deleteCapture(dir);
}

Future<void> _deleteCapture(String dir) async {
  if (dir.isEmpty) return;
  final file = File('$dir${Platform.pathSeparator}$_selfCheckFile');
  if (await file.exists()) {
    await file.delete();
  }
}

Future<String?> _readDismissed(String dir) async {
  if (dir.isEmpty) return null;
  final file = File('$dir${Platform.pathSeparator}$_dismissedFile');
  if (!await file.exists()) return null;
  final text = (await file.readAsString()).trim();
  return text.isEmpty ? null : text;
}
