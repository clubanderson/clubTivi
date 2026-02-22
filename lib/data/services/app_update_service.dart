import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const _repo = 'clubanderson/clubTivi';
const _currentVersion = '0.2.0';

class ReleaseInfo {
  final String tagName;
  final String version;
  final String htmlUrl;
  final String? apkDownloadUrl;
  final String body;
  final DateTime publishedAt;

  ReleaseInfo({
    required this.tagName,
    required this.version,
    required this.htmlUrl,
    this.apkDownloadUrl,
    required this.body,
    required this.publishedAt,
  });

  bool get isNewer => _compareVersions(version, _currentVersion) > 0;
}

class AppUpdateService {
  static final Dio _dio = Dio();

  static String get currentVersion => _currentVersion;

  /// Check GitHub for the latest release.
  static Future<ReleaseInfo?> checkForUpdate() async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$_repo/releases/latest',
        options: Options(
          headers: {'Accept': 'application/vnd.github.v3+json'},
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode != 200) return null;

      final data = response.data as Map<String, dynamic>;
      final tag = data['tag_name'] as String? ?? '';
      final version = tag.replaceFirst(RegExp(r'^v'), '');

      String? apkUrl;
      final assets = data['assets'] as List<dynamic>? ?? [];
      for (final asset in assets) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (name.endsWith('.apk')) {
          apkUrl = asset['browser_download_url'] as String?;
          break;
        }
      }

      return ReleaseInfo(
        tagName: tag,
        version: version,
        htmlUrl: data['html_url'] as String? ?? '',
        apkDownloadUrl: apkUrl,
        body: data['body'] as String? ?? '',
        publishedAt: DateTime.tryParse(data['published_at'] as String? ?? '') ??
            DateTime.now(),
      );
    } catch (e) {
      debugPrint('Update check failed: $e');
      return null;
    }
  }

  /// Download APK and trigger install via Android intent.
  static Future<void> downloadAndInstall(
    String apkUrl, {
    required void Function(double progress) onProgress,
    required void Function(String error) onError,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/clubtivi-update.apk';

      await _dio.download(
        apkUrl,
        filePath,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress(received / total);
        },
      );

      // Trigger Android package installer
      final result = await Process.run('am', [
        'start',
        '-a', 'android.intent.action.VIEW',
        '-t', 'application/vnd.android.package-archive',
        '-d', 'file://$filePath',
        '--grant-read-uri-permission',
      ]);

      if (result.exitCode != 0) {
        // Fallback: use content:// URI via install intent
        await _installViaIntent(filePath);
      }
    } catch (e) {
      onError('Download failed: $e');
    }
  }

  static Future<void> _installViaIntent(String filePath) async {
    // Use shell command as fallback
    await Process.run('am', [
      'start',
      '-a', 'android.intent.action.INSTALL_PACKAGE',
      '-d', 'file://$filePath',
      '--grant-read-uri-permission',
    ]);
  }
}

/// Compare semver strings. Returns >0 if a > b, <0 if a < b, 0 if equal.
int _compareVersions(String a, String b) {
  final aParts = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final bParts = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final len = aParts.length > bParts.length ? aParts.length : bParts.length;
  for (int i = 0; i < len; i++) {
    final av = i < aParts.length ? aParts[i] : 0;
    final bv = i < bParts.length ? bParts[i] : 0;
    if (av != bv) return av - bv;
  }
  return 0;
}
