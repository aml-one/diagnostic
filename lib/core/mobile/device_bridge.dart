import 'package:flutter/services.dart';

import '../adb/package_service.dart';
import '../app_version.dart';

class PhonePermissions {
  const PhonePermissions({
    required this.readLogs,
    required this.overlay,
    required this.notifications,
    required this.batteryUnrestricted,
    required this.xiaomi,
  });

  final bool readLogs;
  final bool overlay;
  final bool notifications;
  final bool batteryUnrestricted;
  final bool xiaomi;

  factory PhonePermissions.fromMap(Map<Object?, Object?> raw) {
    bool flag(String key) => raw[key] == true;
    return PhonePermissions(
      readLogs: flag('readLogs') || flag('appOpsReadLogs'),
      overlay: flag('overlay'),
      notifications: flag('notifications'),
      batteryUnrestricted: flag('batteryUnrestricted'),
      xiaomi: flag('xiaomi'),
    );
  }
}

class PhoneCaptureState {
  const PhoneCaptureState({
    this.running = false,
    this.recording = false,
    this.paused = false,
    this.path,
    this.packageName,
    this.pid,
  });

  final bool running;
  final bool recording;
  final bool paused;
  final String? path;
  final String? packageName;
  final int? pid;

  factory PhoneCaptureState.fromMap(Map<Object?, Object?>? raw) {
    if (raw == null) return const PhoneCaptureState();
    return PhoneCaptureState(
      running: raw['running'] == true,
      recording: raw['recording'] == true,
      paused: raw['paused'] == true,
      path: raw['path'] as String?,
      packageName: raw['packageName'] as String?,
      pid: raw['pid'] as int?,
    );
  }
}

class PhoneInstalledApp {
  const PhoneInstalledApp({
    required this.packageName,
    required this.label,
  });

  final String packageName;
  final String label;

  InstalledPackage get asInstalled =>
      InstalledPackage(packageName: packageName);
}

/// Method + event bridge to the Kotlin logcat engine.
class DeviceBridge {
  DeviceBridge({
    MethodChannel? methods,
    EventChannel? events,
  })  : _methods = methods ?? const MethodChannel(kDeviceChannel),
        _events = events ?? const EventChannel(kLogcatChannel);

  static const kDeviceChannel = 'one.aml.diagnostic/device';
  static const kLogcatChannel = 'one.aml.diagnostic/logcat';

  final MethodChannel _methods;
  final EventChannel _events;

  Stream<Map<Object?, Object?>> get events =>
      _events.receiveBroadcastStream().map((event) {
        if (event is Map) return event;
        return const <Object?, Object?>{};
      });

  Future<PhonePermissions> permissions() async {
    final raw = await _methods.invokeMethod<Map<Object?, Object?>>(
      'permissions',
    );
    return PhonePermissions.fromMap(raw ?? const {});
  }

  Future<void> openSettings(String which) {
    return _methods.invokeMethod<void>('openSettings', {'which': which});
  }

  Future<void> requestNotifications() {
    return _methods.invokeMethod<void>('requestNotifications');
  }

  Future<List<PhoneInstalledApp>> listPackages() async {
    final raw = await _methods.invokeMethod<List<Object?>>('listPackages');
    return (raw ?? const [])
        .whereType<Map>()
        .map(
          (row) => PhoneInstalledApp(
            packageName: '${row['packageName'] ?? ''}',
            label: '${row['label'] ?? ''}',
          ),
        )
        .where((app) => app.packageName.isNotEmpty)
        .toList(growable: false);
  }

  Future<int?> pidOf(String packageName) {
    return _methods.invokeMethod<int>('pidOf', {'packageName': packageName});
  }

  Future<PhoneCaptureState> startWatch({
    String? packageName,
    int? pid,
    String levels = 'VDIWEF',
    bool hideSpam = true,
  }) async {
    final raw = await _methods.invokeMethod<Map<Object?, Object?>>(
      'startWatch',
      {
        'packageName': packageName,
        'pid': pid,
        'levels': levels,
        'hideSpam': hideSpam,
        'toolVersion': kAppVersion,
      },
    );
    return PhoneCaptureState.fromMap(raw);
  }

  Future<void> stopWatch() {
    return _methods.invokeMethod<void>('stopWatch');
  }

