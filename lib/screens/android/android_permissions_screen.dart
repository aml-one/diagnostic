import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/mobile/device_bridge.dart';
import '../../core/mobile/phone_diagnostic.dart';

class AndroidPermissionsScreen extends StatefulWidget {
  const AndroidPermissionsScreen({super.key});

  @override
  State<AndroidPermissionsScreen> createState() =>
      _AndroidPermissionsScreenState();
}

class _AndroidPermissionsScreenState extends State<AndroidPermissionsScreen>
    with WidgetsBindingObserver {
  PhonePermissions? _perms;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _reload() async {
    final perms = await deviceBridge.permissions();
    if (!mounted) return;
    setState(() {
      _perms = perms;
      _loading = false;
    });
  }

  Future<void> _copyGrant() async {
    await Clipboard.setData(const ClipboardData(text: kPmGrantReadLogsCommand));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Copied the fallback grant command. Use Desktop Diagnostic if you can.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final dark = AmlTheme.isDark(context);
    final perms = _perms;
    return Scaffold(
      backgroundColor: dark ? AmlTheme.darkBg : kSettingsPageBackground,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned.fill(child: SettingsAmbientBackground()),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        onPressed: () => Navigator.maybePop(context),
                        icon: Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: ink,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          'Permissions',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                            color: ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _loading || perms == null
                      ? const Center(
                          child: BirdLoader(
                            size: 72,
                            semanticsLabel: 'Loading permissions',
                          ),
                        )
                      : BirdRefreshIndicator(
                          onRefresh: _reload,
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                            children: [
                              _HeroNote(muted: muted, dark: dark),
                              const SizedBox(height: 14),
                              _PermissionCard(
                                icon: Icons.article_rounded,
                                pastelKey: 'logs',
                                title: 'Read logs',
                                why:
                                    'Live Watch of other apps. Android Settings cannot turn this on.',
                                fromWhere:
                                    'Desktop Diagnostic → Allow on-device logging.',
                                granted: perms.readLogs,
                                onTap: _copyGrant,
                              ),
                              const SizedBox(height: 10),
                              _PermissionCard(
                                icon: Icons.picture_in_picture_alt_rounded,
                                pastelKey: 'overlay',
                                title: 'Display over other apps',
                                why:
                                    'Flying Record / Pause / Stop bubble while you use the app under test.',
                                fromWhere:
                                    'Android Settings → Display over other apps.',
                                granted: perms.overlay,
                                onTap: () =>
                                    deviceBridge.openSettings('overlay'),
                              ),
                              const SizedBox(height: 10),
                              _PermissionCard(
                                icon: Icons.notifications_rounded,
                                pastelKey: 'notify',
                                title: 'Notifications',
                                why:
                                    'Keeps the capture service alive in the background.',
                                fromWhere: 'Android Settings → App notifications.',
                                granted: perms.notifications,
                                onTap: () async {
                                  await deviceBridge.requestNotifications();
                                  await deviceBridge.openSettings(
                                    'notifications',
                                  );
                                },
                              ),
                              const SizedBox(height: 10),
                              _PermissionCard(
                                icon: Icons.battery_charging_full_rounded,
                                pastelKey: 'battery',
                                title: 'Unrestricted battery',
                                why:
                                    'Watch keeps running when you switch to the app under test.',
                                fromWhere: perms.xiaomi
                                    ? 'HyperOS: battery unrestricted, plus Autostart.'
                                    : 'Android Settings → Battery → Unrestricted.',
                                granted: perms.batteryUnrestricted,
                                onTap: () =>
                                    deviceBridge.openSettings('battery'),
                              ),
                              if (perms.xiaomi) ...[
                                const SizedBox(height: 10),
                                _PermissionCard(
                                  icon: Icons.play_circle_outline_rounded,
                                  pastelKey: 'autostart',
                                  title: 'Autostart',
                                  why:
                                      'HyperOS otherwise kills capture when you leave Diagnostic.',
                                  fromWhere:
                                      'Security → Autostart → Diagnostic on.',
                                  granted: perms.batteryUnrestricted,
                                  onTap: () =>
                                      deviceBridge.openSettings('autostart'),
                                ),
                              ],
                            ],
                          ),
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

class _HeroNote extends StatelessWidget {
  const _HeroNote({required this.muted, required this.dark});

  final Color muted;
  final bool dark;

  static const _radius = BorderRadius.all(Radius.circular(24));

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: _radius,
      child: Stack(
        children: [
          const Positioned.fill(
            child: AmlMeshAtmosphere(tessellation: 8, borderRadius: _radius),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: _radius,
              border: Border.all(
                color: dark
                    ? Colors.white.withValues(alpha: 0.12)
                    : const Color(0x66FFFFFF),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Text(
                'Watch needs these grants. Pull to refresh after you change one — status updates when you come back.',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.icon,
    required this.pastelKey,
    required this.title,
    required this.why,
    required this.fromWhere,
    required this.granted,
    required this.onTap,
  });

  final IconData icon;
  final String pastelKey;
  final String title;
  final String why;
  final String fromWhere;
  final bool granted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final dark = AmlTheme.isDark(context);
    final accent = granted ? AmlTheme.mint : AmlTheme.amber;
    return Material(
      color: (dark ? AmlTheme.darkSurface : Colors.white)
          .withValues(alpha: dark ? 0.78 : 0.9),
      elevation: 10,
      shadowColor: accent.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  settingsPastelIcon(icon, pastelKey, iconColor: accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.2,
                        fontWeight: FontWeight.w800,
                        color: ink,
                      ),
                    ),
                  ),
                  Container(
                    height: 24,
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    decoration: BoxDecoration(
                      color: Color.alphaBlend(
                        accent.withValues(alpha: 0.22),
                        const Color(0xFFFFFFFF),
                      ),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: accent.withValues(alpha: 0.42),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      granted ? 'Granted' : 'Missing',
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1,
                        fontWeight: FontWeight.w800,
                        color: accent,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                why,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: muted,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                fromWhere,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                  color: ink.withValues(alpha: 0.78),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
