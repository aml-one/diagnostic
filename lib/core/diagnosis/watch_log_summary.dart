import '../logcat/logcat_parser.dart';
import 'diagnosis_report.dart';

/// Counts and headlines from the Watch buffer (phone Diagnose).
class WatchLogSummary {
  const WatchLogSummary({
    required this.lineCount,
    required this.errorCount,
    required this.warningCount,
    required this.fatalCount,
    required this.findings,
    required this.highlights,
    required this.topTags,
  });

  final int lineCount;
  final int errorCount;
  final int warningCount;
  final int fatalCount;
  final List<String> findings;
  final List<String> highlights;
  final List<WatchTagCount> topTags;

  String get headline =>
      findings.isEmpty ? 'No Watch lines captured' : findings.first;
}

class WatchTagCount {
  const WatchTagCount(this.tag, this.count);

  final String tag;
  final int count;
}

final _crashCue = RegExp(
  r'FATAL EXCEPTION|AndroidRuntime|ANR in |Process: .+\s+crashed|'
  r'Fatal signal|java\.lang\.|Dart Error|Unhandled Exception',
  caseSensitive: false,
);

/// Newest-wins merge of Diagnose sources (live dump, native ring, Watch list).
List<LogcatLine> mergeWatchLogLines(
  Iterable<Iterable<LogcatLine>> sources, {
  int cap = 4000,
}) {
  final seen = <String>{};
  final out = <LogcatLine>[];
  for (final source in sources) {
    for (final line in source) {
      final key = line.raw.trim().isNotEmpty
          ? line.raw
          : '${line.timestamp?.millisecondsSinceEpoch}|${line.level}|${line.tag}|${line.message}';
      if (key.trim().isEmpty) continue;
      if (seen.add(key)) out.add(line);
    }
  }
  if (out.length <= cap) return out;
  return out.sublist(out.length - cap);
}

/// Scan every Watch line — not only the last two minutes of ANR traces.
WatchLogSummary summarizeWatchLogs(
  List<LogcatLine> lines, {
  List<String> extraFindings = const [],
}) {
  if (lines.isEmpty) {
    return WatchLogSummary(
      lineCount: 0,
      errorCount: 0,
      warningCount: 0,
      fatalCount: 0,
      findings: [
        'Watch has no log lines yet. Keep the app on screen, then Diagnose again.',
        ...extraFindings,
      ],
      highlights: [],
      topTags: [],
    );
  }

  var errors = 0;
  var warnings = 0;
  var fatals = 0;
  final tagHits = <String, int>{};
  final hot = <LogcatLine>[];
  String? crashLine;

  for (final line in lines) {
    final level = line.level.toUpperCase();
    if (level == 'F') {
      fatals++;
      errors++;
      _countTag(tagHits, line.tag);
      hot.add(line);
    } else if (level == 'E') {
      errors++;
      _countTag(tagHits, line.tag);
      hot.add(line);
    } else if (level == 'W') {
      warnings++;
      hot.add(line);
    }
    if (crashLine == null && _crashCue.hasMatch('${line.tag} ${line.message}')) {
      crashLine = _short(formatLogcatLine(line), 90);
    }
  }

  final tags = tagHits.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final topTags = [
    for (final e in tags.take(3)) WatchTagCount(e.key, e.value),
  ];

  final loud = topTags.isEmpty ? '' : ', mostly ${topTags.first.tag}';
  final findings = <String>[];
  if (crashLine != null) findings.add(crashLine);
  if (errors > 0) {
    findings.add('$errors error${errors == 1 ? '' : 's'}$loud');
  } else if (warnings > 0) {
    findings.add(
      'No errors. $warnings warning${warnings == 1 ? '' : 's'}',
    );
  } else {
    findings.add('${lines.length} Watch lines, no errors or warnings');
  }
  if (errors > 0 && warnings > 0) {
    findings.add('$warnings warning${warnings == 1 ? '' : 's'}');
  }
  findings.addAll(extraFindings);

  final preferred = hot.where((l) {
    final lv = l.level.toUpperCase();
    return lv == 'E' || lv == 'F';
  }).toList();
  final source = preferred.isNotEmpty ? preferred : hot;
  final slice = source.length <= 16
      ? source
      : source.sublist(source.length - 16);

  return WatchLogSummary(
    lineCount: lines.length,
    errorCount: errors,
    warningCount: warnings,
    fatalCount: fatals,
    findings: findings,
    highlights: [for (final line in slice) formatLogcatLine(line)],
    topTags: topTags,
  );
}

void _countTag(Map<String, int> hits, String tag) {
  final key = tag.trim().isEmpty ? '(no tag)' : tag.trim();
  hits[key] = (hits[key] ?? 0) + 1;
}

String _short(String text, int max) {
  final trimmed = text.trim();
  if (trimmed.length <= max) return trimmed;
  return '${trimmed.substring(0, max - 1)}…';
}
