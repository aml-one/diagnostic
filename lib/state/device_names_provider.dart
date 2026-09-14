import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/adb/adb_client.dart';

/// Single prefs key holding `{ serial: nickname }`.
const String kDeviceNicknamesPrefKey = 'device_nicknames';

/// User-chosen nicknames per device serial, persisted in shared_preferences.
///
/// State is a plain map so every row can resolve a label synchronously; the
/// initial load fills it in as soon as prefs answer.
class DeviceNamesController extends Notifier<Map<String, String>> {
  var _disposed = false;

  @override
  Map<String, String> build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    unawaited(_load());
    return const <String, String>{};
  }

  Future<void> _load() async {
    final stored = await _read();
    if (_disposed || stored == null) return;
    state = stored;
  }

  /// Sets (or clears, when [name] is blank) the nickname for [serial].
  Future<void> setName(String serial, String name) async {
    final trimmed = name.trim();
    final next = Map<String, String>.of(state);
    if (trimmed.isEmpty) {
      next.remove(serial);
    } else {
      next[serial] = trimmed;
    }
    if (!_disposed) state = next;
    await _write(next);
  }

  Future<void> clear(String serial) => setName(serial, '');

  /// Nickname for [serial], or null when the device was never renamed.
  String? nicknameFor(String serial) {
    final value = state[serial]?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<Map<String, String>?> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kDeviceNicknamesPrefKey);
      if (raw == null || raw.trim().isEmpty) return const <String, String>{};
      return decodeDeviceNicknames(raw);
    } on Object {
      // No prefs plugin (tests) or unreadable payload — stay with defaults.
      return null;
    }
  }

  Future<void> _write(Map<String, String> names) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (names.isEmpty) {
        await prefs.remove(kDeviceNicknamesPrefKey);
        return;
      }
      await prefs.setString(kDeviceNicknamesPrefKey, jsonEncode(names));
    } on Object {
      // Nickname persistence is best-effort; the session keeps the new label.
    }
  }
}

/// Tolerates hand-edited or legacy payloads. Exposed for tests.
Map<String, String> decodeDeviceNicknames(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return const <String, String>{};
  final out = <String, String>{};
  decoded.forEach((key, value) {
    if (key is! String || value is! String) return;
    final name = value.trim();
    if (name.isEmpty) return;
    out[key] = name;
  });
  return out;
}

final deviceNamesProvider =
    NotifierProvider<DeviceNamesController, Map<String, String>>(
      DeviceNamesController.new,
    );

/// Nickname when the user renamed the device, otherwise the adb model /
/// product / serial fallback from [AdbDevice.displayName].
String resolveDeviceLabel(Map<String, String> names, AdbDevice device) {
  final nickname = names[device.serial]?.trim();
  if (nickname != null && nickname.isNotEmpty) return nickname;
  return device.displayName;
}

/// Best label for a bare serial (Diagnose header) — nickname or the serial.
String resolveSerialLabel(Map<String, String> names, String serial) {
  final nickname = names[serial]?.trim();
  if (nickname != null && nickname.isNotEmpty) return nickname;
  return serial;
}