  Future<PhoneCaptureState> setFilter({
    String? packageName,
    int? pid,
    String? levels,
    bool? hideSpam,
  }) async {
    final raw = await _methods.invokeMethod<Map<Object?, Object?>>(
      'setFilter',
      {
        'packageName': packageName,
        'pid': pid,
        'levels': levels,
        'hideSpam': hideSpam,
      },
    );
    return PhoneCaptureState.fromMap(raw);
  }

  Future<String?> startRecord({String? appLabel}) {
    return _methods.invokeMethod<String>('startRecord', {
      'toolVersion': kAppVersion,
      if (appLabel != null && appLabel.trim().isNotEmpty) 'appLabel': appLabel.trim(),
    });
  }

  Future<Map<String, String>> deviceIdentity() async {
    final raw = await _methods.invokeMethod<Map<Object?, Object?>>('deviceIdentity');
    if (raw == null) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.key != null && entry.value != null)
          '${entry.key}': '${entry.value}',
    };
  }

  Future<String> mdxDirectory() async {
    return await _methods.invokeMethod<String>('mdxDirectory') ?? '';
  }

  Future<PhoneCaptureState> pauseRecord() async {
    final raw = await _methods.invokeMethod<Map<Object?, Object?>>(
      'pauseRecord',
    );
    return PhoneCaptureState.fromMap(raw);
  }

  Future<PhoneCaptureState> resumeRecord() async {
    final raw = await _methods.invokeMethod<Map<Object?, Object?>>(
      'resumeRecord',
    );
    return PhoneCaptureState.fromMap(raw);
  }

  Future<String?> stopRecord() {
    return _methods.invokeMethod<String>('stopRecord');
  }

  Future<PhoneCaptureState> recordState() async {
    final raw = await _methods.invokeMethod<Map<Object?, Object?>>(
      'recordState',
    );
    return PhoneCaptureState.fromMap(raw);
  }

  Future<bool> showOverlay() async {
    return await _methods.invokeMethod<bool>('showOverlay') ?? false;
  }

  Future<void> hideOverlay() {
    return _methods.invokeMethod<void>('hideOverlay');
  }

  Future<void> shareMdx(String path, {String? packageName}) {
    return _methods.invokeMethod<void>('shareMdx', {
      'path': path,
      'packageName': packageName,
    });
  }

  Future<bool> isPackageInstalled(String packageName) async {
    return await _methods.invokeMethod<bool>('isPackageInstalled', {
          'packageName': packageName,
        }) ??
        false;
  }

  Future<String?> consumePendingMdx() {
    return _methods.invokeMethod<String>('consumePendingMdx');
  }

  /// Local `dumpsys <command>` (gfxinfo / meminfo / cpuinfo). Empty on failure.
  Future<String> dumpsys(String command) async {
    return await _methods.invokeMethod<String>('dumpsys', {
          'command': command,
        }) ??
        '';
  }

  /// Last Watch lines kept by the native logcat engine (not the Flutter list).
  Future<List<String>> snapshotLogs() async {
    final raw = await _methods.invokeMethod<List<Object?>>('snapshotLogs');
    return _stringList(raw);
  }

  /// Fresh `logcat -d` dump for Diagnose / Refresh.
  Future<List<String>> dumpLogcat({int maxLines = 4000}) async {
    final raw = await _methods.invokeMethod<List<Object?>>('dumpLogcat', {
      'maxLines': maxLines,
    });
    return _stringList(raw);
  }

  /// Unfiltered main + crash buffers for the Android self-check.
  Future<SelfCheckDump> selfCheckDump({int maxLines = 4000}) async {
    final raw = await _methods.invokeMethod<Map<Object?, Object?>>(
      'selfCheckDump',
      {'maxLines': maxLines},
    );
    final pid = raw?['pid'];
    final linesRaw = raw?['lines'];
    return SelfCheckDump(
      pid: pid is int ? pid : 0,
      lines: _stringList(linesRaw is List ? List<Object?>.from(linesRaw) : null),
    );
  }

  static List<String> _stringList(List<Object?>? raw) {
    if (raw == null || raw.isEmpty) return const [];
    return [
      for (final item in raw)
        if (item is String && item.isNotEmpty) item,
    ];
  }
}

class SelfCheckDump {
  const SelfCheckDump({required this.pid, required this.lines});

  final int pid;
  final List<String> lines;
}

final deviceBridge = DeviceBridge();
