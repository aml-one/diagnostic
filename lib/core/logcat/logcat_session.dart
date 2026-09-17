import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../adb/adb_client.dart';
import '../diagnostics/app_log.dart';
import 'anr_detector.dart';
import 'logcat_parse_isolate.dart';
import 'logcat_parser.dart';

enum LogcatConnectionState { idle, starting, watching, stopped, error }

/// Live logcat for one device: parsed lines, ANR events, connection state.
///
/// Decode + line parse run on a background isolate so a large adb backlog
/// cannot stall the Flutter UI thread (Windows Watch freeze).
class LogcatSession {
  LogcatSession({
    AdbClient? client,
    AnrDetector? detector,
  })  : _client = client ?? AdbClient(),
        detector = detector ?? AnrDetector();

  final AdbClient _client;
  final AnrDetector detector;

  final _lines = StreamController<LogcatLine>.broadcast();
  final _anrs = StreamController<AnrEvent>.broadcast();
  final _states = StreamController<LogcatConnectionState>.broadcast();

  Process? _process;
  LogcatParseIsolate? _parser;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<LogcatLine>>? _batchSub;
  StreamSubscription<String>? _stderrSub;
  String? _serial;
  String? _errorMessage;
  LogcatConnectionState _state = LogcatConnectionState.idle;

  Stream<LogcatLine> get lines => _lines.stream;
  Stream<AnrEvent> get anrEvents => _anrs.stream;
  Stream<LogcatConnectionState> get connectionStates => _states.stream;
  LogcatConnectionState get connectionState => _state;
  String? get serial => _serial;
  String? get errorMessage => _errorMessage;
  List<LogcatLine> get recentBuffer => detector.recentBuffer;

  Future<void> start(
    String serial, {
    String? pid,
    List<String>? filters,
  }) async {
    await stop();
    _serial = serial;
    _errorMessage = null;
    _setState(LogcatConnectionState.starting);
    AppLog.i(
      'logcat',
      'session start serial=$serial pid=${pid ?? 'all'}',
    );
    try {
      final parser = await LogcatParseIsolate.spawn();
      _parser = parser;
      _batchSub = parser.batches.listen(
        _onBatch,
        onError: (Object err) => _fail('$err'),
      );

      final process = await _client.startLogcat(
        serial,
        pid: pid,
        filters: filters,
      );
      _process = process;
      _setState(LogcatConnectionState.watching);

      _stdoutSub = process.stdout.listen(
        parser.addBytes,
        onError: (Object err) => _fail('$err'),
        onDone: () {
          if (_state == LogcatConnectionState.watching) {
            _setState(LogcatConnectionState.stopped);
          }
        },
        cancelOnError: false,
      );

      // Stderr stays light; no parse isolate needed.
      _stderrSub = process.stderr
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final trimmed = line.trim();
            if (trimmed.isEmpty) return;
            if (trimmed.toLowerCase().contains('error')) {
              _fail(trimmed);
            }
          }, onError: (_) {});

      unawaited(
        process.exitCode.then((code) {
          if (_process != process) return;
          if (_state == LogcatConnectionState.watching && code != 0) {
            _fail('logcat exited ($code)');
          } else if (_state == LogcatConnectionState.watching) {
            _setState(LogcatConnectionState.stopped);
          }
        }),
      );
    } on AdbException catch (err) {
      _fail(err.message);
    } on Object catch (err) {
      _fail('$err');
    }
  }

  Future<void> stop() async {
    await _stdoutSub?.cancel();
    await _batchSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _batchSub = null;
    _stderrSub = null;

    final parser = _parser;
    _parser = null;
    if (parser != null) {
      await parser.close();
    }

    final process = _process;
    _process = null;
    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on Object {
        // Best-effort; Windows may already have torn the pipe down.
      }
    }
    final flushed = detector.flush();
    if (flushed != null && !_anrs.isClosed) _anrs.add(flushed);
    if (_state == LogcatConnectionState.watching ||
        _state == LogcatConnectionState.starting) {
      AppLog.i('logcat', 'session stop serial=$_serial');
      _setState(LogcatConnectionState.stopped);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _lines.close();
    await _anrs.close();
    await _states.close();
  }

  /// Apply a parsed batch on the UI isolate without monopolizing it.
  ///
  /// Decode/parse already ran in [LogcatParseIsolate]; ANR detection stays
  /// here so it can share [detector.recentBuffer] with Diagnose. Chunk + yield
  /// so a 2k-line `-T` dump cannot freeze Windows for seconds.
  void _onBatch(List<LogcatLine> batch) {
    if (batch.isEmpty) return;
    unawaited(_applyBatch(batch));
  }

  Future<void> _applyBatch(List<LogcatLine> batch) async {
    const chunkSize = 48;
    for (var i = 0; i < batch.length; i++) {
      final line = batch[i];
      if (!_lines.isClosed) _lines.add(line);
      final event = detector.add(line);
      if (event != null && !_anrs.isClosed) _anrs.add(event);
      if (i > 0 && i % chunkSize == 0) {
        await Future<void>.delayed(Duration.zero);
        if (_lines.isClosed) return;
      }
    }
  }

  void _fail(String message) {
    _errorMessage = message;
    AppLog.e('logcat', 'stream error: $message');
    _setState(LogcatConnectionState.error);
  }

  void _setState(LogcatConnectionState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}
