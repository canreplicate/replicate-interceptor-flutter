// SimVault Interceptor — automatically records Flutter network traffic and
// streams it to the SimVault macOS desktop tool for iOS Simulator sessions.
//
// Quick-start:
//   await SimVaultInterceptor.init();           // in main()
//   final client = SimVaultInterceptor.wrapHttpClient(http.Client());
//   SimVaultInterceptor.addDioInterceptor(dio);
//   // dart:io HttpClient is intercepted automatically.
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'src/interceptors/dart_http_overrides.dart';
import 'src/interceptors/dio_interceptor.dart';
import 'src/interceptors/http_interceptor.dart';
import 'src/session_config.dart';
import 'src/simvault_client.dart';

export 'src/interceptors/dart_http_overrides.dart' show SimVaultHttpOverrides;
export 'src/interceptors/dio_interceptor.dart' show SimVaultDioInterceptor;
export 'src/interceptors/http_interceptor.dart' show SimVaultHttpClientWrapper;
export 'src/intercept_player.dart' show InterceptPlayer, TapeOverride;
export 'src/network_event.dart' show NetworkEvent, NetworkEventSink;
export 'src/session_config.dart' show SimVaultSessionConfig;
export 'src/simvault_client.dart' show SimVaultClient;
export 'src/tape_player.dart' show TapePlayer;

/// Static entry point for the SimVault network recording package.
///
/// Call [init] once in `main()`, before `runApp`.
///
/// Activation is signalled by SimVault writing a `simvault_session.json` file
/// to the app's Documents directory before launching the app. When this file is
/// absent (normal dev runs, CI, etc.) every method is a no-op, so it is safe
/// to leave the calls in production code.
abstract final class SimVaultInterceptor {
  static final _client = SimVaultClient();
  static bool _initialized = false;

  // ─────────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────────

  /// Initialise the interceptor.
  ///
  /// Reads `Documents/simvault_session.json` written by the SimVault desktop
  /// app before launching this process. If the file is absent the interceptor
  /// stays inactive (normal dev / CI runs are unaffected).
  ///
  /// Must be called before `runApp` so that [HttpOverrides] is installed early
  /// enough to cover all [HttpClient] instances.
  static Future<void> init() async {
    final config = await SimVaultSessionConfig.read();

    if (config == null) {
      if (kDebugMode) debugPrint('[SimVaultInterceptor] No simvault_session.json — interceptor inactive');
      return;
    }

    if (kDebugMode) debugPrint('[SimVaultInterceptor] ✅ Activating: sessionId=${config.sessionId}, mode=${config.mode}');

    await SimVaultClient().init(sessionId: config.sessionId, mode: config.mode);
    _initialized = true;
  }

  /// Returns a [http.Client] that forwards all traffic to SimVault.
  ///
  /// When the interceptor is inactive [client] is returned unchanged.
  ///
  /// ```dart
  /// final client = SimVaultInterceptor.wrapHttpClient(http.Client());
  /// ```
  static http.Client wrapHttpClient(http.Client client) {
    if (!_initialized) return client;
    return SimVaultHttpClientWrapper(client, _client);
  }

  /// Attaches a [SimVaultDioInterceptor] to [dio].
  ///
  /// Does nothing when the interceptor is inactive.
  static void addDioInterceptor(Dio dio) {
    if (!_initialized) return;
    dio.interceptors.add(SimVaultDioInterceptor(_client));
  }

  /// Temporarily stop forwarding events without tearing down the connection.
  static void disable() => _client.disable();

  /// Resume forwarding events after a [disable] call.
  static void enable() => _client.enable();

  /// `true` when the interceptor has been initialised and is active.
  static bool get isActive => _initialized && _client.isActive;

  // Internal — exposed for testing.
  // ignore: library_private_types_in_public_api
  static SimVaultClient get debugClient => _client;
}
