import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../datasources/local/database.dart' as db;
import '../datasources/parsers/xmltv_parser.dart';
import '../../features/providers/provider_manager.dart';

class EpgRefreshService {
  final db.AppDatabase _db;
  final _parser = XmltvParser();
  final _uuid = const Uuid();

  EpgRefreshService(this._db);

  /// Refresh a single EPG source by ID.
  Future<void> refreshSource(String sourceId) async {
    final sources = await _db.getAllEpgSources();
    final source = sources.firstWhere((s) => s.id == sourceId);

    // Download XMLTV data
    final dio = Dio();
    try {
      final response = await dio.get<List<int>>(
        source.url,
        options: Options(responseType: ResponseType.bytes),
      );

      final bytes = response.data!;

      // Decompress if gzipped
      List<int> decompressed;
      try {
        decompressed = gzip.decode(bytes);
      } catch (_) {
        decompressed = bytes;
      }

      final xmlContent = utf8.decode(decompressed, allowMalformed: true);
      final result = _parser.parse(xmlContent, sourceId: sourceId);

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

      // Delete old programmes for this source, then insert new ones
      await _db.deleteEpgProgrammesForSource(sourceId);
      final programmeCompanions = result.programmes.map((p) {
        return db.EpgProgrammesCompanion.insert(
          epgChannelId: '${sourceId}_${p.channelId}',
          sourceId: sourceId,
          title: p.title,
          description: Value(p.description),
          category: Value(p.category),
          start: p.start,
          stop: p.stop,
        );
      }).toList();
      if (programmeCompanions.isNotEmpty) {
        await _db.insertEpgProgrammes(programmeCompanions);
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
        // Continue with next source on failure
      }
    }
  }

  /// Add default free EPG sources if none exist.
  Future<void> addDefaultSources() async {
    final existing = await _db.getAllEpgSources();
    if (existing.isNotEmpty) return;

    final defaults = [
      (
        name: 'EPG.pw – English (Global)',
        url: 'https://epg.pw/xmltv/en.xml.gz',
        enabled: true,
      ),
      (
        name: 'Open-EPG – US Channels',
        url: 'https://www.open-epg.com/files/unitedStates_all.xml',
        enabled: true,
      ),
      (
        name: 'EPG.best (requires API key)',
        url: 'https://epg.best/xmltv/YOUR_KEY_HERE',
        enabled: false,
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
