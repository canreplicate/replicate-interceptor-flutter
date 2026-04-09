import 'dart:convert';
import 'dart:typed_data';

/// Minimal interface required by interceptors to forward events.
///
/// [ReplicateClient] is the production implementation; tests can provide a
/// lightweight mock without depending on the WebSocket machinery.
abstract interface class NetworkEventSink {
  void sendEvent(NetworkEvent event);
}

/// Content-type patterns that are stored as UTF-8 strings in tape JSON.
/// Everything else is base64-encoded.
const _textContentTypes = [
  'application/json',
  'text/',
  'application/xml',
  'application/x-www-form-urlencoded',
  'application/graphql',
];

/// Returns `true` if [contentType] represents a text-based body that can be
/// safely stored as a UTF-8 string.
bool _isTextContentType(String? contentType) {
  if (contentType == null || contentType.isEmpty) return true; // assume text
  final lower = contentType.toLowerCase();
  return _textContentTypes.any((t) => lower.contains(t));
}

/// Result of encoding a body for tape JSON storage.
class EncodedBody {
  final String body;
  final String encoding; // "utf8" or "base64"
  const EncodedBody(this.body, this.encoding);
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

  /// Request body as a string — either UTF-8 text or base64-encoded binary.
  /// Check [requestBodyEncoding] to determine which.
  final String? requestBody;

  /// `"utf8"` (default) or `"base64"`.
  final String requestBodyEncoding;

  /// HTTP status code of the response, or null if the request never completed.
  final int? statusCode;

  /// Response headers, or null if no response was received.
  final Map<String, String>? responseHeaders;

  /// Response body as a string — either UTF-8 text or base64-encoded binary.
  /// Check [responseBodyEncoding] to determine which.
  final String? responseBody;

  /// `"utf8"` (default) or `"base64"`.
  final String responseBodyEncoding;

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
    this.requestBodyEncoding = 'utf8',
    this.statusCode,
    this.responseHeaders,
    this.responseBody,
    this.responseBodyEncoding = 'utf8',
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
        requestBodyEncoding:
            json['requestBodyEncoding'] as String? ?? 'utf8',
        statusCode: json['statusCode'] as int?,
        responseHeaders: json['responseHeaders'] != null
            ? Map<String, String>.from(json['responseHeaders'] as Map)
            : null,
        responseBody: json['responseBody'] as String?,
        responseBodyEncoding:
            json['responseBodyEncoding'] as String? ?? 'utf8',
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
        'requestBodyEncoding': requestBodyEncoding,
        'statusCode': statusCode,
        'responseHeaders': responseHeaders,
        'responseBody': responseBody,
        'responseBodyEncoding': responseBodyEncoding,
        'durationMs': durationMs,
        'isSuccess': isSuccess,
      };

  /// Decodes [requestBody] into raw bytes based on [requestBodyEncoding].
  Uint8List get requestBodyBytes {
    if (requestBody == null) return Uint8List(0);
    if (requestBodyEncoding == 'base64') {
      return base64Decode(requestBody!);
    }
    return Uint8List.fromList(utf8.encode(requestBody!));
  }

  /// Decodes [responseBody] into raw bytes based on [responseBodyEncoding].
  Uint8List get responseBodyBytes {
    if (responseBody == null) return Uint8List(0);
    if (responseBodyEncoding == 'base64') {
      return base64Decode(responseBody!);
    }
    return Uint8List.fromList(utf8.encode(responseBody!));
  }

  /// Encodes raw [bytes] for storage in tape JSON, choosing UTF-8 or base64
  /// based on the [contentType] header value.
  static EncodedBody encodeBody(List<int> bytes, String? contentType) {
    if (_isTextContentType(contentType)) {
      try {
        final text = utf8.decode(bytes);
        return EncodedBody(text, 'utf8');
      } catch (_) {
        // Not valid UTF-8 despite text content-type — fall through to base64.
      }
    }
    return EncodedBody(base64Encode(bytes), 'base64');
  }

  @override
  String toString() => jsonEncode(toJson());
}
