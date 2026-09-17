import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'logcat_parser.dart';

/// Background UTF-8 / line-split / parse for live logcat.
///
/// Keeps regex-heavy [LogcatParser] work off the UI isolate so Windows does
/// not freeze when adb dumps a large backlog at Watch start.
class LogcatParseIsolate {
  LogcatParseIsolate._(this._isolate, this._commands, this._events);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _events;
  final _batches = StreamController<List<LogcatLine>>.broadcast();
  StreamSubscription<dynamic>? _eventSub;

  Stream<List<LogcatLine>> get batches => _batches.stream;

  static Future<LogcatParseIsolate> spawn() async {
    final handshake = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      handshake.sendPort,
      debugName: 'logcat-parse',
    );
    final commands = await handshake.first as SendPort;
    handshake.close();

    final events = ReceivePort();
    commands.send(events.sendPort);

    final worker = LogcatParseIsolate._(isolate, commands, events);
    worker._eventSub = events.listen(worker._onEvent);
    return worker;
  }

  void addBytes(List<int> chunk) {
    if (chunk.isEmpty) return;
    // Transferable typed data avoids an extra copy when the isolate accepts it.
    _commands.send(
      chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
    );
  }

  Future<void> close() async {
    try {
      _commands.send(_shutdown);
    } on Object {
      // Isolate may already be gone.
    }
    await _eventSub?.cancel();
    _eventSub = null;
    await _batches.close();
    _events.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  void _onEvent(dynamic message) {
    if (_batches.isClosed) return;
    if (message is! List) return;
    final lines = <LogcatLine>[];
    for (final item in message) {
      if (item is Map) {
        lines.add(
          LogcatLine.fromWire(Map<String, Object?>.from(item)),
        );
      }
    }
    if (lines.isNotEmpty) _batches.add(lines);
  }
}

const _shutdown = Object();

void _workerMain(SendPort handshake) {
  final inbox = ReceivePort();
  handshake.send(inbox.sendPort);

  SendPort? out;
  const decoder = Utf8Decoder(allowMalformed: true);
  var carry = '';
  final pending = <Map<String, Object?>>[];
  Timer? flushTimer;

  void flush() {
    flushTimer?.cancel();
    flushTimer = null;
    if (pending.isEmpty || out == null) return;
    out!.send(List<Map<String, Object?>>.of(pending));
    pending.clear();
  }

  void scheduleFlush() {
    if (pending.length >= 128) {
      flush();
      return;
    }
    flushTimer ??= Timer(const Duration(milliseconds: 16), flush);
  }

  inbox.listen((message) {
    if (identical(message, _shutdown)) {
      flush();
      inbox.close();
      return;
    }
    if (message is SendPort) {
      out = message;
      return;
    }
    if (message is! Uint8List) return;

    carry += decoder.convert(message);
    var start = 0;
    while (true) {
      final nl = carry.indexOf('\n', start);
      if (nl < 0) {
        carry = carry.substring(start);
        break;
      }
      var line = carry.substring(start, nl);
      start = nl + 1;
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.isEmpty) continue;
      pending.add(LogcatParser.parse(line).toWire());
      scheduleFlush();
    }
  });
}
