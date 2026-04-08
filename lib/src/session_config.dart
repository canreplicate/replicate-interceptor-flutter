import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Reads the session config that SimVault writes to the app's Documents folder
/// before launching the app. The presence of this file signals that the app
/// was launched by SimVault (not a normal dev run).
///
/// File location: `Documents/simvault_session.json`
/// ```json
/// {"sessionId": "...", "mode": "record|replay|intercept"}
/// ```
class SimVaultSessionConfig {
  final String sessionId;

  /// `'record'`, `'replay'`, `'intercept'`, or `'dump_keystore'`
  final String mode;

  /// When `true`, the interceptor restores Keychain entries from
  /// `Documents/simvault_keystore.json` on `init()` before the app runs.
  final bool restoreKeystore;

  const SimVaultSessionConfig({
    required this.sessionId,
    required this.mode,
    this.restoreKeystore = false,
  });

  static Future<SimVaultSessionConfig?> read() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/simvault_session.json');
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final sessionId = raw['sessionId'] as String?;
      if (sessionId == null || sessionId.isEmpty) return null;
      return SimVaultSessionConfig(
        sessionId: sessionId,
        mode: raw['mode'] as String? ?? 'record',
        restoreKeystore: raw['restoreKeystore'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }
}
