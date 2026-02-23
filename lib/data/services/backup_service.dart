import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = Logger(printer: SimplePrinter());

/// Keys in SharedPreferences to include in backup.
const _backupPrefKeys = [
  'shows_trakt_client_id',
  'shows_tmdb_api_key',
  'shows_debrid_tokens',
  'shows_favorites',
  'last_group',
  'last_channel_id',
  'failover_enabled',
];

/// Prefix patterns for dynamic keys to back up.
const _backupPrefPrefixes = [
  'lg_webos_key_',
  'show_last_season_',
];

/// Creates and restores `.clubtivi` backup files (ZIP archive) containing
/// the SQLite database and SharedPreferences snapshot.
class BackupService {
  /// Export all data to a `.clubtivi` backup file.
  static Future<String> exportBackup() async {
    final archive = Archive();

    // 1. SQLite database
    final dir = await getApplicationSupportDirectory();
    final dbFile = File(p.join(dir.path, 'clubtivi', 'clubtivi.db'));
    if (await dbFile.exists()) {
      final bytes = await dbFile.readAsBytes();
      archive.addFile(ArchiveFile('clubtivi.db', bytes.length, bytes));
      _log.i('Backup: added database (${bytes.length} bytes)');
    }

    // 2. SharedPreferences as JSON
    final prefs = await SharedPreferences.getInstance();
    final prefData = <String, dynamic>{};
    for (final key in _backupPrefKeys) {
      final value = prefs.get(key);
      if (value != null) prefData[key] = value;
    }
    for (final allKey in prefs.getKeys()) {
      for (final prefix in _backupPrefPrefixes) {
        if (allKey.startsWith(prefix)) {
          prefData[allKey] = prefs.get(allKey);
        }
      }
    }
    final prefJson = utf8.encode(jsonEncode(prefData));
    archive.addFile(ArchiveFile('preferences.json', prefJson.length, prefJson));

    // 3. Metadata
    final meta = utf8.encode(jsonEncode({
      'version': 1,
      'app': 'clubTivi',
      'created': DateTime.now().toIso8601String(),
      'platform': Platform.operatingSystem,
    }));
    archive.addFile(ArchiveFile('meta.json', meta.length, meta));

    // 4. Write ZIP
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) throw Exception('Failed to create backup archive');

    final ts = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final outDir = await getApplicationDocumentsDirectory();
    final outPath = p.join(outDir.path, 'clubtivi-backup-$ts.clubtivi');
    await File(outPath).writeAsBytes(zipBytes);
    _log.i('Backup exported to: $outPath');
    return outPath;
  }

  /// Import data from a `.clubtivi` backup file.
  static Future<String> importBackup(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) throw Exception('Backup file not found');

    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    String summary = '';

    // 1. Check metadata
    final metaFile = archive.findFile('meta.json');
    if (metaFile != null) {
      final meta = jsonDecode(utf8.decode(metaFile.content as List<int>));
      if ((meta['version'] as int? ?? 0) > 1) {
        throw Exception('Backup version too new');
      }
      summary += 'Backup from ${meta['created'] ?? 'unknown'}\n';
    }

    // 2. Restore database
    final dbArchiveFile = archive.findFile('clubtivi.db');
    if (dbArchiveFile != null) {
      final dir = await getApplicationSupportDirectory();
      final dbPath = p.join(dir.path, 'clubtivi', 'clubtivi.db');
      await File(dbPath).parent.create(recursive: true);
      await File(dbPath).writeAsBytes(dbArchiveFile.content as List<int>);
      summary += 'Database restored\n';
    }

    // 3. Restore preferences
    final prefFile = archive.findFile('preferences.json');
    if (prefFile != null) {
      final prefs = await SharedPreferences.getInstance();
      final data = jsonDecode(utf8.decode(prefFile.content as List<int>))
          as Map<String, dynamic>;
      int count = 0;
      for (final entry in data.entries) {
        final v = entry.value;
        if (v is String) { await prefs.setString(entry.key, v); count++; }
        else if (v is int) { await prefs.setInt(entry.key, v); count++; }
        else if (v is double) { await prefs.setDouble(entry.key, v); count++; }
        else if (v is bool) { await prefs.setBool(entry.key, v); count++; }
      }
      summary += '$count preferences restored\n';
    }

    return summary.trim();
  }
}
