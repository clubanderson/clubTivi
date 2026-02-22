import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../datasources/local/database.dart' as db;
import '../datasources/parsers/xmltv_parser.dart';
import '../models/epg.dart';
import '../../features/providers/provider_manager.dart';

/// Runs heavy XML parsing in a background isolate.
XmltvResult _parseInIsolate(_ParseArgs args) {
  return XmltvParser().parse(args.xml, sourceId: args.sourceId);
}

class _ParseArgs {
  final String xml;
  final String sourceId;
  const _ParseArgs(this.xml, this.sourceId);
}

class EpgRefreshService {
  final db.AppDatabase _db;
  final _uuid = const Uuid();

  EpgRefreshService(this._db);

  /// Refresh a single EPG source by ID.
  Future<void> refreshSource(String sourceId) async {
    final sources = await _db.getAllEpgSources();
    final source = sources.firstWhere((s) => s.id == sourceId);
    debugPrint('[EPG] Refreshing source: ${source.name} (${source.url})');

    // Download XMLTV data
    final dio = Dio(BaseOptions(
      headers: {
        'User-Agent': 'clubTivi/1.0 IPTV Player (compatible; XMLTV fetcher)',
      },
    ));
    try {
      final response = await dio.get<List<int>>(
        source.url,
        options: Options(responseType: ResponseType.bytes),
      );

      final bytes = response.data!;
      debugPrint('[EPG] Downloaded ${bytes.length} bytes');

      // Decompress + parse in background isolate to avoid ANR
      final result = await compute(_decompressAndParse, _DecompressParseArgs(bytes, sourceId));
      debugPrint('[EPG] Parsed ${result.channels.length} channels, ${result.programmes.length} programmes');

      // Store channels
      final channelCompanions = result.channels.map((c) {
        return db.EpgChannelsCompanion.insert(
          id: '${sourceId}_${c.id}',
          sourceId: sourceId,
          channelId: c.id,
          displayName: c.primaryName,
          iconUrl: Value(c.iconUrl),
        );
      }).toList();
      await _db.upsertEpgChannels(channelCompanions);

      // Delete old programmes for this source, then insert new ones in batches
      await _db.deleteEpgProgrammesForSource(sourceId);
      final programmeCompanions = result.programmes.map((p) {
        return db.EpgProgrammesCompanion.insert(
          epgChannelId: '${sourceId}_${p.channelId}',
          sourceId: sourceId,
          title: p.title,
          description: Value(p.description),
          category: Value(p.category),
          subtitle: Value(p.subtitle),
          episodeNum: Value(p.episodeNum),
          start: p.start,
          stop: p.stop,
        );
      }).toList();
      if (programmeCompanions.isNotEmpty) {
        // Insert in batches of 5000 to avoid blocking the main thread
        for (var i = 0; i < programmeCompanions.length; i += 5000) {
          final end = (i + 5000).clamp(0, programmeCompanions.length);
          await _db.insertEpgProgrammes(programmeCompanions.sublist(i, end));
          // Yield to the event loop between batches
          await Future<void>.delayed(Duration.zero);
        }
      }

      // Update last refresh timestamp
      await _db.updateEpgSourceRefreshTime(sourceId);
    } finally {
      dio.close();
    }
  }

  /// Refresh all enabled EPG sources.
  Future<void> refreshAllSources() async {
    final sources = await _db.getAllEpgSources();
    for (final source in sources.where((s) => s.enabled)) {
      try {
        await refreshSource(source.id);
      } catch (e) {
        debugPrint('[EPG] Error refreshing ${source.name}: $e');
      }
    }
  }

  /// Add default free EPG sources if none exist.
  Future<void> addDefaultSources() async {
    final existing = await _db.getAllEpgSources();
    if (existing.isNotEmpty) return;
    await _insertDefaults();
  }

  /// Delete all existing sources and re-add defaults.
  Future<void> resetToDefaultSources() async {
    final existing = await _db.getAllEpgSources();
    for (final s in existing) {
      await _db.deleteEpgSource(s.id);
    }
    await _insertDefaults();
  }

  Future<void> _insertDefaults() async {
    final defaults = [
      (
        name: 'EPG.best',
        url: 'http://epg.best/16b5b-ypkixv.xml.gz',
        enabled: true,
      ),
      (
        name: 'USA Locals (ABC, CBS, Fox, NBC)',
        url: 'https://raw.githubusercontent.com/usa-local-epg/usa-locals/main/usalocals.xml.gz',
        enabled: true,
      ),
    ];

    for (final d in defaults) {
      await _db.upsertEpgSource(db.EpgSourcesCompanion.insert(
        id: _uuid.v4(),
        name: d.name,
        url: d.url,
        enabled: Value(d.enabled),
      ));
    }
  }
}

final epgRefreshServiceProvider = Provider<EpgRefreshService>((ref) {
  return EpgRefreshService(ref.watch(databaseProvider));
});

/// Args for the background isolate (must be serializable).
class _DecompressParseArgs {
  final List<int> bytes;
  final String sourceId;
  const _DecompressParseArgs(this.bytes, this.sourceId);
}

/// Top-level function for compute() — runs decompression + XML parsing off the main thread.
XmltvResult _decompressAndParse(_DecompressParseArgs args) {
  List<int> decompressed;
  try {
    decompressed = gzip.decode(args.bytes);
  } catch (_) {
    decompressed = args.bytes;
  }
  final xmlContent = utf8.decode(decompressed, allowMalformed: true);
  return XmltvParser().parse(xmlContent, sourceId: args.sourceId);
}
