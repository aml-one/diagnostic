import 'dart:collection';

import 'package:flutter/foundation.dart';

enum AppLogLevel { debug, info, warn, error }

class AppLogEntry {
  const AppLogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    this.detail,
  });

  final DateTime time;
  final AppLogLevel level;
  final String tag;
  final String message;

  /// Stack trace or error `toString()`, may be multi-line.
  final String? detail;
}

abstract final class AppLog {
  static const int maxEntries = 4000;

  /// Bumped on every append/clear so UI can listen.
  static final ValueNotifier<int> version = ValueNotifier<int>(0);

  static final Queue<AppLogEntry> _entries = Queue<AppLogEntry>();

  static void d(String tag, String message) =>
      _append(AppLogLevel.debug, tag, message);

  static void i(String tag, String message) =>
      _append(AppLogLevel.info, tag, message);

  static void w(String tag, String message, [Object? error]) =>
      _append(AppLogLevel.warn, tag, message, error: error);

  static void e(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) => _append(
    AppLogLevel.error,
    tag,
    message,
    error: error,
    stackTrace: stackTrace,
  );

  /// Immutable copy, oldest first.
  static List<AppLogEntry> snapshot() =>
      List<AppLogEntry>.unmodifiable(_entries.toList(growable: false));

  static void clear() {
    _entries.clear();
    version.value++;
  }

  static void _append(
    AppLogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    _entries.addLast(
      AppLogEntry(
        time: DateTime.now(),
        level: level,
        tag: tag,
        message: message,
        detail: _detail(error, stackTrace),
      ),
    );
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    version.value++;
  }

  static String? _detail(Object? error, StackTrace? stackTrace) {
    if (error == null && stackTrace == null) return null;
    final buf = StringBuffer();
    if (error != null) buf.writeln(error.toString());
    if (stackTrace != null) buf.write(stackTrace.toString());
    final text = buf.toString().trimRight();
    return text.isEmpty ? null : text;
  }
}
