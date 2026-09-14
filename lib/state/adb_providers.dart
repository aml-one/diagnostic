import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/adb/adb_client.dart';
import '../core/diagnostics/app_log.dart';

final adbClientProvider = Provider<AdbClient>((ref) => AdbClient());

final adbAvailableProvider = FutureProvider<bool>((ref) async {
  final available = await ref.watch(adbClientProvider).isAvailable();
  AppLog.i('adb', available ? 'adb available' : 'adb not found on PATH');
  return available;
});

final devicesProvider = StreamProvider<List<AdbDevice>>((ref) {
  return ref.watch(adbClientProvider).watchDevices().handleError((
    Object err,
    StackTrace stack,
  ) {
    AppLog.e('adb', 'device list failed', err, stack);
    Error.throwWithStackTrace(err, stack);
  });
});

final selectedDeviceProvider = StateProvider<AdbDevice?>((ref) => null);
