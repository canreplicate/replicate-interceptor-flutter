import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'network_event.dart';
import 'tape_player.dart';

class SimVaultClient implements NetworkEventSink {
  SimVaultClient._internal();
  static final SimVaultClient _instance = SimVaultClient._internal();
  factory SimVaultClient() => _instance;

  WebSocketChannel? _channel;
  String? _sessionId;
  String _host = '127.0.0.1';
  int _port = 8889;
  bool _connected = false;
  bool _enabled = true;
  bool _disposed = false;
  Timer? _reconnectTimer;
  TapePlayer? _tapePlayer;

  bool get isConnected => _connected;
  bool get isReplayMode => _tapePlayer != null;

  Future<void> init({required String sessionId, String host = '127.0.0.1', int port = 8889}) async {
    _sessionId = sessionId;
    _host = host;
    _port = port;
    _disposed = false;

    final mode = Platform.environment['SIMVAULT_MODE'] ?? 'record';
    if (mode == 'replay') {
      debugPrint('[SimVaultClient] Replay mode — loading tape, skipping WebSocket');
      _tapePlayer = TapePlayer();
      await _tapePlayer!.load();
      return;
    }

    await _connect();
  }

  /// Returns the next recorded response for [method] + [url], or null if
  /// no tape entry matches (caller should fall through to real network).
  NetworkEvent? replay(String method, String url) => _tapePlayer?.play(method, url);

  Future<void> _connect() async {
    if (_disposed) return;

    try {
      final uri = Uri.parse('ws://$_host:$_port');
      debugPrint('[SimVaultClient] Connecting to $uri ...');

      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _connected = true;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;

      debugPrint('[SimVaultClient] ✅ Connected to SimVault');

      // Send hello
      _send({'type': 'hello', 'sessionId': _sessionId, 'version': '1.0.0'});

      await Future.delayed(const Duration(milliseconds: 800)); // ← Give time for handshake
      debugPrint('[SimVaultClient] Delay after hello — ready to send events');

      _channel!.stream.listen(
        (message) {
          debugPrint('[SimVaultClient] Received message from SimVault: $message');
        },
        onDone: _onDisconnected,
        onError: (e) {
          debugPrint('[SimVaultClient] WebSocket error: $e');
          _onDisconnected();
        },
        cancelOnError: false,
      );
    } catch (e) {
      _connected = false;
      debugPrint('[SimVaultClient] Connection failed: $e. Retrying in 3s...');
      _scheduleReconnect();
    }
  }

  void _onDisconnected() {
    if (_disposed) return;
    _connected = false;
    debugPrint('[SimVaultClient] Connection closed. Retrying in 3s...');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _connect);
  }

  @override
  void sendEvent(NetworkEvent event) {
    debugPrint('''🚀 SENDING NETWORK EVENT:
  ID: ${event.id}
  ${event.method} ${event.url}
  Status: ${event.statusCode}''');

    // PRIMARY: Always write to file (this is reliable)
    _writeEventToFile(event);

    // SECONDARY: Try WebSocket if connected
    if (_connected && _enabled) {
      try {
        _send({'type': 'network_event', 'data': event.toJson()});
        debugPrint('[SimVaultClient] ✅ Sent via WebSocket');
      } catch (e) {
        debugPrint('[SimVaultClient] WebSocket send failed: $e');
      }
    } else {
      debugPrint('[SimVaultClient] WebSocket not ready — using file fallback only');
    }
  }

  // Add this private method to the SimVaultClient class
  Future<void> _writeEventToFile(NetworkEvent event) async {
    try {
      // Correct way to get the app's Documents directory on iOS
      final directory = await getApplicationDocumentsDirectory();
      final tapeDir = Directory('${directory.path}/simvault_tape');

      if (!await tapeDir.exists()) {
        await tapeDir.create(recursive: true);
      }

      final file = File('${tapeDir.path}/${event.id}.json');
      await file.writeAsString(jsonEncode(event.toJson()) + '\n', mode: FileMode.append);

      debugPrint('📁 Event saved to: ${file.path}');
    } catch (e) {
      debugPrint('❌ Failed to write event to file: $e');
    }
  }

  void _send(Map<String, dynamic> payload) {
    try {
      final jsonString = jsonEncode(payload);
      _channel?.sink.add(jsonString);
      debugPrint('[SimVaultClient] ✅ Message added to sink: ${payload['type']}');
    } catch (e) {
      debugPrint('[SimVaultClient] ❌ Failed to send message: $e');
      _connected = false;
      _scheduleReconnect();
    }
  }

  void disable() => _enabled = false;
  void enable() => _enabled = true;

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    await _channel?.sink.close();
    _connected = false;
    debugPrint('[SimVaultClient] Disposed');
  }
}
