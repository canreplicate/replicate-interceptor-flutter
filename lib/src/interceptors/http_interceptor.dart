import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../intercept_player.dart';
import '../network_event.dart';
import '../simvault_client.dart';

/// A drop-in [http.Client] wrapper that forwards every request/response pair
/// to SimVault.
///
/// Obtain an instance via [SimVaultInterceptor.wrapHttpClient]:
/// ```dart
/// final client = SimVaultInterceptor.wrapHttpClient(http.Client());
/// final response = await client.get(Uri.parse('https://example.com/api'));
/// ```
///
/// The original client is returned unchanged when the interceptor is inactive
/// (i.e. the app was not launched by SimVault).
class SimVaultHttpClientWrapper extends http.BaseClient {
  final http.Client _inner;
  final NetworkEventSink _simvault;
  static const _uuid = Uuid();

  SimVaultHttpClientWrapper(this._inner, this._simvault);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final id = _uuid.v4();
    final timestamp = DateTime.now().toIso8601String();
    final stopwatch = Stopwatch()..start();

    // Capture request body for non-streaming requests.
    String? requestBody;
    if (request is http.Request && request.body.isNotEmpty) {
      requestBody = request.body;
    }

    // In replay mode: return recorded response without hitting the network.
    if (_simvault is SimVaultClient) {
      final client = _simvault as SimVaultClient;

      if (client.isReplayMode) {
        final recorded = client.replay(request.method, request.url.toString());
        if (recorded != null) {
          final bytes = utf8.encode(recorded.responseBody ?? '');
          return http.StreamedResponse(
            Stream.value(bytes),
            recorded.statusCode ?? 200,
            contentLength: bytes.length,
            headers: recorded.responseHeaders ?? {},
          );
        }
      }

      // In intercept mode: modify request and/or response, always hit real network.
      if (client.isInterceptMode) {
        final override = client.intercept(request.method, request.url.toString());
        print('🎯 [http] intercept ${request.method} ${request.url} → override=$override');
        if (override != null) {
          request = _applyRequestOverride(request, override);
          requestBody = override.requestBodyOverride ?? requestBody;
        }

        try {
          final response = await _inner.send(request);
          final bytes = await response.stream.toBytes();
          stopwatch.stop();

          String? responseBody;
          try {
            responseBody = utf8.decode(bytes);
          } catch (_) {
            responseBody = '<binary ${bytes.length} bytes>';
          }

          _simvault.sendEvent(NetworkEvent(
            id: id,
            timestamp: timestamp,
            method: request.method,
            url: request.url.toString(),
            requestHeaders: Map<String, String>.from(request.headers),
            requestBody: requestBody,
            statusCode: override?.statusCodeOverride ?? response.statusCode,
            responseHeaders: Map<String, String>.from(response.headers),
            responseBody: override?.responseBodyOverride ?? responseBody,
            durationMs: stopwatch.elapsedMilliseconds,
            isSuccess: (override?.statusCodeOverride ?? response.statusCode) >= 200 &&
                (override?.statusCodeOverride ?? response.statusCode) < 300,
          ));

          final effectiveBytes = override?.responseBodyOverride != null
              ? utf8.encode(override!.responseBodyOverride!)
              : bytes;

          return http.StreamedResponse(
            Stream.value(effectiveBytes),
            override?.statusCodeOverride ?? response.statusCode,
            contentLength: effectiveBytes.length,
            request: response.request,
            headers: response.headers,
            isRedirect: response.isRedirect,
            persistentConnection: response.persistentConnection,
            reasonPhrase: response.reasonPhrase,
          );
        } catch (e, st) {
          stopwatch.stop();
          Error.throwWithStackTrace(e, st);
        }
      }
    }

    try {
      final response = await _inner.send(request);

      // Drain the response stream so we can inspect the body, then re-wrap it
      // so the caller can still read it normally.
      final bytes = await response.stream.toBytes();
      stopwatch.stop();

      String? responseBody;
      try {
        responseBody = utf8.decode(bytes);
      } catch (_) {
        responseBody = '<binary ${bytes.length} bytes>';
      }

      // === VERY LOUD DEBUG ===
      print('''
🚀🚀🚀 SENDING NETWORK EVENT TO WEBSOCKET 🚀🚀🚀
  Event ID: $id
  Method: ${request.method}
  URL: ${request.url}
  Status: ${response.statusCode}
  Duration: ${stopwatch.elapsedMilliseconds}ms
''');

      _simvault.sendEvent(
        NetworkEvent(
          id: id,
          timestamp: timestamp,
          method: request.method,
          url: request.url.toString(),
          requestHeaders: Map<String, String>.from(request.headers),
          requestBody: requestBody,
          statusCode: response.statusCode,
          responseHeaders: Map<String, String>.from(response.headers),
          responseBody: responseBody,
          durationMs: stopwatch.elapsedMilliseconds,
          isSuccess: response.statusCode >= 200 && response.statusCode < 300,
        ),
      );

      print('✅ Event sent to _simvault.sendEvent() — waiting for WebSocket to deliver it');
      // Rebuild the StreamedResponse with the already-consumed bytes.
      return http.StreamedResponse(
        Stream.value(bytes),
        response.statusCode,
        contentLength: bytes.length,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (e, st) {
      stopwatch.stop();
      // Record the failure so SimVault shows it in the timeline.

      print('''
🚀🚀🚀 ERROR SENDING NETWORK EVENT TO WEBSOCKET 🚀🚀🚀
  Event ID: $id
  Method: ${request.method}
  URL: ${request.url}
]  Duration: ${stopwatch.elapsedMilliseconds}ms
''');

      _simvault.sendEvent(
        NetworkEvent(
          id: id,
          timestamp: timestamp,
          method: request.method,
          url: request.url.toString(),
          requestHeaders: Map<String, String>.from(request.headers),
          requestBody: requestBody,
          durationMs: stopwatch.elapsedMilliseconds,
          isSuccess: false,
        ),
      );
      Error.throwWithStackTrace(e, st);
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }

  /// Rebuilds [request] with the request body replaced by [override.requestBodyOverride].
  /// Only applies to [http.Request] (non-streaming). Streaming requests are returned unchanged.
  http.BaseRequest _applyRequestOverride(http.BaseRequest request, TapeOverride override) {
    if (override.requestBodyOverride == null) return request;
    if (request is! http.Request) return request;

    final modified = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..body = override.requestBodyOverride!;
    return modified;
  }
}
