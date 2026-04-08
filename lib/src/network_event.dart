import 'dart:convert';

/// Minimal interface required by interceptors to forward events.
///
/// [ReplicateClient] is the production implementation; tests can provide a
/// lightweight mock without depending on the WebSocket machinery.
abstract interface class NetworkEventSink {
  void sendEvent(NetworkEvent event);
}

/// A captured HTTP request/response pair, ready to be sent to Replicate.
class NetworkEvent {
  /// Unique identifier (UUID v4) for this event.
  final String id;

  /// ISO 8601 timestamp of when the request was initiated.
  final String timestamp;

  /// HTTP method in upper-case (GET, POST, PUT, DELETE, PATCH, HEAD, …).
  final String method;

  /// Full request URL including query string.
  final String url;

  /// Request headers as a flat map (multi-value headers are joined with ", ").
  final Map<String, String> requestHeaders;

  /// Request body decoded as UTF-8, or null if there was no body.
  /// Binary payloads are represented as `<binary N bytes>`.
  final String? requestBody;

  /// HTTP status code of the response, or null if the request never completed.
  final int? statusCode;

  /// Response headers, or null if no response was received.
  final Map<String, String>? responseHeaders;

  /// Response body decoded as UTF-8, or null if no response was received.
  final String? responseBody;

  /// Elapsed time from request start to the last byte of the response, in ms.
  final int durationMs;

  /// True when [statusCode] is in the 200–299 range.
  final bool isSuccess;

  const NetworkEvent({
    required this.id,
    required this.timestamp,
    required this.method,
    required this.url,
    required this.requestHeaders,
    this.requestBody,
    this.statusCode,
    this.responseHeaders,
    this.responseBody,
    required this.durationMs,
    required this.isSuccess,
  });

  factory NetworkEvent.fromJson(Map<String, dynamic> json) => NetworkEvent(
        id: json['id'] as String,
        timestamp: json['timestamp'] as String,
        method: json['method'] as String,
        url: json['url'] as String,
        requestHeaders: json['requestHeaders'] != null
            ? Map<String, String>.from(json['requestHeaders'] as Map)
            : {},
        requestBody: json['requestBody'] as String?,
        statusCode: json['statusCode'] as int?,
        responseHeaders: json['responseHeaders'] != null
            ? Map<String, String>.from(json['responseHeaders'] as Map)
            : null,
        responseBody: json['responseBody'] as String?,
        durationMs: json['durationMs'] as int? ?? 0,
        isSuccess: json['isSuccess'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp,
        'method': method,
        'url': url,
        'requestHeaders': requestHeaders,
        'requestBody': requestBody,
        'statusCode': statusCode,
        'responseHeaders': responseHeaders,
        'responseBody': responseBody,
        'durationMs': durationMs,
        'isSuccess': isSuccess,
      };

  @override
  String toString() => jsonEncode(toJson());
}
