import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_version.dart';
import '../logcat/anr_detector.dart';
import '../mobile/mdx_file.dart';
import '../mobile/phone_diagnostic.dart';
import 'diagnosis_report.dart';

/// Writes a completed [DiagnosisReport] to
/// `<Documents>/diagnostic-reports/` as Markdown or JSON.
///
/// This is a pure formatting/IO helper: it does not touch adb, Riverpod, or
/// the AI layer. The Diagnose report screen passes in the assembled report
/// plus the extra context ([DiagnosisState] fields) that the AI-owned
/// [DiagnosisReport] model does not carry (device serial, raw ANR events,
/// bugreport/perfetto artifact paths, run timestamps).
class DiagnosisReportExport {
  DiagnosisReportExport._();

  static Future<File> writeMarkdown({
    required DiagnosisReport report,
    required String serial,
    String? packageName,
    List<AnrEvent> anrEvents = const [],
    DateTime? startedAt,
    DateTime? finishedAt,
    String? bugreportZipPath,
    String? bugreportExtractDir,
    String? perfettoTracePath,
    String? perfettoProcessorNote,
  }) async {
    final file = await _targetFile(
      serial: serial,
      packageName: packageName,
      extension: 'md',
    );
    final text = _renderMarkdown(
      report: report,
      serial: serial,
      packageName: packageName,
      anrEvents: anrEvents,
      startedAt: startedAt,
      finishedAt: finishedAt,
      bugreportZipPath: bugreportZipPath,
      bugreportExtractDir: bugreportExtractDir,
      perfettoTracePath: perfettoTracePath,
      perfettoProcessorNote: perfettoProcessorNote,
    );
    await file.writeAsString(text);
    return file;
  }

  /// Diagnose envelope: JSON header (`MDXD1`) + JSON body. Same family as `.mdx`.
  static Future<File> writeMdxd({
    required DiagnosisReport report,
    required String serial,
    String? packageName,
    String? appLabel,
    String brand = '',
    String model = '',
    String deviceName = '',
    String manufacturer = '',
    List<AnrEvent> anrEvents = const [],
    DateTime? startedAt,
    DateTime? finishedAt,
    String? bugreportZipPath,
    String? bugreportExtractDir,
    String? perfettoTracePath,
    String? perfettoProcessorNote,
    Directory? directory,
  }) async {
    final file = directory == null
        ? await _targetFile(
            serial: serial,
            packageName: packageName,
            extension: 'mdxd',
          )
        : File(
            p.join(
              directory.path,
              '${_safe(packageName ?? serial)}_${DateTime.now().millisecondsSinceEpoch}.mdxd',
            ),
          );
    await file.parent.create(recursive: true);
    final payload = buildPayloadMap(
      report: report,
      serial: serial,
      packageName: packageName,
      anrEvents: anrEvents,
      startedAt: startedAt,
      finishedAt: finishedAt,
      bugreportZipPath: bugreportZipPath,
      bugreportExtractDir: bugreportExtractDir,
      perfettoTracePath: perfettoTracePath,
      perfettoProcessorNote: perfettoProcessorNote,
    );
    if (appLabel != null && appLabel.trim().isNotEmpty) {
      payload['appLabel'] = appLabel.trim();
    }
    if (brand.isNotEmpty) payload['brand'] = brand;
    if (model.isNotEmpty) payload['model'] = model;
    if (deviceName.isNotEmpty) payload['deviceName'] = deviceName;
    final header = MdxHeader(
      magic: kMdxdMagic,
      toolVersion: kAppVersion,
      device: model.isNotEmpty ? model : serial,
      manufacturer: manufacturer,
      brand: brand,
      model: model.isNotEmpty ? model : serial,
      deviceName: deviceName.isNotEmpty ? deviceName : serial,
      appLabel: appLabel?.trim() ?? '',
      packages: [
        if (packageName != null && packageName.trim().isNotEmpty)
          packageName.trim(),
      ],
      levels: 'diagnosis',
      startedAt: startedAt?.toIso8601String() ?? DateTime.now().toUtc().toIso8601String(),
      stoppedAt: finishedAt?.toIso8601String(),
      source: 'diagnosis',
    );
    await file.writeAsString(
      composeMdx(header: header, body: jsonEncode(payload)),
    );
    return file;
  }

