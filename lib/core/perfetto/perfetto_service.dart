import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../adb/adb_client.dart';
import 'perfetto_models.dart';

/// Official Perfetto UI. Local files cannot be passed in the URL; drag the
/// pulled `.perfetto-trace` onto the tab.
const kPerfettoUiUrl = 'https://ui.perfetto.dev';

/// Shown when `trace_processor_shell` is missing or will not run.
const kPerfettoProcessorFallbackNote = 'Install/open in Perfetto UI';

/// Pinned Windows amd64 `trace_processor_shell` from Perfetto v58.2
/// (https://get.perfetto.dev/trace_processor manifest / LUCI artifacts).
const kTraceProcessorRelease = 'v58.2';
const kTraceProcessorUrl =
    'https://commondatastorage.googleapis.com/perfetto-luci-artifacts/v58.2/windows-amd64/trace_processor_shell.exe';

/// Unrooted devices must write here; `adb pull` can read this path.
const kDeviceTraceDir = '/data/misc/perfetto-traces';

typedef PerfettoProgressCallback = void Function(
  String message, {
  double? progress,
});

/// Capture a short on-device Perfetto trace, pull it, and optionally summarize
/// it with a cached Windows `trace_processor_shell`.
///
/// Capture prefers the short category form:
/// `perfetto -t 10s -o … sched freq idle am wm gfx view binder_driver`
/// Full `--txt -c -` pbtxt on stdin is a fallback: many OEM `perfetto` builds
/// reject or ignore a pushed config, while `-t` + atrace categories works
/// without root.
class PerfettoService {
  PerfettoService({
    AdbClient? adb,
    http.Client? httpClient,
    Future<Directory> Function()? documentsDirectory,
    Future<Directory> Function()? supportDirectory,
    Future<bool> Function(Uri url)? launchUrlFn,
  })  : _adb = adb ?? AdbClient(),
        _http = httpClient ?? http.Client(),
        _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory,
        _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
        _launchUrl = launchUrlFn ?? _launchPerfettoUi;

  final AdbClient _adb;
  final http.Client _http;
  final Future<Directory> Function() _documentsDirectory;
  final Future<Directory> Function() _supportDirectory;
  final Future<bool> Function(Uri url) _launchUrl;

  /// Records ~10s on [serial], pulls the trace into the app documents dir,
  /// then runs canned SQL when the processor binary is available.
  Future<PerfettoCaptureResult> captureAndAnalyze({
    required String serial,
    String? packageName,
    Duration duration = const Duration(seconds: 10),
    PerfettoProgressCallback? onProgress,
  }) async {
    final trace = await capture(
      serial: serial,
      packageName: packageName,
      duration: duration,
      onProgress: onProgress,
    );
    onProgress?.call('Analyzing trace…', progress: 0.72);
    final analyzed = await analyze(trace, onProgress: onProgress);
    onProgress?.call('Done', progress: 1);
    return PerfettoCaptureResult(
      traceFile: trace,
      findings: analyzed.findings,
      processorNote: analyzed.processorNote,
    );
  }

  /// Runs `perfetto` on the phone and `adb pull`s the file next to other
  /// Diagnostic captures (`<documents>/perfetto/…`).
  Future<File> capture({
    required String serial,
    String? packageName,
    Duration duration = const Duration(seconds: 10),
    PerfettoProgressCallback? onProgress,
  }) async {
    final seconds = _clampCaptureSeconds(duration);
    onProgress?.call('Checking perfetto on device…', progress: 0.05);
    await _ensureDevicePerfetto(serial);

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final remoteName = 'aml_diag_$stamp.perfetto-trace';
    final remotePath = '$kDeviceTraceDir/$remoteName';

    onProgress?.call('Recording ${seconds}s on device…', progress: 0.12);
    await _runShortCapture(
      serial: serial,
      remotePath: remotePath,
      seconds: seconds,
      packageName: packageName,
      onProgress: onProgress,
    );

    onProgress?.call('Pulling trace…', progress: 0.55);
    final local = await _localTraceFile(serial, stamp);
    await local.parent.create(recursive: true);
    final pull = await _adb.run(
      ['pull', remotePath, local.path],
      serial: serial,
    );
    if (pull.exitCode != 0 || !local.existsSync() || local.lengthSync() == 0) {
      final err = pull.stderr.toString().trim();
      throw PerfettoUnavailableException(
        err.isEmpty
            ? 'adb pull failed for $remotePath'
            : 'adb pull failed: $err',
      );
    }
    await _tryRemoveRemote(serial, remotePath);
    onProgress?.call('Trace saved', progress: 0.68);
    return local;
  }

