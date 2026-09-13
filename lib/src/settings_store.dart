import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'touchpad_settings.dart';

/// Persists [TouchpadSettings] (including the daemon host) between launches.
class SettingsStore {
  static const _key = 'touchpad_settings_v1';

  static Future<TouchpadSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const TouchpadSettings();
      return TouchpadSettings.fromJson(
          jsonDecode(raw) as Map<String, Object?>);
    } catch (_) {
      return const TouchpadSettings();
    }
  }

  static Future<void> save(TouchpadSettings s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(s.toJson()));
    } catch (_) {}
  }
}