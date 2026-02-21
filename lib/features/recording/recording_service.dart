import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/feature_gate.dart';

/// Manages stream recording to local storage, NAS (SMB/NFS), or mounted paths.
///
/// Pro feature. Supports:
/// - Manual recording (start/stop)
/// - Scheduled recording from EPG (set start/end time)
/// - Timeshift / pause live TV (circular buffer)
///
/// Storage backends:
/// - Local filesystem (default)
/// - NAS via mounted SMB/CIFS share
/// - NAS via mounted NFS share
/// - Any path the OS can write to (WebDAV via FUSE, etc.)
class RecordingService {
  final Dio _dio;
  final List<ActiveRecording> _active = [];

  RecordingService({Dio? dio}) : _dio = dio ?? Dio();

  List<ActiveRecording> get activeRecordings =>
      List.unmodifiable(_active);

  /// Start recording a stream to a file.
  /// Throws if recording feature is not available (free tier).
  Future<ActiveRecording> startRecording({
    required String streamUrl,
    required String channelName,
    required String outputDir,
    String? filename,
  }) async {
    if (!FeatureGate.recording) {
      throw RecordingProException();
    }

    final sanitizedName =
        channelName.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(' ', '_');
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final fname = filename ?? '${sanitizedName}_$timestamp.ts';
    final outputPath = p.join(outputDir, fname);

    // Ensure output directory exists
    await Directory(outputDir).create(recursive: true);

    final file = File(outputPath);
    final sink = file.openWrite();
    final cancelToken = CancelToken();

    final recording = ActiveRecording(
      channelName: channelName,
      streamUrl: streamUrl,
      outputPath: outputPath,
      startedAt: DateTime.now(),
      cancelToken: cancelToken,
      sink: sink,
    );
    _active.add(recording);

    // Stream download in background
    _recordStream(recording);

    return recording;
  }

  Future<void> _recordStream(ActiveRecording recording) async {
    try {
      final response = await _dio.get<ResponseBody>(
        recording.streamUrl,
        options: Options(responseType: ResponseType.stream),
        cancelToken: recording.cancelToken,
      );

      await for (final chunk in response.data!.stream) {
        recording.sink.add(chunk);
        recording.bytesWritten += chunk.length;
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        // Normal stop
      } else {
        recording.error = e.toString();
      }
    } catch (e) {
      recording.error = e.toString();
    } finally {
      await recording.sink.close();
      recording.stoppedAt = DateTime.now();
    }
  }

  /// Stop a recording.
  Future<void> stopRecording(ActiveRecording recording) async {
    recording.cancelToken.cancel('User stopped recording');
    _active.remove(recording);
  }

  /// Stop all active recordings.
  Future<void> stopAll() async {
    for (final r in List.of(_active)) {
      await stopRecording(r);
    }
  }

  /// Schedule a recording from EPG data.
  Future<ScheduledRecording> scheduleRecording({
    required String streamUrl,
    required String channelName,
    required String outputDir,
    required DateTime startAt,
    required DateTime endAt,
  }) async {
    if (!FeatureGate.recording) {
      throw RecordingProException();
    }

    final scheduled = ScheduledRecording(
      channelName: channelName,
      streamUrl: streamUrl,
      outputDir: outputDir,
      startAt: startAt,
      endAt: endAt,
    );

    // Set up timers for start and stop
    final startDelay = startAt.difference(DateTime.now());
    if (startDelay.isNegative) {
      throw ArgumentError('Start time is in the past');
    }

    Timer(startDelay, () async {
      final recording = await startRecording(
        streamUrl: streamUrl,
        channelName: channelName,
        outputDir: outputDir,
      );
      scheduled.activeRecording = recording;

      // Auto-stop at end time
      final duration = endAt.difference(startAt);
      Timer(duration, () => stopRecording(recording));
    });

    return scheduled;
  }

  void dispose() {
    stopAll();
    _dio.close();
  }
}

/// An actively recording stream.
class ActiveRecording {
  final String channelName;
  final String streamUrl;
  final String outputPath;
  final DateTime startedAt;
  final CancelToken cancelToken;
  final IOSink sink;

  int bytesWritten = 0;
  DateTime? stoppedAt;
  String? error;

  ActiveRecording({
    required this.channelName,
    required this.streamUrl,
    required this.outputPath,
    required this.startedAt,
    required this.cancelToken,
    required this.sink,
  });

  Duration get duration =>
      (stoppedAt ?? DateTime.now()).difference(startedAt);

  bool get isActive => stoppedAt == null && error == null;

  /// Human-readable file size.
  String get fileSizeDisplay {
    if (bytesWritten < 1024) return '$bytesWritten B';
    if (bytesWritten < 1024 * 1024) {
      return '${(bytesWritten / 1024).toStringAsFixed(1)} KB';
    }
    if (bytesWritten < 1024 * 1024 * 1024) {
      return '${(bytesWritten / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytesWritten / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// A scheduled future recording.
class ScheduledRecording {
  final String channelName;
  final String streamUrl;
  final String outputDir;
  final DateTime startAt;
  final DateTime endAt;
  ActiveRecording? activeRecording;

  ScheduledRecording({
    required this.channelName,
    required this.streamUrl,
    required this.outputDir,
    required this.startAt,
    required this.endAt,
  });

  bool get isPending =>
      activeRecording == null && DateTime.now().isBefore(startAt);
  bool get isRecording => activeRecording?.isActive ?? false;
  bool get isComplete => activeRecording?.stoppedAt != null;
}

class RecordingProException implements Exception {
  @override
  String toString() => 'Recording requires clubTivi Pro.';
}

/// Riverpod provider.
final recordingServiceProvider = Provider<RecordingService>((ref) {
  final service = RecordingService();
  ref.onDispose(() => service.dispose());
  return service;
});
