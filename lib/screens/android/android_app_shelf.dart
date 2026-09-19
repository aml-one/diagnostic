import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

import '../../core/adb/package_display_name.dart';
import '../../core/app_version.dart';
import '../../core/mobile/device_bridge.dart';
import '../../theme/desktop_theme.dart';

class AndroidAppShelfPage extends StatelessWidget {
  const AndroidAppShelfPage({
    super.key,
    required this.apps,
    required this.query,
    required this.onQueryChanged,
    required this.onWatch,
    required this.onWatchAll,
    required this.onSettings,
    required this.onRefresh,
    this.selfCheckPackage,
    this.onSelfCheck,
  });

  final List<PhoneInstalledApp> apps;
  final TextEditingController query;
  final VoidCallback onQueryChanged;
  final ValueChanged<PhoneInstalledApp> onWatch;
  final VoidCallback onWatchAll;
  final VoidCallback onSettings;
  final Future<void> Function() onRefresh;
  final String? selfCheckPackage;
  final VoidCallback? onSelfCheck;

  @override
  Widget build(BuildContext context) {
    final dark = AmlTheme.isDark(context);
    final needle = query.text.trim().toLowerCase();
    final filtered = needle.isEmpty
        ? apps
        : apps
            .where((app) {
              return app.packageName.toLowerCase().contains(needle) ||
                  app.label.toLowerCase().contains(needle) ||
                  displayPackageTitle(app.packageName)
                      .toLowerCase()
                      .contains(needle);
            })
            .toList(growable: false);

    final aow = filtered
        .where((app) => isOfficialAowPackage(app.packageName))
        .toList()
      ..sort(_byTitle);
    final built = filtered
        .where((app) => isAppBuilderPackage(app.packageName))
        .toList()
      ..sort(_byTitle);
    final third = filtered
        .where((app) =>
            packagePickerGroup(app.packageName) == PackagePickerGroup.thirdParty)
        .toList()
      ..sort(_byTitle);

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
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: _WatchHero(
                    versionLabel: 'v$kAppVersion',
                    onSettings: onSettings,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: query,
                    onChanged: (_) => onQueryChanged(),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search for an app',
                      prefixIcon: const Icon(Icons.search_rounded, size: 22),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      filled: true,
                      fillColor: (dark ? AmlTheme.darkSurface : Colors.white)
                          .withValues(alpha: 0.88),
                    ),
                  ),
                ),
                Expanded(
                  child: BirdRefreshIndicator(
                    onRefresh: onRefresh,
                    child: CustomScrollView(
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          sliver: SliverToBoxAdapter(
                            child: _WatchAllTile(onTap: onWatchAll),
                          ),
                        ),
                        ..._section(
                          context,
                          title: 'AmL One World',
                          count: aow.length,
                          sliver: _AowGrid(
                            apps: aow,
                            onWatch: onWatch,
                            selfCheckPackage: selfCheckPackage,
                            onSelfCheck: onSelfCheck,
                          ),
                        ),
                        ..._section(
                          context,
                          title: 'Made with App Builder',
                          count: built.length,
                          sliver: _AppRowList(apps: built, onWatch: onWatch),
                        ),
                        ..._section(
                          context,
                          title: 'Third party',
                          count: third.length,
                          sliver: _AppRowList(apps: third, onWatch: onWatch),
                        ),
                        if (aow.isEmpty && built.isEmpty && third.isEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
                              child: Text(
                                'No apps match.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: AmlTheme.mutedOf(context),
                                ),
                              ),
                            ),
                          ),
                        const SliverToBoxAdapter(child: SizedBox(height: 28)),
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

  static List<Widget> _section(
    BuildContext context, {
    required String title,
    required int count,
    required Widget sliver,
  }) {
    if (count == 0) return const [];
    final muted = AmlTheme.mutedOf(context);
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
        sliver: SliverToBoxAdapter(
          child: Text(
            '$title · $count',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
              color: muted,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        sliver: sliver,
      ),
    ];
  }

  static int _byTitle(PhoneInstalledApp a, PhoneInstalledApp b) {
    return shelfTitle(a).toLowerCase().compareTo(shelfTitle(b).toLowerCase());
  }
}

String shelfTitle(PhoneInstalledApp app) {
  if (isAowPackage(app.packageName)) {
    return displayPackageTitle(app.packageName);
  }
  if (app.label.isNotEmpty) return app.label;
  return displayPackageTitle(app.packageName);
}

class _WatchHero extends StatelessWidget {
  const _WatchHero({required this.versionLabel, required this.onSettings});

  final String versionLabel;
  final VoidCallback onSettings;
  static const _radius = BorderRadius.all(Radius.circular(26));

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    return ClipRRect(
      borderRadius: _radius,
      child: SizedBox(
        height: 108,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const AmlMeshAtmosphere(borderRadius: _radius, tessellation: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  const BirdLoader(size: 56, semanticsLabel: 'Diagnostic'),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Diagnostic',
                              style: TextStyle(
                                fontSize: 22,
                                height: 1.1,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                                color: ink,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                versionLabel,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.1,
                                  fontWeight: FontWeight.w700,
                                  color: muted,
                                ),
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              tooltip: 'Settings',
                              onPressed: onSettings,
                              iconSize: 24,
                              visualDensity: VisualDensity.compact,
                              style: IconButton.styleFrom(
                                minimumSize: const Size(44, 44),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                padding: const EdgeInsets.all(8),
                              ),
                              icon: Icon(Icons.settings_rounded, color: ink),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Tap an app to Watch live logcat.',
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
          ],
        ),
      ),
    );
  }
}

