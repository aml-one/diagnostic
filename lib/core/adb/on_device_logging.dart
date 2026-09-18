import '../mobile/phone_diagnostic.dart';
import 'adb_client.dart';

enum OnDeviceLoggingStatus { granted, notInstalled, missing, failed }

class OnDeviceLoggingSnapshot {
  const OnDeviceLoggingSnapshot({
    required this.status,
    this.detail = '',
  });

  final OnDeviceLoggingStatus status;
  final String detail;

  bool get isGranted => status == OnDeviceLoggingStatus.granted;

  String get label {
    switch (status) {
      case OnDeviceLoggingStatus.granted:
        return 'Granted';
      case OnDeviceLoggingStatus.notInstalled:
        return 'Not installed';
      case OnDeviceLoggingStatus.missing:
        return 'Missing';
      case OnDeviceLoggingStatus.failed:
        return 'Failed';
    }
  }
}

bool parsePackageInstalledFromPmPath(String stdout) {
  final text = stdout.trim();
  if (text.isEmpty) return false;
  return text.contains('package:') || text.startsWith('/');
}

/// True when `dumpsys package` shows `READ_LOGS` as granted.
bool parseReadLogsGranted(String dumpsys) {
  if (RegExp(
    r'android\.permission\.READ_LOGS:\s*granted=true',
  ).hasMatch(dumpsys)) {
    return true;
  }
  final start = dumpsys.indexOf('grantedPermissions:');
  if (start < 0) return false;
  final slice = dumpsys.substring(start);
  return RegExp(
    r'(^|\s)android\.permission\.READ_LOGS\b',
    multiLine: true,
  ).hasMatch(slice);
}

/// Desktop helper: detect the phone APK and `pm grant READ_LOGS`.
class OnDeviceLoggingService {
  OnDeviceLoggingService(this._adb);

  final AdbClient _adb;

  Future<OnDeviceLoggingSnapshot> inspect(String serial) async {
    try {
      final path = await _adb.shell(
        serial,
        'pm path $kDiagnosticAndroidPackage',
      );
      if (!parsePackageInstalledFromPmPath(path)) {
        return const OnDeviceLoggingSnapshot(
          status: OnDeviceLoggingStatus.notInstalled,
          detail: 'Install Diagnostic on the phone first.',
        );
      }
    } on AdbException {
      return const OnDeviceLoggingSnapshot(
        status: OnDeviceLoggingStatus.notInstalled,
        detail: 'Install Diagnostic on the phone first.',
      );
    }

    try {
      final dump = await _adb.shell(
        serial,
        'dumpsys package $kDiagnosticAndroidPackage',
      );
      if (parseReadLogsGranted(dump)) {
        return const OnDeviceLoggingSnapshot(
          status: OnDeviceLoggingStatus.granted,
          detail: 'Phone Diagnostic can Watch other apps.',
        );
      }
      return const OnDeviceLoggingSnapshot(
        status: OnDeviceLoggingStatus.missing,
        detail: 'Tap Allow on-device logging.',
      );
    } on AdbException catch (err) {
      return OnDeviceLoggingSnapshot(
        status: OnDeviceLoggingStatus.failed,
        detail: err.message,
      );
    }
  }

  Future<OnDeviceLoggingSnapshot> grant(String serial) async {
    final before = await inspect(serial);
    if (before.status == OnDeviceLoggingStatus.notInstalled) return before;

    try {
      await _adb.shell(
        serial,
        'pm grant $kDiagnosticAndroidPackage $kReadLogsPermission',
      );
    } on AdbException catch (err) {
      return OnDeviceLoggingSnapshot(
        status: OnDeviceLoggingStatus.failed,
        detail: err.message,
      );
    }

    for (final op in kDeviceLogAppOps) {
      try {
        await _adb.shell(
          serial,
          'cmd appops set $kDiagnosticAndroidPackage $op allow',
        );
      } on AdbException {
        // Optional on OEM builds that still honor pm grant alone.
      }
    }

    final after = await inspect(serial);
    if (after.isGranted) return after;
    if (after.status == OnDeviceLoggingStatus.missing) {
      return const OnDeviceLoggingSnapshot(
        status: OnDeviceLoggingStatus.failed,
        detail: 'Grant ran but READ_LOGS is still missing.',
      );
    }
    return after;
  }
}
