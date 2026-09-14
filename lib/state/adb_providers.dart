import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/adb/adb_client.dart';

final adbClientProvider = Provider<AdbClient>((ref) => AdbClient());

final adbAvailableProvider = FutureProvider<bool>((ref) {
  return ref.watch(adbClientProvider).isAvailable();
});

final devicesProvider = StreamProvider<List<AdbDevice>>((ref) {
  return ref.watch(adbClientProvider).watchDevices();
});

final selectedDeviceProvider = StateProvider<AdbDevice?>((ref) => null);
