import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/adb/package_service.dart';
import 'adb_providers.dart';
import 'logcat_providers.dart';

final packageServiceProvider = Provider<PackageService>((ref) {
  return PackageService(ref.watch(adbClientProvider));
});

final packagesProvider =
    FutureProvider.autoDispose.family<List<InstalledPackage>, String>((
      ref,
      serial,
    ) {
      return ref.watch(packageServiceProvider).listPackages(serial);
    });

class AppSessionState {
  const AppSessionState({
    this.serial,
    this.packageName,
    this.activity,
    this.pid,
    this.launch,
    this.launching = false,
    this.showAllLogs = false,
    this.errorMessage,
    this.active = false,
  });

  final String? serial;
  final String? packageName;
  final String? activity;
  final int? pid;
  final AppLaunchResult? launch;
  final bool launching;
  final bool showAllLogs;
  final String? errorMessage;
  final bool active;

  AppSessionState copyWith({
    String? serial,
    String? packageName,
    String? activity,
    int? pid,
    AppLaunchResult? launch,
    bool? launching,
    bool? showAllLogs,
    String? errorMessage,
    bool? active,
    bool clearError = false,
    bool clearPid = false,
  }) {
    return AppSessionState(
      serial: serial ?? this.serial,
      packageName: packageName ?? this.packageName,
      activity: activity ?? this.activity,
      pid: clearPid ? pid : (pid ?? this.pid),
      launch: launch ?? this.launch,
      launching: launching ?? this.launching,
      showAllLogs: showAllLogs ?? this.showAllLogs,
      errorMessage: clearError ? errorMessage : (errorMessage ?? this.errorMessage),
      active: active ?? this.active,
    );
  }
}

class AppSessionController extends Notifier<AppSessionState> {
  var _disposed = false;

  @override
  AppSessionState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
    });
    return const AppSessionState();
  }

  void setShowAllLogs(bool value) {
    if (_disposed) return;
    state = state.copyWith(showAllLogs: value);
  }

  Future<void> startAndWatch({
    required String serial,
    required String packageName,
    void Function()? onWatching,
  }) async {
    state = AppSessionState(
      serial: serial,
      packageName: packageName,
      launching: true,
      active: true,
    );
    try {
      await ref.read(logcatSessionProvider.notifier).watchDevice(serial);
      if (_disposed) return;
      onWatching?.call();
      final launch = await ref
          .read(packageServiceProvider)
          .startApp(serial, packageName);
      if (_disposed) return;
      state = state.copyWith(
        launching: false,
        pid: launch.pid,
        activity: launch.component,
        launch: launch,
        clearError: true,
        errorMessage: null,
      );
    } catch (err) {
      if (_disposed) return;
      state = state.copyWith(
        launching: false,
        errorMessage: '$err',
        clearError: true,
      );
    }
  }

  Future<void> stop() async {
    await ref.read(logcatSessionProvider.notifier).stop();
    if (_disposed) return;
    state = const AppSessionState();
  }
}

final appSessionProvider =
    NotifierProvider<AppSessionController, AppSessionState>(
      AppSessionController.new,
    );
