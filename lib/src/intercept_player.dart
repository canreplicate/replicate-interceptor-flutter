import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// The fields a user can override for a given tape entry.
/// All fields are optional — only the ones present are applied.
class TapeOverride {
  /// Replaces the outgoing request body (intercept mode only).
  final String? requestBodyOverride;

  /// Replaces the response status code (replay + intercept).
  final int? statusCodeOverride;

  /// Replaces the response body (replay + intercept).
  final String? responseBodyOverride;

  const TapeOverride({
    this.requestBodyOverride,
    this.statusCodeOverride,
    this.responseBodyOverride,
  });

  factory TapeOverride.fromJson(Map<String, dynamic> json) => TapeOverride(
        requestBodyOverride: json['requestBodyOverride'] as String?,
        statusCodeOverride: json['statusCodeOverride'] as int?,
        responseBodyOverride: json['responseBodyOverride'] as String?,
      );

  bool get hasRequestOverride => requestBodyOverride != null;
  bool get hasResponseOverride =>
      statusCodeOverride != null || responseBodyOverride != null;
}

/// Loads override files from `Documents/simvault_overrides/` and surfaces them
/// per `"METHOD url"` key for use in intercept mode.
///
/// Unlike [TapePlayer], overrides are not consumed (no FIFO) — the same
/// override applies every time the endpoint is called.
class InterceptPlayer {
  final _overrides = <String, TapeOverride>{};

  /// Reads all `*.json` files from `Documents/simvault_overrides/` and builds
  /// the in-memory override map.
  Future<void> load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final overridesDir = Directory('${dir.path}/simvault_overrides');

      if (!await overridesDir.exists()) {
        if (kDebugMode) debugPrint('[InterceptPlayer] simvault_overrides/ not found — nothing to load');
        return;
      }

      final files = await overridesDir
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();

      for (final file in files) {
        try {
          final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;

          // Each override file has a "method" + "url" field so we can build
          // the lookup key. These are copied from the original tape entry by
          // SimVault when it creates the override file.
          final method = raw['method'] as String?;
          final url = raw['url'] as String?;
          if (method == null || url == null) continue;

          final key = '${method.toUpperCase()} $url';
          _overrides[key] = TapeOverride.fromJson(raw);
        } catch (e) {
          if (kDebugMode) debugPrint('[InterceptPlayer] Failed to parse ${file.path}: $e');
        }
      }

      if (kDebugMode) debugPrint('[InterceptPlayer] ✅ Loaded ${_overrides.length} overrides');
      for (final k in _overrides.keys) {
        if (kDebugMode) debugPrint('[InterceptPlayer]   → $k');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[InterceptPlayer] ❌ load() error: $e');
    }
  }

  /// Returns the [TapeOverride] for [method] + [url], or `null` if none exists.
  /// Unlike TapePlayer, this does NOT consume the entry — same override is
  /// returned on every call.
  TapeOverride? getOverride(String method, String url) {
    final key = '${method.toUpperCase()} $url';
    final override = _overrides[key];
    if (override == null) {
      if (kDebugMode) debugPrint('[InterceptPlayer] MISS: $key');
    } else {
      if (kDebugMode) debugPrint('[InterceptPlayer] HIT: $key  (reqOverride=${override.hasRequestOverride}, respOverride=${override.hasResponseOverride})');
    }
    return override;
  }
}
