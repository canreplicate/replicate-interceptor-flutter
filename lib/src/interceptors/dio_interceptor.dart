import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../network_event.dart';
import '../simvault_client.dart';

/// A Dio [Interceptor] that forwards every request/response pair to SimVault.
///
/// Add it to your [Dio] instance via [SimVaultInterceptor.addDioInterceptor]:
/// ```dart
/// final dio = Dio();
/// SimVaultInterceptor.addDioInterceptor(dio);
/// ```
///
/// Does nothing when the interceptor is inactive (i.e. the app was not
/// launched by SimVault).
class SimVaultDioInterceptor extends Interceptor {
  final NetworkEventSink _simvault;
  static const _uuid = Uuid();

  // Keys stored in RequestOptions.extra to carry timing data across callbacks.
  static const _kStart = '_sv_start_ms';
  static const _kId = '_sv_id';
  static const _kTs = '_sv_timestamp';

  SimVaultDioInterceptor(this._simvault);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_kStart] = DateTime.now().millisecondsSinceEpoch;
    options.extra[_kId] = _uuid.v4();
    options.extra[_kTs] = DateTime.now().toIso8601String();

    // In replay mode: resolve with recorded response without hitting the network.
    if (_simvault is SimVaultClient) {
      final recorded = (_simvault as SimVaultClient)
          .replay(options.method.toUpperCase(), options.uri.toString());
      if (recorded != null) {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: recorded.statusCode ?? 200,
            data: recorded.responseBody,
            headers: Headers.fromMap(
              (recorded.responseHeaders ?? {}).map((k, v) => MapEntry(k, [v])),
            ),
          ),
          true, // callFollowingResponseInterceptor
        );
        return;
      }
    }

    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    _record(response.requestOptions, response: response);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _record(err.requestOptions, error: err);
    handler.next(err);
  }

  void _record(
    RequestOptions options, {
    Response<dynamic>? response,
    DioException? error,
  }) {
    final startMs = options.extra[_kStart] as int? ??
        DateTime.now().millisecondsSinceEpoch;
    final id = options.extra[_kId] as String? ?? _uuid.v4();
    final timestamp =
        options.extra[_kTs] as String? ?? DateTime.now().toIso8601String();
    final durationMs = DateTime.now().millisecondsSinceEpoch - startMs;

    // Flatten request headers.
    final requestHeaders = <String, String>{};
    options.headers.forEach((k, v) {
      if (v != null) requestHeaders[k] = v.toString();
    });

    // Serialise request body.
    String? requestBody;
    final data = options.data;
    if (data != null) {
      try {
        requestBody = data is String ? data : jsonEncode(data);
      } catch (_) {
        requestBody = data.toString();
      }
    }

    // Resolve response (may come from a successful response or an error that
    // still carries a response, e.g. a 4xx/5xx).
    final resp = response ?? error?.response;
    int? statusCode = resp?.statusCode;

    Map<String, String>? responseHeaders;
    String? responseBody;
    if (resp != null) {
      responseHeaders = {};
      resp.headers.forEach((k, v) => responseHeaders![k] = v.join(', '));

      final body = resp.data;
      if (body != null) {
        try {
          responseBody = body is String ? body : jsonEncode(body);
        } catch (_) {
          responseBody = body.toString();
        }
      }
    }

    _simvault.sendEvent(NetworkEvent(
      id: id,
      timestamp: timestamp,
      method: options.method.toUpperCase(),
      url: options.uri.toString(),
      requestHeaders: requestHeaders,
      requestBody: requestBody,
      statusCode: statusCode,
      responseHeaders: responseHeaders,
      responseBody: responseBody,
      durationMs: durationMs,
      isSuccess: statusCode != null && statusCode >= 200 && statusCode < 300,
    ));
  }
}
