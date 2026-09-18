import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/mobile/device_bridge.dart';
import '../../core/mobile/phone_diagnostic.dart';
import '../../theme/desktop_theme.dart';
import 'android_app_shelf.dart';
import 'android_permissions_screen.dart';
import 'android_settings_screen.dart';
import 'android_watch_screen.dart';
import 'mdx_share_sheet.dart';

class AndroidHomeScreen extends StatefulWidget {
  const AndroidHomeScreen({super.key});

  @override
  State<AndroidHomeScreen> createState() => _AndroidHomeScreenState();
}

class _AndroidHomeScreenState extends State<AndroidHomeScreen>
    with WidgetsBindingObserver {
  PhonePermissions? _perms;
  List<PhoneInstalledApp> _apps = const [];
  var _loading = true;
  String? _error;
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) offerPendingMdx(context);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _query.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reload(soft: true);
      offerPendingMdx(context);
    }
  }

  Future<void> _reload({bool soft = false}) async {
    if (!soft) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final perms = await deviceBridge.permissions();
      var apps = const <PhoneInstalledApp>[];
      if (perms.readLogs) {
        apps = await deviceBridge.listPackages();
      }
      if (!mounted) return;
      setState(() {
        _perms = perms;
        _apps = apps;
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = '$err';
        _loading = false;
      });
    }
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AndroidSettingsScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final perms = _perms;
    if (_loading) {
      return SettingsPageScaffold(
        title: 'Diagnostic',
        showBackButton: false,
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_rounded),
          ),
        ],
        body: const Center(
          child: BirdLoader(size: 72, semanticsLabel: 'Loading Diagnostic'),
        ),
      );
    }
    if (perms == null || !perms.readLogs) {
      return _GrantGate(
        error: _error,
        onSettings: _openSettings,
        onPermissions: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const AndroidPermissionsScreen(),
            ),
          );
        },
        onRefresh: _reload,
      );
    }
    return AndroidAppShelfPage(
      apps: _apps,
      query: _query,
      onQueryChanged: () => setState(() {}),
      onWatch: (app) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AndroidWatchScreen(app: app),
          ),
        );
      },
      onWatchAll: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const AndroidWatchScreen(),
          ),
        );
      },
      onSettings: _openSettings,
      onRefresh: () => _reload(soft: true),
    );
  }
}

class _GrantGate extends StatelessWidget {
  const _GrantGate({
    required this.onPermissions,
    required this.onRefresh,
    required this.onSettings,
    this.error,
  });

  final VoidCallback onPermissions;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;
  final String? error;

