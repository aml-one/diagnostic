// Human titles and Pick an app grouping.

/// Pick an app shelf: official AOW, user projects from App Builder, other apps.
enum PackagePickerGroup { aow, appBuilder, thirdParty }

/// AmL One World packages share the `one.aml.` prefix.
bool isAowPackage(String packageName) =>
    packageName.startsWith('one.aml.');

/// App Builder the product (`one.aml.appbuilder.v4`, frozen `appbuilder2`).
bool isOfficialAppBuilderPackage(String packageName) {
  if (packageName == 'one.aml.appbuilder' ||
      packageName == 'one.aml.appbuilder2') {
    return true;
  }
  return packageName.startsWith('one.aml.appbuilder.v');
}

/// User projects built with App Builder — not the studio itself.
bool isAppBuilderPackage(String packageName) {
  if (isOfficialAppBuilderPackage(packageName)) return false;
  return packageName.startsWith('one.aml.ab2.') ||
      packageName.startsWith('one.aml.ab.') ||
      packageName.startsWith('one.aml.appbuilder.');
}

/// Official AmL apps on the AOW shelf (includes App Builder itself).
bool isOfficialAowPackage(String packageName) =>
    isAowPackage(packageName) && !isAppBuilderPackage(packageName);

PackagePickerGroup packagePickerGroup(String packageName) {
  if (isAppBuilderPackage(packageName)) return PackagePickerGroup.appBuilder;
  if (isAowPackage(packageName)) return PackagePickerGroup.aow;
  return PackagePickerGroup.thirdParty;
}

/// Product names for official AOW packages (not the generic title-case).
String? officialAowTitle(String packageName) {
  const exact = <String, String>{
    'one.aml.messageme': 'MessageMe',
    'one.aml.oneauth': 'OneAuth',
    'one.aml.one_auth': 'OneAuth',
    'one.aml.securekeyboard': 'AmL Keyboard',
    'one.aml.launcher': 'AmL Launcher',
    'one.aml.onebrowser': 'OneBrowser',
    'one.aml.onemail': 'One Mail',
    'one.aml.onedrop': 'OneDrop',
    'one.aml.gallery': 'Gallery',
    'one.aml.store': 'AmL One',
    'one.aml.pixx': 'pixx',
    'one.aml.aurora': 'Aurora',
    'one.aml.diagnostic': 'Diagnostic',
  };
  final mapped = exact[packageName];
  if (mapped != null) return mapped;
  if (isOfficialAppBuilderPackage(packageName)) return 'App Builder';
  return null;
}

/// Title shown on Pick an app. Underscores become spaces; first letter of
/// each word is capitalized.
String displayPackageTitle(String packageName) {
  final name = packageName.trim();
  if (name.isEmpty) return name;

  final official = officialAowTitle(name);
  if (official != null) return official;

  final abPrefix = _appBuilderPrefix(name);
  if (abPrefix != null) {
    return _appBuilderTitle(name.substring(abPrefix.length));
  }

  if (isAowPackage(name)) {
    return _titleCaseTokens(_splitNameTokens(name.substring('one.aml.'.length)));
  }

  return _thirdPartyTitle(name);
}

String? _appBuilderPrefix(String packageName) {
  if (isOfficialAppBuilderPackage(packageName)) return null;
  if (packageName.startsWith('one.aml.ab2.')) return 'one.aml.ab2.';
  if (packageName.startsWith('one.aml.ab.')) return 'one.aml.ab.';
  if (packageName.startsWith('one.aml.appbuilder.')) {
    return 'one.aml.appbuilder.';
  }
  return null;
}

/// `gyaloglomail_catcheck_purrs` → `Catcheck Purrs [gyaloglomail]`.
String _appBuilderTitle(String remainder) {
  if (remainder.isEmpty) return remainder;
  final split = remainder.indexOf('_');
  if (split < 0) {
    return _titleCaseTokens(_splitNameTokens(remainder));
  }
  final userId = remainder.substring(0, split);
  final app = remainder.substring(split + 1);
  if (app.isEmpty) {
    return _titleCaseTokens(_splitNameTokens(userId));
  }
  return '${_titleCaseTokens(_splitNameTokens(app))} [$userId]';
}

/// `com.accuweather.android` → `Android (Accuweather)`.
String _thirdPartyTitle(String packageName) {
  final parts = packageName.split('.');
  if (parts.isEmpty) return packageName;
  final last = _titleCaseTokens(_splitNameTokens(parts.last));
  if (parts.length < 2) return last;
  final vendor = _titleCaseTokens(_splitNameTokens(parts[parts.length - 2]));
  if (vendor.isEmpty) return last;
  return '$last ($vendor)';
}

List<String> _splitNameTokens(String raw) {
  return raw
      .split(RegExp(r'[._]+'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
}

String _titleCaseTokens(Iterable<String> tokens) {
  return tokens.map(_capitalizeFirst).join(' ');
}

String _capitalizeFirst(String token) {
  if (token.isEmpty) return token;
  return '${token[0].toUpperCase()}${token.substring(1)}';
}
