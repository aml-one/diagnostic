import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/settings_store.dart';
import '../diagnostics/app_log.dart';
import '../mobile/phone_diagnostic.dart';
import 'field_report_client.dart';

/// Uploads a saved `.mdx` / `.mdxd` without opening the share sheet.
///
/// ColorOS ANRs on the MessageMe / system share path. Server upload is the
/// default so every Watch, Diagnose, and self-check lands in field reports.
abstract final class CaptureAutoUpload {
  static final _store = SettingsStore();
  static final _client = FieldReportClient();
  static String? _lastPath;

  static Future<bool> enabled() => _store.serverUploadEnabled();

  /// Returns `true` when server upload handled the file (including failures).
  /// Returns `false` when the Settings switch is off so the caller may share.
  static Future<bool> maybeUpload(
    BuildContext? context, {
    required String path,
    required String applicationId,
    String source = 'auto-upload',
  }) async {
    if (path.isEmpty) return false;
    if (!await enabled()) return false;
    if (path == _lastPath) return true;
    _lastPath = path;
    final messenger = context != null && context.mounted
        ? ScaffoldMessenger.maybeOf(context)
        : null;
    await _upload(
      messenger,
      path: path,
      applicationId: applicationId,
      source: source,
    );
    return true;
  }

  static Future<void> _upload(
    ScaffoldMessengerState? messenger, {
    required String path,
    required String applicationId,
    required String source,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      _snack(messenger, 'Capture file is missing.', error: true);
      return;
    }
    final diagnosis = path.toLowerCase().endsWith('.mdxd');
    final packageId = applicationId.trim().isEmpty
        ? kDiagnosticAndroidPackage
        : applicationId.trim();
    _snack(messenger, 'Sending to the server…');
    try {
      await _client.upload(
        applicationId: packageId,
        kind: diagnosis
            ? FieldReportKinds.diagnosis
            : FieldReportKinds.logcatExcerpt,
        title: diagnosis ? 'Diagnostic .mdxd' : 'Diagnostic .mdx',
        deviceSerial: kOnDeviceSerial,
        attachment: file,
        payloadJson: {
          'format': diagnosis ? 'mdxd' : 'mdx',
          'magic': diagnosis ? kMdxdMagic : kMdxMagic,
          'source': source,
          'watchedPackage': packageId,
          'autoUpload': true,
        },
      );
      _snack(messenger, 'Sent to the server.');
    } on FieldReportUploadException catch (err) {
      AppLog.e('upload', 'auto-upload failed: ${err.code}', err);
      _snack(messenger, fieldReportUserMessage(err), error: true);
    } catch (err) {
      AppLog.e('upload', 'auto-upload failed', err);
      _snack(messenger, 'Could not send to the server.', error: true);
    }
  }

  static void _snack(
    ScaffoldMessengerState? messenger,
    String message, {
    bool error = false,
  }) {
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: error ? 5 : 3),
      ),
    );
  }
}
