import '../onedrop/onedrop_watch.dart';
import 'logcat_parser.dart';

/// Tags that mention a package in the *message* but are not that app.
/// Launcher IconCustomizer is the ColorOS/HyperOS case that flooded OneDrop Watch.
const kLogcatOemPackageMentionTags = {
  'IconCustomizer',
  'ThemedIcon',
  'IconPolicy',
};

const kLogcatLifecycleTags = {
  'ActivityManager',
  'ActivityTaskManager',
  'WindowManager',
};

const kOneDropNearbyTags = {
  'WifiService',
  'WifiClient',
  'WifiNative',
  'WifiManager',
  'LocationManager',
  'NsdManager',
  'ConnectivityService',
  'NearbyConnections',
  'BluetoothAdapter',
  'BluetoothLeScanner',
};

/// Whether a Watch line belongs to [packageName] when pidof cannot see it.
///
/// OEM launchers log `one.aml.onedrop` in the message. OneDrop's own lines
/// use tags `OneDrop` / `OneDropP2p` / `OneDropEngine` and never mention the
/// package. Matching `raw.contains(package)` therefore hid the real logs.
bool shouldKeepWatchLine(
  LogcatLine line, {
  required Set<int> pids,
  String? packageName,
  required String levelsKey,
  required bool hideSpam,
  bool uidScoped = false,
}) {
  if (!line.isParsed) return true;
  final pkg = packageName?.trim();
  if (hideSpam &&
      (kLogcatNoiseTags.contains(line.tag) ||
          kLogcatOemPackageMentionTags.contains(line.tag))) {
    return false;
  }
  if (levelsKey.isNotEmpty && !levelsKey.contains(line.level)) {
    return false;
  }
  if (_isTaggedAppLog(line, pkg)) return true;
  if (pkg == kOneDropPackageName && isOneDropNearbyTag(line.tag)) return true;
  if (pids.isNotEmpty) {
    final pid = line.pid;
    if (pid != null && pids.contains(pid)) return true;
  }
  if (uidScoped && pkg != null && pkg.isNotEmpty) return true;
  if (pkg == null || pkg.isEmpty) return true;
  if (kLogcatLifecycleTags.contains(line.tag) && line.raw.contains(pkg)) {
    return true;
  }
  if (pkg == kOneDropPackageName && line.raw.contains(pkg)) return true;
  return false;
}

bool isOneDropNearbyTag(String tag) {
  if (tag.startsWith('BtGatt') || tag.startsWith('Bluetooth')) return true;
  return kOneDropNearbyTags.contains(tag);
}

bool _isTaggedAppLog(LogcatLine line, String? pkg) {
  if (pkg == kOneDropPackageName && isOneDropWatchLine(line)) return true;
  return false;
}
