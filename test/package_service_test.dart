import 'package:flutter_test/flutter_test.dart';

import 'package:diagnostic/core/adb/package_service.dart';

void main() {
  test('parses pm list packages and -f', () {
    const stdout = '''
package:one.aml.messageme
package:/data/app/~~abc==/one.aml.one_auth-xyz==/base.apk=one.aml.one_auth
package:notaname
package:com.android.settings
''';
    final packages = parsePackageList(stdout);
    expect(
      packages.map((p) => p.packageName),
      ['one.aml.messageme', 'one.aml.one_auth', 'com.android.settings'],
    );
    expect(packages[1].apkPath, contains('one.aml.one_auth'));
    expect(packages[0].shortName, 'messageme');
  });

  test('parses resolve-activity --brief', () {
    const stdout = '''
priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true
one.aml.messageme/.MainActivity
''';
    expect(
      parseResolveActivityBrief(stdout, 'one.aml.messageme'),
      'one.aml.messageme/.MainActivity',
    );
  });

  test('parses dumpsys MAIN/LAUNCHER activity', () {
    const stdout = '''
Activity Resolver Table:
  Non-Data Actions:
      android.intent.action.MAIN:
        8f3e2a1 one.aml.messageme/.MainActivity filter 1a2b
          Action: "android.intent.action.MAIN"
          Category: "android.intent.category.LAUNCHER"
''';
    expect(
      parseLaunchActivityFromDumpsys(stdout, 'one.aml.messageme'),
      'one.aml.messageme/.MainActivity',
    );
  });

  test('parses am start -W timing', () {
    const stdout = '''
Starting: Intent { cmp=one.aml.messageme/.MainActivity }
Status: ok
LaunchState: COLD
Activity: one.aml.messageme/.MainActivity
ThisTime: 456
TotalTime: 512
WaitTime: 600
Complete
''';
    final wait = parseAmStartWait(stdout);
    expect(wait.thisTimeMs, 456);
    expect(wait.totalTimeMs, 512);
    expect(wait.waitTimeMs, 600);
    expect(wait.launchState, 'COLD');
    expect(wait.component, 'one.aml.messageme/.MainActivity');
    expect(wait.status, 'ok');
  });

  test('parses pidof and ps -A', () {
    expect(parsePidof('12345\n'), 12345);
    expect(parsePidof('12345 12346'), 12345);
    const ps = '''
USER           PID  PPID     VSZ    RSS WCHAN            ADDR S NAME
u0_a12           1     0   10000    800 0                   S init
u0_a210      43210   888 1234567   9000 0                   S one.aml.messageme
''';
    expect(parsePidFromPs(ps, 'one.aml.messageme'), 43210);
  });

  test('rejects invalid package names', () {
    expect(isValidAndroidPackageName('one.aml.messageme'), isTrue);
    expect(isValidAndroidPackageName('com.foo;reboot'), isFalse);
    expect(isValidAndroidPackageName('settings'), isFalse);
  });
}
