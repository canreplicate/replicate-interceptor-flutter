import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'network_event.dart';

/// Loads recorded tape files and replays them FIFO per `METHOD url` key.
///
/// Used when the app is launched with `SIMVAULT_MODE=replay`. Call [load]
/// once on startup, then call [play] for each outgoing request.
class TapePlayer {
  // "GET https://api.example.com/path" → ordered queue of recorded events
  final _queues = <String, Queue<NetworkEvent>>{};

  /// Reads all `*.json` files from `Documents/simvault_tape/` and builds
  /// the in-memory replay map.
  Future<void> load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final tapeDir = Directory('${dir.path}/simvault_tape');

      if (!await tapeDir.exists()) {
        debugPrint('[TapePlayer] simvault_tape/ not found — nothing to load');
        return;
      }

      final files = await tapeDir
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();

      for (final file in files) {
        try {
          final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          final event = NetworkEvent.fromJson(json);
          final key = '${event.method.toUpperCase()} ${event.url}';
          (_queues[key] ??= Queue<NetworkEvent>()).add(event);
        } catch (e) {
          debugPrint('[TapePlayer] Failed to parse ${file.path}: $e');
        }
      }

      final total = _queues.values.fold(0, (s, q) => s + q.length);
      debugPrint('[TapePlayer] Loaded $total events across ${_queues.length} endpoints');
    } catch (e) {
      debugPrint('[TapePlayer] load() error: $e');
    }
  }

  /// Returns the next recorded [NetworkEvent] for [method] + [url], or
  /// `null` if no match exists (caller should fall through to real network).
  NetworkEvent? play(String method, String url) {
    final key = '${method.toUpperCase()} $url';
    final queue = _queues[key];
    if (queue == null || queue.isEmpty) {
      debugPrint('[TapePlayer] MISS: $key');
      return null;
    }
    final event = queue.removeFirst();
    debugPrint('[TapePlayer] HIT: $key (${queue.length} remaining)');
    return event;
  }
}
