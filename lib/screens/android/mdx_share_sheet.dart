import 'dart:io';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

import '../../core/mobile/device_bridge.dart';
import '../../core/mobile/phone_diagnostic.dart';
import '../../core/upload/field_report_client.dart';

/// After Stop, send the saved `.mdx` to MessageMe and App Builder separately
/// so both work when both apps are on the phone.
Future<void> offerMdxActions(
  BuildContext context, {
  required String path,
  String applicationId = kDiagnosticAndroidPackage,
}) async {
  if (path.isEmpty || !_MdxOfferGate.take(path)) return;
  await deviceBridge.consumePendingMdx();
  if (!context.mounted) return;
  final messageMe = await deviceBridge.isPackageInstalled(kMessageMeAndroidPackage);
  var appBuilder = false;
  for (final pkg in kAppBuilderAndroidPackages) {
    if (await deviceBridge.isPackageInstalled(pkg)) {
      appBuilder = true;
      break;
    }
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheet) {
      final ink = AmlTheme.inkOf(sheet);
      final muted = AmlTheme.mutedOf(sheet);
      final name = path.split(Platform.pathSeparator).last;
      final kindLabel = path.toLowerCase().endsWith('.mdxd') ? '.mdxd' : '.mdx';
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Material(
            color: Colors.white.withValues(alpha: 0.96),
            elevation: 12,
            shadowColor: AmlTheme.violet.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(24),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Capture saved',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: muted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Kept on this phone. Send to MessageMe and App Builder as two separate actions.',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      color: muted,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _ShareTile(
                    icon: Icons.chat_bubble_rounded,
                    pastelKey: 'MessageMe',
                    title: 'Send to MessageMe',
                    subtitle: messageMe
                        ? 'Opens MessageMe with this $kindLabel'
                        : 'MessageMe is not installed',
                    enabled: messageMe,
                    onTap: () {
                      Navigator.pop(sheet);
                      _shareTo(
                        context,
                        path: path,
                        packageName: kMessageMeAndroidPackage,
                        missing: 'Install MessageMe to send this capture.',
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  _ShareTile(
                    icon: Icons.handyman_rounded,
                    pastelKey: 'AppBuilder',
                    title: 'Send to App Builder',
                    subtitle: appBuilder
                        ? 'Uploads to the studio field reports'
                        : 'Uploads to App Builder even if the app is closed',
                    onTap: () {
                      Navigator.pop(sheet);
                      uploadMdx(
                        context,
                        path: path,
                        applicationId: applicationId,
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  _ShareTile(
                    icon: Icons.ios_share_rounded,
                    pastelKey: 'Share',
                    title: 'Share elsewhere',
                    subtitle: 'Files, Drive, or another app',
                    onTap: () {
                      Navigator.pop(sheet);
                      deviceBridge.shareMdx(path);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

Future<void> offerPendingMdx(
  BuildContext context, {
  String applicationId = kDiagnosticAndroidPackage,
}) async {
  final path = await deviceBridge.consumePendingMdx();
  if (!context.mounted || path == null || path.isEmpty) return;
  await offerMdxActions(
    context,
    path: path,
    applicationId: applicationId,
  );
}

Future<void> uploadMdx(
  BuildContext context, {
  required String path,
  required String applicationId,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Sending to App Builder…')));
  final diagnosis = path.toLowerCase().endsWith('.mdxd');
  try {
    final result = await FieldReportClient().upload(
      applicationId: applicationId,
      kind: diagnosis
          ? FieldReportKinds.diagnosis
          : FieldReportKinds.logcatExcerpt,
      title: diagnosis ? 'Diagnostic .mdxd' : 'Diagnostic .mdx',
      attachment: File(path),
      payloadJson: {
        'format': diagnosis ? 'mdxd' : 'mdx',
        'magic': diagnosis ? kMdxdMagic : kMdxMagic,
      },
    );
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text('Sent to App Builder as ${result.kind}')),
    );
  } on FieldReportUploadException catch (err) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(fieldReportUserMessage(err))),
    );
  } catch (err) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('Could not send to App Builder: $err')));
  }
}

Future<void> _shareTo(
  BuildContext context, {
  required String path,
  required String packageName,
  required String missing,
}) async {
  try {
    await deviceBridge.shareMdx(path, packageName: packageName);
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(missing)));
  }
}

class _ShareTile extends StatelessWidget {
  const _ShareTile({
    required this.icon,
    required this.pastelKey,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String pastelKey;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: AmlTheme.field.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Row(
              children: [
                settingsPastelIcon(icon, pastelKey),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15.5,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

abstract final class _MdxOfferGate {
  static String? _last;

  static bool take(String path) {
    if (path.isEmpty || path == _last) return false;
    _last = path;
    return true;
  }
}