  /// JSON payload for App Builder field-report upload (same shape as export).
  static Map<String, Object?> buildPayloadMap({
    required DiagnosisReport report,
    required String serial,
    String? packageName,
    List<AnrEvent> anrEvents = const [],
    DateTime? startedAt,
    DateTime? finishedAt,
    String? bugreportZipPath,
    String? bugreportExtractDir,
    String? perfettoTracePath,
    String? perfettoProcessorNote,
  }) {
    return <String, Object?>{
      'device': serial,
      'package': packageName,
      'startedAt': startedAt?.toIso8601String(),
      'finishedAt': finishedAt?.toIso8601String(),
      'elapsedMs': (startedAt != null && finishedAt != null)
          ? finishedAt.difference(startedAt).inMilliseconds
          : null,
      'topFinding': topFindingFor(report),
      'anr': {
        'reason': report.anrReason,
        'subject': report.subject,
        'process': report.process,
        'timestamp': report.timestamp?.toIso8601String(),
        'mainThreadName': report.mainThreadName,
        'mainThreadState': report.mainThreadState,
        'mainThreadFrames': report.mainThreadFrames,
        'lockedStacks': report.lockedStacks,
      },
      'perf': {
        'cpuLoad': report.cpu?.load,
        'cpuSummary': report.cpuSummary,
        'totalPssKb': report.mem?.totalPssKb,
        'nativeHeapPssKb': report.mem?.nativeHeapPssKb,
        'dalvikHeapPssKb': report.mem?.dalvikHeapPssKb,
        'memSummary': report.memSummary,
        'totalFrames': report.gfx?.totalFrames,
        'jankyFrames': report.gfx?.jankyFrames,
        'jankyPercent': report.gfx?.jankyPercent,
        'gfxSummary': report.gfxSummary,
      },
      'perfetto': {
        'findings': [
          for (final finding in report.perfettoFindings)
            {
              'title': finding.title,
              'detail': finding.detail,
              'severity': finding.severity.name,
            },
        ],
        'tracePath': perfettoTracePath,
        'processorNote': perfettoProcessorNote ?? report.processorNote,
      },
      'bugreport': {
        'zipPath': bugreportZipPath,
        'extractDir': bugreportExtractDir,
      },
      'recentAnrEvents': [
        for (final event in anrEvents)
          {
            'time': event.time.toIso8601String(),
            'packageHint': event.packageHint,
            'reason': event.reason,
          },
      ],
      'logcatContext': report.logcatContext,
    };
  }

  /// Markdown summary for App Builder field-report [textBody].
  static String buildMarkdown({
    required DiagnosisReport report,
    required String serial,
    String? packageName,
    List<AnrEvent> anrEvents = const [],
    DateTime? startedAt,
    DateTime? finishedAt,
    String? bugreportZipPath,
    String? bugreportExtractDir,
    String? perfettoTracePath,
    String? perfettoProcessorNote,
  }) {
    return _renderMarkdown(
      report: report,
      serial: serial,
      packageName: packageName,
      anrEvents: anrEvents,
      startedAt: startedAt,
      finishedAt: finishedAt,
      bugreportZipPath: bugreportZipPath,
      bugreportExtractDir: bugreportExtractDir,
      perfettoTracePath: perfettoTracePath,
      perfettoProcessorNote: perfettoProcessorNote,
    );
  }

  static Future<File> writeJson({
    required DiagnosisReport report,
    required String serial,
    String? packageName,
    List<AnrEvent> anrEvents = const [],
    DateTime? startedAt,
    DateTime? finishedAt,
    String? bugreportZipPath,
    String? bugreportExtractDir,
    String? perfettoTracePath,
    String? perfettoProcessorNote,
  }) async {
    final file = await _targetFile(
      serial: serial,
      packageName: packageName,
      extension: 'json',
    );
    final payload = buildPayloadMap(
      report: report,
      serial: serial,
      packageName: packageName,
      anrEvents: anrEvents,
      startedAt: startedAt,
      finishedAt: finishedAt,
      bugreportZipPath: bugreportZipPath,
      bugreportExtractDir: bugreportExtractDir,
      perfettoTracePath: perfettoTracePath,
      perfettoProcessorNote: perfettoProcessorNote,
    );
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(payload));
    return file;
  }

  static Future<File> _targetFile({
    required String serial,
    String? packageName,
    required String extension,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'diagnostic-reports'));
    await dir.create(recursive: true);
    final pkg = (packageName == null || packageName.trim().isEmpty)
        ? 'unknown'
        : packageName.trim();
    final name =
        'aml_diag_${_safe(serial)}_${_safe(pkg)}_${_stamp()}.$extension';
    return File(p.join(dir.path, name));
  }
}

/// One-line headline shared by the export payload and the report UI's
/// "Top finding" stat card.
String topFindingFor(DiagnosisReport report) {
  final reason = report.anrReason?.trim();
  if (reason != null && reason.isNotEmpty) return reason;
  if (report.logFindings.isNotEmpty) return report.logFindings.first;
  if (report.perfettoFindings.isNotEmpty) {
    final sorted = [...report.perfettoFindings]
      ..sort((a, b) => b.severity.index.compareTo(a.severity.index));
    return sorted.first.title;
  }
  return 'No ANR or jank evidence captured';
}

