import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/datasources/local/database.dart' as db;
import '../../data/services/stream_alternatives_service.dart';
import '../../features/providers/provider_manager.dart' show databaseProvider;
import '../casting/cast_service.dart';
import '../casting/cast_dialog.dart';
import '../channels/channel_debug_dialog.dart';
import 'player_control_bar.dart';
import 'player_service.dart';

/// Full-screen video player with overlay controls and keyboard navigation.
class PlayerScreen extends ConsumerStatefulWidget {
  final String streamUrl;
  final String channelName;
  final String? channelLogo;
  final List<String> alternativeUrls;
  final List<Map<String, dynamic>> channels;
  final int currentIndex;

  const PlayerScreen({
    super.key,
    required this.streamUrl,
    required this.channelName,
    this.channelLogo,
    this.alternativeUrls = const [],
    this.channels = const [],
    this.currentIndex = 0,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  bool _showOverlay = true;
  int _currentUrlIndex = 0;
  bool _showChannelList = false;
  bool _isFavorite = false;

  // Channel switching state
  late int _channelIndex;
  late String _currentChannelName;
  late String? _currentChannelLogo;

  // Volume state
  double _volume = 100.0;
  bool _showVolumeOverlay = false;
  Timer? _volumeTimer;

  // Overlay timer
  Timer? _overlayTimer;

  // EPG state
  String? _nowPlayingTitle;
  String? _nowPlayingTime;
  String? _nextTitle;
  String? _nextTime;

  // Favorite lists
  List<db.FavoriteList> _favoriteLists = [];

  // Track selection state
  bool _subtitlesEnabled = false;
  List<SubtitleTrack> _subtitleTracks = [];
  List<AudioTrack> _audioTracks = [];

  @override
  void initState() {
    super.initState();
    _channelIndex = widget.currentIndex;
    _currentChannelName = widget.channelName;
    _currentChannelLogo = widget.channelLogo;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _startPlayback();
    _autoHideOverlay();
    _loadEpgInfo();
    _loadFavoriteState();
  }

  Future<void> _loadFavoriteState() async {
    if (widget.channels.isEmpty) return;
    final ch = widget.channels[_channelIndex];
    final channelId = ch['id'] as String? ?? '';
    if (channelId.isEmpty) return;
    final database = ref.read(databaseProvider);
    final lists = await database.getAllFavoriteLists();
    final listsForChannel = await database.getListsForChannel(channelId);
    if (mounted) {
      setState(() {
        _favoriteLists = lists;
        _isFavorite = listsForChannel.isNotEmpty;
      });
    }
  }

  Future<void> _loadEpgInfo() async {
    if (widget.channels.isEmpty) return;
    final ch = widget.channels[_channelIndex];
    final epgId = ch['epgId'] as String?;
    if (epgId == null || epgId.isEmpty) {
      if (mounted) {
        setState(() {
          _nowPlayingTitle = null;
          _nowPlayingTime = null;
          _nextTitle = null;
          _nextTime = null;
        });
      }
      return;
    }

    final database = ref.read(databaseProvider);
    final now = DateTime.now();
    final programmes = await database.getProgrammes(
      epgChannelId: epgId,
      start: now.subtract(const Duration(hours: 1)),
      end: now.add(const Duration(hours: 6)),
    );

    if (!mounted) return;

    db.EpgProgramme? current;
    db.EpgProgramme? next;
    for (final p in programmes) {
      if (now.isAfter(p.start) && now.isBefore(p.stop)) {
        current = p;
      } else if (current != null && next == null && now.isBefore(p.start)) {
        next = p;
        break;
      }
    }

    setState(() {
      _nowPlayingTitle = current?.title;
      _nowPlayingTime = current != null
          ? '${_fmtTime(current.start)} – ${_fmtTime(current.stop)}'
          : null;
      _nextTitle = next?.title;
      _nextTime = next != null
          ? '${_fmtTime(next.start)} – ${_fmtTime(next.stop)}'
          : null;
    });
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _startPlayback() {
    final playerService = ref.read(playerServiceProvider);
    final urls = [widget.streamUrl, ...widget.alternativeUrls];

    // If channels list is empty, this is a show/VOD stream — always start fresh
    final isShowStream = widget.channels.isEmpty;

    if (isShowStream ||
        !(playerService.player.state.playing ||
            playerService.player.state.buffering)) {
      playerService.play(urls[_currentUrlIndex],
        channelId: widget.channels.isNotEmpty ? widget.channels[_channelIndex]['id'] as String? : null,
        epgChannelId: widget.channels.isNotEmpty ? widget.channels[_channelIndex]['epgChannelId'] as String? : null,
        tvgId: widget.channels.isNotEmpty ? widget.channels[_channelIndex]['tvgId'] as String? : null,
        channelName: _currentChannelName,
        vanityName: widget.channels.isNotEmpty ? widget.channels[_channelIndex]['vanityName'] as String? : null,
        originalName: widget.channels.isNotEmpty ? widget.channels[_channelIndex]['tvgName'] as String? : null,
      );
    }

    // Load track info once tracks become available
    playerService.player.stream.tracks.listen((tracks) {
      if (mounted) _loadTrackInfo();
    });

    playerService.bufferingStream.listen((buffering) {
      playerService.onBufferingChanged(buffering);
      if (playerService.shouldFailover && _hasAlternativeStreams) {
        _switchToNextStream();
      }
    });
  }

  bool get _hasAlternativeStreams {
    final urls = [widget.streamUrl, ...widget.alternativeUrls];
    return _currentUrlIndex < urls.length - 1;
  }

  void _switchToNextStream() {
    setState(() => _currentUrlIndex++);
    final urls = [widget.streamUrl, ...widget.alternativeUrls];
    ref.read(playerServiceProvider).play(urls[_currentUrlIndex],
      channelName: _currentChannelName,
    );
  }

  Future<void> _showCastPicker() async {
    final device = await showCastDialog(context, ref);
    if (device != null && mounted) {
      final castService = ref.read(castServiceProvider);
      final urls = [widget.streamUrl, ...widget.alternativeUrls];
      final success = await castService.castTo(
        device,
        urls[_currentUrlIndex],
        title: widget.channelName,
      );
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Casting to ${device.name}'),
            backgroundColor: Colors.green.shade800,
            duration: const Duration(seconds: 2),
          ),
        );
        setState(() {});
      }
    }
  }

