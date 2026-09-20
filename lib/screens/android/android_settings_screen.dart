import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ai/deepseek_client.dart';
import '../../core/app_version.dart';
import '../../core/mobile/device_bridge.dart';
import '../../core/mobile/phone_diagnostic.dart';
import '../../services/settings_store.dart';
import '../../state/deepseek_providers.dart';
import '../../theme/desktop_theme.dart';
import 'android_permissions_screen.dart';

class AndroidSettingsScreen extends StatefulWidget {
  const AndroidSettingsScreen({super.key});

  @override
  State<AndroidSettingsScreen> createState() => _AndroidSettingsScreenState();
}

class _AndroidSettingsScreenState extends State<AndroidSettingsScreen>
    with WidgetsBindingObserver {
  PhonePermissions? _perms;
  var _loading = true;
  var _serverUpload = true;

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
    final serverUpload = await SettingsStore().serverUploadEnabled();
    if (!mounted) return;
    setState(() {
      _perms = perms;
      _serverUpload = serverUpload;
      _loading = false;
    });
  }

  Future<void> _setServerUpload(bool value) async {
    await SettingsStore().setServerUploadEnabled(value);
    if (!mounted) return;
    setState(() => _serverUpload = value);
  }

  Future<void> _copyGrant() async {
    await Clipboard.setData(const ClipboardData(text: kPmGrantReadLogsCommand));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied the grant command')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final dark = AmlTheme.isDark(context);
    final perms = _perms;
    final ready = perms?.readLogs == true;
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
                          'Settings',
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
                            semanticsLabel: 'Loading settings',
                          ),
                        )
                      : BirdRefreshIndicator(
                          onRefresh: _reload,
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                            children: [
                              const _SettingsHero(),
                              const SizedBox(height: 14),
                              _StatusBanner(
                                ready: ready,
                                muted: muted,
                                ink: ink,
                                dark: dark,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Watch',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.2,
                                  color: muted,
                                ),
                              ),
                              const SizedBox(height: 8),
                              _GlassTile(
                                icon: Icons.verified_user_rounded,
                                pastelKey: 'Permissions',
                                title: 'Permissions',
                                subtitle:
                                    'Logcat, overlay, notifications, battery',
                                trailing: _StatusPill(
                                  label: ready ? 'Ready' : 'Needs grant',
                                  accent: ready ? AmlTheme.mint : AmlTheme.amber,
                                ),
                                onTap: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          const AndroidPermissionsScreen(),
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 10),
                              _GlassTile(
                                icon: Icons.picture_in_picture_alt_rounded,
                                pastelKey: 'Overlay',
                                title: 'Display over other apps',
                                subtitle: 'Flying Record / Pause / Stop bubble',
                                trailing: _StatusPill(
                                  label: perms.overlay ? 'On' : 'Off',
                                  accent: perms.overlay
                                      ? AmlTheme.mint
                                      : AmlTheme.amber,
                                ),
                                onTap: () => deviceBridge.openSettings('overlay'),
                              ),
                              const SizedBox(height: 10),
                              _GlassTile(
                                icon: Icons.notifications_rounded,
                                pastelKey: 'Notify',
                                title: 'Notifications',
                                subtitle: 'Keeps capture alive in the background',
                                trailing: _StatusPill(
                                  label: perms.notifications ? 'On' : 'Off',
                                  accent: perms.notifications
                                      ? AmlTheme.mint
                                      : AmlTheme.amber,
                                ),
                                onTap: () async {
                                  await deviceBridge.requestNotifications();
                                  await deviceBridge.openSettings('notifications');
                                },
                              ),
                              const SizedBox(height: 10),
                              _GlassTile(
                                icon: Icons.battery_charging_full_rounded,
                                pastelKey: 'Battery',
                                title: 'Unrestricted battery',
                                subtitle: perms.xiaomi
                                    ? 'HyperOS: also turn on Autostart'
                                    : 'So Watch survives when you leave Diagnostic',
                                trailing: _StatusPill(
                                  label: perms.batteryUnrestricted ? 'On' : 'Off',
                                  accent: perms.batteryUnrestricted
                                      ? AmlTheme.mint
                                      : AmlTheme.amber,
                                ),
                                onTap: () =>
                                    deviceBridge.openSettings('battery'),
                              ),
                              if (perms.xiaomi) ...[
                                const SizedBox(height: 10),
                                _GlassTile(
                                  icon: Icons.play_circle_outline_rounded,
                                  pastelKey: 'Autostart',
                                  title: 'Autostart',
                                  subtitle: 'Security → Autostart → Diagnostic',
                                  trailing: const _StatusPill(
                                    label: 'Open',
                                    accent: AmlTheme.sky,
                                  ),
                                  onTap: () =>
                                      deviceBridge.openSettings('autostart'),
                                ),
                              ],
                              const SizedBox(height: 18),
                              Text(
                                'Server',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.2,
                                  color: muted,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SettingsCard(
                                children: [
                                  SettingsSwitchTile(
                                    secondary: settingsPastelIcon(
                                      Icons.cloud_upload_rounded,
                                      'Upload',
                                    ),
                                    title: const Text('Upload captures to server'),
                                    subtitle:
                                        'Sends each Watch, Diagnose, and self-check automatically.',
                                    value: _serverUpload,
                                    onChanged: _setServerUpload,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              Text(
                                'AI',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.2,
                                  color: muted,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const _DeepSeekKeyCard(),
                              const SizedBox(height: 18),
                              Text(
                                'Fallback',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.2,
                                  color: muted,
                                ),
                              ),
                              const SizedBox(height: 8),
                              _GlassTile(
                                icon: Icons.content_copy_rounded,
                                pastelKey: 'Grant',
                                title: 'Copy ADB grant',
                                subtitle:
                                    'If Desktop Diagnostic is not on this PC',
                                trailing: Icon(
                                  Icons.copy_rounded,
                                  size: 18,
                                  color: muted,
                                ),
                                onTap: _copyGrant,
                              ),
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

class _SettingsHero extends StatelessWidget {
  const _SettingsHero();

  static const _radius = BorderRadius.all(Radius.circular(28));

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: _radius,
      child: Stack(
        children: [
          const Positioned.fill(
            child: AmlMeshAtmosphere(tessellation: 8, borderRadius: _radius),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 18, 12, 16),
            child: SettingsAboutHero(
              productName: 'Diagnostic',
              versionLabel: 'v$kAppVersion',
              creditLabel: 'AmL One World',
              semanticsLabel: 'Diagnostic',
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.ready,
    required this.muted,
    required this.ink,
    required this.dark,
  });

  final bool ready;
  final Color muted;
  final Color ink;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final accent = ready ? AmlTheme.mint : AmlTheme.amber;
    return Material(
      color: Color.alphaBlend(
        accent.withValues(alpha: dark ? 0.18 : 0.16),
        dark ? AmlTheme.darkSurface : Colors.white,
      ).withValues(alpha: 0.92),
      elevation: 8,
      shadowColor: accent.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          children: [
            settingsPastelIcon(
              ready ? Icons.lock_open_rounded : Icons.lock_rounded,
              ready ? 'ready' : 'lock',
              iconColor: accent,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ready ? 'Watch is unlocked' : 'Watch still needs a grant',
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.2,
                      fontWeight: FontWeight.w800,
                      color: ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    ready
                        ? 'Live logcat of other apps is allowed on this phone.'
                        : 'Open Diagnostic on the PC and tap Allow on-device logging.',
                    style: TextStyle(
                      fontSize: 13,
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

class _GlassTile extends StatelessWidget {
  const _GlassTile({
    required this.icon,
    required this.pastelKey,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String pastelKey;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final dark = AmlTheme.isDark(context);
    return Material(
      color: (dark ? AmlTheme.darkSurface : Colors.white)
          .withValues(alpha: dark ? 0.78 : 0.9),
      elevation: 10,
      shadowColor: AmlTheme.violet.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
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
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.accent});

  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.22),
          const Color(0xFFFFFFFF),
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.42)),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          height: 1,
          fontWeight: FontWeight.w800,
          color: accent,
        ),
      ),
    );
  }
}

class _DeepSeekKeyCard extends ConsumerStatefulWidget {
  const _DeepSeekKeyCard();

  @override
  ConsumerState<_DeepSeekKeyCard> createState() => _DeepSeekKeyCardState();
}

class _DeepSeekKeyCardState extends ConsumerState<_DeepSeekKeyCard> {
  final _key = TextEditingController();
  var _obscure = true;
  var _saving = false;
  var _testing = false;
  var _saved = false;
  String? _saveError;
  String? _testMessage;
  var _testOk = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final stored = await ref.read(deepSeekApiKeyProvider.future);
    if (!mounted) return;
    setState(() => _key.text = stored);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saveError = null;
      _saved = false;
      _testMessage = null;
    });
    try {
      await ref.read(deepSeekApiKeyProvider.notifier).save(_key.text);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Could not save the key on this phone.';
      });
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testMessage = null;
      _testOk = false;
    });
    try {
      await ref.read(deepSeekApiKeyProvider.notifier).test(_key.text);
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = true;
        _testMessage = 'Key works.';
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testMessage = err is DeepSeekException
            ? err.message
            : 'Could not test the key.';
      });
    }
  }

  String? _statusMessage() {
    if (_saveError != null) return _saveError;
    if (_saved) return 'Key saved.';
    if (_testMessage != null) return _testMessage;
    return null;
  }

  bool _statusOk() {
    if (_saveError != null) return false;
    if (_saved) return true;
    return _testOk;
  }

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final dark = AmlTheme.isDark(context);
    final stored = ref.watch(deepSeekApiKeyProvider).valueOrNull ?? '';
    final busy = _saving || _testing;
    return Material(
      color: (dark ? AmlTheme.darkSurface : Colors.white)
          .withValues(alpha: dark ? 0.78 : 0.9),
      elevation: 10,
      shadowColor: AmlTheme.violet.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                settingsPastelIcon(Icons.key_rounded, 'DeepSeek'),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'DeepSeek API key',
                        style: TextStyle(
                          fontSize: 15.5,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Saved on this phone. DeepSeek stays off until you tap Ask.',
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
                _StatusPill(
                  label: stored.trim().isEmpty ? 'Not set' : 'Saved',
                  accent: stored.trim().isEmpty
                      ? AmlTheme.amber
                      : AmlTheme.mint,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              maskDeepSeekApiKey(stored),
              style: Desk.mono(
                size: 11.5,
                weight: FontWeight.w700,
                color: stored.trim().isEmpty ? muted : AmlTheme.mint,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _key,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.done,
              style: Desk.mono(size: 13),
              onChanged: (_) => setState(() {
                _saved = false;
                _saveError = null;
                _testMessage = null;
              }),
              onSubmitted: (_) => _save(),
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'\s')),
              ],
              decoration: InputDecoration(
                labelText: 'API key',
                hintText: 'sk-…',
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show key' : 'Hide key',
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  onPressed: busy ? null : _save,
                  child: Text(_saving ? 'Saving…' : 'Save key'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : _test,
                  child: Text(_testing ? 'Testing…' : 'Test key'),
                ),
                if (_statusMessage() != null)
                  Text(
                    _statusMessage()!,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: _statusOk() ? AmlTheme.mint : Desk.danger,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
