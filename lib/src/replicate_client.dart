import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

import 'intercept_player.dart';
import 'network_event.dart';
import 'tape_player.dart';

class ReplicateClient implements NetworkEventSink {
  ReplicateClient._internal();
  static final ReplicateClient _instance = ReplicateClient._internal();
  factory ReplicateClient() => _instance;

  String? _sessionId;
  TapePlayer? _tapePlayer;
  InterceptPlayer? _interceptPlayer;

  bool _active = false;

  bool get isReplayMode => _tapePlayer != null;
  bool get isInterceptMode => _interceptPlayer != null;
  bool get isActive => _active;

  /// [mode] is `'record'` (default), `'replay'`, or `'intercept'`.
  /// It is passed from [ReplicateInterceptor.init] which reads it from
  /// `Documents/replicate_session.json` written by the Replicate desktop app.
  Future<void> init({
    required String sessionId,
    String mode = 'record',
  }) async {
    _sessionId = sessionId;
    _active = true;

    if (mode == 'replay') {
      if (kDebugMode) debugPrint('🎬 [ReplicateClient] REPLAY MODE — loading tape files');
      _tapePlayer = TapePlayer();
      await _tapePlayer!.load();
      return;
    }

    if (mode == 'intercept') {
      if (kDebugMode) debugPrint('🎯 [ReplicateClient] INTERCEPT MODE — loading override files');
      _interceptPlayer = InterceptPlayer();
      await _interceptPlayer!.load();
      if (kDebugMode) debugPrint('🎯 [ReplicateClient] InterceptPlayer loaded. isInterceptMode = $isInterceptMode');
      return;
    }

    if (kDebugMode) debugPrint('🔴 [ReplicateClient] RECORD MODE');
  }

  /// Returns the next recorded response for [method] + [url], or null if
  /// no tape entry matches (caller should fall through to real network).
  NetworkEvent? replay(String method, String url) =>
      _active ? _tapePlayer?.play(method, url) : null;

  /// Returns the [TapeOverride] for [method] + [url], or null if no override
  /// exists for this endpoint (caller should proceed with original request).
  TapeOverride? intercept(String method, String url) =>
      _active ? _interceptPlayer?.getOverride(method, url) : null;

  @override
  void sendEvent(NetworkEvent event) {
    if (!_active) return;

    if (kDebugMode) {
      debugPrint('''🚀 SENDING NETWORK EVENT:
  ID: ${event.id}
  ${event.method} ${event.url}
  Status: ${event.statusCode}''');
    }

    _writeEventToFile(event);
  }

  Future<void> _writeEventToFile(NetworkEvent event) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final tapeDir = Directory('${directory.path}/replicate_tape');

      if (!await tapeDir.exists()) {
        await tapeDir.create(recursive: true);
      }

      final file = File('${tapeDir.path}/${event.id}.json');
      await file.writeAsString(jsonEncode(event.toJson()) + '\n', mode: FileMode.append);

      if (kDebugMode) debugPrint('📁 Event saved to: ${file.path}');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Failed to write event to file: $e');
    }
  }

  void disable() => _active = false;
  void enable() => _active = true;

  void dispose() {
    _active = false;
    if (kDebugMode) debugPrint('[ReplicateClient] Disposed');
  }
}
