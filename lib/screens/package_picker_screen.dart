import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/adb/package_service.dart';
import '../state/package_providers.dart';
import 'session_screen.dart';

class PackagePickerScreen extends ConsumerStatefulWidget {
  const PackagePickerScreen({super.key, required this.serial});

  final String serial;

  @override
  ConsumerState<PackagePickerScreen> createState() =>
      _PackagePickerScreenState();
}

class _PackagePickerScreenState extends ConsumerState<PackagePickerScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final packages = ref.watch(packagesProvider(widget.serial));
    final ink = AmlTheme.inkOf(context);
    final needle = _query.text.trim().toLowerCase();

    return SettingsPageScaffold(
      title: 'Pick app',
      actions: [
        IconButton(
          tooltip: 'Reload',
          onPressed: () => ref.invalidate(packagesProvider(widget.serial)),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      body: packages.when(
        loading: () => const Center(
          child: BirdLoader(
            size: 96,
            semanticsLabel: 'Loading apps',
          ),
        ),
        error: (err, _) => _PickerError(
          message: '$err',
          onRetry: () => ref.invalidate(packagesProvider(widget.serial)),
        ),
        data: (list) {
          final filtered = needle.isEmpty
              ? list
              : list
                    .where(
                      (pkg) =>
                          pkg.packageName.toLowerCase().contains(needle) ||
                          pkg.shortName.toLowerCase().contains(needle),
                    )
                    .toList(growable: false);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: TextField(
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search packages',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: needle.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            onPressed: () {
                              _query.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                  ),
                ),
              ),
              Expanded(
                child: BirdRefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(packagesProvider(widget.serial));
                    await ref.read(packagesProvider(widget.serial).future);
                  },
                  child: filtered.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            const SizedBox(height: 48),
                            Center(
                              child: Text(
                                list.isEmpty
                                    ? 'No third-party apps on this phone.'
                                    : 'No packages match that search.',
                                style: TextStyle(
                                  color: AmlTheme.mutedOf(context),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        )
                      : ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final pkg = filtered[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _PackageRow(
                                package: pkg,
                                ink: ink,
                                onStart: () => _start(pkg),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _start(InstalledPackage pkg) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionScreen(
          serial: widget.serial,
          packageName: pkg.packageName,
        ),
      ),
    );
  }
}

class _PackageRow extends StatelessWidget {
  const _PackageRow({
    required this.package,
    required this.ink,
    required this.onStart,
  });

  final InstalledPackage package;
  final Color ink;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AmlTheme.panelOf(context),
      elevation: 1,
      shadowColor: AmlTheme.violet.withValues(alpha: 0.16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: AmlTheme.strokeOf(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onStart,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              settingsPastelIcon(Icons.apps_rounded, package.packageName),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      package.shortName,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      package.packageName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: AmlTheme.mutedOf(context),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Start and watch',
                onPressed: onStart,
                icon: Icon(Icons.play_arrow_rounded, color: AmlTheme.violet),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerError extends StatelessWidget {
  const _PickerError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: SettingsCard(
        children: [
          SettingsListTile(
            leading: settingsPastelIcon(Icons.error_outline_rounded, 'pink'),
            title: const Text('Could not list apps'),
            subtitle: message,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: FilledButton(
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ),
        ],
      ),
    );
  }
}
