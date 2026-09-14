import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../diagnostics/app_log.dart';

/// Connection state reported by `adb devices`.
enum AdbDeviceState {
  device,
  offline,
  unauthorized,
  unknown,
}

AdbDeviceState parseAdbDeviceState(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'device':
      return AdbDeviceState.device;
    case 'offline':
      return AdbDeviceState.offline;
    case 'unauthorized':
      return AdbDeviceState.unauthorized;
    default:
      return AdbDeviceState.unknown;
  }
}

/// A phone (or emulator) attached to this PC.
class AdbDevice {
  const AdbDevice({
    required this.serial,
    required this.state,
    this.model,
    this.product,
  });

  final String serial;
  final AdbDeviceState state;
  final String? model;
  final String? product;

  bool get isReady => state == AdbDeviceState.device;

  String get displayName {
    final label = model?.trim();
    if (label != null && label.isNotEmpty) return label;
    final prod = product?.trim();
    if (prod != null && prod.isNotEmpty) return prod;
    return serial;
  }

  String get stateLabel {
    switch (state) {
      case AdbDeviceState.device:
        return 'online';
      case AdbDeviceState.offline:
        return 'offline';
      case AdbDeviceState.unauthorized:
        return 'unauthorized';
      case AdbDeviceState.unknown:
        return 'unknown';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AdbDevice &&
      other.serial == serial &&
      other.state == state &&
      other.model == model &&
      other.product == product;

  @override
  int get hashCode => Object.hash(serial, state, model, product);
}

class AdbException implements Exception {
  AdbException(this.message, {this.exitCode});

  final String message;
  final int? exitCode;

  @override
  String toString() =>
      exitCode == null ? message : '$message (exit $exitCode)';
}

/// Locates `adb` on PATH and wraps device list / shell / logcat.
class AdbClient {
  AdbClient();

  String? _adbPath;
  Future<String?>? _resolveInFlight;

  /// Resolved `adb` executable, or null when it is not on PATH.
  Future<String?> resolveExecutable() {
    return _resolveInFlight ??= _resolveExecutable();
  }

  Future<bool> isAvailable() async {
    final path = await resolveExecutable();
    if (path == null) return false;
    try {
      final result = await Process.run(
        path,
        const ['version'],
        runInShell: false,
      );
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }

  Future<List<AdbDevice>> listDevices() async {
    final path = await resolveExecutable();
    if (path == null) return const [];
    try {
      final result = await run(const ['devices', '-l']);
      if (result.exitCode != 0) {
        AppLog.w('adb', 'command failed: devices -l (exit ${result.exitCode})');
        return const [];
      }
      return parseDevicesOutput(result.stdout.toString());
    } on Object catch (err) {
      AppLog.w('adb', 'listDevices failed', err);
      return const [];
    }
  }

  /// Emits the current device list, then again whenever `adb track-devices`
  /// reports a change. Falls back to a 2s poll if tracking is unavailable.
  Stream<List<AdbDevice>> watchDevices({
    Duration pollInterval = const Duration(seconds: 2),
  }) {
    late StreamController<List<AdbDevice>> controller;
    Timer? poll;
    Process? tracker;
    Timer? debounce;
    var closed = false;
    var emitting = false;

    Future<void> emitList() async {
      if (closed || emitting) return;
      emitting = true;
      try {
        final devices = await listDevices();
        if (!closed && !controller.isClosed) {
          controller.add(devices);
        }
      } finally {
        emitting = false;
      }
    }

    void scheduleEmit() {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 120), emitList);
    }

    Future<Process?> startTracker() async {
      final path = await resolveExecutable();
      if (path == null || closed) return null;
      try {
        final process = await Process.start(
          path,
          const ['track-devices'],
          runInShell: false,
        );
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (_) => scheduleEmit(),
              onError: (_) {},
              onDone: () {
                if (closed) return;
                poll ??= Timer.periodic(pollInterval, (_) => emitList());
              },
            );
        process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((_) {}, onError: (_) {});
        return process;
      } on Object {
        return null;
      }
    }

    controller = StreamController<List<AdbDevice>>(
      onListen: () async {
        await emitList();
        tracker = await startTracker();
        if (tracker == null && !closed) {
          poll = Timer.periodic(pollInterval, (_) => emitList());
        }
      },
      onCancel: () async {
        closed = true;
        debounce?.cancel();
        poll?.cancel();
        tracker?.kill();
      },
    );

    return controller.stream;
  }

  Future<String> shell(String serial, String command) async {
    final parts = command
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    final result = await run(['shell', ...parts], serial: serial);
    final stdout = result.stdout.toString();
    final stderr = result.stderr.toString();
    if (result.exitCode != 0 && stdout.trim().isEmpty) {
      throw AdbException(
        stderr.trim().isEmpty ? 'adb shell failed' : stderr.trim(),
        exitCode: result.exitCode,
      );
    }
    return stdout;
  }

