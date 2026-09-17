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

/// Thrown when [AdbCancelToken.cancel] stops a tracked `adb` process.
class AdbCancelled implements Exception {
  const AdbCancelled();

  @override
  String toString() => 'Cancelled';
}

/// Kills in-flight [AdbClient.runTracked] / attached [Process] jobs.
class AdbCancelToken {
  final _processes = <Process>[];
  var isCancelled = false;

  void attach(Process process) {
    _processes.add(process);
    if (isCancelled) killAdbProcess(process);
  }

  void cancel() {
    isCancelled = true;
    final list = List<Process>.from(_processes);
    _processes.clear();
    for (final process in list) {
      killAdbProcess(process);
    }
  }
}

/// Stops a local `adb` client. Windows uses a process-tree kill so
/// `adb bugreport` children die instead of finishing in the background.
void killAdbProcess(Process process) {
  try {
    if (Platform.isWindows) {
      Process.runSync(
        'taskkill',
        ['/PID', '${process.pid}', '/T', '/F'],
        runInShell: false,
      );
      return;
    }
    process.kill();
  } on Object {
    try {
      process.kill();
    } on Object {
      // Already gone.
    }
  }
}

/// Where [AdbClient] found the `adb` binary.
enum AdbSource { env, bundled, path, sdk }

/// Locates bundled / PATH / SDK `adb` and wraps device list / shell / logcat.
class AdbClient {
  AdbClient();

  String? _adbPath;
  AdbSource? _adbSource;
  Future<String?>? _resolveInFlight;

  /// Which discovery path produced [resolveExecutable], once resolved.
  AdbSource? get resolvedSource => _adbSource;

  /// Resolved `adb` executable, or null when none is available.
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