  void _loadTrackInfo() {
    final player = ref.read(playerServiceProvider).player;
    final tracks = player.state.tracks;
    setState(() {
      _subtitleTracks = tracks.subtitle
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();
      _audioTracks = tracks.audio
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();
      _subtitlesEnabled = player.state.track.subtitle.id != 'no' &&
          player.state.track.subtitle.id != 'auto';
    });
  }

  void _toggleSubtitles() {
    final player = ref.read(playerServiceProvider).player;
    if (_subtitlesEnabled) {
      player.setSubtitleTrack(SubtitleTrack.no());
      setState(() => _subtitlesEnabled = false);
    } else if (_subtitleTracks.isNotEmpty) {
      player.setSubtitleTrack(_subtitleTracks.first);
      setState(() => _subtitlesEnabled = true);
    }
  }

  void _showSubtitlePicker() {
    _loadTrackInfo();
    final player = ref.read(playerServiceProvider).player;
    final currentId = player.state.track.subtitle.id;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.closed_caption, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text('Subtitles', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              ListTile(
                dense: true,
                leading: Icon(Icons.block, color: currentId == 'no' ? Colors.greenAccent : Colors.white54, size: 20),
                title: const Text('Off', style: TextStyle(color: Colors.white70, fontSize: 13)),
                trailing: currentId == 'no' ? const Icon(Icons.check, color: Colors.greenAccent, size: 18) : null,
                onTap: () {
                  player.setSubtitleTrack(SubtitleTrack.no());
                  setState(() => _subtitlesEnabled = false);
                  Navigator.of(ctx).pop();
                },
              ),
              ..._subtitleTracks.map((t) {
                final isActive = t.id == currentId;
                return ListTile(
                  dense: true,
                  title: Text(
                    t.title ?? t.language ?? t.id,
                    style: TextStyle(color: isActive ? Colors.white : Colors.white70, fontSize: 13),
                  ),
                  subtitle: t.language != null
                      ? Text(t.language!, style: const TextStyle(color: Colors.white38, fontSize: 11))
                      : null,
                  trailing: isActive ? const Icon(Icons.check, color: Colors.greenAccent, size: 18) : null,
                  onTap: () {
                    player.setSubtitleTrack(t);
                    setState(() => _subtitlesEnabled = true);
                    Navigator.of(ctx).pop();
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  void _showAudioPicker() {
    _loadTrackInfo();
    final player = ref.read(playerServiceProvider).player;
    final currentId = player.state.track.audio.id;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.audiotrack, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text('Audio Tracks', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              ..._audioTracks.map((t) {
                final isActive = t.id == currentId;
                return ListTile(
                  dense: true,
                  title: Text(
                    t.title ?? t.language ?? t.id,
                    style: TextStyle(color: isActive ? Colors.white : Colors.white70, fontSize: 13),
                  ),
                  subtitle: t.language != null
                      ? Text(t.language!, style: const TextStyle(color: Colors.white38, fontSize: 11))
                      : null,
                  trailing: isActive ? const Icon(Icons.check, color: Colors.greenAccent, size: 18) : null,
                  onTap: () {
                    player.setAudioTrack(t);
                    Navigator.of(ctx).pop();
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  void _autoHideOverlay() {
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showOverlay = false);
    });
  }

  void _toggleOverlay() {
    setState(() => _showOverlay = !_showOverlay);
    if (_showOverlay) _autoHideOverlay();
  }

  // ---- Keyboard controls ----

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final isAndroid = Platform.isAndroid;

    // Escape / Backspace / Back → close channel list first, then exit
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.goBack) {
      if (_showChannelList) {
        setState(() => _showChannelList = false);
        return KeyEventResult.handled;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        GoRouter.of(context).canPop()
            ? GoRouter.of(context).pop()
            : GoRouter.of(context).go('/');
      });
      return KeyEventResult.handled;
    }

    // Select / Enter → toggle overlay
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA) {
      _toggleOverlay();
      return KeyEventResult.handled;
    }

    // Channel switching: use channelUp/Down on Android, arrows elsewhere
    if (key == LogicalKeyboardKey.channelUp ||
        (!isAndroid && key == LogicalKeyboardKey.arrowUp)) {
      _switchChannel(-1);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.channelDown ||
        (!isAndroid && key == LogicalKeyboardKey.arrowDown)) {
      _switchChannel(1);
      return KeyEventResult.handled;
    }

    // Volume: only on non-Android (D-pad arrows needed for focus on Android)
    if (!isAndroid && key == LogicalKeyboardKey.arrowLeft) {
      _adjustVolume(-5);
      return KeyEventResult.handled;
    }

    if (!isAndroid && key == LogicalKeyboardKey.arrowRight) {
      _adjustVolume(5);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _switchChannel(int delta) {
    if (widget.channels.isEmpty) return;
    setState(() {
      _channelIndex =
          (_channelIndex + delta) % widget.channels.length;
      if (_channelIndex < 0) _channelIndex += widget.channels.length;
      final ch = widget.channels[_channelIndex];
      _currentChannelName = ch['name'] as String? ?? '';
      _currentChannelLogo = ch['tvgLogo'] as String?;
      _currentUrlIndex = 0;
      _showOverlay = true;
    });
    final ch = widget.channels[_channelIndex];
    ref.read(playerServiceProvider).play(ch['streamUrl'] as String? ?? '',
      channelId: ch['id'] as String?,
      epgChannelId: ch['epgChannelId'] as String?,
      tvgId: ch['tvgId'] as String?,
      channelName: ch['name'] as String?,
    );
    _autoHideOverlay();
    _loadEpgInfo();
    _loadFavoriteState();
  }

  void _adjustVolume(double delta) {
    setState(() {
      _volume = (_volume + delta).clamp(0.0, 100.0);
      _showVolumeOverlay = true;
    });
    ref.read(playerServiceProvider).setVolume(_volume);
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showVolumeOverlay = false);
    });
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    _volumeTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playerService = ref.watch(playerServiceProvider);

    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: MouseRegion(
          onHover: (_) {
            if (!_showOverlay) setState(() => _showOverlay = true);
            _autoHideOverlay();
          },
          child: GestureDetector(
            onTap: _toggleOverlay,
            child: Stack(
              fit: StackFit.expand,
              children: [
              // Video — fill entire screen
              Video(controller: playerService.videoController, controls: NoVideoControls),

              // TiviMate-style control bar overlay
              PlayerControlBar(
                isCasting: ref.read(castServiceProvider).isCasting,
                isFavorite: _isFavorite,
                hasSubtitles: _subtitleTracks.isNotEmpty,
                subtitlesEnabled: _subtitlesEnabled,
                onSubtitleToggle: _toggleSubtitles,
                onSubtitleSelect: _showSubtitlePicker,
                audioTrackCount: _audioTracks.length,
                onAudioSelect: _showAudioPicker,
                onCastTap: () => _showCastPicker(),
                onBackTap: () {
                  GoRouter.of(context).canPop()
                      ? GoRouter.of(context).pop()
                      : GoRouter.of(context).go('/');
                },
                onScreenshot: _takeScreenshot,
                onFavorite: _toggleFavorite,
                onPip: _enterPip,
                onInfo: _showInfoDialog,
                onRename: _renameCurrentChannel,
                onSettings: () => GoRouter.of(context).push('/settings'),
                onChannelList: () => setState(() => _showChannelList = !_showChannelList),
              ),

              // Channel info overlay (top, shown alongside control bar)
              if (_showOverlay) ...[
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(48, 4, 8, 8),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black87, Colors.transparent],
                      ),
                    ),
                    child: Row(
                      children: [
                        if (_currentChannelLogo != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Image.network(
                              _currentChannelLogo!,
                              width: 24,
                              height: 24,
                              errorBuilder: (c, e, s) =>
                                  const SizedBox(),
                            ),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _currentChannelName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (_nowPlayingTitle != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  '▶ $_nowPlayingTitle${_nowPlayingTime != null ? '  $_nowPlayingTime' : ''}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                              if (_nextTitle != null) ...[
                                Text(
                                  'Next: $_nextTitle${_nextTime != null ? '  $_nextTime' : ''}',
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 10,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              // Volume overlay
              if (_showVolumeOverlay)
                Positioned(
                  top: 80,
                  right: 24,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _volume == 0
                              ? Icons.volume_off
                              : _volume < 50
                                  ? Icons.volume_down
                                  : Icons.volume_up,
                          color: Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${_volume.round()}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // Channel list overlay
              if (_showChannelList && widget.channels.isNotEmpty)
                Positioned(
                  right: 0, top: 0, bottom: 0,
                  width: 320,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.85),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 40, 8, 8),
                          child: Row(
                            children: [
                              const Icon(Icons.list, color: Colors.white70, size: 20),
                              const SizedBox(width: 8),
                              const Text('Channels', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                                onPressed: () => setState(() => _showChannelList = false),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1, color: Colors.white10),
                        Expanded(
                          child: ListView.builder(
                            itemCount: widget.channels.length,
                            itemBuilder: (ctx, i) {
                              final ch = widget.channels[i];
                              final name = ch['name'] as String? ?? '';
                              final isCurrent = i == _channelIndex;
                              return ListTile(
                                dense: true,
                                selected: isCurrent,
                                selectedTileColor: const Color(0xFF6C5CE7).withValues(alpha: 0.3),
                                leading: ch['tvgLogo'] != null
                                    ? Image.network(ch['tvgLogo'] as String, width: 28, height: 28, errorBuilder: (_, __, ___) => const Icon(Icons.tv, size: 28, color: Colors.white30))
                                    : const Icon(Icons.tv, size: 28, color: Colors.white30),
                                title: Text(name, style: TextStyle(
                                  color: isCurrent ? Colors.white : Colors.white70,
                                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                  fontSize: 13,
                                ), maxLines: 1, overflow: TextOverflow.ellipsis),
                                onTap: () {
                                  setState(() => _showChannelList = false);
                                  if (i != _channelIndex) {
                                    _switchChannel(i - _channelIndex);
                                  }
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- Action handlers ----

  Future<void> _takeScreenshot() async {
    final ps = ref.read(playerServiceProvider);
    try {
      final dir = Platform.isMacOS || Platform.isLinux || Platform.isWindows
          ? (await getDownloadsDirectory()) ?? await getTemporaryDirectory()
          : await getTemporaryDirectory();
      final path = '${dir.path}/clubtivi_screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
      final result = await ps.takeScreenshot(path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result != null ? 'Screenshot saved: $path' : 'Screenshot not available')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Screenshot failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _toggleFavorite() {
    if (widget.channels.isEmpty) return;
    final ch = widget.channels[_channelIndex];
    final channelId = ch['id'] as String? ?? '';
    final channelName = ch['name'] as String? ?? '';
    if (channelId.isEmpty) return;
    _showFavoriteListSheet(channelId, channelName);
  }

  Future<void> _showFavoriteListSheet(String channelId, String channelName) async {
    final database = ref.read(databaseProvider);
    final listsForChannel = await database.getListsForChannel(channelId);
    final checkedIds = listsForChannel.map((l) => l.id).toSet();

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.star_rounded, color: Colors.amber, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Add "$channelName" to list',
                          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_favoriteLists.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text('No favorite lists yet', style: TextStyle(color: Colors.white38)),
                      ),
                    ),
                  ..._favoriteLists.map((list) {
                    final isInList = checkedIds.contains(list.id);
                    return CheckboxListTile(
                      dense: true,
                      value: isInList,
                      activeColor: const Color(0xFFE17055),
                      title: Text('★ ${list.name}',
                          style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      onChanged: (val) async {
                        if (val == true) {
                          await database.addChannelToList(list.id, channelId);
                          checkedIds.add(list.id);
                        } else {
                          await database.removeChannelFromList(list.id, channelId);
                          checkedIds.remove(list.id);
                        }
                        setSheetState(() {});
                      },
                    );
                  }),
                  const Divider(color: Colors.white12),
                  TextButton.icon(
                    onPressed: () async {
                      final name = await _showCreateListDialog();
                      if (name != null && name.isNotEmpty) {
                        final newList = await database.createFavoriteList(name);
                        await database.addChannelToList(newList.id, channelId);
                        checkedIds.add(newList.id);
                        final updated = await database.getAllFavoriteLists();
                        setState(() => _favoriteLists = updated);
                        setSheetState(() {});
                      }
                    },
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Create new list'),
                    style: TextButton.styleFrom(foregroundColor: Colors.cyanAccent),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
    // Refresh favorite state after sheet closes
    final listsAfter = await database.getListsForChannel(channelId);
    if (mounted) {
      setState(() => _isFavorite = listsAfter.isNotEmpty);
    }
  }

  Future<String?> _showCreateListDialog() async {
    String name = '';
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('New Favorite List', style: TextStyle(color: Colors.white)),
        content: TextField(
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'e.g. Sports, News, Kids',
            hintStyle: TextStyle(color: Colors.white38),
          ),
          onChanged: (v) => name = v,
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(name.trim()), child: const Text('Create')),
        ],
      ),
    );
  }

  Future<void> _enterPip() async {
    // PiP not yet available on desktop — show a message
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Picture-in-Picture — available on mobile'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _renameCurrentChannel() async {
    if (widget.channels.isEmpty) return;
    final ch = widget.channels[_channelIndex];
    final channelId = ch['id'] as String?;
    if (channelId == null) return;

    // Load current vanity names
    final prefs = await SharedPreferences.getInstance();
    final vanityJson = prefs.getString('channel_vanity_names');
    Map<String, String> vanityNames = {};
    if (vanityJson != null) {
      try {
        final decoded = jsonDecode(vanityJson) as Map<String, dynamic>;
        vanityNames = decoded.map((k, v) => MapEntry(k, v as String));
      } catch (_) {}
    }

    final originalName = ch['name'] as String? ?? '';
    final currentVanity = vanityNames[channelId];
    final controller = TextEditingController(text: currentVanity ?? originalName);

    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Display Name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Original: $originalName',
                style: const TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Display Name'),
            ),
          ],
        ),
        actions: [
          if (currentVanity != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, '\x00RESET'),
              child: const Text('Reset to Original'),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;

    if (result == '\x00RESET') {
      vanityNames.remove(channelId);
    } else if (result.isNotEmpty && result != originalName) {
      vanityNames[channelId] = result;
    } else {
      return;
    }

    await prefs.setString('channel_vanity_names', jsonEncode(vanityNames));

    // Update in-memory channel map and displayed name
    if (!mounted) return;
    setState(() {
      widget.channels[_channelIndex]['vanityName'] =
          vanityNames[channelId];
      widget.channels[_channelIndex]['name'] =
          vanityNames[channelId] ?? originalName;
      _currentChannelName =
          vanityNames[channelId] ?? originalName;
    });
  }

  void _showInfoDialog() {
    if (widget.channels.isEmpty) return;
    try {
      final ch = widget.channels[_channelIndex];
      final channel = db.Channel(
        id: ch['id']?.toString() ?? '',
        providerId: ch['providerId']?.toString() ?? '',
        name: ch['name']?.toString() ?? '',
        groupTitle: ch['groupTitle']?.toString() ?? '',
        streamUrl: ch['streamUrl']?.toString() ?? '',
        streamType: ch['streamType']?.toString() ?? 'live',
        tvgId: ch['tvgId']?.toString(),
        tvgName: ch['tvgName']?.toString(),
        tvgLogo: ch['tvgLogo']?.toString(),
        favorite: false,
        hidden: false,
        sortOrder: 0,
      );
      final ps = ref.read(playerServiceProvider);
      final epgId = ch['epgId']?.toString();
      final alts = ref.read(streamAlternativesProvider).getAlternativeDetails(
        channelId: ch['id']?.toString() ?? '',
        epgChannelId: epgId,
        tvgId: ch['tvgId']?.toString(),
        channelName: ch['name']?.toString(),
        vanityName: ch['vanityName']?.toString(),
        originalName: ch['tvgName']?.toString(),
        excludeUrl: ch['streamUrl']?.toString() ?? '',
      );
      ChannelDebugDialog.show(context, channel, ps,
          mappedEpgId: epgId,
          originalName: ch['tvgName']?.toString() ?? ch['originalName']?.toString() ?? ch['name']?.toString(),
          currentProviderName: ref.read(streamAlternativesProvider).providerName(ch['providerId']?.toString() ?? ''),
          alternatives: alts);
    } catch (e) {
      debugPrint('Error showing info dialog: $e');
    }
  }
}
