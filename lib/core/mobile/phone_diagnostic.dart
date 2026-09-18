import 'dart:io';

import 'package:flutter/foundation.dart';

/// On-device Diagnostic (same product as desktop). Widget tests stay desktop.
bool get kIsPhoneDiagnostic => !kIsWeb && Platform.isAndroid;

const kDiagnosticAndroidPackage = 'one.aml.diagnostic';

const kMessageMeAndroidPackage = 'one.aml.messageme';

/// Studio clients that can sit next to MessageMe on the same phone.
const kAppBuilderAndroidPackages = [
  'one.aml.appbuilder.v4',
  'one.aml.appbuilder2',
];

/// Diagnose serial when Watch is running on the phone itself (no ADB).
const kOnDeviceSerial = 'This phone';

const kReadLogsPermission = 'android.permission.READ_LOGS';

const kPmGrantReadLogsCommand =
    'adb shell pm grant $kDiagnosticAndroidPackage $kReadLogsPermission && '
    'adb shell cmd appops set $kDiagnosticAndroidPackage 10017 allow && '
    'adb shell cmd appops set $kDiagnosticAndroidPackage 114 allow';

/// AppOps that skip Android's "access all device logs?" one-time dialog.
/// Named ops are AOSP; `114` is `OP_READ_DEVICE_LOGS`; `10017` is HyperOS
/// `MIUIOP(10017)` (mode `ask` by default — that is the one-time dialog).
const kDeviceLogAppOps = [
  'READ_LOGS',
  'READ_DEVICE_LOGS',
  'android:read_device_logs',
  '114',
  '10017',
];

const kMdxMagic = 'MDX1';
const kMdxMimeType = 'application/x-aml-mdx';
const kMdxExtension = 'mdx';

const kMdxdMagic = 'MDXD1';
const kMdxdMimeType = 'application/x-aml-mdxd';
const kMdxdExtension = 'mdxd';

bool isMdxCapturePath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.$kMdxExtension') ||
      lower.endsWith('.$kMdxdExtension');
}

String mimeForMdxPath(String path) {
  return path.toLowerCase().endsWith('.$kMdxdExtension')
      ? kMdxdMimeType
      : kMdxMimeType;
}
