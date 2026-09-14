import 'dart:async';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/adb/adb_client.dart';
import '../state/adb_providers.dart';
import '../state/device_names_provider.dart';
import '../state/logcat_providers.dart';
import '../theme/desktop_theme.dart';
import '../widgets/desktop_chrome.dart';
import 'package_picker_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adb = ref.watch(adbAvailableProvider);
    final devices = ref.watch(devicesProvider);
    final selected = ref.watch(selectedDeviceProvider);
    final session = ref.watch(logcatSessionProvider);
    final ink = AmlTheme.inkOf(context);

    ref.listen<AsyncValue<List<AdbDevice>>>(devicesProvider, (prev, next) {
      final list = next.valueOrNull;
      if (list == null) return;
      final current = ref.read(selectedDeviceProvider);
      if (current == null) return;
      final match = list.where((d) => d.serial == current.serial);
      if (match.isEmpty) {
        ref.read(selectedDeviceProvider.notifier).state = null;
      } else {
        ref.read(selectedDeviceProvider.notifier).state = match.first;
      }
    });

    final deviceCount = devices.valueOrNull?.length ?? 0;

    return Scaffold(
      backgroundColor: AmlTheme.isDark(context)
          ? AmlTheme.darkBg
          : kSettingsPageBackground,
      appBar: AppBar(
        titleSpacing: 16,
        toolbarHeight: 48,
        title: Text(
          'AmL Diagnostic',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.1,
            color: ink,
          ),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (session.anrCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: DesktopTag(
                  label: '${session.anrCount} ANR',
                  color: AmlTheme.pink,
                  icon: Icons.warning_amber_rounded,
                ),
              ),
            ),
          DesktopIconAction(
            icon: Icons.settings_rounded,
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              );
            },
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: SettingsAmbientBackground()),
          Positioned.fill(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
              children: [
                DesktopContent(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _AdbStatusStrip(adb: adb),
                      const SizedBox(height: 14),
                      DesktopSectionLabel(
                        label: 'Devices',
                        trailing: Row(
                          children: [
                            if (deviceCount > 0)
                              DesktopTag(
                                label: deviceCount == 1
                                    ? '1 attached'
                                    : '$deviceCount attached',
                                color: AmlTheme.sky,
                              ),
                            const SizedBox(width: 4),
                            DesktopIconAction(
                              icon: Icons.refresh_rounded,
                              tooltip: 'Rescan devices',
                              onPressed: () {
                                ref.invalidate(adbAvailableProvider);
                                ref.invalidate(devicesProvider);
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      _DeviceList(
                        adb: adb,
                        devices: devices,
                        selected: selected,
                        session: session,
                      ),
                      if (session.errorMessage != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          session.errorMessage!,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: Desk.danger,
                          ),
                        ),
                      ] else if (session.isWatching) ...[
                        const SizedBox(height: 10),
                        _WatchingNote(serial: session.serial),
                      ],
                    ],
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

class _WatchingNote extends ConsumerWidget {
  const _WatchingNote({required this.serial});

  final String? serial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final names = ref.watch(deviceNamesProvider);
    final label = serial == null
        ? 'this device'
        : resolveSerialLabel(names, serial!);
    return Row(
      children: [
        Icon(
          Icons.podcasts_rounded,
          size: 14,
          color: AmlTheme.violet.withValues(alpha: 0.85),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Watching logcat on $label — ANRs and crashes increment the badge.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.35,
              color: AmlTheme.mutedOf(context),
            ),
          ),
        ),
      ],
    );
  }
}

class _AdbStatusStrip extends StatelessWidget {
  const _AdbStatusStrip({required this.adb});

  final AsyncValue<bool> adb;

  @override
  Widget build(BuildContext context) {
    final available = adb.valueOrNull ?? false;
    final loading = adb.isLoading && adb.valueOrNull == null;

    if (loading) {
      return const DesktopStatusStrip(
        icon: Icons.usb_rounded,
        accent: AmlTheme.sky,
        title: 'Looking for adb',
        detail: 'Checking PATH for platform-tools.',
        leading: SizedBox(
          width: 24,
          height: 24,
          child: Center(
            child: BirdLoader(size: 22, semanticsLabel: 'Looking for adb'),
          ),
        ),
      );
    }

    if (available) {
      return const DesktopStatusStrip(
        icon: Icons.check_rounded,
        accent: AmlTheme.mint,
        title: 'adb found',
        detail: 'Ready to talk to USB-debugging phones.',
        leading: SizedBox(
          width: 24,
          height: 24,
          child: Center(child: DesktopStatusDot(color: AmlTheme.mint)),
        ),
      );
    }

    return DesktopStatusStrip(
      icon: Icons.usb_off_rounded,
      accent: AmlTheme.amber,
      title: 'adb missing',
      detail: 'Install Android platform-tools and add adb to PATH.',
      leading: const SizedBox(
        width: 24,
        height: 24,
        child: Center(child: DesktopStatusDot(color: AmlTheme.amber)),
      ),
      trailing: TextButton(
        onPressed: () {
          unawaited(
            launchUrl(
              Uri.parse(
                'https://developer.android.com/tools/releases/platform-tools',
              ),
            ),
          );
        },
        child: const Text('Install'),
      ),
    );
  }
}

class _DeviceList extends ConsumerWidget {
  const _DeviceList({
    required this.adb,
    required this.devices,
    required this.selected,
    required this.session,
  });

  final AsyncValue<bool> adb;
  final AsyncValue<List<AdbDevice>> devices;
  final AdbDevice? selected;
  final LogcatSessionView session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adbReady = adb.valueOrNull ?? false;
    final listing = devices.isLoading && devices.valueOrNull == null;

    if ((adb.isLoading && adb.valueOrNull == null) || (adbReady && listing)) {
      return const DesktopPanel(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: BirdLoader(size: 64, semanticsLabel: 'Looking for devices'),
        ),
      );
    }
    if (adb.hasError) {
      return DesktopStatusStrip(
        icon: Icons.error_outline_rounded,
        accent: AmlTheme.pink,
        title: 'Could not check adb',
        detail: '${adb.error}',
      );
    }
    if (!adbReady) {
      return const DesktopStatusStrip(
        icon: Icons.phone_android_rounded,
        accent: AmlTheme.sky,
        title: 'Connect a device',
        detail:
            'Install platform-tools first, then plug in a phone with USB debugging.',
      );
    }
    if (devices.hasError) {
      return DesktopStatusStrip(
        icon: Icons.error_outline_rounded,
        accent: AmlTheme.pink,
        title: 'Could not list devices',
        detail: '${devices.error}',
      );
    }

    final list = devices.valueOrNull ?? const <AdbDevice>[];
    if (list.isEmpty) {
      return const DesktopStatusStrip(
        icon: Icons.phone_android_rounded,
        accent: AmlTheme.sky,
        title: 'Connect a device',
        detail:
            'Plug in a phone with USB debugging, unlock it, and allow this PC.',
      );
    }

    return DesktopPanel(
      child: Column(
        children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) const DesktopHairline(indent: 13),
            _DeviceRow(
              device: list[i],
              selected: selected?.serial == list[i].serial,
              watching: session.isWatching && session.serial == list[i].serial,
              anrCount: session.isWatching && session.serial == list[i].serial
                  ? session.anrCount
                  : 0,
            ),
          ],
        ],
      ),
    );
  }
}