  /// Runs canned SQL against [traceFile]. Missing processor → empty findings
  /// and [kPerfettoProcessorFallbackNote].
  Future<({List<PerfettoFinding> findings, String? processorNote})> analyze(
    File traceFile, {
    PerfettoProgressCallback? onProgress,
  }) async {
    final exe = await ensureTraceProcessor(onProgress: onProgress);
    if (exe == null) {
      return (
        findings: const <PerfettoFinding>[],
        processorNote: kPerfettoProcessorFallbackNote,
      );
    }
    try {
      final tables = await _queryTables(exe, traceFile);
      final findings = <PerfettoFinding>[];
      if (tables.contains('slice')) {
        findings.addAll(await _queryMainThreadSlices(exe, traceFile, tables));
      }
      if (tables.contains('actual_frame_timeline_slice')) {
        findings.addAll(await _queryFrameJank(exe, traceFile));
      }
      return (findings: findings, processorNote: null);
    } on Object {
      return (
        findings: const <PerfettoFinding>[],
        processorNote: kPerfettoProcessorFallbackNote,
      );
    }
  }

  /// Downloads the Windows `trace_processor_shell` once into app-support cache.
  /// Never writes into the git tree. Returns null when the download fails.
  Future<File?> ensureTraceProcessor({
    PerfettoProgressCallback? onProgress,
  }) async {
    if (!Platform.isWindows) {
      return null;
    }
    final support = await _supportDirectory();
    final dir = Directory(
      p.join(support.path, 'perfetto', kTraceProcessorRelease),
    );
    final exe = File(p.join(dir.path, 'trace_processor_shell.exe'));
    if (exe.existsSync() && exe.lengthSync() > 1024 * 1024) {
      return exe;
    }
    onProgress?.call('Downloading trace_processor_shell…', progress: 0.78);
    try {
      await dir.create(recursive: true);
      final tmp = File('${exe.path}.tmp');
      if (tmp.existsSync()) {
        await tmp.delete();
      }
      final request = http.Request('GET', Uri.parse(kTraceProcessorUrl));
      final response = await _http.send(request).timeout(
        const Duration(seconds: 120),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final sink = tmp.openWrite();
      try {
        await response.stream.pipe(sink);
      } finally {
        await sink.close();
      }
      if (!tmp.existsSync() || tmp.lengthSync() < 1024 * 1024) {
        if (tmp.existsSync()) await tmp.delete();
        return null;
      }
      if (exe.existsSync()) await exe.delete();
      await tmp.rename(exe.path);
      return exe;
    } on Object {
      return null;
    }
  }

  /// Opens https://ui.perfetto.dev and returns the local path for drag-and-drop.
  /// No clipboard package is in pubspec; the path is in [PerfettoUiLaunch].
  Future<PerfettoUiLaunch> openInPerfettoUi({File? traceFile}) async {
    var opened = false;
    try {
      opened = await _launchUrl(Uri.parse(kPerfettoUiUrl));
    } on Object {
      opened = false;
    }
    final path = traceFile?.path ?? '';
    final instruction = path.isEmpty
        ? 'Open $kPerfettoUiUrl and drag a .perfetto-trace onto the tab.'
        : 'Open $kPerfettoUiUrl and drag this file onto the tab:\n$path';
    return PerfettoUiLaunch(
      openedBrowser: opened,
      tracePath: path,
      instruction: instruction,
    );
  }

  Future<void> _ensureDevicePerfetto(String serial) async {
    final result = await _adb.run(
      const ['shell', 'perfetto', '--help'],
      serial: serial,
    );
    final out = '${result.stdout}${result.stderr}'.toLowerCase();
    if (_looksLikeMissingBinary(out) ||
        (result.exitCode != 0 && out.contains('inaccessible or not found'))) {
      throw PerfettoUnavailableException(
        'This device has no perfetto binary. Open a bugreport in Perfetto UI instead.',
      );
    }
  }

  Future<void> _runShortCapture({
    required String serial,
    required String remotePath,
    required int seconds,
    String? packageName,
    PerfettoProgressCallback? onProgress,
  }) async {
    final args = buildPerfettoCaptureArgs(
      remotePath: remotePath,
      seconds: seconds,
      packageName: packageName,
    );
    final process = await _adb.start(args, serial: serial);
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    var elapsed = 0;
    final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      elapsed++;
      final fraction = (0.12 + (elapsed / seconds) * 0.4).clamp(0.12, 0.52);
      onProgress?.call(
        'Recording… ${elapsed}s / ${seconds}s',
        progress: fraction,
      );
    });
    int code;
    try {
      code = await process.exitCode.timeout(
        Duration(seconds: seconds + 25),
      );
    } on TimeoutException {
      process.kill();
      ticker.cancel();
      throw PerfettoUnavailableException(
        'perfetto capture timed out after ${seconds}s.',
      );
    } finally {
      ticker.cancel();
    }

