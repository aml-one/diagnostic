import 'dart:convert';

import '../diagnostics/app_log.dart';
import 'adb_client.dart';

/// Third-party (or all) package installed on a device.
class InstalledPackage {
  const InstalledPackage({
    required this.packageName,
    this.apkPath,
  });

  final String packageName;
  final String? apkPath;

  /// Last dotted segment, e.g. `messageme` from `one.aml.messageme`.
  String get shortName {
    final i = packageName.lastIndexOf('.');
    if (i < 0 || i == packageName.length - 1) return packageName;
    return packageName.substring(i + 1);
  }

  @override
  bool operator ==(Object other) =>
      other is InstalledPackage &&
      other.packageName == packageName &&
      other.apkPath == apkPath;

  @override
  int get hashCode => Object.hash(packageName, apkPath);
}

/// Result of `am start -S -W`.
class AppLaunchResult {
  const AppLaunchResult({
    required this.packageName,
    this.component,
    this.pid,
    this.thisTimeMs,
    this.totalTimeMs,
    this.waitTimeMs,
    this.launchState,
    this.rawOutput = '',
  });

  final String packageName;
  final String? component;
  final int? pid;
  final int? thisTimeMs;
  final int? totalTimeMs;
  final int? waitTimeMs;
  final String? launchState;
  final String rawOutput;

  Duration? get thisTime =>
      thisTimeMs == null ? null : Duration(milliseconds: thisTimeMs!);
  Duration? get totalTime =>
      totalTimeMs == null ? null : Duration(milliseconds: totalTimeMs!);
  Duration? get waitTime =>
      waitTimeMs == null ? null : Duration(milliseconds: waitTimeMs!);
}

final _packageNameRe = RegExp(
  r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
);

bool isValidAndroidPackageName(String name) =>
    _packageNameRe.hasMatch(name.trim());

/// Lists, resolves, and starts apps through [AdbClient.shell] / [AdbClient.run].
class PackageService {
  PackageService(this._client);

  final AdbClient _client;

  Future<List<InstalledPackage>> listPackages(
    String serial, {
    bool thirdPartyOnly = true,
  }) async {
    final flags = thirdPartyOnly ? '-3 -f' : '-f';
    final stdout = await _client.shell(serial, 'pm list packages $flags');
    final packages = parsePackageList(stdout);
    packages.sort(
      (a, b) => a.packageName.toLowerCase().compareTo(b.packageName.toLowerCase()),
    );
    return packages;
  }

  Future<String?> resolveLaunchActivity(
    String serial,
    String packageName,
  ) async {
    _requirePackage(packageName);
    try {
      final brief = await _client.shell(
        serial,
        'cmd package resolve-activity --brief $packageName',
      );
      final fromBrief = parseResolveActivityBrief(brief, packageName);
      if (fromBrief != null) return fromBrief;
    } on AdbException catch (err) {
      AppLog.w(
        'package',
        'resolve-activity failed for $packageName',
        err,
      );
    }
    try {
      final dump = await _client.shell(serial, 'dumpsys package $packageName');
      return parseLaunchActivityFromDumpsys(dump, packageName);
    } on AdbException catch (err) {
      AppLog.w(
        'package',
        'could not resolve launch activity for $packageName',
        err,
      );
      return null;
    }
  }

