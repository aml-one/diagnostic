import 'package:flutter_test/flutter_test.dart';

import 'package:diagnostic/core/adb/device_details.dart';

void main() {
  test('Watch title is manufacturer + model and serial', () {
    const details = AdbDeviceDetails(
      serial: 'bbd6506e',
      manufacturer: 'Xiaomi',
      brand: 'Xiaomi',
      model: '17 Ultra',
      marketName: 'Xiaomi 17 Ultra',
    );
    expect(details.brandedModel, 'Xiaomi 17 Ultra');
    expect(details.titleWithSerial(), 'Xiaomi 17 Ultra (bbd6506e)');
  });

  test('prefixes manufacturer when the marketing name omits it', () {
    const details = AdbDeviceDetails(
      serial: 'abc',
      manufacturer: 'Xiaomi',
      model: '17 Ultra',
    );
    expect(details.brandedModel, 'Xiaomi 17 Ultra');
    expect(details.titleWithSerial(), 'Xiaomi 17 Ultra (abc)');
  });

  test('nickname wins over the marketing name', () {
    const details = AdbDeviceDetails(
      serial: 'bbd6506e',
      manufacturer: 'Xiaomi',
      marketName: 'Xiaomi 17 Ultra',
    );
    expect(
      details.titleWithSerial(nickname: 'Studio Ultra'),
      'Studio Ultra (bbd6506e)',
    );
  });
}
