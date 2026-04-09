import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'network_event.dart';

/// Loads recorded tape files and replays them FIFO per `METHOD url` key.
///
/// Used when the app is launched with `REPLICATE_MODE=replay`. Call [load]
/// once on startup, then call [play] for each outgoing request.
class TapePlayer {
  // "GET https://api.example.com/path" → ordered queue of recorded events
  final _queues = <String, Queue<NetworkEvent>>{};

  /// Reads all `*.json` files from `Documents/replicate_tape/` and builds
  /// the in-memory replay map.
  Future<void> load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final tapeDir = Directory('${dir.path}/replicate_tape');

      if (!await tapeDir.exists()) {
        if (kDebugMode) debugPrint('[TapePlayer] ⚠️ replicate_tape/ not found — nothing to load');
        return;
      }

      final files = await tapeDir
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();

      // Parse all events, partitioning manual vs recorded.
      final manual = <NetworkEvent>[];
      final recorded = <NetworkEvent>[];
      for (final file in files) {
        try {
          final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          final event = NetworkEvent.fromJson(json);
          if (event.source == 'manual') {
            manual.add(event);
          } else {
            recorded.add(event);
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[TapePlayer] Failed to parse ${file.path}: $e');
        }
      }

      // Build queues: manual entries first, then recorded (per endpoint).
      for (final event in manual) {
        final key = '${event.method.toUpperCase()} ${event.url}';
        (_queues[key] ??= Queue<NetworkEvent>()).add(event);
      }
      for (final event in recorded) {
        final key = '${event.method.toUpperCase()} ${event.url}';
        (_queues[key] ??= Queue<NetworkEvent>()).add(event);
      }

      final total = _queues.values.fold(0, (s, q) => s + q.length);
      if (kDebugMode) debugPrint('[TapePlayer] ✅ Loaded $total events across ${_queues.length} endpoints');
    } catch (e) {
      if (kDebugMode) debugPrint('[TapePlayer] load() error: $e');
    }
  }

  /// Returns the next [NetworkEvent] for [method] + [url] without consuming it.
  NetworkEvent? peek(String method, String url) {
    final key = '${method.toUpperCase()} $url';
    final queue = _queues[key];
    if (queue == null || queue.isEmpty) return null;
    return queue.first;
  }

  /// Returns the next recorded [NetworkEvent] for [method] + [url], or
  /// `null` if no match exists (caller should fall through to real network).
  NetworkEvent? play(String method, String url) {
    final key = '${method.toUpperCase()} $url';
    final queue = _queues[key];
    if (queue == null || queue.isEmpty) {
      if (kDebugMode) debugPrint('[TapePlayer] MISS: $key');
      return null;
    }
    final event = queue.removeFirst();
    if (kDebugMode) debugPrint('[TapePlayer] HIT: $key (${queue.length} remaining)');
    return event;
  }
}
