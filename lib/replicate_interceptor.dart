// Replicate Interceptor — automatically records Flutter network traffic and
// streams it to the Replicate macOS desktop tool for iOS Simulator sessions.
//
// Quick-start:
//   await ReplicateInterceptor.init();           // in main()
//   final client = ReplicateInterceptor.wrapHttpClient(http.Client());
//   ReplicateInterceptor.addDioInterceptor(dio);
//   // dart:io HttpClient is intercepted automatically.
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'src/interceptors/dart_http_overrides.dart';
import 'src/interceptors/dio_interceptor.dart';
import 'src/interceptors/http_interceptor.dart';
import 'src/keystore_manager.dart';
import 'src/session_config.dart';
import 'src/replicate_client.dart';

export 'src/interceptors/dart_http_overrides.dart' show ReplicateHttpOverrides;
export 'src/interceptors/dio_interceptor.dart' show ReplicateDioInterceptor;
export 'src/interceptors/http_interceptor.dart' show ReplicateHttpClientWrapper;
export 'src/intercept_player.dart' show InterceptPlayer, TapeOverride;
export 'src/keystore_manager.dart' show KeystoreManager;
export 'src/network_event.dart' show NetworkEvent, NetworkEventSink;
export 'src/session_config.dart' show ReplicateSessionConfig;
export 'src/replicate_client.dart' show ReplicateClient;
export 'src/tape_player.dart' show TapePlayer;

/// Static entry point for the Replicate network recording package.
///
/// Call [init] once in `main()`, before `runApp`.
///
/// Activation is signalled by Replicate writing a `replicate_session.json` file
/// to the app's Documents directory before launching the app. When this file is
/// absent (normal dev runs, CI, etc.) every method is a no-op, so it is safe
/// to leave the calls in production code.
abstract final class ReplicateInterceptor {
  static final _client = ReplicateClient();
  static bool _initialized = false;

  // ─────────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────────

  /// Initialise the interceptor.
  ///
  /// Reads `Documents/replicate_session.json` written by the Replicate desktop
  /// app before launching this process. If the file is absent the interceptor
  /// stays inactive (normal dev / CI runs are unaffected).
  ///
  /// Must be called before `runApp` so that [HttpOverrides] is installed early
  /// enough to cover all [HttpClient] instances.
  static Future<void> init() async {
    try {
      await _doInit();
    } catch (e) {
      // Never crash the host app — if init fails, stay inactive.
      if (kDebugMode) debugPrint('[ReplicateInterceptor] ❌ init() failed — staying inactive: $e');
    }
  }

  static Future<void> _doInit() async {
    final config = await ReplicateSessionConfig.read();

    if (config == null) {
      if (kDebugMode) debugPrint('[ReplicateInterceptor] No replicate_session.json — interceptor inactive');
      return;
    }

    if (kDebugMode) debugPrint('[ReplicateInterceptor] ✅ Activating: sessionId=${config.sessionId}, mode=${config.mode}');

    // Restore Keychain entries before the app's auth logic runs.
    if (config.restoreKeystore && !kReleaseMode) {
      if (kDebugMode) debugPrint('[ReplicateInterceptor] Restoring keystore...');
      try {
        final restored = await KeystoreManager().restoreFromFile();
        if (kDebugMode) debugPrint('[ReplicateInterceptor] Keystore restore: ${restored ? 'success' : 'skipped'}');
      } catch (e) {
        if (kDebugMode) debugPrint('[ReplicateInterceptor] Keystore restore failed (non-fatal): $e');
      }
    }

    // dump_keystore mode: dump keystore and return without activating interceptors.
    if (config.mode == 'dump_keystore') {
      if (kDebugMode) debugPrint('[ReplicateInterceptor] dump_keystore mode — dumping and exiting');
      try {
        await KeystoreManager().dumpToFile();
      } catch (e) {
        if (kDebugMode) debugPrint('[ReplicateInterceptor] Keystore dump failed: $e');
      }
      return;
    }

    // restore_only mode: keystore was already restored above, nothing else to do.
    // Used by Quick Save restore — app runs normally with no interception.
    if (config.mode == 'restore_only') {
      if (kDebugMode) debugPrint('[ReplicateInterceptor] restore_only mode — keystore restored, staying inactive');
      return;
    }

    await ReplicateClient().init(sessionId: config.sessionId, mode: config.mode);
    _initialized = true;

    // In record mode, dump keystore after the app finishes initializing.
    // Deferred so WidgetsFlutterBinding is initialized before FlutterSecureStorage is accessed.
    if (config.mode == 'record' && !kReleaseMode) {
      Future.delayed(const Duration(seconds: 3), () {
        KeystoreManager().dumpToFile().catchError((_) {});
      });
    }
  }

  /// Dumps all `flutter_secure_storage` entries to
  /// `Documents/replicate_keystore.json`.
  ///
  /// Called automatically in record mode. Also used by `dump_keystore` mode.
  /// No-op in release builds.
  // Internal — not part of the public API. May be promoted in a future version.
  static Future<bool> dumpKeystore() async {
    if (kReleaseMode) return false;
    return KeystoreManager().dumpToFile();
  }

  /// Returns a [http.Client] that forwards all traffic to Replicate.
  ///
  /// When the interceptor is inactive [client] is returned unchanged.
  ///
  /// ```dart
  /// final client = ReplicateInterceptor.wrapHttpClient(http.Client());
  /// ```
  static http.Client wrapHttpClient(http.Client client) {
    if (!_initialized) return client;
    return ReplicateHttpClientWrapper(client, _client);
  }

  /// Attaches a [ReplicateDioInterceptor] to [dio].
  ///
  /// Does nothing when the interceptor is inactive.
  static void addDioInterceptor(Dio dio) {
    if (!_initialized) return;
    dio.interceptors.add(ReplicateDioInterceptor(_client));
  }

  /// Temporarily stop forwarding events without tearing down the connection.
  static void disable() => _client.disable();

  /// Resume forwarding events after a [disable] call.
  static void enable() => _client.enable();

  /// `true` when the interceptor has been initialised and is active.
  static bool get isActive => _initialized && _client.isActive;

  // Internal — exposed for testing.
  // ignore: library_private_types_in_public_api
  static ReplicateClient get debugClient => _client;
}