  static const _panelRadius = BorderRadius.all(Radius.circular(28));

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final dark = AmlTheme.isDark(context);
    return Scaffold(
      backgroundColor: dark ? AmlTheme.darkBg : kSettingsPageBackground,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned.fill(
            child: AmlMeshAtmosphere(tessellation: 10),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: 'Settings',
                      onPressed: onSettings,
                      iconSize: 26,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        tapTargetSize: MaterialTapTargetSize.padded,
                        padding: const EdgeInsets.all(10),
                      ),
                      icon: Icon(Icons.settings_rounded, color: ink),
                    ),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(18, 4, 18, 20),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight - 8,
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 420),
                              child: Material(
                                color: (dark
                                        ? AmlTheme.darkSurface
                                        : Colors.white)
                                    .withValues(alpha: dark ? 0.72 : 0.86),
                                elevation: 18,
                                shadowColor:
                                    AmlTheme.violet.withValues(alpha: 0.28),
                                borderRadius: _panelRadius,
                                clipBehavior: Clip.antiAlias,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: _panelRadius,
                                    border: Border.all(
                                      color: dark
                                          ? AmlTheme.darkStroke
                                          : const Color(0x66E9E4F5),
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      22,
                                      22,
                                      22,
                                      18,
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const BirdLoader(
                                          size: 96,
                                          semanticsLabel: 'Diagnostic',
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          'Unlock Watch',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: 30,
                                            height: 1.1,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.7,
                                            color: ink,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          'One tap on the PC. Watch stays closed until Desktop Diagnostic grants live logcat.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: 14.5,
                                            height: 1.4,
                                            fontWeight: FontWeight.w600,
                                            color: muted,
                                          ),
                                        ),
                                        const SizedBox(height: 20),
                                        const _GrantStep(
                                          index: 1,
                                          icon: Icons.usb_rounded,
                                          pastelKey: 'usb',
                                          title: 'Connect this phone',
                                          subtitle:
                                              'USB cable, or wireless debugging.',
                                        ),
                                        const SizedBox(height: 8),
                                        const _GrantStep(
                                          index: 2,
                                          icon: Icons.desktop_windows_rounded,
                                          pastelKey: 'desktop',
                                          title: 'Open Diagnostic on the PC',
                                          subtitle:
                                              'The same app, on this computer.',
                                        ),
                                        const SizedBox(height: 8),
                                        const _GrantStep(
                                          index: 3,
                                          icon: Icons.verified_rounded,
                                          pastelKey: 'allow',
                                          title: 'Allow on-device logging',
                                          subtitle:
                                              'On this phone’s card. It lasts until you uninstall.',
                                        ),
                                        const SizedBox(height: 12),
                                        DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: AmlTheme.amber.withValues(
                                              alpha: dark ? 0.16 : 0.2,
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(16),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              12,
                                              10,
                                              12,
                                              10,
                                            ),
                                            child: Row(
                                              children: [
                                                settingsPastelIcon(
                                                  Icons.battery_charging_full_rounded,
                                                  'battery',
                                                  dimension: 36,
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Text(
                                                    'HyperOS: set unrestricted battery and Autostart so Watch survives the game.',
                                                    style: TextStyle(
                                                      fontSize: 12.5,
                                                      height: 1.35,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: ink,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        if (error != null) ...[
                                          const SizedBox(height: 10),
                                          Text(
                                            error!,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: Desk.danger,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 18),
                                        SizedBox(
                                          width: double.infinity,
                                          height: 52,
                                          child: FilledButton(
                                            onPressed: onRefresh,
                                            child: const Text('Check again'),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        SizedBox(
                                          width: double.infinity,
                                          height: 48,
                                          child: OutlinedButton(
                                            onPressed: onPermissions,
                                            child: const Text(
                                              'Open Permissions',
                                            ),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () async {
                                            await Clipboard.setData(
                                              const ClipboardData(
                                                text: kPmGrantReadLogsCommand,
                                              ),
                                            );
                                            if (!context.mounted) return;
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  'Copied the fallback grant command',
                                                ),
                                              ),
                                            );
                                          },
                                          child: Text(
                                            'Copy fallback adb command',
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w700,
                                              color: muted,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GrantStep extends StatelessWidget {
  const _GrantStep({
    required this.index,
    required this.icon,
    required this.pastelKey,
    required this.title,
    required this.subtitle,
  });

  final int index;
  final IconData icon;
  final String pastelKey;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final dark = AmlTheme.isDark(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AmlTheme.violet.withValues(alpha: dark ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AmlTheme.violet.withValues(alpha: dark ? 0.2 : 0.12),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 4, bottom: 4),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  settingsPastelIcon(icon, pastelKey, dimension: 44),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: dark ? AmlTheme.darkSurface : Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AmlTheme.violet.withValues(alpha: 0.28),
                        ),
                      ),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: Center(
                          child: Text(
                            '$index',
                            style: const TextStyle(
                              fontSize: 10,
                              height: 1,
                              fontWeight: FontWeight.w800,
                              color: AmlTheme.violet,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.2,
                      fontWeight: FontWeight.w800,
                      color: ink,
                    ),
                  ),
                  const SizedBox(height: 2),
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
          ],
        ),
      ),
    );
  }
}