    final stdoutText = await stdoutFuture;
    final stderrText = await stderrFuture;
    final combined = '$stdoutText$stderrText'.toLowerCase();
    if (code != 0 || _looksLikeMissingBinary(combined)) {
      // Short `-t` form failed. Some devices accept a pbtxt on stdin instead.
      final fallbackOk = await _runStdinConfigCapture(
        serial: serial,
        remotePath: remotePath,
        seconds: seconds,
        packageName: packageName,
      );
      if (fallbackOk) return;
      if (_looksLikeMissingBinary(combined)) {
        throw PerfettoUnavailableException(
          'This device has no perfetto binary.',
        );
      }
      final detail = '$stdoutText $stderrText'.trim();
      throw PerfettoUnavailableException(
        detail.isEmpty
            ? 'perfetto capture failed (exit $code).'
            : 'perfetto capture failed: $detail',
      );
    }
  }

  /// Fallback: `adb shell perfetto --txt -c - -o PATH` with a tiny pbtxt on
  /// stdin. Prefer [buildPerfettoCaptureArgs] (`-t`) first — stdin configs are
  /// flaky on many OEM builds (rejected proto, truncated stdin, or SELinux).
  Future<bool> _runStdinConfigCapture({
    required String serial,
    required String remotePath,
    required int seconds,
    String? packageName,
  }) async {
    try {
      final process = await _adb.start(
        [
          'shell',
          'perfetto',
          '--txt',
          '-c',
          '-',
          '-o',
          remotePath,
        ],
        serial: serial,
      );
      process.stdin.write(
        buildPerfettoTextConfig(
          seconds: seconds,
          packageName: packageName,
        ),
      );
      await process.stdin.close();
      final code = await process.exitCode.timeout(
        Duration(seconds: seconds + 25),
      );
      return code == 0;
    } on Object {
      return false;
    }
  }

  Future<void> _tryRemoveRemote(String serial, String remotePath) async {
    try {
      await _adb.run(['shell', 'rm', '-f', remotePath], serial: serial);
    } on Object {
      // Leaving the on-device copy is harmless.
    }
  }

  Future<File> _localTraceFile(String serial, int stamp) async {
    final docs = await _documentsDirectory();
    final safeSerial = serial.replaceAll(RegExp(r'[^\w.-]'), '_');
    return File(
      p.join(docs.path, 'perfetto', 'aml_diag_${safeSerial}_$stamp.perfetto-trace'),
    );
  }

  Future<Set<String>> _queryTables(File exe, File trace) async {
    const sql =
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;";
    final out = await _runSql(exe, trace, sql);
    if (out == null) return {};
    final rows = parseTraceProcessorTable(out);
    return {
      for (final row in rows)
        (row['name'] ?? (row.isEmpty ? '' : row.values.first)).toLowerCase(),
    };
  }

  Future<List<PerfettoFinding>> _queryMainThreadSlices(
    File exe,
    File trace,
    Set<String> tables,
  ) async {
    final sql = tables.contains('thread') && tables.contains('thread_track')
        ? _kMainThreadSql
        : _kLongSliceFallbackSql;
    final out = await _runSql(exe, trace, sql);
    if (out == null) return const [];
    return findingsFromSliceRows(parseTraceProcessorTable(out));
  }

  Future<List<PerfettoFinding>> _queryFrameJank(File exe, File trace) async {
    final out = await _runSql(exe, trace, _kFrameJankSql);
    if (out == null) return const [];
    return findingsFromFrameRows(parseTraceProcessorTable(out));
  }

  Future<String?> _runSql(File exe, File trace, String sql) async {
    final sqlFile = File('${trace.path}.q.sql');
    try {
      await sqlFile.writeAsString(sql);
      for (final args in [
        <String>['query', '--query-file', sqlFile.path, trace.path],
        <String>['--query-file', sqlFile.path, trace.path],
        <String>['-q', sqlFile.path, trace.path],
      ]) {
        try {
          final result = await Process.run(
            exe.path,
            args,
            runInShell: false,
          ).timeout(const Duration(seconds: 45));
          if (result.exitCode == 0) {
            final stdout = result.stdout.toString();
            if (stdout.trim().isNotEmpty) return stdout;
          }
        } on Object {
          continue;
        }
      }
      return null;
    } on Object {
      return null;
    } finally {
      try {
        if (sqlFile.existsSync()) await sqlFile.delete();
      } on Object {
        // Temp SQL next to the trace is gitignored via *.perfetto-trace sibling.
      }
    }
  }
}

