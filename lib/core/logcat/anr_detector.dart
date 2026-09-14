import 'dart:async';
import 'dart:math' as math;

import 'logcat_parser.dart';

/// ANR or fatal crash spotted in logcat, with nearby lines for Diagnose.
class AnrEvent {
  const AnrEvent({
    required this.time,
    required this.packageHint,
    required this.reason,
    required this.context,
  });

  final DateTime time;
  final String packageHint;
  final String reason;
  final List<LogcatLine> context;
}

/// Watches parsed logcat, keeps a ring buffer, and emits ANR/crash events.
class AnrDetector {
  AnrDetector({
    this.bufferSize = 5000,
    this.contextLines = 120,
    this.followLines = 24,
  }) : _ring = _LineRing(bufferSize);

  final int bufferSize;
  final int contextLines;
  final int followLines;

  final _LineRing _ring;
  AnrEvent? _pending;
  int _pendingSeen = 0;
  DateTime? _lastEmitAt;
  String? _lastEmitKey;

  List<LogcatLine> get recentBuffer => _ring.snapshot();

  /// Bind a parsed-line stream. Each ANR/crash yields an [AnrEvent].
  Stream<AnrEvent> watch(Stream<LogcatLine> lines) async* {
    try {
      await for (final line in lines) {
        final event = add(line);
        if (event != null) yield event;
      }
    } finally {
      final flushed = flush();
      if (flushed != null) yield flushed;
    }
  }

  /// Feed one line. Returns an event when a burst is complete.
  AnrEvent? add(LogcatLine line) {
    _ring.add(line);
    if (_pending != null) {
      _pending = _enrich(_pending!, line);
      _pendingSeen++;
      final gotReason = _pending!.reason.isNotEmpty &&
          _pending!.reason != _pendingReasonPlaceholder;
      if (gotReason || _pendingSeen >= followLines) {
        final ready = _pending!;
        _pending = null;
        _pendingSeen = 0;
        return _emitIfFresh(ready);
      }
      return null;
    }
    if (!_isSignal(line)) return null;
    _pending = _startEvent(line);
    _pendingSeen = 0;
    return null;
  }

  AnrEvent? flush() {
    final pending = _pending;
    _pending = null;
    _pendingSeen = 0;
    if (pending == null) return null;
    return _emitIfFresh(pending);
  }

  void clear() {
    _pending = null;
    _pendingSeen = 0;
    _ring.clear();
  }

  AnrEvent _startEvent(LogcatLine line) {
    final hay = _hay(line);
    final packageHint = _packageFrom(hay) ?? _packageFromNearby() ?? '';
    final reason = _reasonFrom(hay) ?? _pendingReasonPlaceholder;
    return AnrEvent(
      time: line.timestamp ?? DateTime.now(),
      packageHint: packageHint,
      reason: reason,
      context: _ring.snapshot(last: contextLines),
    );
  }

  AnrEvent _enrich(AnrEvent pending, LogcatLine line) {
    final hay = _hay(line);
    var packageHint = pending.packageHint;
    var reason = pending.reason;
    final foundPackage = _packageFrom(hay);
    if (packageHint.isEmpty && foundPackage != null) {
      packageHint = foundPackage;
    }
    final foundReason = _reasonFrom(hay);
    if ((reason.isEmpty || reason == _pendingReasonPlaceholder) &&
        foundReason != null) {
      reason = foundReason;
    }
    if (packageHint == pending.packageHint && reason == pending.reason) {
      return pending;
    }
    return AnrEvent(
      time: pending.time,
      packageHint: packageHint,
      reason: reason,
      context: pending.context,
    );
  }

  AnrEvent? _emitIfFresh(AnrEvent event) {
    final key = '${event.packageHint}|${event.reason}';
    final now = event.time;
    if (_lastEmitKey == key &&
        _lastEmitAt != null &&
        now.difference(_lastEmitAt!) < const Duration(seconds: 2)) {
      return null;
    }
    _lastEmitKey = key;
    _lastEmitAt = now;
    final reason = event.reason == _pendingReasonPlaceholder
        ? 'ANR or crash'
        : event.reason;
    return AnrEvent(
      time: event.time,
      packageHint: event.packageHint,
      reason: reason,
      context: event.context,
    );
  }

  String? _packageFromNearby() {
    for (final line in _ring.snapshot(last: 40).reversed) {
      final found = _packageFrom(_hay(line));
      if (found != null) return found;
    }
    return null;
  }
}

const _pendingReasonPlaceholder = '__pending__';

bool _isSignal(LogcatLine line) {
  final hay = _hay(line);
  if (hay.contains('ANR in')) return true;
  if (hay.contains('Input dispatching timed out')) return true;
  if (hay.contains('am_anr')) return true;
  if (hay.contains('FATAL EXCEPTION')) return true;
  if (line.tag == 'AndroidRuntime' &&
      (line.level == 'E' || line.level == 'F') &&
      (hay.contains('FATAL') || hay.contains('AndroidRuntime'))) {
    return true;
  }
  return false;
}

String _hay(LogcatLine line) => '${line.tag} ${line.message}';

String? _packageFrom(String hay) {
  final anr = _anrIn.firstMatch(hay);
  if (anr != null) return anr.group(1);
  final process = _process.firstMatch(hay);
  if (process != null) return process.group(1);
  final am = _amAnr.firstMatch(hay);
  if (am != null) return am.group(3);
  return null;
}

String? _reasonFrom(String hay) {
  final reason = _reason.firstMatch(hay);
  if (reason != null) {
    final text = reason.group(1)!.trim();
    if (text.isNotEmpty) return text;
  }
  if (hay.contains('Input dispatching timed out')) {
    return 'Input dispatching timed out';
  }
  if (hay.contains('FATAL EXCEPTION')) {
    final fatal = _fatal.firstMatch(hay);
    return fatal != null
        ? 'FATAL EXCEPTION: ${fatal.group(1)!.trim()}'
        : 'FATAL EXCEPTION';
  }
  if (hay.contains('am_anr')) return 'am_anr';
  return null;
}

final _anrIn = RegExp(r'ANR in ([a-zA-Z0-9._]+)');
final _process = RegExp(r'Process:\s*([a-zA-Z0-9._]+)');
final _amAnr = RegExp(r'\[(\d+),(\d+),([a-zA-Z0-9._]+)');
final _reason = RegExp(r'Reason:\s*(.+)');
final _fatal = RegExp(r'FATAL EXCEPTION:\s*(.+)');

class _LineRing {
  _LineRing(this.capacity)
    : _items = List<LogcatLine?>.filled(capacity, null);

  final int capacity;
  final List<LogcatLine?> _items;
  int _next = 0;
  int _count = 0;

  void add(LogcatLine line) {
    _items[_next] = line;
    _next = (_next + 1) % capacity;
    if (_count < capacity) _count++;
  }

  void clear() {
    _next = 0;
    _count = 0;
    _items.fillRange(0, capacity, null);
  }

  List<LogcatLine> snapshot({int? last}) {
    final n = last == null ? _count : math.min(last, _count);
    if (n == 0) return const [];
    final out = <LogcatLine>[];
    final start = (_next - n + capacity) % capacity;
    for (var i = 0; i < n; i++) {
      out.add(_items[(start + i) % capacity]!);
    }
    return out;
  }
}
