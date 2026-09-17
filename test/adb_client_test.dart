import 'package:flutter_test/flutter_test.dart';

import 'package:diagnostic/core/adb/adb_client.dart';

void main() {
  test('parses adb devices -l', () {
    const stdout = '''
List of devices attached
emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
R5CT123ABC             unauthorized usb:1-1 transport_id:2
deadbeef               offline
''';
    final devices = parseDevicesOutput(stdout);
    expect(devices, hasLength(3));
    expect(devices[0].serial, 'emulator-5554');
    expect(devices[0].state, AdbDeviceState.device);
    expect(devices[0].model, 'sdk gphone64 arm64');
    expect(devices[0].product, 'sdk_gphone64_arm64');
    expect(devices[1].state, AdbDeviceState.unauthorized);
    expect(devices[2].state, AdbDeviceState.offline);
  });

  test('AdbCancelToken cancel is sticky', () {
    final token = AdbCancelToken();
    expect(token.isCancelled, isFalse);
    token.cancel();
    expect(token.isCancelled, isTrue);
    token.cancel();
    expect(token.isCancelled, isTrue);
  });
}
