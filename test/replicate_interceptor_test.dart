import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:replicate_interceptor/replicate_interceptor.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

/// Lightweight [NetworkEventSink] that collects events in memory.
class _CollectingSink implements NetworkEventSink {
  final List<NetworkEvent> events = [];

  @override
  void sendEvent(NetworkEvent event) => events.add(event);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('NetworkEvent', () {
    test('toJson contains all required fields', () {
      final event = NetworkEvent(
        id: 'test-id',
        timestamp: '2024-01-01T00:00:00.000Z',
        method: 'GET',
        url: 'https://example.com/api',
        requestHeaders: {'accept': 'application/json'},
        statusCode: 200,
        responseHeaders: {'content-type': 'application/json'},
        responseBody: '{"ok":true}',
        durationMs: 42,
        isSuccess: true,
      );

      final json = event.toJson();
      expect(json['id'], 'test-id');
      expect(json['method'], 'GET');
      expect(json['url'], 'https://example.com/api');
      expect(json['statusCode'], 200);
      expect(json['durationMs'], 42);
      expect(json['isSuccess'], true);
      expect(json['requestHeaders'], {'accept': 'application/json'});
      expect(json['responseBody'], '{"ok":true}');
    });

    test('null optional fields are preserved in toJson', () {
      final event = NetworkEvent(
        id: 'x',
        timestamp: '2024-01-01T00:00:00.000Z',
        method: 'POST',
        url: 'https://example.com',
        requestHeaders: {},
        durationMs: 0,
        isSuccess: false,
      );

      final json = event.toJson();
      expect(json['statusCode'], isNull);
      expect(json['requestBody'], isNull);
      expect(json['responseBody'], isNull);
    });

    test('toString() returns valid JSON', () {
      final event = NetworkEvent(
        id: 'y',
        timestamp: '2024-01-01T00:00:00.000Z',
        method: 'GET',
        url: 'https://example.com',
        requestHeaders: {},
        durationMs: 10,
        isSuccess: true,
      );
      expect(() => jsonDecode(event.toString()), returnsNormally);
    });
  });

  group('ReplicateHttpClientWrapper', () {
    test('returns the response body unchanged', () async {
      final sink = _CollectingSink();
      final mockHttp = MockClient((_) async => http.Response(
            '{"hello":"world"}',
            200,
            headers: {'content-type': 'application/json'},
          ));
      final wrapper = ReplicateHttpClientWrapper(mockHttp, sink);

      final response = await wrapper.get(Uri.parse('https://example.com/api'));

      expect(response.statusCode, 200);
      expect(response.body, '{"hello":"world"}');
    });

    test('records a successful GET event', () async {
      final sink = _CollectingSink();
      final mockHttp = MockClient((_) async => http.Response(
            '{"hello":"world"}',
            200,
            headers: {'content-type': 'application/json'},
          ));
      final wrapper = ReplicateHttpClientWrapper(mockHttp, sink);

      await wrapper.get(Uri.parse('https://example.com/api'));

      expect(sink.events, hasLength(1));
      final event = sink.events.first;
      expect(event.method, 'GET');
      expect(event.url, 'https://example.com/api');
      expect(event.statusCode, 200);
      expect(event.isSuccess, true);
      expect(event.responseBody, '{"hello":"world"}');
      expect(event.durationMs, greaterThanOrEqualTo(0));
      // id should be a non-empty string (UUID)
      expect(event.id, isNotEmpty);
      // timestamp should be ISO 8601
      expect(DateTime.tryParse(event.timestamp), isNotNull);
    });

    test('records a POST with request body', () async {
      final sink = _CollectingSink();
      final mockHttp = MockClient((_) async => http.Response('created', 201));
      final wrapper = ReplicateHttpClientWrapper(mockHttp, sink);

      await wrapper.post(
        Uri.parse('https://example.com/users'),
        body: '{"name":"Alice"}',
        headers: {'content-type': 'application/json'},
      );

      expect(sink.events.first.requestBody, '{"name":"Alice"}');
      expect(sink.events.first.statusCode, 201);
      expect(sink.events.first.isSuccess, true);
    });

    test('records a 4xx response as not successful', () async {
      final sink = _CollectingSink();
      final mockHttp =
          MockClient((_) async => http.Response('not found', 404));
      final wrapper = ReplicateHttpClientWrapper(mockHttp, sink);

      final response =
          await wrapper.get(Uri.parse('https://example.com/missing'));

      expect(response.statusCode, 404);
      expect(sink.events.first.isSuccess, false);
      expect(sink.events.first.statusCode, 404);
    });

    test('records a network failure and re-throws the error', () async {
      final sink = _CollectingSink();
      final mockHttp =
          MockClient((_) async => throw const SocketException('no route'));
      final wrapper = ReplicateHttpClientWrapper(mockHttp, sink);

      await expectLater(
        wrapper.get(Uri.parse('https://example.com')),
        throwsA(isA<SocketException>()),
      );

      expect(sink.events, hasLength(1));
      expect(sink.events.first.isSuccess, false);
      expect(sink.events.first.statusCode, isNull);
    });
  });
}
