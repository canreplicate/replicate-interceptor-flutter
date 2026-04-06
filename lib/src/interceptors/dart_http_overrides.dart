import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../intercept_player.dart';
import '../network_event.dart';
import '../simvault_client.dart';

/// Sets `HttpOverrides.global` so that every [dart:io] [HttpClient] created
/// after [SimVaultInterceptor.init] is automatically intercepted — including
/// clients created inside third-party packages.
///
/// The previous [HttpOverrides] (if any) is preserved via composition so other
/// overrides (e.g. from `flutter_test`) keep working.
class SimVaultHttpOverrides extends HttpOverrides {
  final HttpOverrides? _previous;
  final NetworkEventSink _simvault;

  SimVaultHttpOverrides({
    required NetworkEventSink client,
    HttpOverrides? previous,
  })  : _simvault = client,
        _previous = previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner = _previous != null
        ? _previous.createHttpClient(context)
        : super.createHttpClient(context);
    return _SimVaultHttpClient(inner, _simvault);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _SimVaultHttpClient
// Delegates everything to [_inner]; overrides open*/get*/post*/… so that the
// returned request is wrapped.
// ─────────────────────────────────────────────────────────────────────────────

class _SimVaultHttpClient implements HttpClient {
  final HttpClient _inner;
  final NetworkEventSink _simvault;

  _SimVaultHttpClient(this._inner, this._simvault);

  Future<HttpClientRequest> _wrap(
    Future<HttpClientRequest> future,
    String method,
    String url,
  ) async {
    final req = await future;
    // Pass _inner (the real unwrapped HttpClient) so _sendWithOverriddenBody
    // can open a fresh connection without going through HttpOverrides again.
    return _SimVaultHttpClientRequest(req, _simvault, method, url, _inner);
  }

  // ---- Request factories ----

  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      _wrap(_inner.open(method, host, port, path), method,
          'http://$host:$port$path');

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _wrap(_inner.openUrl(method, url), method, url.toString());

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _wrap(_inner.get(host, port, path), 'GET', 'http://$host:$port$path');

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _wrap(_inner.getUrl(url), 'GET', url.toString());

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _wrap(_inner.post(host, port, path), 'POST', 'http://$host:$port$path');

  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      _wrap(_inner.postUrl(url), 'POST', url.toString());

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _wrap(_inner.put(host, port, path), 'PUT', 'http://$host:$port$path');

  @override
  Future<HttpClientRequest> putUrl(Uri url) =>
      _wrap(_inner.putUrl(url), 'PUT', url.toString());

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _wrap(_inner.delete(host, port, path), 'DELETE',
          'http://$host:$port$path');

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _wrap(_inner.deleteUrl(url), 'DELETE', url.toString());

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _wrap(_inner.head(host, port, path), 'HEAD', 'http://$host:$port$path');

  @override
  Future<HttpClientRequest> headUrl(Uri url) =>
      _wrap(_inner.headUrl(url), 'HEAD', url.toString());

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _wrap(_inner.patch(host, port, path), 'PATCH',
          'http://$host:$port$path');

  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _wrap(_inner.patchUrl(url), 'PATCH', url.toString());

  // ---- Delegated properties ----

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) =>
      _inner.maxConnectionsPerHost = value;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)?
              f) =>
      _inner.authenticate = f;

  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;

  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)?
              callback) =>
      _inner.badCertificateCallback = callback;

  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _inner.connectionFactory = f;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

// ─────────────────────────────────────────────────────────────────────────────
// _SimVaultHttpClientRequest
// Captures bytes written to the sink; wraps close() to intercept the response.
// ─────────────────────────────────────────────────────────────────────────────

class _SimVaultHttpClientRequest implements HttpClientRequest {
  final HttpClientRequest _inner;
  final NetworkEventSink _simvault;
  final String _method;
  final String _url;
  // The real (unwrapped) HttpClient — used by _sendWithOverriddenBody to avoid
  // re-entering HttpOverrides.global and causing infinite recursion.
  final HttpClient _rawClient;

