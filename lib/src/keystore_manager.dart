import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Manages exporting and importing `flutter_secure_storage` Keychain entries
/// so that login state (auth tokens, etc.) survives Replicate snapshot restores.
///
/// **Security:** This class writes plaintext Keychain contents to a JSON file
/// in Documents/. It is guarded by [kReleaseMode] — all operations are no-ops
/// in release builds.
class KeystoreManager {
  static const _fileName = 'replicate_keystore.json';

  final FlutterSecureStorage _storage;

  KeystoreManager({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Reads all keys from `flutter_secure_storage` and returns them as a map.
  ///
  /// Returns `null` if storage is empty, unavailable, or running in release mode.
  Future<Map<String, String>?> export() async {
    assert(!kReleaseMode, 'KeystoreManager must not run in release builds');
    if (kReleaseMode) return null;

    try {
      final all = await _storage.readAll();
      if (all.isEmpty) {
        if (kDebugMode) debugPrint('[KeystoreManager] Secure storage is empty — nothing to export');
        return null;
      }
      if (kDebugMode) debugPrint('[KeystoreManager] Exported ${all.length} keystore entries');
      return all;
    } catch (e) {
      if (kDebugMode) debugPrint('[KeystoreManager] export() failed: $e');
      return null;
    }
  }

  /// Writes each key-value pair into `flutter_secure_storage`.
  Future<void> import(Map<String, String> entries) async {
    assert(!kReleaseMode, 'KeystoreManager must not run in release builds');
    if (kReleaseMode) return;

    try {
      for (final entry in entries.entries) {
        await _storage.write(key: entry.key, value: entry.value);
      }
      if (kDebugMode) debugPrint('[KeystoreManager] Imported ${entries.length} keystore entries');
    } catch (e) {
      if (kDebugMode) debugPrint('[KeystoreManager] import() failed: $e');
    }
  }

  /// Calls [export] and writes the result to `Documents/replicate_keystore.json`.
  ///
  /// Returns `true` if the file was written successfully.
  Future<bool> dumpToFile() async {
    assert(!kReleaseMode, 'KeystoreManager must not run in release builds');
    if (kReleaseMode) return false;

    try {
      final entries = await export();
      if (entries == null) return false;

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');

      final payload = {
        'entries': entries,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
      };

      await file.writeAsString(jsonEncode(payload));
      if (kDebugMode) debugPrint('[KeystoreManager] Keystore dumped to ${file.path}');
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[KeystoreManager] dumpToFile() failed: $e');
      return false;
    }
  }

  /// Reads `Documents/replicate_keystore.json`, writes entries into
  /// `flutter_secure_storage`, then deletes the file.
  ///
  /// Returns `true` if keystore was restored successfully.
  Future<bool> restoreFromFile() async {
    assert(!kReleaseMode, 'KeystoreManager must not run in release builds');
    if (kReleaseMode) return false;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');

      if (!await file.exists()) {
        if (kDebugMode) debugPrint('[KeystoreManager] No keystore file found — skipping restore');
        return false;
      }

      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final entries = (raw['entries'] as Map<String, dynamic>?)
          ?.map((k, v) => MapEntry(k, v as String));

      if (entries == null || entries.isEmpty) {
        if (kDebugMode) debugPrint('[KeystoreManager] Keystore file is empty — skipping');
        await file.delete();
        return false;
      }

      await import(entries);

      // Delete the plaintext file immediately after restoring to Keychain.
      await file.delete();
      if (kDebugMode) debugPrint('[KeystoreManager] Keystore restored and file deleted');
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[KeystoreManager] restoreFromFile() failed: $e');
      return false;
    }
  }
}
