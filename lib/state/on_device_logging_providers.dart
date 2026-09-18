import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/adb/on_device_logging.dart';
import 'adb_providers.dart';

final onDeviceLoggingServiceProvider = Provider<OnDeviceLoggingService>((ref) {
  return OnDeviceLoggingService(ref.watch(adbClientProvider));
});

final onDeviceLoggingProvider =
    FutureProvider.autoDispose.family<OnDeviceLoggingSnapshot, String>((
      ref,
      serial,
    ) {
      return ref.watch(onDeviceLoggingServiceProvider).inspect(serial);
    });