  final String _id = const Uuid().v4();
  final String _timestamp = DateTime.now().toIso8601String();
  final Stopwatch _stopwatch = Stopwatch()..start();
  final List<int> _bodyBytes = [];

  // Memoised future so that both close() and done return the same instance.
  Future<HttpClientResponse>? _closeFuture;

  _SimVaultHttpClientRequest(
      this._inner, this._simvault, this._method, this._url, this._rawClient);

  // ---- Body interception ----

  @override
  void add(List<int> data) {
    _bodyBytes.addAll(data);
    _inner.add(data);
  }

  @override
  void write(Object? obj) {
    final str = '$obj';
    _bodyBytes.addAll(encoding.encode(str));
    _inner.write(obj);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _bodyBytes.addAll(encoding.encode(objects.join(separator)));
    _inner.writeAll(objects, separator);
  }

  @override
  void writeln([Object? obj = '']) {
    _bodyBytes.addAll(encoding.encode('$obj\n'));
    _inner.writeln(obj);
  }

  @override
  void writeCharCode(int charCode) {
    _bodyBytes.add(charCode);
    _inner.writeCharCode(charCode);
  }

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) {
    // Buffer chunks locally and forward them to the inner sink.
    final captured = stream.map((chunk) {
      _bodyBytes.addAll(chunk);
      return chunk;
    });
    return _inner.addStream(captured);
  }

  // ---- close() / done ----

  @override
  Future<HttpClientResponse> close() {
    _closeFuture ??= _doClose();
    return _closeFuture!;
  }

  Future<HttpClientResponse> _doClose() async {
    if (_simvault is SimVaultClient) {
      final client = _simvault as SimVaultClient;

      // In replay mode: return recorded response without touching the network.
      if (client.isReplayMode) {
        final recorded = client.replay(_method, _url);
        if (recorded != null) {
          _inner.abort();
          return _SimVaultReplayResponse(recorded);
        }
      }

      // In intercept mode: optionally replace request body, then apply response overrides.
      if (client.isInterceptMode) {
        final override = client.intercept(_method, _url);
        if (override != null && override.requestBodyOverride != null) {
          // dart:io doesn't let us rewrite bytes already written to _inner.
          // Abort this request and open a fresh one with the overridden body.
          _inner.abort();
          final overrideResponse = await _sendWithOverriddenBody(override);
          if (overrideResponse != null) return overrideResponse;
          // If that fails, fall through to original request (already aborted —
          // surface as a network error by rethrowing below).
        } else if (override != null && override.hasResponseOverride) {
          // No request change — send normally, wrap response on the way back.
          final response = await _inner.close();
          _stopwatch.stop();
          return _SimVaultInterceptResponse(response, override);
        }
      }
    }

    final response = await _inner.close();
    _stopwatch.stop();

    // Snapshot request headers now that they've been fully written.
    final reqHeaders = <String, String>{};
    _inner.headers.forEach((name, values) {
      reqHeaders[name] = values.join(', ');
    });

    String? requestBody;
    if (_bodyBytes.isNotEmpty) {
      try {
        requestBody = utf8.decode(_bodyBytes);
      } catch (_) {
        requestBody = '<binary ${_bodyBytes.length} bytes>';
      }
    }

    return _SimVaultHttpClientResponse(
      response,
      _simvault,
      _method,
      _url,
      _id,
      _timestamp,
      _stopwatch.elapsedMilliseconds,
      reqHeaders,
      requestBody,
    );
  }

  /// Opens a brand-new [HttpClientRequest] to the same URL with the overridden
  /// body and returns the response (with optional response overrides applied).
  ///
  /// Uses [_rawClient] (the real, unwrapped [HttpClient]) so that the new
  /// request does NOT re-enter [HttpOverrides.global] and cause infinite
  /// recursion.
  Future<HttpClientResponse?> _sendWithOverriddenBody(TapeOverride override) async {
    try {
      final uri = Uri.parse(_url);
      // Use the raw (unwrapped) client — NOT HttpClient() which would go through
      // HttpOverrides.global again and re-trigger this same intercept path.
      final newRequest = await _rawClient.openUrl(_method, uri);

      // Copy headers from original request.
      _inner.headers.forEach((name, values) {
        for (final v in values) {
          newRequest.headers.add(name, v);
        }
      });

      final bodyBytes = utf8.encode(override.requestBodyOverride!);
      newRequest.contentLength = bodyBytes.length;
      newRequest.add(bodyBytes);

      final response = await newRequest.close();
      // Do NOT close _rawClient — it is shared and managed by _SimVaultHttpClient.

      if (override.hasResponseOverride) {
        return _SimVaultInterceptResponse(response, override);
      }
      return response;
    } catch (e) {
      print('[SimVault] ❌ dart:io intercept body override failed: $e');
      return null;
    }
  }

  @override
  Future<HttpClientResponse> get done => close();

  // ---- Pure delegates ----

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<dynamic> flush() => _inner.flush();

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;

  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  String get method => _inner.method;

  @override
  Uri get uri => _inner.uri;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  List<Cookie> get cookies => _inner.cookies;
}