  /// Force-stops, starts the launcher activity, waits, then reads PID.
  Future<AppLaunchResult> startApp(String serial, String packageName) async {
    _requirePackage(packageName);
    final activity = await resolveLaunchActivity(serial, packageName);
    final component = activity == null
        ? null
        : normalizeComponent(packageName, activity);

    String stdout;
    try {
      if (component != null) {
        stdout = await _client
            .shell(serial, 'am start -S -W -n $component')
            .timeout(const Duration(seconds: 30));
      } else {
        stdout = await _client
            .shell(
              serial,
              'am start -S -W -a android.intent.action.MAIN '
              '-c android.intent.category.LAUNCHER -p $packageName',
            )
            .timeout(const Duration(seconds: 30));
      }
    } catch (_) {
      try {
        stdout = await _client
            .shell(
              serial,
              'monkey -p $packageName -c android.intent.category.LAUNCHER '
              '--pct-syskeys 0 1',
            )
            .timeout(const Duration(seconds: 20));
      } catch (err) {
        AppLog.e('package', 'could not start $packageName', err);
        throw AdbException('Could not start $packageName. $err');
      }
    }

    final timing = parseAmStartWait(stdout);
    var pid = await pidOf(serial, packageName);
    if (pid == null) {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        pid = await pidOf(serial, packageName);
        if (pid != null) break;
      }
    }
    if (pid == null) {
      AppLog.w('package', 'could not find PID for $packageName');
    }

    return AppLaunchResult(
      packageName: packageName,
      component: component ??
          timing.component ??
          parseComponentFromMonkey(stdout, packageName),
      pid: pid,
      thisTimeMs: timing.thisTimeMs,
      totalTimeMs: timing.totalTimeMs,
      waitTimeMs: timing.waitTimeMs,
      launchState: timing.launchState,
      rawOutput: stdout,
    );
  }

  Future<int?> pidOf(String serial, String packageName) async {
    _requirePackage(packageName);
    try {
      final out = await _client.shell(serial, 'pidof $packageName');
      final pid = parsePidof(out);
      if (pid != null) return pid;
    } on AdbException {
      // pidof missing or no process.
    }
    try {
      final out = await _client.shell(serial, 'pidof -s $packageName');
      final pid = parsePidof(out);
      if (pid != null) return pid;
    } on AdbException {
      // Continue.
    }
    try {
      final out = await _client.shell(serial, 'ps -A');
      return parsePidFromPs(out, packageName);
    } on AdbException {
      return null;
    }
  }

  void _requirePackage(String packageName) {
    if (!isValidAndroidPackageName(packageName)) {
      throw AdbException('Invalid package name: $packageName');
    }
  }
}

/// Parses `pm list packages` / `pm list packages -f` stdout.
List<InstalledPackage> parsePackageList(String stdout) {
  final out = <InstalledPackage>[];
  final seen = <String>{};
  for (final raw in const LineSplitter().convert(stdout)) {
    final parsed = parsePackageLine(raw.trim());
    if (parsed == null) continue;
    if (!isValidAndroidPackageName(parsed.packageName)) continue;
    if (!seen.add(parsed.packageName)) continue;
    out.add(parsed);
  }
  return out;
}

InstalledPackage? parsePackageLine(String line) {
  const prefix = 'package:';
  if (!line.startsWith(prefix)) return null;
  final rest = line.substring(prefix.length).trim();
  if (rest.isEmpty) return null;
  final eq = rest.lastIndexOf('=');
  if (eq > 0) {
    return InstalledPackage(
      packageName: rest.substring(eq + 1).trim(),
      apkPath: rest.substring(0, eq).trim(),
    );
  }
  return InstalledPackage(packageName: rest);
}

/// Parses `cmd package resolve-activity --brief`.
String? parseResolveActivityBrief(String stdout, String packageName) {
  for (final raw in const LineSplitter().convert(stdout)) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    final lower = trimmed.toLowerCase();
    if (lower.contains('no activity')) return null;
    if (trimmed.contains('priority=') || trimmed.contains('preferredOrder=')) {
      continue;
    }
    if (!trimmed.contains('/')) continue;
    final token = trimmed
        .split(RegExp(r'\s+'))
        .firstWhere((part) => part.contains('/'), orElse: () => trimmed);
    final cleaned = token.replaceAll(RegExp(r'[,"]+$'), '');
    return normalizeComponent(packageName, cleaned);
  }
  return null;
}

