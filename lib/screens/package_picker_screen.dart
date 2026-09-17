import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/adb/package_service.dart';
import '../state/adb_providers.dart';
import '../state/package_providers.dart';
import '../theme/desktop_theme.dart';
import '../widgets/desktop_chrome.dart';
import '../widgets/desktop_title_bar.dart';
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
    final needle = _query.text.trim().toLowerCase();

    final hidePageHeader = kDesktopCustomTitleBar;
    final page = SettingsPageScaffold(
      title: 'Pick an app',
      showAppBar: !hidePageHeader,
      showBackButton: !hidePageHeader,
      embedInParentAmbient: hidePageHeader,
      actions: hidePageHeader
          ? null
          : [
              DesktopIconAction(
                tooltip: 'Reload packages',
                onPressed: () =>
                    ref.invalidate(packagesProvider(widget.serial)),
                icon: Icons.refresh_rounded,
              ),
              const SizedBox(width: 8),
            ],
      body: packages.when(
        loading: () => const Center(
          child: BirdLoader(size: 72, semanticsLabel: 'Loading apps'),
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
                          pkg.displayTitle.toLowerCase().contains(needle),
                    )
                    .toList(growable: false);
          final aow = filtered.where((pkg) => pkg.isOfficialAow).toList()
            ..sort(_comparePackageTitle);
          final appBuilder = filtered.where((pkg) => pkg.isAppBuilder).toList()
            ..sort(_comparePackageTitle);
          final thirdParty = filtered
              .where((pkg) => !pkg.isAow)
              .toList()
            ..sort(_comparePackageTitle);
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
            child: DesktopContent(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: Desk.buttonHeight,
                    child: TextField(
                      controller: _query,
                      onChanged: (_) => setState(() {}),
                      textInputAction: TextInputAction.search,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Search packages',
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                        ),
                        prefixIcon: const Icon(Icons.search_rounded, size: 17),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                        suffixIcon: needle.isEmpty
                            ? null
                            : DesktopIconAction(
                                tooltip: 'Clear',
                                onPressed: () {
                                  _query.clear();
                                  setState(() {});
                                },
                                icon: Icons.close_rounded,
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: BirdRefreshIndicator(
                      onRefresh: () async {
                        ref.invalidate(packagesProvider(widget.serial));
                        await ref.read(packagesProvider(widget.serial).future);
                      },
                      child: aow.isEmpty &&
                              appBuilder.isEmpty &&
                              thirdParty.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                const SizedBox(height: 8),
                                DesktopStatusStrip(
                                  icon: Icons.search_off_rounded,
                                  accent: AmlTheme.amber,
                                  title: list.isEmpty
                                      ? 'No apps listed'
                                      : 'No matches',
                                  detail: list.isEmpty
                                      ? 'This phone only reports system '
                                            'packages.'
                                      : 'Nothing matches that search.',
                                ),
                              ],
                            )
                          : CustomScrollView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              slivers: [
                                ..._sectionSlivers(
                                  label: 'AOW apps',
                                  packages: aow,
                                  emptyTitle: 'No AOW apps',
                                  emptyDetail: needle.isEmpty
                                      ? 'No official AmL apps are installed.'
                                      : 'No AOW apps match that search.',
                                  accent: AmlTheme.violet,
                                  onStart: _start,
                                ),
                                const SliverToBoxAdapter(
                                  child: SizedBox(height: 16),
                                ),
                                ..._sectionSlivers(
                                  label: 'Made with App Builder',
                                  packages: appBuilder,
                                  emptyTitle: 'No App Builder apps',
                                  emptyDetail: needle.isEmpty
                                      ? 'No one.aml.ab, ab2, or appbuilder '
                                            'projects are installed.'
                                      : 'No App Builder apps match that search.',
                                  accent: AmlTheme.mint,
                                  onStart: _start,
                                ),
                                const SliverToBoxAdapter(
                                  child: SizedBox(height: 16),
                                ),
                                ..._sectionSlivers(
                                  label: 'Third party apps',
                                  packages: thirdParty,
                                  emptyTitle: 'No third party apps',
                                  emptyDetail: needle.isEmpty
                                      ? 'Only AmL packages are on this phone.'
                                      : 'No third party apps match that search.',
                                  accent: AmlTheme.sky,
                                  onStart: _start,
                                ),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (!hidePageHeader) return page;

    return DesktopTitleChromeBinder(
      title: 'Pick an app',
      actions: [
        DesktopTitleAction(
          icon: Icons.refresh_rounded,
          tooltip: 'Reload packages',
          onPressed: () => ref.invalidate(packagesProvider(widget.serial)),
        ),
      ],
      child: page,
    );
  }

  int _comparePackageTitle(InstalledPackage a, InstalledPackage b) {
    final byTitle = a.displayTitle.toLowerCase().compareTo(
      b.displayTitle.toLowerCase(),
    );
    if (byTitle != 0) return byTitle;
    return a.packageName.toLowerCase().compareTo(b.packageName.toLowerCase());
  }

  List<Widget> _sectionSlivers({
    required String label,
    required List<InstalledPackage> packages,
    required String emptyTitle,
    required String emptyDetail,
    required Color accent,
    required void Function(InstalledPackage pkg) onStart,
  }) {
    return [
      SliverToBoxAdapter(
        child: DesktopSectionLabel(
          label: label,
          trailing: DesktopTag(
            label: '${packages.length}',
            color: accent,
            mono: true,
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 6)),
      if (packages.isEmpty)
        SliverToBoxAdapter(
          child: DesktopStatusStrip(
            icon: Icons.apps_rounded,
            accent: accent,
            title: emptyTitle,
            detail: emptyDetail,
          ),
        )
      else
        SliverToBoxAdapter(
          child: DesktopPanel(
            radius: Desk.row,
            child: Column(
              children: [
                for (var i = 0; i < packages.length; i++) ...[
                  if (i > 0) const DesktopHairline(indent: 44),
                  _PackageRow(
                    package: packages[i],
                    onStart: () => onStart(packages[i]),
                  ),
                ],
              ],
            ),
          ),
        ),
    ];
  }

  void _start(InstalledPackage pkg) {
    final selected = ref.read(selectedDeviceProvider);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionScreen(
          serial: widget.serial,
          packageName: pkg.packageName,
          device: selected?.serial == widget.serial ? selected : null,
        ),
      ),
    );
  }
}

/// Compact desktop row — same rhythm as the Home device list.
class _PackageRow extends StatelessWidget {
  const _PackageRow({required this.package, required this.onStart});

  final InstalledPackage package;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    return InkWell(
      onTap: onStart,
      child: SizedBox(
        height: Desk.packageRowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              DesktopMiniIcon(
                icon: Icons.apps_rounded,
                color: _accentFor(package.packageName),
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      package.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        color: ink,
                      ),
                    ),
                    Text(
                      package.packageName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Desk.mono(size: 11, color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              DesktopIconAction(
                tooltip: 'Start and watch',
                onPressed: onStart,
                icon: Icons.play_arrow_rounded,
                color: AmlTheme.violet,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stable pastel per package so rows are scannable without being noisy.
Color _accentFor(String key) {
  const palette = <Color>[
    AmlTheme.violet,
    AmlTheme.mint,
    AmlTheme.sky,
    AmlTheme.pink,
    AmlTheme.amber,
  ];
  var hash = 0;
  for (final unit in key.codeUnits) {
    hash = (hash + unit) % palette.length;
  }
  return palette[hash];
}

class _PickerError extends StatelessWidget {
  const _PickerError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: DesktopContent(
        maxWidth: Desk.formWidth,
        child: DesktopPanel(
          tint: Desk.danger,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const DesktopPanelHeader(
                icon: Icons.error_outline_rounded,
                accent: Desk.danger,
                title: 'Could not list apps',
              ),
              const SizedBox(height: 10),
              DesktopMonoBlock(text: message, maxHeight: 160),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
