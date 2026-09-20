import 'logcat_parser.dart';

/// One Watch row after consecutive identical lines are merged.
class CollapsedLogcatLine {
  const CollapsedLogcatLine({
    required this.line,
    this.count = 1,
    this.dimmed = false,
  });

  final LogcatLine line;
  final int count;
  final bool dimmed;

  CollapsedLogcatLine bump(LogcatLine latest) => CollapsedLogcatLine(
        line: latest,
        count: count + 1,
        dimmed: dimmed,
      );

  LogcatLine toDiagnoseLine() {
    if (count <= 1) return line;
    return LogcatLine(
      raw: collapsedLogcatExport(this),
      timestamp: line.timestamp,
      pid: line.pid,
      tid: line.tid,
      level: line.level,
      tag: line.tag,
      message: line.message,
    );
  }
}

final _digits = RegExp(r'\d+');

String logcatCollapseBody(LogcatLine line) {
  final raw = line.message.isEmpty ? line.raw : line.message;
  return raw.replaceAll(_digits, '#');
}

/// Tag + level + message, ignoring timestamp, pid, and isolated digits
/// (`gatt server state=2` stacks with `state=0`).
bool sameLogcatCollapseKey(LogcatLine a, LogcatLine b) {
  if (a.level != b.level || a.tag != b.tag) return false;
  return logcatCollapseBody(a) == logcatCollapseBody(b);
}

/// Append [line] onto [rows], merging it into the last row when the body
/// matches. Returns true when a new row was added.
bool appendCollapsed(
  List<CollapsedLogcatLine> rows,
  LogcatLine line, {
  bool dimmed = false,
}) {
  if (rows.isNotEmpty) {
    final last = rows.last;
    if (last.dimmed == dimmed && sameLogcatCollapseKey(last.line, line)) {
      rows[rows.length - 1] = last.bump(line);
      return false;
    }
  }
  rows.add(CollapsedLogcatLine(line: line, dimmed: dimmed));
  return true;
}

List<CollapsedLogcatLine> collapseLogcatLines(
  Iterable<LogcatLine> lines, {
  bool dimmed = false,
}) {
  final rows = <CollapsedLogcatLine>[];
  for (final line in lines) {
    appendCollapsed(rows, line, dimmed: dimmed);
  }
  return rows;
}

String collapsedLogcatExport(CollapsedLogcatLine row) {
  if (row.count <= 1) return row.line.raw;
  return '${row.line.raw}  ×${row.count}';
}