Future<bool> _launchPerfettoUi(Uri url) {
  return launchUrl(url, mode: LaunchMode.externalApplication);
}

int _clampCaptureSeconds(Duration duration) {
  final raw = duration.inSeconds;
  if (raw < 10) return 10;
  if (raw > 15) return 15;
  return raw;
}

bool _looksLikeMissingBinary(String output) {
  return output.contains('not found') ||
      output.contains('no such file') ||
      output.contains('inaccessible or not found') ||
      output.contains('\'perfetto\' is not recognized');
}

/// `adb shell perfetto -t Ns -o PATH [--app pkg] <categories>`
List<String> buildPerfettoCaptureArgs({
  required String remotePath,
  required int seconds,
  String? packageName,
}) {
  final app = packageName?.trim();
  return [
    'shell',
    'perfetto',
    '-o',
    remotePath,
    '-t',
    '${seconds}s',
    if (app != null && app.isNotEmpty) ...['--app', app],
    'sched',
    'freq',
    'idle',
    'am',
    'wm',
    'gfx',
    'view',
    'binder_driver',
  ];
}

/// Lightweight text proto used only if `-t` capture fails (see class docs).
String buildPerfettoTextConfig({
  required int seconds,
  String? packageName,
}) {
  final app = packageName?.trim();
  final appLine = (app != null && app.isNotEmpty)
      ? '            atrace_apps: "$app"\n'
      : '';
  return '''
duration_ms: ${seconds * 1000}
buffers: {
    size_kb: 32768
    fill_policy: DISCARD
}
data_sources: {
    config {
        name: "linux.ftrace"
        ftrace_config {
            ftrace_events: "sched/sched_switch"
            ftrace_events: "sched/sched_wakeup"
            atrace_categories: "am"
            atrace_categories: "wm"
            atrace_categories: "gfx"
            atrace_categories: "view"
            atrace_categories: "binder_driver"
$appLine        }
    }
}
''';
}

const _kMainThreadSql = '''
SELECT
  COALESCE(thread.name, '') AS thread_name,
  slice.name AS slice_name,
  CAST(slice.dur / 1000000 AS INT) AS dur_ms
FROM slice
JOIN thread_track ON slice.track_id = thread_track.id
JOIN thread USING (utid)
WHERE slice.dur >= 16000000
  AND (
    thread.is_main_thread = 1
    OR thread.name LIKE '%main%'
    OR thread.name LIKE '%.ui'
    OR LOWER(thread.name) LIKE '%ui thread%'
  )
ORDER BY slice.dur DESC
LIMIT 25;
''';

const _kLongSliceFallbackSql = '''
SELECT
  '' AS thread_name,
  slice.name AS slice_name,
  CAST(slice.dur / 1000000 AS INT) AS dur_ms
FROM slice
WHERE slice.dur >= 50000000
ORDER BY slice.dur DESC
LIMIT 15;
''';

