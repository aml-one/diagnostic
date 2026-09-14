import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';

abstract final class AppLogExport {
  /// Plain-text render: one line per entry
  /// `HH:mm:ss.SSS [LEVEL] tag: message`, with `detail` (if present)
  /// indented on following lines. Oldest first.
  static String renderText({List<AppLogEntry>? entries}) {
    final list = entries ?? AppLog.snapshot();
    if (list.isEmpty) return '';
    final buf = StringBuffer();
    for (final entry in list) {
      buf.writeln(
        '${_formatTime(entry.time)} [${entry.level.name.toUpperCase()}] '
        '${entry.tag}: ${entry.message}',
      );
      final detail = entry.detail;
      if (detail == null || detail.isEmpty) continue;
      for (final line in const LineSplitter().convert(detail)) {
        buf.writeln('  $line');
      }
    }
    return buf.toString();
  }

  /// Writes [renderText] to
  /// `<Documents>/diagnostic-reports/app-log/aml_diagnostic_applog_<stamp>.txt`.
  static Future<File> writeToFile() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'diagnostic-reports', 'app-log'));
    await dir.create(recursive: true);
    final file = File(
      p.join(dir.path, 'aml_diagnostic_applog_${_stamp()}.txt'),
    );
    await file.writeAsString(renderText());
    return file;
  }
}

String _formatTime(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  String three(int v) => v.toString().padLeft(3, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.'
      '${three(time.millisecond)}';
}

String _stamp() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}${two(n.month)}${two(n.day)}-'
      '${two(n.hour)}${two(n.minute)}${two(n.second)}';
}
