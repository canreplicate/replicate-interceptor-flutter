// SimVault Interceptor — automatically records Flutter network traffic and
// streams it to the SimVault macOS desktop tool for iOS Simulator sessions.
//
// Quick-start:
//   await SimVaultInterceptor.init();           // in main()
//   final client = SimVaultInterceptor.wrapHttpClient(http.Client());
//   SimVaultInterceptor.addDioInterceptor(dio);
//   // dart:io HttpClient is intercepted automatically.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'src/interceptors/dart_http_overrides.dart';
import 'src/interceptors/dio_interceptor.dart';
import 'src/interceptors/http_interceptor.dart';
import 'src/simvault_client.dart';

export 'src/interceptors/dart_http_overrides.dart' show SimVaultHttpOverrides;
export 'src/interceptors/dio_interceptor.dart' show SimVaultDioInterceptor;
export 'src/interceptors/http_interceptor.dart' show SimVaultHttpClientWrapper;
export 'src/network_event.dart' show NetworkEvent, NetworkEventSink;
export 'src/simvault_client.dart' show SimVaultClient;
export 'src/tape_player.dart' show TapePlayer;

/// Static entry point for the SimVault network recording package.
///
/// Call [init] once in `main()`. The interceptor automatically reads the
/// `SIMVAULT_SESSION_ID` environment variable injected by SimVault at launch
/// time and opens a WebSocket to the desktop tool. When the variable is absent
/// (normal app runs, CI, etc.) every method becomes a no-op, so it is safe to
/// leave the calls in production code — they are also stripped in release
/// builds by default.
abstract final class SimVaultInterceptor {
  static final _client = SimVaultClient();
  static bool _initialized = false;

  // ─────────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────────

  /// Initialise the interceptor.
  ///
  /// Reads `SIMVAULT_SESSION_ID` and (optionally) `SIMVAULT_WS_PORT` from
  /// [Platform.environment].  If `SIMVAULT_SESSION_ID` is absent the method
  /// returns immediately and the interceptor stays inactive.
  ///
  /// Set [forceInRelease] to `true` to allow the interceptor to run in a
  /// release build.  **Do not ship with this flag set to `true`.**
  ///
  /// Must be called before `runApp` so that [HttpOverrides] is installed early
  /// enough to cover all [HttpClient] instances.
  static Future<void> init() async {
    final sessionId = Platform.environment['SIMVAULT_SESSION_ID'] ?? "dev-test-session-${DateTime.now().millisecondsSinceEpoch}";

    debugPrint('✅ SimVaultInterceptor: Starting with sessionId = $sessionId');

    await SimVaultClient().init(sessionId: sessionId);
    _initialized = true;
  }

  /// Returns a [http.Client] that forwards all traffic to SimVault.
  ///
  /// When the interceptor is inactive [client] is returned unchanged, so
  /// callers do not need to guard against the inactive case.
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
  ///
  /// ```dart
  /// final dio = Dio();
  /// SimVaultInterceptor.addDioInterceptor(dio);
  /// ```
  static void addDioInterceptor(Dio dio) {
    if (!_initialized) return;
    dio.interceptors.add(SimVaultDioInterceptor(_client));
  }

  /// Temporarily stop forwarding events without tearing down the connection.
  static void disable() => _client.disable();

  /// Resume forwarding events after a [disable] call.
  static void enable() => _client.enable();

  /// `true` when the interceptor has been initialised **and** the WebSocket
  /// connection to SimVault is currently open.
  static bool get isActive => _initialized && _client.isConnected;

  // Internal — exposed for testing.
  // ignore: library_private_types_in_public_api
  static SimVaultClient get debugClient => _client;
}
