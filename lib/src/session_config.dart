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

  /// `'record'`, `'replay'`, or `'intercept'`
  final String mode;

  const SimVaultSessionConfig({required this.sessionId, required this.mode});

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
      );
    } catch (_) {
      return null;
    }
  }
}
