import 'dart:async';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/adb/adb_client.dart';
import '../state/adb_providers.dart';
import '../state/logcat_providers.dart';
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

    return Scaffold(
      backgroundColor: AmlTheme.isDark(context)
          ? AmlTheme.darkBg
          : kSettingsPageBackground,
      appBar: AppBar(
        title: const Text('AmL Diagnostic'),
        backgroundColor: Colors.transparent,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (session.anrCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: _AnrBadge(count: session.anrCount),
              ),
            ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScreen(),
                ),
              );
            },
            icon: const Icon(Icons.settings_rounded),
          ),
        ],
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: SettingsAmbientBackground()),
          Positioned.fill(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _AdbStatusCard(adb: adb),
                        const SizedBox(height: 18),
                        Text(
                          'Devices',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.15,
                            color: AmlTheme.mutedOf(context),
                          ),
                        ),
                        const SizedBox(height: 10),
                        _DeviceList(
                          adb: adb,
                          devices: devices,
                          selected: selected,
                          session: session,
                        ),
                        const SizedBox(height: 16),
                        _WatchButton(
                          selected: selected,
                          session: session,
                        ),
                        const SizedBox(height: 10),
                        _PickAppButton(selected: selected),
                        if (session.errorMessage != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            session.errorMessage!,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFE85D75),
                            ),
                          ),
                        ] else if (session.isWatching) ...[
                          const SizedBox(height: 10),
                          Text(
                            'Watching logcat on ${session.serial}. ANRs and '
                            'crashes will increment the badge.',
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.35,
                              color: AmlTheme.mutedOf(context),
                            ),
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

class _AdbStatusCard extends StatelessWidget {
  const _AdbStatusCard({required this.adb});

  final AsyncValue<bool> adb;

  @override
  Widget build(BuildContext context) {
    final available = adb.valueOrNull ?? false;
    final loading = adb.isLoading && adb.valueOrNull == null;
    return SettingsCard(
      children: [
        SettingsListTile(
          leading: settingsPastelIcon(
            available
                ? Icons.check_circle_rounded
                : Icons.usb_off_rounded,
            available ? 'mint' : 'amber',
            iconColor: available ? AmlTheme.mint : AmlTheme.amber,
          ),
          title: Text(
            loading
                ? 'Looking for adb'
                : available
                ? 'adb found'
                : 'adb missing',
          ),
          subtitle: loading
              ? 'Checking PATH for platform-tools.'
              : available
              ? 'Ready to talk to USB-debugging phones.'
              : 'Install Android platform-tools and add adb to PATH.',
          trailing: !available && !loading
              ? TextButton(
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
                )
              : null,
        ),
      ],
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
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 36),
        child: Center(
          child: BirdLoader(
            size: 96,
            semanticsLabel: 'Looking for devices',
          ),
        ),
      );
    }
    if (adb.hasError) {
      return SettingsCard(
        children: [
          SettingsListTile(
            leading: settingsPastelIcon(Icons.error_outline_rounded, 'pink'),
            title: const Text('Could not check adb'),
            subtitle: '${adb.error}',
          ),
        ],
      );
    }
    if (!adbReady) {
      return SettingsCard(
        children: [
          SettingsListTile(
            leading: settingsPastelIcon(
              Icons.phone_android_rounded,
              'sky',
            ),
            title: const Text('Connect a device'),
            subtitle:
                'Install platform-tools first, then plug in a phone with USB debugging.',
          ),
        ],
      );
    }
    if (devices.hasError) {
      return SettingsCard(
        children: [
          SettingsListTile(
            leading: settingsPastelIcon(Icons.error_outline_rounded, 'pink'),
            title: const Text('Could not list devices'),
            subtitle: '${devices.error}',
          ),
        ],
      );
    }
    final list = devices.valueOrNull ?? const <AdbDevice>[];
    if (list.isEmpty) {
      return SettingsCard(
        children: [
          SettingsListTile(
            leading: settingsPastelIcon(
              Icons.phone_android_rounded,
              'sky',
            ),
            title: const Text('Connect a device'),
            subtitle:
                'Plug in a phone with USB debugging, unlock it, and allow this PC.',
          ),
        ],
      );
    }
    return Column(
      children: [
        for (var i = 0; i < list.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _DeviceCard(
            device: list[i],
            selected: selected?.serial == list[i].serial,
            watching: session.isWatching && session.serial == list[i].serial,
            anrCount: session.isWatching && session.serial == list[i].serial
                ? session.anrCount
                : 0,
            onTap: () {
              ref.read(selectedDeviceProvider.notifier).state = list[i];
            },
          ),
        ],
      ],
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.selected,
    required this.watching,
    required this.anrCount,
    required this.onTap,
  });

  final AdbDevice device;
  final bool selected;
  final bool watching;
  final int anrCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final accent = switch (device.state) {
      AdbDeviceState.device => AmlTheme.mint,
      AdbDeviceState.unauthorized => AmlTheme.amber,
      AdbDeviceState.offline => AmlTheme.pink,
      AdbDeviceState.unknown => AmlTheme.sky,
    };
    return Material(
      color: AmlTheme.panelOf(context),
      elevation: selected ? 3 : 1,
      shadowColor: AmlTheme.violet.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(
          color: selected
              ? AmlTheme.violet.withValues(alpha: 0.55)
              : AmlTheme.strokeOf(context),
          width: selected ? 1.6 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              settingsPastelIcon(
                Icons.phone_android_rounded,
                device.isReady ? 'sky' : 'amber',
                iconColor: accent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.displayName,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      device.serial,
                      style: TextStyle(
                        fontSize: 13,
                        color: AmlTheme.mutedOf(context),
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _StateChip(label: device.stateLabel, color: accent),
                  if (watching) ...[
                    const SizedBox(height: 6),
                    _StateChip(
                      label: anrCount > 0 ? '$anrCount ANR' : 'watching',
                      color: anrCount > 0 ? AmlTheme.pink : AmlTheme.violet,
                    ),
                  ] else if (selected) ...[
                    const SizedBox(height: 6),
                    _StateChip(label: 'selected', color: AmlTheme.violet),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _AnrBadge extends StatelessWidget {
  const _AnrBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AmlTheme.pink.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AmlTheme.pink.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          '$count ANR',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: AmlTheme.pink,
          ),
        ),
      ),
    );
  }
}

class _WatchButton extends ConsumerWidget {
  const _WatchButton({
    required this.selected,
    required this.session,
  });

  final AdbDevice? selected;
  final LogcatSessionView session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watching = session.isWatching;
    final canStart = selected != null && selected!.isReady && !watching;
    final label = watching ? 'Stop logcat' : 'Watch logcat';
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton.icon(
        onPressed: watching
            ? () => ref.read(logcatSessionProvider.notifier).stop()
            : canStart
            ? () => ref
                  .read(logcatSessionProvider.notifier)
                  .watchDevice(selected!.serial)
            : null,
        icon: Icon(
          watching ? Icons.stop_rounded : Icons.monitor_heart_outlined,
        ),
        label: Text(label),
      ),
    );
  }
}

class _PickAppButton extends ConsumerWidget {
  const _PickAppButton({required this.selected});

  final AdbDevice? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canPick = selected != null && selected!.isReady;
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: OutlinedButton.icon(
        onPressed: canPick
            ? () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PackagePickerScreen(
                      serial: selected!.serial,
                    ),
                  ),
                );
              }
            : null,
        icon: const Icon(Icons.apps_rounded),
        label: const Text('Pick app'),
      ),
    );
  }
}