// ─────────────────────────────────────────────────────────────────────────────
// _SimVaultHttpClientResponse
// Wraps the response Stream to capture the body; fires the SimVault event
// once the stream is fully consumed.
// ─────────────────────────────────────────────────────────────────────────────

class _SimVaultHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final HttpClientResponse _inner;
  final NetworkEventSink _simvault;
  final String _method;
  final String _url;
  final String _id;
  final String _timestamp;
  final int _durationMs;
  final Map<String, String> _reqHeaders;
  final String? _requestBody;

  _SimVaultHttpClientResponse(
    this._inner,
    this._simvault,
    this._method,
    this._url,
    this._id,
    this._timestamp,
    this._durationMs,
    this._reqHeaders,
    this._requestBody,
  );

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final buffer = <int>[];
    return _inner.listen(
      (data) {
        buffer.addAll(data);
        onData?.call(data);
      },
      onError: onError,
      onDone: () {
        _record(buffer);
        onDone?.call();
      },
      cancelOnError: cancelOnError,
    );
  }

  void _record(List<int> bytes) {
    final respHeaders = <String, String>{};
    _inner.headers.forEach((k, v) => respHeaders[k] = v.join(', '));

    String? responseBody;
    if (bytes.isNotEmpty) {
      try {
        responseBody = utf8.decode(bytes);
      } catch (_) {
        responseBody = '<binary ${bytes.length} bytes>';
      }
    }

    _simvault.sendEvent(NetworkEvent(
      id: _id,
      timestamp: _timestamp,
      method: _method,
      url: _url,
      requestHeaders: _reqHeaders,
      requestBody: _requestBody,
      statusCode: _inner.statusCode,
      responseHeaders: respHeaders,
      responseBody: responseBody,
      durationMs: _durationMs,
      isSuccess: _inner.statusCode >= 200 && _inner.statusCode < 300,
    ));
  }

  // ---- Pure delegates for HttpClientResponse ----

  @override
  X509Certificate? get certificate => _inner.certificate;

  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  int get contentLength => _inner.contentLength;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  Future<Socket> detachSocket() => _inner.detachSocket();

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  bool get isRedirect => _inner.isRedirect;

  @override
  bool get persistentConnection => _inner.persistentConnection;

  @override
  String get reasonPhrase => _inner.reasonPhrase;

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) =>
      _inner.redirect(method, url, followLoops);

  @override
  List<RedirectInfo> get redirects => _inner.redirects;

  @override
  int get statusCode => _inner.statusCode;
}

// ─────────────────────────────────────────────────────────────────────────────
// _SimVaultInterceptResponse
// Wraps a real HttpClientResponse but overrides status code and/or body bytes
// when a TapeOverride specifies them. Used in intercept mode.
// ─────────────────────────────────────────────────────────────────────────────