class _DeviceRow extends ConsumerWidget {
  const _DeviceRow({
    required this.device,
    required this.selected,
    required this.watching,
    required this.anrCount,
  });

  final AdbDevice device;
  final bool selected;
  final bool watching;
  final int anrCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final names = ref.watch(deviceNamesProvider);
    final nickname = names[device.serial]?.trim();
    final renamed = nickname != null && nickname.isNotEmpty;
    final primary = renamed ? nickname : device.displayName;
    final secondary = renamed
        ? '${device.displayName} · ${device.serial}'
        : device.serial;

    final accent = switch (device.state) {
      AdbDeviceState.device => AmlTheme.mint,
      AdbDeviceState.unauthorized => AmlTheme.amber,
      AdbDeviceState.offline => AmlTheme.pink,
      AdbDeviceState.unknown => AmlTheme.sky,
    };

    void select() {
      ref.read(selectedDeviceProvider.notifier).state = device;
    }

    return Material(
      color: selected ? Desk.selectedRowFill(context) : Colors.transparent,
      child: InkWell(
        onTap: select,
        child: SizedBox(
          height: Desk.deviceRowHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 3,
                color: selected ? AmlTheme.violet : Colors.transparent,
              ),
              const SizedBox(width: 10),
              Center(child: DesktopStatusDot(color: accent)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      primary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      secondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Desk.mono(size: 11, color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Center(
                child: Row(
                  children: [
                    if (watching)
                      DesktopTag(
                        label: anrCount > 0 ? '$anrCount ANR' : 'watching',
                        color: anrCount > 0 ? AmlTheme.pink : AmlTheme.violet,
                      )
                    else
                      DesktopTag(label: device.stateLabel, color: accent),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Center(
                child: Row(
                  children: [
                    DesktopIconAction(
                      icon: watching
                          ? Icons.stop_rounded
                          : Icons.monitor_heart_outlined,
                      tooltip: watching ? 'Stop logcat' : 'Watch logcat',
                      color: watching ? AmlTheme.pink : AmlTheme.violet,
                      onPressed: watching
                          ? () =>
                                ref.read(logcatSessionProvider.notifier).stop()
                          : device.isReady
                          ? () {
                              select();
                              ref
                                  .read(logcatSessionProvider.notifier)
                                  .watchDevice(device.serial);
                            }
                          : null,
                    ),
                    DesktopIconAction(
                      icon: Icons.apps_rounded,
                      tooltip: 'Pick app',
                      onPressed: device.isReady
                          ? () {
                              select();
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => PackagePickerScreen(
                                    serial: device.serial,
                                  ),
                                ),
                              );
                            }
                          : null,
                    ),
                    DesktopIconAction(
                      icon: Icons.drive_file_rename_outline_rounded,
                      tooltip: 'Rename device',
                      onPressed: () => _showRenameDialog(context, device),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showRenameDialog(BuildContext context, AdbDevice device) {
  return showDialog<void>(
    context: context,
    builder: (_) => _RenameDeviceDialog(device: device),
  );
}

/// Small rename dialog: nickname in, adb identity kept visible underneath.
class _RenameDeviceDialog extends ConsumerStatefulWidget {
  const _RenameDeviceDialog({required this.device});

  final AdbDevice device;

  @override
  ConsumerState<_RenameDeviceDialog> createState() =>
      _RenameDeviceDialogState();
}

class _RenameDeviceDialogState extends ConsumerState<_RenameDeviceDialog> {
  late final TextEditingController _name;
  late final bool _hadNickname;

  @override
  void initState() {
    super.initState();
    final stored =
        ref.read(deviceNamesProvider)[widget.device.serial]?.trim() ?? '';
    _hadNickname = stored.isNotEmpty;
    _name = TextEditingController(text: stored);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _apply(String value) {
    final notifier = ref.read(deviceNamesProvider.notifier);
    Navigator.of(context).pop();
    unawaited(notifier.setName(widget.device.serial, value));
  }

  @override
  Widget build(BuildContext context) {
    final muted = AmlTheme.mutedOf(context);
    return AlertDialog(
      title: const Text('Rename device'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: _apply,
              decoration: InputDecoration(
                labelText: 'Nickname',
                hintText: widget.device.displayName,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'adb reports this device as',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: muted,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.device.displayName} · ${widget.device.serial}',
              style: Desk.mono(size: 11.5, color: muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (_hadNickname)
          TextButton(
            onPressed: () => _apply(''),
            style: TextButton.styleFrom(foregroundColor: AmlTheme.pink),
            child: const Text('Clear'),
          ),
        FilledButton(
          onPressed: () => _apply(_name.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
