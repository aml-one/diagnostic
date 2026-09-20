import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local prefs. DeepSeek keys stay in Windows Credential Manager.
class SettingsStore {
  SettingsStore({FlutterSecureStorage? storage})
    : _secure = storage ?? const FlutterSecureStorage();

  static const _deepSeekKey = 'deepseek_api_key';
  static const serverUploadKey = 'server_upload';

  final FlutterSecureStorage _secure;

  Future<String> deepSeekApiKey() =>
      _secure.read(key: _deepSeekKey).then((value) => value ?? '');

  Future<bool> hasDeepSeekApiKey() async {
    final key = await deepSeekApiKey();
    return key.trim().isNotEmpty;
  }

  Future<void> setDeepSeekApiKey(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await _secure.delete(key: _deepSeekKey);
      return;
    }
    await _secure.write(key: _deepSeekKey, value: trimmed);
  }

  /// Default on — every Watch / Diagnose / self-check goes to the server.
  Future<bool> serverUploadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(serverUploadKey) ?? true;
  }

  Future<void> setServerUploadEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(serverUploadKey, value);
  }
}

/// Status line only — never the full key.
String maskDeepSeekApiKey(String? key) {
  final trimmed = (key ?? '').trim();
  if (trimmed.isEmpty) return 'No key saved';
  if (trimmed.length < 8) return 'Key saved';
  final prefix = trimmed.substring(0, 3);
  final suffix = trimmed.substring(trimmed.length - 4);
  return 'Saved · $prefix••••$suffix';
}
