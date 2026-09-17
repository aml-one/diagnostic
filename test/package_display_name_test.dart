import 'package:flutter_test/flutter_test.dart';

import 'package:diagnostic/core/adb/package_display_name.dart';

void main() {
  test('groups AOW vs App Builder vs third-party', () {
    expect(packagePickerGroup('one.aml.messageme'), PackagePickerGroup.aow);
    expect(packagePickerGroup('one.aml.onedrop'), PackagePickerGroup.aow);
    expect(
      packagePickerGroup('one.aml.appbuilder.v4'),
      PackagePickerGroup.aow,
    );
    expect(
      packagePickerGroup('one.aml.appbuilder.v3'),
      PackagePickerGroup.aow,
    );
    expect(packagePickerGroup('one.aml.appbuilder2'), PackagePickerGroup.aow);
    expect(
      packagePickerGroup('one.aml.ab2.gyaloglomail_catcheck_purrs'),
      PackagePickerGroup.appBuilder,
    );
    expect(
      packagePickerGroup('one.aml.ab.gyaloglomail_catcheck_purrs'),
      PackagePickerGroup.appBuilder,
    );
    expect(
      packagePickerGroup('one.aml.appbuilder.gyaloglomail_starship'),
      PackagePickerGroup.appBuilder,
    );
    expect(
      packagePickerGroup('com.accuweather.android'),
      PackagePickerGroup.thirdParty,
    );
    expect(isOfficialAowPackage('one.aml.appbuilder.v4'), isTrue);
    expect(isAppBuilderPackage('one.aml.appbuilder.v4'), isFalse);
    expect(isAowPackage('one.aml.ab2.gyaloglomail_catcheck_purrs'), isTrue);
    expect(isOfficialAowPackage('one.aml.ab2.gyaloglomail_catcheck_purrs'), isFalse);
  });

  test('title-cases third-party last segment and vendor', () {
    expect(
      displayPackageTitle('com.accuweather.android'),
      'Android (Accuweather)',
    );
    expect(
      displayPackageTitle('com.alibaba.aliexpresshd'),
      'Aliexpresshd (Alibaba)',
    );
    expect(
      displayPackageTitle('com.amazon.appmanager'),
      'Appmanager (Amazon)',
    );
    expect(
      displayPackageTitle('com.android.deskclock'),
      'Deskclock (Android)',
    );
    expect(
      displayPackageTitle('cn.wps.moffice_eng'),
      'Moffice Eng (Wps)',
    );
  });

  test('formats App Builder packages with user id', () {
    expect(
      displayPackageTitle('one.aml.ab2.gyaloglomail_catcheck_purrs'),
      'Catcheck Purrs [gyaloglomail]',
    );
    expect(
      displayPackageTitle('one.aml.ab2.gyaloglomail_f1_zone'),
      'F1 Zone [gyaloglomail]',
    );
    expect(
      displayPackageTitle('one.aml.ab2.a_weather_chess_3d'),
      'Weather Chess 3d [a]',
    );
    expect(
      displayPackageTitle('one.aml.ab.gyaloglomail_catcheck_purrs'),
      'Catcheck Purrs [gyaloglomail]',
    );
    expect(isAppBuilderPackage('one.aml.appbuilder.v4'), isFalse);
    expect(
      displayPackageTitle('one.aml.appbuilder.v4'),
      'Appbuilder V4',
    );
    expect(
      displayPackageTitle('one.aml.appbuilder.gyaloglomail_starship'),
      'Starship [gyaloglomail]',
    );
  });

  test('title-cases AOW remainder and replaces underscores', () {
    expect(displayPackageTitle('one.aml.messageme'), 'Messageme');
    expect(displayPackageTitle('one.aml.one_auth'), 'One Auth');
    expect(displayPackageTitle('one.aml.securekeyboard'), 'Securekeyboard');
  });
}