class _SimVaultInterceptResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final HttpClientResponse _inner;
  final TapeOverride _override;
  late final List<int> _overrideBytes;

  _SimVaultInterceptResponse(this._inner, this._override) {
    _overrideBytes = _override.responseBodyOverride != null
        ? utf8.encode(_override.responseBodyOverride!)
        : [];
  }

  @override
  int get statusCode => _override.statusCodeOverride ?? _inner.statusCode;

  @override
  String get reasonPhrase => _inner.reasonPhrase;

  @override
  int get contentLength =>
      _override.responseBodyOverride != null ? _overrideBytes.length : _inner.contentLength;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  bool get persistentConnection => _inner.persistentConnection;

  @override
  bool get isRedirect => _inner.isRedirect;

  @override
  List<RedirectInfo> get redirects => _inner.redirects;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  X509Certificate? get certificate => _inner.certificate;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;

  @override
  Future<Socket> detachSocket() => _inner.detachSocket();

  @override
  Future<HttpClientResponse> redirect([String? method, Uri? url, bool? followLoops]) =>
      _inner.redirect(method, url, followLoops);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_override.responseBodyOverride != null) {
      // Drain real response to avoid connection leaks, then emit override bytes.
      _inner.listen((_) {}, onDone: () {});
      return Stream.value(_overrideBytes).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
    }
    return _inner.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _SimVaultReplayResponse
// Synthesised HttpClientResponse returned when a tape entry matches a request.
// The real network is never contacted.
// ─────────────────────────────────────────────────────────────────────────────

class _SimVaultReplayResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final NetworkEvent _event;
  final List<int> _bodyBytes;

  _SimVaultReplayResponse(this._event)
      : _bodyBytes = utf8.encode(_event.responseBody ?? '');

  @override
  int get statusCode => _event.statusCode ?? 200;

  @override
  String get reasonPhrase => '';

  @override
  int get contentLength => _bodyBytes.length;

  @override
  HttpHeaders get headers => _MapHttpHeaders(_event.responseHeaders);

  @override
  bool get persistentConnection => false;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  List<Cookie> get cookies => const [];

  @override
  X509Certificate? get certificate => null;

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  Future<Socket> detachSocket() =>
      throw UnsupportedError('detachSocket not supported in replay mode');

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) =>
      throw UnsupportedError('redirect not supported in replay mode');

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream.value(_bodyBytes).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _MapHttpHeaders
// Minimal HttpHeaders implementation backed by a plain Map, used by
// _SimVaultReplayResponse to surface recorded response headers.
// ─────────────────────────────────────────────────────────────────────────────

class _MapHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _map;

  _MapHttpHeaders(Map<String, String>? source)
      : _map = source?.map((k, v) => MapEntry(k.toLowerCase(), [v])) ?? {};

  @override
  List<String>? operator [](String name) => _map[name.toLowerCase()];

  @override
  String? value(String name) => _map[name.toLowerCase()]?.join(', ');

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _map.forEach(action);

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      _map.update(name.toLowerCase(), (l) => l..add(value.toString()),
          ifAbsent: () => [value.toString()]);

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _map[name.toLowerCase()] = [value.toString()];

  @override
  void remove(String name, Object value) =>
      _map[name.toLowerCase()]?.remove(value.toString());

  @override
  void removeAll(String name) => _map.remove(name.toLowerCase());

  @override
  void noFolding(String name) {}

  @override
  void clear() => _map.clear();

  // Typed header accessors — parsed on demand or stubbed.
  @override
  DateTime? get date => null;
  @override
  set date(DateTime? value) {}

  @override
  DateTime? get expires => null;
  @override
  set expires(DateTime? value) {}

  @override
  DateTime? get ifModifiedSince => null;
  @override
  set ifModifiedSince(DateTime? value) {}

  @override
  String? get host => null;
  @override
  set host(String? value) {}

  @override
  int? get port => null;
  @override
  set port(int? value) {}

  @override
  ContentType? get contentType => null;
  @override
  set contentType(ContentType? value) {}

  @override
  int get contentLength => -1;
  @override
  set contentLength(int value) {}

  @override
  bool get persistentConnection => false;
  @override
  set persistentConnection(bool value) {}

  @override
  bool get chunkedTransferEncoding => false;
  @override
  set chunkedTransferEncoding(bool value) {}
}