class _WatchAllTile extends StatelessWidget {
  const _WatchAllTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final dark = AmlTheme.isDark(context);
    return Material(
      color: AmlTheme.violet.withValues(alpha: dark ? 0.22 : 0.14),
      elevation: 0,
      shadowColor: AmlTheme.violet.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
          child: Row(
            children: [
              settingsPastelIcon(
                Icons.monitor_heart_rounded,
                'watch-all',
                dimension: 42,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Watch the whole device',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: ink,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: AmlTheme.mutedOf(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AowGrid extends StatelessWidget {
  const _AowGrid({
    required this.apps,
    required this.onWatch,
    this.selfCheckPackage,
    this.onSelfCheck,
  });

  final List<PhoneInstalledApp> apps;
  final ValueChanged<PhoneInstalledApp> onWatch;
  final String? selfCheckPackage;
  final VoidCallback? onSelfCheck;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        mainAxisExtent: 64,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final app = apps[index];
          final selfCheck = app.packageName == selfCheckPackage;
          return _AppChip(
            app: app,
            attention: selfCheck,
            onTap: () {
              if (selfCheck && onSelfCheck != null) {
                onSelfCheck!();
              } else {
                onWatch(app);
              }
            },
          );
        },
        childCount: apps.length,
      ),
    );
  }
}

class _AppRowList extends StatelessWidget {
  const _AppRowList({required this.apps, required this.onWatch});

  final List<PhoneInstalledApp> apps;
  final ValueChanged<PhoneInstalledApp> onWatch;

  @override
  Widget build(BuildContext context) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final app = apps[index];
          return Padding(
            padding: EdgeInsets.only(bottom: index == apps.length - 1 ? 0 : 8),
            child: _AppChip(
              app: app,
              wide: true,
              onTap: () => onWatch(app),
            ),
          );
        },
        childCount: apps.length,
      ),
    );
  }
}

class _AppChip extends StatelessWidget {
  const _AppChip({
    required this.app,
    required this.onTap,
    this.wide = false,
    this.attention = false,
  });

  final PhoneInstalledApp app;
  final VoidCallback onTap;
  final bool wide;
  final bool attention;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final dark = AmlTheme.isDark(context);
    final title = shelfTitle(app);
    final visual = _visualFor(app.packageName);
    return RepaintBoundary(
      child: Material(
        color: (dark ? AmlTheme.darkSurface : Colors.white)
            .withValues(alpha: dark ? 0.78 : 0.9),
        elevation: 4,
        shadowColor: (attention ? AmlTheme.amber : AmlTheme.violet)
            .withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            button: true,
            label: attention
                ? '$title self-check. Review or send leftover logs.'
                : '$title. ${app.packageName}',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      settingsPastelIcon(
                        visual.icon,
                        visual.pastelKey,
                        dimension: 40,
                      ),
                      if (attention)
                        Positioned(
                          right: -2,
                          top: -2,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Desk.danger,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: dark
                                    ? AmlTheme.darkSurface
                                    : Colors.white,
                                width: 1.5,
                              ),
                            ),
                            child: const SizedBox(width: 10, height: 10),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.15,
                        fontWeight: FontWeight.w800,
                        color: ink,
                      ),
                    ),
                  ),
                  if (wide)
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: AmlTheme.mutedOf(context),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppVisual {
  const _AppVisual(this.icon, this.pastelKey);
  final IconData icon;
  final String pastelKey;
}

_AppVisual _visualFor(String packageName) {
  if (packageName == 'one.aml.messageme') {
    return const _AppVisual(Icons.chat_bubble_rounded, 'messageme');
  }
  if (packageName == 'one.aml.oneauth' || packageName == 'one.aml.one_auth') {
    return const _AppVisual(Icons.shield_rounded, 'oneauth');
  }
  if (packageName == 'one.aml.securekeyboard') {
    return const _AppVisual(Icons.keyboard_rounded, 'keyboard');
  }
  if (packageName == 'one.aml.launcher') {
    return const _AppVisual(Icons.home_rounded, 'launcher');
  }
  if (packageName == 'one.aml.onebrowser') {
    return const _AppVisual(Icons.public_rounded, 'browser');
  }
  if (packageName == 'one.aml.onemail') {
    return const _AppVisual(Icons.mail_rounded, 'mail');
  }
  if (packageName == 'one.aml.onedrop') {
    return const _AppVisual(Icons.water_drop_rounded, 'drop');
  }
  if (packageName == 'one.aml.gallery') {
    return const _AppVisual(Icons.photo_rounded, 'gallery');
  }
  if (packageName == 'one.aml.store') {
    return const _AppVisual(Icons.shopping_bag_rounded, 'store');
  }
  if (packageName == 'one.aml.diagnostic') {
    return const _AppVisual(Icons.monitor_heart_rounded, 'diagnostic');
  }
  if (isOfficialAppBuilderPackage(packageName)) {
    return const _AppVisual(Icons.auto_awesome_rounded, 'builder');
  }
  if (isAppBuilderPackage(packageName)) {
    return _AppVisual(Icons.sports_esports_rounded, packageName);
  }
  return _AppVisual(Icons.apps_rounded, packageName);
}
