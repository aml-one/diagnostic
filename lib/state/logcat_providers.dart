import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logcat/anr_detector.dart';
import '../core/logcat/logcat_session.dart';
import 'adb_providers.dart';

class LogcatSessionView {
  const LogcatSessionView({
    this.connection = LogcatConnectionState.idle,
    this.serial,
    this.errorMessage,
    this.anrCount = 0,
    this.recentAnrs = const [],
  });

  final LogcatConnectionState connection;
  final String? serial;
  final String? errorMessage;
  final int anrCount;
  final List<AnrEvent> recentAnrs;

  bool get isWatching =>
      connection == LogcatConnectionState.watching ||
      connection == LogcatConnectionState.starting;
}

class LogcatSessionController extends Notifier<LogcatSessionView> {
  LogcatSession? _session;
  StreamSubscription<AnrEvent>? _anrSub;
  StreamSubscription<LogcatConnectionState>? _stateSub;
  var _disposed = false;

  LogcatSession? get session => _session;

  @override
  LogcatSessionView build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      unawaited(_tearDown());
    });
    return const LogcatSessionView();
  }

  Future<void> watchDevice(String serial) async {
    await _tearDown();
    final session = LogcatSession(client: ref.read(adbClientProvider));
    _session = session;
    state = LogcatSessionView(
      connection: LogcatConnectionState.starting,
      serial: serial,
    );
    _anrSub = session.anrEvents.listen((event) {
      if (_disposed) return;
      final recent = [...state.recentAnrs, event];
      if (recent.length > 20) {
        recent.removeRange(0, recent.length - 20);
      }
      state = LogcatSessionView(
        connection: session.connectionState,
        serial: session.serial,
        errorMessage: session.errorMessage,
        anrCount: state.anrCount + 1,
        recentAnrs: recent,
      );
    });
    _stateSub = session.connectionStates.listen((connection) {
      if (_disposed) return;
      state = LogcatSessionView(
        connection: connection,
        serial: session.serial,
        errorMessage: session.errorMessage,
        anrCount: state.anrCount,
        recentAnrs: state.recentAnrs,
      );
    });
    await session.start(serial);
  }

  Future<void> stop() => _tearDown();

  Future<void> _tearDown() async {
    await _anrSub?.cancel();
    await _stateSub?.cancel();
    _anrSub = null;
    _stateSub = null;
    final session = _session;
    _session = null;
    if (session != null) {
      await session.dispose();
    }
    if (_disposed) return;
    state = LogcatSessionView(
      connection: LogcatConnectionState.idle,
      anrCount: state.anrCount,
      recentAnrs: state.recentAnrs,
    );
  }
}

final logcatSessionProvider =
    NotifierProvider<LogcatSessionController, LogcatSessionView>(
      LogcatSessionController.new,
    );
