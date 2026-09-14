import 'dart:async';

/// One Android `logcat -v threadtime` line.
class LogcatLine {
  const LogcatLine({
    required this.raw,
    this.timestamp,
    this.pid,
    this.tid,
    this.level = '',
    this.tag = '',
    this.message = '',
  });

  final DateTime? timestamp;
  final int? pid;
  final int? tid;
  final String level;
  final String tag;
  final String message;
  final String raw;

  bool get isParsed => timestamp != null;

  @override
  String toString() => raw;
}

/// Parses `MM-DD HH:MM:SS.mmm  PID  TID LEVEL TAG: message`.
class LogcatParser {
  LogcatParser._();

  static final StreamTransformer<String, LogcatLine> transformer =
      StreamTransformer<String, LogcatLine>.fromHandlers(
        handleData: (line, sink) => sink.add(parse(line)),
      );

  static LogcatLine parse(String raw) {
    final line = raw.replaceAll('\r', '');
    final match = _threadtime.firstMatch(line);
    if (match == null) {
      return LogcatLine(raw: line, message: line);
    }
    final month = int.parse(match.group(1)!);
    final day = int.parse(match.group(2)!);
    final hour = int.parse(match.group(3)!);
    final minute = int.parse(match.group(4)!);
    final second = int.parse(match.group(5)!);
    final millis = int.parse(match.group(6)!.padRight(3, '0'));
    return LogcatLine(
      raw: line,
      timestamp: _stamp(month, day, hour, minute, second, millis),
      pid: int.tryParse(match.group(7)!),
      tid: int.tryParse(match.group(8)!),
      level: match.group(9)!,
      tag: match.group(10)!.trim(),
      message: match.group(11) ?? '',
    );
  }
}

final _threadtime = RegExp(
  r'^(\d{2})-(\d{2})\s+'
  r'(\d{2}):(\d{2}):(\d{2})\.(\d{1,3})\s+'
  r'(\d+)\s+(\d+)\s+'
  r'([VDIWEF])\s+'
  r'(.+?):\s(.*)$',
);

DateTime _stamp(
  int month,
  int day,
  int hour,
  int minute,
  int second,
  int millis,
) {
  final now = DateTime.now();
  var stamp = DateTime(now.year, month, day, hour, minute, second, millis);
  if (stamp.isAfter(now.add(const Duration(days: 1)))) {
    stamp = DateTime(now.year - 1, month, day, hour, minute, second, millis);
  }
  return stamp;
}