String _renderMarkdown({
  required DiagnosisReport report,
  required String serial,
  String? packageName,
  List<AnrEvent> anrEvents = const [],
  DateTime? startedAt,
  DateTime? finishedAt,
  String? bugreportZipPath,
  String? bugreportExtractDir,
  String? perfettoTracePath,
  String? perfettoProcessorNote,
}) {
  final buf = StringBuffer();
  buf.writeln('# AmL Diagnostic report');
  buf.writeln();
  buf.writeln('- Device: `$serial`');
  buf.writeln('- Package: `${packageName ?? 'unknown'}`');
  if (startedAt != null) {
    buf.writeln('- Started: ${startedAt.toIso8601String()}');
  }
  if (finishedAt != null) {
    buf.writeln('- Finished: ${finishedAt.toIso8601String()}');
  }
  if (startedAt != null && finishedAt != null) {
    buf.writeln(
      '- Elapsed: ${formatDiagnosisElapsed(finishedAt.difference(startedAt))}',
    );
  }
  buf.writeln();
  buf.writeln('## Top finding');
  buf.writeln(topFindingFor(report));
  buf.writeln();
  if (report.scannedLines > 0 || report.logFindings.isNotEmpty) {
    buf.writeln('## Watch logs');
    buf.writeln('- Lines scanned: ${report.scannedLines}');
    buf.writeln('- Errors: ${report.errorLines}');
    buf.writeln('- Warnings: ${report.warningLines}');
    for (final finding in report.logFindings) {
      buf.writeln('- $finding');
    }
    buf.writeln();
  }
  if (report.hasEvidence) {
    buf.writeln('## ANR');
    if (report.anrReason != null) {
      buf.writeln('- Reason: ${report.anrReason}');
    }
    if (report.subject != null) buf.writeln('- Subject: ${report.subject}');
    if (report.process != null) buf.writeln('- Process: ${report.process}');
    if (report.timestamp != null) {
      buf.writeln('- Timestamp: ${report.timestamp!.toIso8601String()}');
    }
    if (report.mainThreadFrames.isNotEmpty) {
      buf.writeln(
        '- Main thread `${report.mainThreadName ?? 'main'}` '
        '(${report.mainThreadState ?? 'unknown'}):',
      );
      buf.writeln('```');
      for (final frame in report.mainThreadFrames) {
        buf.writeln(frame);
      }
      buf.writeln('```');
    }
    if (report.lockedStacks.isNotEmpty) {
      buf.writeln('- Locked / waiting stacks:');
      buf.writeln('```');
      for (final line in report.lockedStacks) {
        buf.writeln(line);
      }
      buf.writeln('```');
    }
    buf.writeln();
  }
  buf.writeln('## Perf snapshot');
  if (report.cpu?.load != null) buf.writeln('- CPU: ${report.cpu!.load}');
  if (report.mem?.totalPssKb != null) {
    buf.writeln('- Total PSS: ${report.mem!.totalPssKb} kB');
  }
  if (report.gfx?.totalFrames != null) {
    final janky = report.gfx!.jankyFrames ?? 0;
    final percent = report.gfx!.jankyPercent;
    buf.writeln(
      '- Frames: ${report.gfx!.totalFrames} total, $janky janky'
      '${percent == null ? '' : ' (${percent.toStringAsFixed(1)}%)'}',
    );
  }
  buf.writeln();
  buf.writeln('## Perfetto');
  if (report.perfettoFindings.isEmpty) {
    buf.writeln(
      perfettoProcessorNote ?? report.processorNote ?? 'No findings recorded.',
    );
  } else {
    for (final finding in report.perfettoFindings) {
      buf.writeln(
        '- **${finding.severity.name}** ${finding.title} — ${finding.detail}',
      );
    }
  }
  if (perfettoTracePath != null && perfettoTracePath.isNotEmpty) {
    buf.writeln();
    buf.writeln('Trace file: `$perfettoTracePath`');
  }
  buf.writeln();
  if (bugreportZipPath != null || bugreportExtractDir != null) {
    buf.writeln('## Bugreport');
    if (bugreportZipPath != null) buf.writeln('- Zip: `$bugreportZipPath`');
    if (bugreportExtractDir != null) {
      buf.writeln('- Extracted: `$bugreportExtractDir`');
    }
    buf.writeln();
  }
  if (anrEvents.isNotEmpty) {
    buf.writeln('## Recent ANR events (logcat)');
    for (final event in anrEvents) {
      final pkg = event.packageHint.isEmpty ? 'unknown package' : event.packageHint;
      buf.writeln('- ${event.time.toIso8601String()} — ${event.reason} ($pkg)');
    }
    buf.writeln();
  }
  if (report.logcatContext.isNotEmpty) {
    buf.writeln('## Logcat context');
    buf.writeln('```');
    for (final line in report.logcatContext) {
      buf.writeln(line);
    }
    buf.writeln('```');
  }
  return buf.toString();
}

String _safe(String value) => value.replaceAll(RegExp(r'[^\w.-]'), '_');

String _stamp() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}${two(n.month)}${two(n.day)}-'
      '${two(n.hour)}${two(n.minute)}${two(n.second)}';
}
