import 'dart:convert';
import 'dart:typed_data';

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

    // Capture request body bytes from all request types.
    Uint8List? requestBodyRaw;
    String? requestContentType;
    if (request is http.Request && request.body.isNotEmpty) {
      requestBodyRaw = Uint8List.fromList(utf8.encode(request.body));
      requestContentType = request.headers['content-type'];
    } else if (request is http.MultipartRequest) {
      // Finalize to get the byte stream — we must reconstruct a StreamedRequest.
      requestContentType = request.headers['content-type'] ??
          'multipart/form-data; boundary=${request.hashCode}';
      final finalized = request.finalize();
      requestBodyRaw = await finalized.toBytes();
      // Rebuild as a StreamedRequest so _inner.send() still works.
      final replacement = http.StreamedRequest(request.method, request.url)
        ..headers.addAll(request.headers);
      replacement.contentLength = requestBodyRaw.length;
      replacement.sink.add(requestBodyRaw);
      // ignore: unawaited_futures
      replacement.sink.close();
      request = replacement;
    } else if (request is http.StreamedRequest) {
      requestContentType = request.headers['content-type'];
      // Read the stream, then create a new StreamedRequest with the captured bytes.
      final finalized = request.finalize();
      requestBodyRaw = await finalized.toBytes();
      final replacement = http.StreamedRequest(request.method, request.url)
        ..headers.addAll(request.headers);
      replacement.contentLength = requestBodyRaw.length;
      replacement.sink.add(requestBodyRaw);
      // ignore: unawaited_futures
      replacement.sink.close();
      request = replacement;
    }

    // Encode request body for tape storage.
    EncodedBody? encodedReqBody;
    if (requestBodyRaw != null && requestBodyRaw.isNotEmpty) {
      encodedReqBody = NetworkEvent.encodeBody(requestBodyRaw, requestContentType);
    }

    // In replay mode: return recorded response without hitting the network.
    if (_replicate is ReplicateClient) {
      final client = _replicate as ReplicateClient;

      if (client.isReplayMode) {
        final recorded = client.replay(request.method, request.url.toString());
        if (recorded != null) {
          final bytes = recorded.responseBodyBytes;
          return http.StreamedResponse(
            Stream.value(bytes),
            recorded.statusCode ?? 200,
            contentLength: bytes.length,
            headers: recorded.responseHeaders ?? {},
          );
        }
      }

      // In intercept mode: check manual tape entries first, then real network.
      if (client.isInterceptMode) {
        // Manual tape entries are served without hitting the network.
        final manualEntry = client.replayManualEntry(request.method, request.url.toString());
        if (manualEntry != null) {
          final bytes = manualEntry.responseBodyBytes;
          return http.StreamedResponse(
            Stream.value(bytes),
            manualEntry.statusCode ?? 200,
            contentLength: bytes.length,
            headers: manualEntry.responseHeaders ?? {},
          );
        }

        final override = client.intercept(request.method, request.url.toString());
        if (kDebugMode) debugPrint('🎯 [http] intercept ${request.method} ${request.url} → override=$override');
        if (override != null) {
          if (override.hasRequestOverride) {
            request = _applyRequestOverride(request, override);
            encodedReqBody = override.requestBodyOverrideEncoded;
          }
        }

        try {
          final response = await _inner.send(request);
          final bytes = await response.stream.toBytes();
          stopwatch.stop();

          final respContentType = response.headers['content-type'];
          final encodedRespBody = NetworkEvent.encodeBody(bytes, respContentType);

          final effectiveStatus = (override != null && override.hasResponseOverride && override.statusCodeOverride != null)
              ? override.statusCodeOverride!
              : response.statusCode;
          final EncodedBody effectiveRespBody;
          final Uint8List effectiveBytes;
          if (override != null && override.hasResponseOverride && override.responseBodyOverride != null) {
            effectiveRespBody = override.responseBodyOverrideEncoded!;
            effectiveBytes = override.responseBodyOverrideBytes!;
          } else {
            effectiveRespBody = encodedRespBody;
            effectiveBytes = Uint8List.fromList(bytes);
          }

          _replicate.sendEvent(NetworkEvent(
            id: id,
            timestamp: timestamp,
            method: request.method,
            url: request.url.toString(),
            requestHeaders: Map<String, String>.from(request.headers),
            requestBody: encodedReqBody?.body,
            requestBodyEncoding: encodedReqBody?.encoding ?? 'utf8',
            statusCode: effectiveStatus,
            responseHeaders: Map<String, String>.from(response.headers),
            responseBody: effectiveRespBody.body,
            responseBodyEncoding: effectiveRespBody.encoding,
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

      final respContentType = response.headers['content-type'];
      final encodedRespBody = NetworkEvent.encodeBody(bytes, respContentType);

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
          requestBody: encodedReqBody?.body,
          requestBodyEncoding: encodedReqBody?.encoding ?? 'utf8',
          statusCode: response.statusCode,
          responseHeaders: Map<String, String>.from(response.headers),
          responseBody: encodedRespBody.body,
          responseBodyEncoding: encodedRespBody.encoding,
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
          requestBody: encodedReqBody?.body,
          requestBodyEncoding: encodedReqBody?.encoding ?? 'utf8',
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
    // For any request type, replace body with the override bytes as a new Request.
    final overrideBytes = override.requestBodyOverrideBytes;
    if (overrideBytes == null) return request;

    final modified = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = overrideBytes;
    return modified;
  }
}
