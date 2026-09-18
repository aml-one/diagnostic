import 'package:flutter_test/flutter_test.dart';

import 'package:diagnostic/core/adb/on_device_logging.dart';
import 'package:diagnostic/core/mobile/mdx_file.dart';
import 'package:diagnostic/core/mobile/phone_diagnostic.dart';

void main() {
  group('on-device logging dumpsys', () {
    test('detects granted=true form', () {
      const dump = '''
Package [one.aml.diagnostic] (u0):
  requested permissions:
    android.permission.READ_LOGS: granted=true
    android.permission.INTERNET: granted=true
''';
      expect(parseReadLogsGranted(dump), isTrue);
    });

    test('detects grantedPermissions block', () {
      const dump = '''
Package [one.aml.diagnostic]:
  grantedPermissions:
    android.permission.INTERNET
    android.permission.READ_LOGS
    android.permission.FOREGROUND_SERVICE
''';
      expect(parseReadLogsGranted(dump), isTrue);
    });

    test('missing when only requested', () {
      const dump = '''
Package [one.aml.diagnostic]:
  requested permissions:
    android.permission.READ_LOGS
  grantedPermissions:
    android.permission.INTERNET
''';
      expect(parseReadLogsGranted(dump), isFalse);
    });

    test('pm path installed', () {
      expect(
        parsePackageInstalledFromPmPath(
          'package:/data/app/~~x==/one.aml.diagnostic-y==/base.apk',
        ),
        isTrue,
      );
      expect(parsePackageInstalledFromPmPath(''), isFalse);
    });

    test('desktop grant also allows READ_DEVICE_LOGS AppOps', () {
      expect(kDeviceLogAppOps, contains('READ_DEVICE_LOGS'));
      expect(kDeviceLogAppOps, contains('10017'));
      expect(kDeviceLogAppOps, contains('114'));
      expect(kPmGrantReadLogsCommand, contains('10017'));
      expect(kPmGrantReadLogsCommand, contains('114'));
    });
  });

  group('mdx', () {
    test('round-trips header and body', () {
      final doc = parseMdx(
        composeMdx(
          header: MdxHeader(
            toolVersion: '1.0.3',
            device: '17 Ultra',
            manufacturer: 'Xiaomi',
            sdk: 35,
            packages: const ['one.aml.messageme'],
            levels: 'WEF',
            startedAt: '2026-09-17T17:00:00.000Z',
          ),
          body: '09-17 12:00:00.000  123  123 E Foo: boom\n',
        ),
      );
      expect(doc.header.magic, kMdxMagic);
      expect(doc.header.packages, ['one.aml.messageme']);
      expect(doc.header.levels, 'WEF');
      expect(doc.body, contains('E Foo: boom'));
    });

    test('round-trips MDXD1 diagnosis envelope', () {
      final doc = parseMdx(
        composeMdx(
          header: MdxHeader(
            magic: kMdxdMagic,
            toolVersion: '1.0.3',
            device: '17 Ultra',
            brand: 'Xiaomi',
            model: '17 Ultra',
            deviceName: 'Ambrus phone',
            appLabel: 'MessageMe',
            packages: const ['one.aml.messageme'],
            levels: 'diagnosis',
            startedAt: '2026-09-18T10:00:00.000Z',
            source: 'diagnosis',
          ),
          body: '{"topFinding":"crash"}',
        ),
      );
      expect(doc.header.magic, kMdxdMagic);
      expect(doc.header.isDiagnosis, isTrue);
      expect(doc.header.appLabel, 'MessageMe');
      expect(doc.header.brand, 'Xiaomi');
      expect(doc.body, contains('crash'));
    });

    test('rejects unknown magic', () {
      expect(
        () => parseMdx('{"magic":"NOPE"}\nbody'),
        throwsFormatException,
      );
    });
  });

  group('share targets', () {
    test('MessageMe and App Builder packages stay distinct', () {
      expect(kMessageMeAndroidPackage, 'one.aml.messageme');
      expect(kAppBuilderAndroidPackages, contains('one.aml.appbuilder.v4'));
      expect(
        kAppBuilderAndroidPackages.contains(kMessageMeAndroidPackage),
        isFalse,
      );
    });
  });
}
