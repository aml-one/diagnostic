import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/adb/adb_client.dart';
import '../core/adb/device_details.dart';
import '../core/diagnostics/app_log.dart';

final adbClientProvider = Provider<AdbClient>((ref) => AdbClient());

final adbAvailableProvider = FutureProvider<bool>((ref) async {
  final available = await ref.watch(adbClientProvider).isAvailable();
  AppLog.i(
    'adb',
    available
        ? 'adb available (${ref.read(adbClientProvider).resolvedSource?.name ?? 'unknown'})'
        : 'adb not found (bundled / PATH / SDK)',
  );
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

/// Manufacturer / model / marketing name for one attached serial.
///
/// Falls back to the thin `adb devices -l` fields when the device is not
/// ready for shell, or when getprop fails.
final deviceDetailsProvider =
    FutureProvider.family<AdbDeviceDetails, AdbDevice>((ref, device) async {
      final client = ref.watch(adbClientProvider);
      return readAdbDeviceDetails(client, device);
    });