  Future<String> shell(
    String serial,
    String command, {
    AdbCancelToken? cancel,
  }) async {
    final parts = command
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    final result = await runTracked(
      ['shell', ...parts],
      serial: serial,
      cancel: cancel,
    );
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
  ///
  /// [tailCount] maps to `logcat -T N`: dump the last N lines then keep
  /// following. Caps the initial backlog so Watch does not freeze the UI
  /// while parsing tens of thousands of historical lines on Windows.
  Future<Process> startLogcat(
    String serial, {
    String? pid,
    List<String>? filters,
    int tailCount = 2000,
  }) async {
    final args = <String>[
      'logcat',
      '-v',
      'threadtime',
      if (tailCount > 0) ...['-T', '$tailCount'],
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
    return runTracked(args, serial: serial);
  }

  /// Like [run], but [cancel] can kill the process instead of waiting it out.
  Future<ProcessResult> runTracked(
    List<String> args, {
    String? serial,
    AdbCancelToken? cancel,
  }) async {
    if (cancel?.isCancelled == true) throw const AdbCancelled();
    final path = await resolveExecutable();
    if (path == null) {
      AppLog.w('adb', 'command failed: adb not found');
      throw AdbException(
        'adb was not found. Reinstall AmL Diagnostic or set AML_ADB to an adb binary.',
      );
    }
    try {
      if (cancel == null) {
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
      }
      final process = await Process.start(
        path,
        _withSerial(args, serial),
        runInShell: false,
      );
      cancel.attach(process);
      final stdout = StringBuffer();
      final stderr = StringBuffer();
      final outDone = process.stdout
          .transform(utf8.decoder)
          .listen(stdout.write, onError: (_) {})
          .asFuture<void>();
      final errDone = process.stderr
          .transform(utf8.decoder)
          .listen(stderr.write, onError: (_) {})
          .asFuture<void>();
      if (cancel.isCancelled) {
        killAdbProcess(process);
        await process.exitCode;
        throw const AdbCancelled();
      }
      final code = await process.exitCode;
      try {
        await outDone;
        await errDone;
      } on Object {
        if (cancel.isCancelled) throw const AdbCancelled();
        rethrow;
      }
      if (cancel.isCancelled) throw const AdbCancelled();
      if (code != 0) {
        AppLog.w(
          'adb',
          'command failed: ${_withSerial(args, serial).join(' ')} '
          '(exit $code)',
        );
      }
      return ProcessResult(process.pid, code, stdout.toString(), stderr.toString());
    } on AdbCancelled {
      rethrow;
    } on ProcessException catch (err) {
      AppLog.w('adb', 'command failed: ${args.join(' ')}', err);
      throw AdbException(err.message);
    }
  }

  Future<Process> _start(List<String> args, {String? serial}) async {
    final path = await resolveExecutable();
    if (path == null) {
      AppLog.w('adb', 'command failed: adb not found');
      throw AdbException(
        'adb was not found. Reinstall AmL Diagnostic or set AML_ADB to an adb binary.',
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

    final fromEnv = _fromEnvOverride();
    if (fromEnv != null) {
      _adbPath = fromEnv;
      _adbSource = AdbSource.env;
      AppLog.i('adb', 'using env override: $fromEnv');
      return _adbPath;
    }

    final bundled = _bundledAdbPath();
    if (bundled != null) {
      _adbPath = bundled;
      _adbSource = AdbSource.bundled;
      AppLog.i('adb', 'using bundled: $bundled');
      return _adbPath;
    }

    final fromPath = await _lookupOnPath();
    if (fromPath != null) {
      _adbPath = fromPath;
      _adbSource = AdbSource.path;
      AppLog.i('adb', 'using PATH: $fromPath');
      return _adbPath;
    }

    final fromSdk = _fromAndroidSdk();
    if (fromSdk != null) {
      _adbPath = fromSdk;
      _adbSource = AdbSource.sdk;
      AppLog.i('adb', 'using Android SDK: $fromSdk');
      return _adbPath;
    }

    // Last try: bare `adb` if the OS can spawn it without a full path.
    try {
      final probe = await Process.run(
        'adb',
        const ['version'],
        runInShell: false,
      );
      if (probe.exitCode == 0) {
        _adbPath = 'adb';
        _adbSource = AdbSource.path;
        AppLog.i('adb', 'using bare adb on PATH');
        return _adbPath;
      }
    } on Object {
      // Missing — callers treat as unavailable.
    }

    _resolveInFlight = null;
    return null;
  }

  /// `AML_ADB` (preferred) or `ADB` absolute path override.
  String? _fromEnvOverride() {
    for (final key in const ['AML_ADB', 'ADB']) {
      final raw = Platform.environment[key]?.trim();
      if (raw == null || raw.isEmpty) continue;
      // `ADB` is sometimes set to a directory in older setups.
      final asFile = File(raw);
      if (asFile.existsSync() && !_looksLikeDirectory(raw)) {
        return asFile.path;
      }
      final nested = File(
        raw.endsWith(Platform.pathSeparator)
            ? '${raw}adb${Platform.isWindows ? '.exe' : ''}'
            : '$raw${Platform.pathSeparator}adb${Platform.isWindows ? '.exe' : ''}',
      );
      if (nested.existsSync()) return nested.path;
    }
    return null;
  }

  bool _looksLikeDirectory(String path) {
    try {
      return FileSystemEntity.isDirectorySync(path);
    } on Object {
      return false;
    }
  }

  /// `<exeDir>/platform-tools/adb[.exe]` shipped next to the app.
  String? _bundledAdbPath() {
    final exeName = Platform.isWindows ? 'adb.exe' : 'adb';
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = <String>[
      '${exeDir.path}${Platform.pathSeparator}platform-tools'
          '${Platform.pathSeparator}$exeName',
    ];
    // macOS .app: also check Contents/Resources/platform-tools
    if (Platform.isMacOS) {
      final contents = exeDir.parent; // Contents
      candidates.add(
        '${contents.path}${Platform.pathSeparator}Resources'
            '${Platform.pathSeparator}platform-tools'
            '${Platform.pathSeparator}$exeName',
      );
    }
    for (final path in candidates) {
      final file = File(path);
      if (file.existsSync()) return file.path;
    }
    return null;
  }

  String? _fromAndroidSdk() {
    final exeName = Platform.isWindows ? 'adb.exe' : 'adb';
    for (final key in const ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
      final root = Platform.environment[key]?.trim();
      if (root == null || root.isEmpty) continue;
      final candidate = File(
        '$root${Platform.pathSeparator}platform-tools'
        '${Platform.pathSeparator}$exeName',
      );
      if (candidate.existsSync()) return candidate.path;
    }
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