  /// Follows `adb -s SERIAL logcat -v threadtime`, optional `--pid=` / filters.
  Future<Process> startLogcat(
    String serial, {
    String? pid,
    List<String>? filters,
  }) async {
    final args = <String>[
      'logcat',
      '-v',
      'threadtime',
      if (pid != null && pid.trim().isNotEmpty) '--pid=${pid.trim()}',
      ...?filters,
    ];
    return start(args, serial: serial);
  }

  /// Starts adb with [args] (long-running shell, stdin config, pull streams).
  Future<Process> start(List<String> args, {String? serial}) {
    return _start(args, serial: serial);
  }

  Future<ProcessResult> run(List<String> args, {String? serial}) async {
    final path = await resolveExecutable();
    if (path == null) {
      AppLog.w('adb', 'command failed: adb not found on PATH');
      throw AdbException(
        'adb was not found on PATH. Install Android platform-tools.',
      );
    }
    try {
      final result = await Process.run(
        path,
        _withSerial(args, serial),
        runInShell: false,
      );
      if (result.exitCode != 0) {
        AppLog.w(
          'adb',
          'command failed: ${_withSerial(args, serial).join(' ')} '
          '(exit ${result.exitCode})',
        );
      }
      return result;
    } on ProcessException catch (err) {
      AppLog.w('adb', 'command failed: ${args.join(' ')}', err);
      throw AdbException(err.message);
    }
  }

  Future<Process> _start(List<String> args, {String? serial}) async {
    final path = await resolveExecutable();
    if (path == null) {
      AppLog.w('adb', 'command failed: adb not found on PATH');
      throw AdbException(
        'adb was not found on PATH. Install Android platform-tools.',
      );
    }
    try {
      return Process.start(
        path,
        _withSerial(args, serial),
        runInShell: false,
      );
    } on ProcessException catch (err) {
      AppLog.w('adb', 'command failed: ${args.join(' ')}', err);
      throw AdbException(err.message);
    }
  }

  List<String> _withSerial(List<String> args, String? serial) {
    if (serial == null || serial.isEmpty) return args;
    return ['-s', serial, ...args];
  }

  Future<String?> _resolveExecutable() async {
    if (_adbPath != null) return _adbPath;
    final fromWhere = await _lookupOnPath();
    if (fromWhere != null) {
      _adbPath = fromWhere;
      return _adbPath;
    }
    // Last try: `adb` itself if the OS can spawn it without a shell.
    try {
      final probe = await Process.run(
        'adb',
        const ['version'],
        runInShell: false,
      );
      if (probe.exitCode == 0) {
        _adbPath = 'adb';
        return _adbPath;
      }
    } on Object {
      // Missing from PATH — callers treat this as unavailable.
    }
    _resolveInFlight = null;
    return null;
  }

  Future<String?> _lookupOnPath() async {
    final tool = Platform.isWindows ? 'where' : 'which';
    try {
      final result = await Process.run(
        tool,
        const ['adb'],
        runInShell: false,
      );
      if (result.exitCode != 0) return null;
      final lines = const LineSplitter()
          .convert(result.stdout.toString())
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty);
      for (final line in lines) {
        if (line.toLowerCase().startsWith('info:')) continue;
        return line;
      }
    } on Object {
      return null;
    }
    return null;
  }
}

/// Parses `adb devices -l` stdout. Exposed for tests.
List<AdbDevice> parseDevicesOutput(String stdout) {
  final devices = <AdbDevice>[];
  for (final raw in const LineSplitter().convert(stdout)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('List of devices')) continue;
    if (line.startsWith('* ')) continue;
    final match = _deviceLine.firstMatch(line);
    if (match == null) continue;
    final serial = match.group(1)!;
    final state = parseAdbDeviceState(match.group(2)!);
    final rest = match.group(3) ?? '';
    String? model;
    String? product;
    for (final kv in _deviceProp.allMatches(rest)) {
      final key = kv.group(1);
      final value = kv.group(2);
      if (key == 'model') model = _humanizeModel(value);
      if (key == 'product') product = value;
    }
    devices.add(
      AdbDevice(
        serial: serial,
        state: state,
        model: model,
        product: product,
      ),
    );
  }
  return devices;
}

final _deviceLine = RegExp(r'^(\S+)\s+(\S+)(?:\s+(.*))?$');
final _deviceProp = RegExp(r'(\w+):(\S+)');

String? _humanizeModel(String? value) {
  if (value == null || value.isEmpty) return value;
  return value.replaceAll('_', ' ');
}
