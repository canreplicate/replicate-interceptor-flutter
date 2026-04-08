import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../intercept_player.dart';
import '../network_event.dart';
import '../replicate_client.dart';

/// A drop-in [http.Client] wrapper that forwards every request/response pair
/// to Replicate.
///
/// Obtain an instance via [ReplicateInterceptor.wrapHttpClient]:
/// ```dart
/// final client = ReplicateInterceptor.wrapHttpClient(http.Client());
/// final response = await client.get(Uri.parse('https://example.com/api'));
/// ```
///
/// The original client is returned unchanged when the interceptor is inactive
/// (i.e. the app was not launched by Replicate).
class ReplicateHttpClientWrapper extends http.BaseClient {
  final http.Client _inner;
  final NetworkEventSink _replicate;
  static const _uuid = Uuid();

  ReplicateHttpClientWrapper(this._inner, this._replicate);

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
    if (_replicate is ReplicateClient) {
      final client = _replicate as ReplicateClient;

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
        if (kDebugMode) debugPrint('🎯 [http] intercept ${request.method} ${request.url} → override=$override');
        if (override != null) {
          if (override.hasRequestOverride) {
            request = _applyRequestOverride(request, override);
            requestBody = override.requestBodyOverride ?? requestBody;
          }
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

          final effectiveStatus = (override != null && override.hasResponseOverride && override.statusCodeOverride != null)
              ? override.statusCodeOverride!
              : response.statusCode;
          final effectiveBody = (override != null && override.hasResponseOverride && override.responseBodyOverride != null)
              ? override.responseBodyOverride!
              : responseBody;
          final effectiveBytes = (override != null && override.hasResponseOverride && override.responseBodyOverride != null)
              ? utf8.encode(override.responseBodyOverride!)
              : bytes;

          _replicate.sendEvent(NetworkEvent(
            id: id,
            timestamp: timestamp,
            method: request.method,
            url: request.url.toString(),
            requestHeaders: Map<String, String>.from(request.headers),
            requestBody: requestBody,
            statusCode: effectiveStatus,
            responseHeaders: Map<String, String>.from(response.headers),
            responseBody: effectiveBody,
            durationMs: stopwatch.elapsedMilliseconds,
            isSuccess: effectiveStatus >= 200 && effectiveStatus < 300,
          ));

          return http.StreamedResponse(
            Stream.value(effectiveBytes),
            effectiveStatus,
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

      if (kDebugMode) {
        debugPrint('''
🚀 SENDING NETWORK EVENT
  Event ID: $id
  Method: ${request.method}
  URL: ${request.url}
  Status: ${response.statusCode}
  Duration: ${stopwatch.elapsedMilliseconds}ms
''');
      }

      _replicate.sendEvent(
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

      if (kDebugMode) debugPrint('✅ Event sent to _replicate.sendEvent()');
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
      // Record the failure so Replicate shows it in the timeline.

      if (kDebugMode) {
        debugPrint('''
❌ NETWORK EVENT ERROR
  Event ID: $id
  Method: ${request.method}
  URL: ${request.url}
  Duration: ${stopwatch.elapsedMilliseconds}ms
''');
      }

      _replicate.sendEvent(
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