const _kFrameJankSql = '''
SELECT
  name AS slice_name,
  CAST(dur / 1000000 AS INT) AS dur_ms
FROM actual_frame_timeline_slice
WHERE dur >= 16666667
ORDER BY dur DESC
LIMIT 25;
''';

/// Parses `trace_processor_shell` text or CSV table stdout into row maps.
Map<String, String> _rowFromParts(List<String> header, List<String> cells) {
  final row = <String, String>{};
  for (var i = 0; i < header.length; i++) {
    row[header[i]] = i < cells.length ? cells[i] : '';
  }
  return row;
}

List<String> _splitTableLine(String line) {
  final trimmed = line.trim();
  if (trimmed.contains('|')) {
    return trimmed
        .split('|')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
  }
  if (trimmed.contains(',')) {
    return _splitCsvLine(trimmed);
  }
  return trimmed.split(RegExp(r'\s{2,}')).map((part) => part.trim()).toList();
}

List<String> _splitCsvLine(String line) {
  final cells = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      inQuotes = !inQuotes;
      continue;
    }
    if (ch == ',' && !inQuotes) {
      cells.add(buf.toString().trim());
      buf.clear();
      continue;
    }
    buf.write(ch);
  }
  cells.add(buf.toString().trim());
  return cells.where((cell) => cell.isNotEmpty || cells.length > 1).toList();
}

bool _isSeparatorLine(String line) {
  final t = line.trim();
  if (t.isEmpty) return true;
  final compact = t.replaceAll(RegExp(r'[\s|]+'), '');
  return compact.isNotEmpty && RegExp(r'^[\-|=+_]+$').hasMatch(compact);
}

/// Exposed for tests.
List<Map<String, String>> parseTraceProcessorTable(String stdout) {
  final lines = const LineSplitter()
      .convert(stdout)
      .map((line) => line.trimRight())
      .where((line) => line.trim().isNotEmpty)
      .where((line) => !line.trimLeft().startsWith('#'))
      .toList();
  if (lines.isEmpty) return const [];
  var headerIndex = 0;
  while (headerIndex < lines.length && _isSeparatorLine(lines[headerIndex])) {
    headerIndex++;
  }
  if (headerIndex >= lines.length) return const [];
  final header = _splitTableLine(lines[headerIndex])
      .map((name) => name.toLowerCase().replaceAll(' ', '_'))
      .toList();
  if (header.isEmpty) return const [];
  final rows = <Map<String, String>>[];
  for (var i = headerIndex + 1; i < lines.length; i++) {
    if (_isSeparatorLine(lines[i])) continue;
    final cells = _splitTableLine(lines[i]);
    if (cells.isEmpty) continue;
    rows.add(_rowFromParts(header, cells));
  }
  return rows;
}

PerfettoSeverity severityForDurationMs(int durMs) {
  if (durMs >= 100) return PerfettoSeverity.severe;
  if (durMs >= 32) return PerfettoSeverity.warning;
  return PerfettoSeverity.info;
}

int _durMs(Map<String, String> row) {
  return int.tryParse(row['dur_ms'] ?? row['dur'] ?? '') ?? 0;
}

/// Exposed for tests.
List<PerfettoFinding> findingsFromSliceRows(List<Map<String, String>> rows) {
  final findings = <PerfettoFinding>[];
  for (final row in rows) {
    final dur = _durMs(row);
    if (dur <= 0) continue;
    final name = row['slice_name'] ?? row['name'] ?? 'slice';
    final thread = row['thread_name'] ?? '';
    final where = thread.isEmpty ? 'main / UI thread' : thread;
    findings.add(
      PerfettoFinding(
        title: 'Long slice on $where (${dur}ms)',
        detail: name,
        severity: severityForDurationMs(dur),
      ),
    );
  }
  return findings;
}

/// Exposed for tests.
List<PerfettoFinding> findingsFromFrameRows(List<Map<String, String>> rows) {
  final findings = <PerfettoFinding>[];
  for (final row in rows) {
    final dur = _durMs(row);
    if (dur <= 0) continue;
    final name = row['slice_name'] ?? row['name'] ?? 'frame';
    findings.add(
      PerfettoFinding(
        title: 'Frame jank (${dur}ms)',
        detail: name,
        severity: severityForDurationMs(dur),
      ),
    );
  }
  return findings;
}
