import 'dart:async';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/adb/adb_client.dart';
import '../state/adb_providers.dart';
import '../state/device_names_provider.dart';
import '../state/logcat_providers.dart';
import '../theme/desktop_theme.dart';
import '../widgets/connect_device_pictogram.dart';
import '../widgets/desktop_chrome.dart';
import '../widgets/desktop_title_bar.dart';
import '../widgets/device_card.dart';
import 'package_picker_screen.dart';
import 'session_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adb = ref.watch(adbAvailableProvider);
    final devices = ref.watch(devicesProvider);
    final selected = ref.watch(selectedDeviceProvider);
    final session = ref.watch(logcatSessionProvider);

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
    const outerPadding = EdgeInsets.fromLTRB(16, 12, 16, 20);

    // Under the custom desktop title bar the ambient wash lives in
    // [DesktopAppFrame]; keep this scaffold transparent so it does not
    // redraw a second gradient that starts below the title strip.
    return DesktopTitleChromeBinder(
      title: 'AOW Diagnostic tool for Android',
      child: Scaffold(
      backgroundColor: kDesktopCustomTitleBar
          ? Colors.transparent
          : (AmlTheme.isDark(context)
                ? AmlTheme.darkBg
                : kSettingsPageBackground),
      body: Stack(
        children: [
          if (!kDesktopCustomTitleBar)
            const Positioned.fill(child: SettingsAmbientBackground()),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, viewport) {
                // At least the full viewport, so an empty/short state (the
                // connect-a-device pictogram) can center in the leftover
                // space via Expanded below — but content taller than the
                // window (many devices) still just scrolls normally.
                final minHeight =
                    (viewport.maxHeight - outerPadding.vertical).clamp(
                      0.0,
                      double.infinity,
                    );
                // Card width is measured here — not with a LayoutBuilder
                // inside IntrinsicHeight (that crashes and blanks the window).
                final cardWidth =
                    (viewport.maxWidth - outerPadding.horizontal).clamp(
                      0.0,
                      Desk.deviceCardWidth,
                    );
                return SingleChildScrollView(
                  padding: outerPadding,
                  child: DesktopContent(
                    // The ConstrainedBox must sit *inside* DesktopContent
                    // (past its internal Align, which loosens incoming
                    // height constraints) or the minHeight below is
                    // discarded and Expanded never gets real leftover space.
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: minHeight),
                      child: IntrinsicHeight(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (session.anrCount > 0) ...[
                              Align(
                                alignment: Alignment.centerLeft,
                                child: DesktopTag(
                                  label: '${session.anrCount} ANR',
                                  color: AmlTheme.pink,
                                  icon: Icons.warning_amber_rounded,
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                            _AdbStatusStrip(adb: adb),
                            DesktopSectionLabel(
                              // Hidden while no device is attached — the big
                              // pictogram below is the call to action instead.
                              label: deviceCount > 0 ? 'Devices' : '',
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
                                      ref.invalidate(deviceDetailsProvider);
                                    },
                                  ),
                                  // Linux keeps the native title bar, so
                                  // settings lives here.
                                  if (!kDesktopCustomTitleBar) ...[
                                    const SizedBox(width: 2),
                                    DesktopIconAction(
                                      icon: Icons.settings_rounded,
                                      tooltip: 'Settings',
                                      onPressed: () {
                                        Navigator.of(context).push(
                                          MaterialPageRoute<void>(
                                            builder: (_) =>
                                                const SettingsScreen(),
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 6),
                            Expanded(
                              child: _DeviceList(
                                adb: adb,
                                devices: devices,
                                selected: selected,
                                session: session,
                                cardWidth: cardWidth,
                              ),
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
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
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
            'Watching logcat on $label — live lines are on the Watch screen.',
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
    // Quiet when adb is found (bundled or system) or still resolving.
    // Only surface a warning when nothing usable is available.
    final available = adb.valueOrNull ?? false;
    final stillLooking = adb.isLoading && adb.valueOrNull == null;
    if (stillLooking || available) {
      return const SizedBox.shrink();
    }

    return const Padding(
      padding: EdgeInsets.only(bottom: 14),
      child: DesktopStatusStrip(
        icon: Icons.usb_off_rounded,
        accent: AmlTheme.amber,
        title: 'adb missing',
        detail:
            'Could not find the bundled platform-tools or an adb on PATH / Android SDK. Reinstall the app, install platform-tools, or set AML_ADB to an adb binary.',
        leading: SizedBox(
          width: 24,
          height: 24,
          child: Center(child: DesktopStatusDot(color: AmlTheme.amber)),
        ),
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
    required this.cardWidth,
  });

  final AsyncValue<bool> adb;
  final AsyncValue<List<AdbDevice>> devices;
  final AdbDevice? selected;
  final LogcatSessionView session;
  final double cardWidth;

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
      // Warning is shown once by `_AdbStatusStrip` above.
      return const SizedBox.shrink();
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
      return const ConnectDevicePictogram();
    }

    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: [
        for (final device in list)
          SizedBox(
            width: cardWidth,
            height: Desk.deviceCardHeight,
            child: DeviceCard(
              device: device,
              selected: selected?.serial == device.serial,
              watching:
                  session.isWatching && session.serial == device.serial,
              anrCount:
                  session.isWatching && session.serial == device.serial
                  ? session.anrCount
                  : 0,
              onSelect: () {
                ref.read(selectedDeviceProvider.notifier).state = device;
              },
              onWatchToggle: () {
                final notifier = ref.read(logcatSessionProvider.notifier);
                if (session.isWatching && session.serial == device.serial) {
                  notifier.stop();
                  return;
                }
                ref.read(selectedDeviceProvider.notifier).state = device;
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SessionScreen(
                      serial: device.serial,
                      device: device,
                    ),
                  ),
                );
              },
              onPickApp: () {
                ref.read(selectedDeviceProvider.notifier).state = device;
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        PackagePickerScreen(serial: device.serial),
                  ),
                );
              },
              onRename: () => _showRenameDialog(context, device),
            ),
          ),
      ],
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