/// Finds the MAIN/LAUNCHER activity in `dumpsys package` output.
String? parseLaunchActivityFromDumpsys(String stdout, String packageName) {
  final componentRe = RegExp('${RegExp.escape(packageName)}/\\S+');
  String? lastComponent;
  String? launcherComponent;
  for (final raw in const LineSplitter().convert(stdout)) {
    final match = componentRe.firstMatch(raw);
    if (match != null) {
      lastComponent = normalizeComponent(
        packageName,
        match.group(0)!.split(RegExp(r'[\s{},]')).first,
      );
    }
    if (raw.contains('android.intent.category.LAUNCHER') &&
        lastComponent != null) {
      launcherComponent = lastComponent;
      break;
    }
  }
  return launcherComponent ?? lastComponent;
}

String? parseComponentFromMonkey(String stdout, String packageName) {
  final cmp = RegExp(
    'cmp=([^\\s}]+)',
    caseSensitive: false,
  ).firstMatch(stdout);
  if (cmp == null) return null;
  return normalizeComponent(packageName, cmp.group(1)!);
}

class AmStartWait {
  const AmStartWait({
    this.thisTimeMs,
    this.totalTimeMs,
    this.waitTimeMs,
    this.launchState,
    this.component,
    this.status,
  });

  final int? thisTimeMs;
  final int? totalTimeMs;
  final int? waitTimeMs;
  final String? launchState;
  final String? component;
  final String? status;
}

AmStartWait parseAmStartWait(String stdout) {
  int? thisTime;
  int? totalTime;
  int? waitTime;
  String? launchState;
  String? component;
  String? status;
  for (final raw in const LineSplitter().convert(stdout)) {
    final line = raw.trim();
    thisTime ??= _intAfter(line, 'ThisTime:');
    totalTime ??= _intAfter(line, 'TotalTime:');
    waitTime ??= _intAfter(line, 'WaitTime:');
    if (line.startsWith('LaunchState:')) {
      launchState = line.substring('LaunchState:'.length).trim();
    } else if (line.startsWith('Status:')) {
      status = line.substring('Status:'.length).trim();
    } else if (line.startsWith('Activity:')) {
      component = line.substring('Activity:'.length).trim();
    } else {
      final cmp = RegExp(r'cmp=([^\s}]+)').firstMatch(line);
      if (cmp != null) component ??= cmp.group(1);
    }
  }
  return AmStartWait(
    thisTimeMs: thisTime,
    totalTimeMs: totalTime,
    waitTimeMs: waitTime,
    launchState: launchState,
    component: component,
    status: status,
  );
}

int? parsePidof(String stdout) {
  for (final raw in const LineSplitter().convert(stdout)) {
    for (final part in raw.trim().split(RegExp(r'\s+'))) {
      final pid = int.tryParse(part);
      if (pid != null && pid > 0) return pid;
    }
  }
  return null;
}

int? parsePidFromPs(String stdout, String packageName) {
  for (final raw in const LineSplitter().convert(stdout)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.contains('PID') && (line.contains('NAME') || line.contains('USER'))) {
      continue;
    }
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final name = parts.last;
    if (name != packageName) continue;
    final pid = int.tryParse(parts.length > 1 ? parts[1] : '');
    if (pid != null && pid > 0) return pid;
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n != null && n > 1) return n;
    }
  }
  return null;
}

String normalizeComponent(String packageName, String activity) {
  var value = activity.trim();
  if (value.startsWith('cmp=')) value = value.substring(4);
  value = value.replaceAll(RegExp(r'[,"}]+$'), '');
  if (value.startsWith('.')) return '$packageName/$value';
  if (value.startsWith('/')) return '$packageName$value';
  if (!value.contains('/')) return '$packageName/$value';
  return value;
}

int? _intAfter(String line, String label) {
  if (!line.startsWith(label)) return null;
  return int.tryParse(line.substring(label.length).trim());
}
