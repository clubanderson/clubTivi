import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/fuzzy_match.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/services/epg_refresh_service.dart';
import '../player/player_service.dart';
import '../providers/provider_manager.dart';
import 'channel_debug_dialog.dart';
import 'channel_info_overlay.dart';

class ChannelsScreen extends ConsumerStatefulWidget {
  const ChannelsScreen({super.key});

  @override
  ConsumerState<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends ConsumerState<ChannelsScreen> {
  List<db.Channel> _allChannels = [];
  List<db.Channel> _filteredChannels = [];
  List<String> _groups = [];
  String _selectedGroup = 'All';
  String _searchQuery = '';
  bool _showSearch = false;
  int _selectedIndex = -1;
  db.Channel? _previewChannel;
  List<db.EpgProgramme> _nowPlaying = [];
  bool _isLoading = true;

  /// Maps channel ID → mapped EPG channel ID (from epg_mappings table)
  Map<String, String> _epgMappings = {};
  bool _showGuideView = true;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _channelListController = ScrollController();
  final _guideScrollController = ScrollController();

  // Overlay state
  bool _showOverlay = false;
  Timer? _overlayTimer;
  final _focusNode = FocusNode();

  // Volume state
  double _volume = 100.0;
  bool _showVolumeOverlay = false;
  Timer? _volumeOverlayTimer;

  // Last channel for back/forth toggle (not a full history stack)
  int _previousIndex = -1;

  // Favorite lists state
  List<db.FavoriteList> _favoriteLists = [];
  Set<String> _favoritedChannelIds = {};

  @override
  void initState() {
    super.initState();
    _loadChannels();
    _ensureEpgSources();
  }

  /// Add default EPG sources on first run and kick off a background refresh.
  Future<void> _ensureEpgSources() async {
    final epgService = ref.read(epgRefreshServiceProvider);
    await epgService.addDefaultSources();
    // Refresh in background — don't block the UI
    epgService.refreshAllSources().then((_) {
      debugPrint('[EPG] Background refresh complete');
    }).catchError((e) {
      debugPrint('[EPG] Background refresh failed: $e');
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _channelListController.dispose();
    _guideScrollController.dispose();
    _overlayTimer?.cancel();
    _volumeOverlayTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadChannels() async {
    final database = ref.read(databaseProvider);
    final providers = await database.getAllProviders();
    final List<db.Channel> allChannels = [];
    for (final provider in providers) {
      final channels = await database.getChannelsForProvider(provider.id);
      allChannels.addAll(channels);
    }

    // Extract unique groups
    final groupSet = <String>{};
    for (final ch in allChannels) {
      if (ch.groupTitle != null && ch.groupTitle!.isNotEmpty) {
        groupSet.add(ch.groupTitle!);
      }
    }
    final groups = groupSet.toList()..sort();

    // Load EPG mappings (channel ID → EPG channel ID)
    final mappings = await database.getAllMappings();
    final epgMap = <String, String>{};
    for (final m in mappings) {
      epgMap[m.channelId] = m.epgChannelId;
    }

    // Load now-playing EPG data using mapped IDs (fall back to tvgId)
    final epgChannelIds = <String>{};
    for (final c in allChannels) {
      final mapped = epgMap[c.id];
      if (mapped != null && mapped.isNotEmpty) {
        epgChannelIds.add(mapped);
      } else if (c.tvgId != null && c.tvgId!.isNotEmpty) {
        epgChannelIds.add(c.tvgId!);
      }
    }
    List<db.EpgProgramme> nowPlaying = [];
    if (epgChannelIds.isNotEmpty) {
      nowPlaying = await database.getNowPlaying(epgChannelIds.toList());
    }

    // Load favorite lists
    final favLists = await database.getAllFavoriteLists();
    final favChannelIds = await database.getAllFavoritedChannelIds();

    if (!mounted) return;
    setState(() {
      _allChannels = allChannels;
      _groups = groups;
      _nowPlaying = nowPlaying;
      _epgMappings = epgMap;
      _favoriteLists = favLists;
      _favoritedChannelIds = favChannelIds;
      _isLoading = false;
      _applyFilters();
    });
  }

  void _applyFilters() {
    var channels = _allChannels;

    // Favorite list filters
    if (_selectedGroup == 'Favorites') {
      channels =
          channels.where((c) => _favoritedChannelIds.contains(c.id)).toList();
    } else if (_selectedGroup.startsWith('fav:')) {
      final listId = _selectedGroup.substring(4);
      // We'll need the channel IDs for this list — loaded async below
      _applyFavoriteListFilter(listId);
      return;
    } else if (_selectedGroup != 'All') {
      channels =
          channels.where((c) => c.groupTitle == _selectedGroup).toList();
    }

    if (_searchQuery.isNotEmpty) {
      channels = channels
          .where((c) => fuzzyMatchPasses(
              _searchQuery, [c.name, c.groupTitle, _getChannelNowPlaying(c)]))
          .toList();
    }
    _filteredChannels = channels;
    if (_selectedIndex >= _filteredChannels.length) {
      _selectedIndex = _filteredChannels.isEmpty ? -1 : 0;
    }
  }

  Future<void> _applyFavoriteListFilter(String listId) async {
    final database = ref.read(databaseProvider);
    var channels = await database.getChannelsInList(listId);
    if (_searchQuery.isNotEmpty) {
      channels = channels
          .where((c) => fuzzyMatchPasses(
              _searchQuery, [c.name, c.groupTitle, _getChannelNowPlaying(c)]))
          .toList();
    }
    if (!mounted) return;
    setState(() {
      _filteredChannels = channels;
      if (_selectedIndex >= _filteredChannels.length) {
        _selectedIndex = _filteredChannels.isEmpty ? -1 : 0;
      }
    });
  }

  void _selectChannel(int index) {
    if (index < 0 || index >= _filteredChannels.length) return;
    // Remember current as previous (for back/forth toggle)
    if (_selectedIndex >= 0 && _selectedIndex != index) {
      _previousIndex = _selectedIndex;
    }
    final channel = _filteredChannels[index];
    final playerService = ref.read(playerServiceProvider);
    playerService.play(channel.streamUrl);
    setState(() {
      _selectedIndex = index;
      _previewChannel = channel;
    });
    _showInfoOverlay(channel, index);
  }

  /// Toggle between current channel and the last channel.
  void _goBackChannel() {
    if (_previousIndex < 0 || _previousIndex >= _filteredChannels.length) return;
    final swapTo = _previousIndex;
    _previousIndex = _selectedIndex;
    final channel = _filteredChannels[swapTo];
    final playerService = ref.read(playerServiceProvider);
    playerService.play(channel.streamUrl);
    setState(() {
      _selectedIndex = swapTo;
      _previewChannel = channel;
    });
    _showInfoOverlay(channel, swapTo);
  }

  void _showInfoOverlay(db.Channel channel, int index) {
    setState(() => _showOverlay = true);

    // Reset auto-hide timer
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showOverlay = false);
    });
  }

  void _goFullscreen(db.Channel channel) {
    final channelMaps = _filteredChannels
        .map((c) => <String, dynamic>{
              'name': c.name,
              'streamUrl': c.streamUrl,
              'tvgLogo': c.tvgLogo,
              'groupTitle': c.groupTitle,
              'alternativeUrls': <String>[],
            })
        .toList();
    context.push('/player', extra: {
      'streamUrl': channel.streamUrl,
      'channelName': channel.name,
      'channelLogo': channel.tvgLogo,
      'alternativeUrls': <String>[],
      'channels': channelMaps,
      'currentIndex': _selectedIndex >= 0 ? _selectedIndex : 0,
    });
  }

  // ---------------------------------------------------------------------------
  // EPG helpers
  // ---------------------------------------------------------------------------

  /// Get the effective EPG channel ID: mapped ID takes priority over tvgId.
  String? _getEpgId(db.Channel channel) {
    final mapped = _epgMappings[channel.id];
    if (mapped != null && mapped.isNotEmpty) return mapped;
    if (channel.tvgId != null && channel.tvgId!.isNotEmpty) return channel.tvgId;
    return null;
  }

  String? _getChannelNowPlaying(db.Channel channel) {
    final epgId = _getEpgId(channel);
    if (epgId == null) return null;
    final match =
        _nowPlaying.where((p) => p.epgChannelId == epgId).toList();
    return match.isNotEmpty ? match.first.title : null;
  }

  db.EpgProgramme? _getEpgProgramme(db.Channel channel) {
    final epgId = _getEpgId(channel);
    if (epgId == null) return null;
    final matches =
        _nowPlaying.where((p) => p.epgChannelId == epgId).toList();
    return matches.isNotEmpty ? matches.first : null;
  }

  db.EpgProgramme? _getNextProgramme(db.Channel channel) {
    final epgId = _getEpgId(channel);
    if (epgId == null) return null;
    final matches =
        _nowPlaying.where((p) => p.epgChannelId == epgId).toList();
    return matches.length > 1 ? matches[1] : null;
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }

  String? _programmeTimeRange(db.EpgProgramme? p) {
    if (p == null) return null;
    return '${_formatTime(p.start)} - ${_formatTime(p.stop)}';
  }

  // ---------------------------------------------------------------------------
  // Keyboard navigation
  // ---------------------------------------------------------------------------

  void _handleKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.channelUp) {
      final newIndex = (_selectedIndex - 1).clamp(0, _filteredChannels.length - 1);
      if (newIndex != _selectedIndex) {
        _selectChannel(newIndex);
        _scrollToIndex(newIndex);
      }
      return;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.channelDown) {
      final newIndex = (_selectedIndex + 1).clamp(0, _filteredChannels.length - 1);
      if (newIndex != _selectedIndex) {
        _selectChannel(newIndex);
        _scrollToIndex(newIndex);
      }
      return;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.select) {
      if (_previewChannel != null) {
        _goFullscreen(_previewChannel!);
      }
      return;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _adjustVolume(-5);
      return;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _adjustVolume(5);
      return;
    }

    // Backspace → go back in channel history
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _goBackChannel();
      return;
    }
  }

  void _scrollToIndex(int index) {
    // Approximate item height of ~52px
    final offset = (index * 52.0).clamp(
      0.0,
      _channelListController.position.maxScrollExtent,
    );
    _channelListController.animateTo(
      offset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _adjustVolume(double delta) {
    setState(() {
      _volume = (_volume + delta).clamp(0.0, 100.0);
      _showVolumeOverlay = true;
    });
    ref.read(playerServiceProvider).setVolume(_volume);
    _volumeOverlayTimer?.cancel();
    _volumeOverlayTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showVolumeOverlay = false);
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_allChannels.isEmpty) {
      return _buildEmptyState(context);
    }

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is! KeyDownEvent) return;
        if (_searchFocusNode.hasFocus) return;
        _handleKeyEvent(event);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1A2E),
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(context),
              Expanded(
                child: Column(
                  children: [
                    // Video preview (left) + programme info (right)
                    _buildPreviewRow(),
                    // Group filter
                    _buildGroupFilter(),
                    // Channel list or guide view fills the rest
                    Expanded(child: _showGuideView ? _buildGuideView() : _buildChannelList()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context),
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.live_tv_rounded,
                        size: 64, color: Colors.white24),
                    SizedBox(height: 16),
                    Text(
                      'No channels yet',
                      style:
                          TextStyle(fontSize: 20, color: Colors.white54),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Add an IPTV provider to get started',
                      style:
                          TextStyle(fontSize: 14, color: Colors.white38),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Text(
            'clubTivi',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 16),
          if (_showSearch)
            Expanded(
              child: SizedBox(
                height: 36,
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Search channels...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.white12,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.close,
                          size: 18, color: Colors.white54),
                      onPressed: () {
                        setState(() {
                          _showSearch = false;
                          _searchQuery = '';
                          _searchController.clear();
                          _applyFilters();
                        });
                        _focusNode.requestFocus();
                      },
                    ),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                      _applyFilters();
                    });
                  },
                ),
              ),
            )
          else
            const Spacer(),
          // Previous channel toggle button
          if (_previousIndex >= 0)
            IconButton(
              icon: const Icon(Icons.swap_horiz_rounded, color: Colors.white70),
              tooltip: 'Previous channel (Backspace)',
              onPressed: _goBackChannel,
            ),
          IconButton(
            icon: const Icon(Icons.search_rounded, color: Colors.white70),
            tooltip: 'Search',
            onPressed: () {
              setState(() => _showSearch = true);
              // Ensure cursor focus goes to search field
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _searchFocusNode.requestFocus();
              });
            },
          ),
          IconButton(
            icon: Icon(_showGuideView ? Icons.list_rounded : Icons.calendar_view_week_rounded, color: Colors.white70),
            tooltip: _showGuideView ? 'Channel List' : 'Program Guide',
            onPressed: () => setState(() => _showGuideView = !_showGuideView),
          ),
          IconButton(
            icon: const Icon(Icons.dns_rounded, color: Colors.white70),
            tooltip: 'Providers',
            onPressed: () => context.push('/providers'),
          ),
          IconButton(
            icon: const Icon(Icons.link_rounded, color: Colors.white70),
            tooltip: 'EPG Mappings',
            onPressed: () => context.push('/epg-mapping'),
          ),
          IconButton(
            icon: const Icon(Icons.settings_rounded, color: Colors.white70),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
    );
  }

  /// Top section: video preview on left, programme + status info on right.
  Widget _buildPreviewRow() {
    final playerService = ref.watch(playerServiceProvider);
    final programme = _previewChannel != null ? _getEpgProgramme(_previewChannel!) : null;
    final nextProg = _previewChannel != null ? _getNextProgramme(_previewChannel!) : null;

    return SizedBox(
      height: 200,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 16, top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Video preview (left, 16:9 aspect in 200px height ≈ 356px wide)
            SizedBox(
              width: 356,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                ),
                clipBehavior: Clip.antiAlias,
                child: _previewChannel == null
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.tv_rounded, size: 48, color: Colors.white24),
                            SizedBox(height: 8),
                            Text('Select a channel', style: TextStyle(color: Colors.white38, fontSize: 13)),
                          ],
                        ),
                      )
                    : GestureDetector(
                        onTap: () => _goFullscreen(_previewChannel!),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Video(
                              controller: playerService.videoController,
                              controls: NoVideoControls,
                            ),
                            if (_showOverlay && _previewChannel != null)
                              ChannelInfoOverlay(
                                channelNumber: _selectedIndex + 1,
                                channelName: _previewChannel!.name,
                                channelLogo: _previewChannel!.tvgLogo,
                                groupTitle: _previewChannel!.groupTitle,
                                currentProgramme: programme?.title,
                                currentProgrammeTime: _programmeTimeRange(programme),
                                nextProgramme: nextProg?.title,
                                nextProgrammeTime: _programmeTimeRange(nextProg),
                                playerService: playerService,
                                onDismissed: () {
                                  if (mounted) setState(() => _showOverlay = false);
                                },
                              ),
                            if (_showVolumeOverlay)
                              Positioned(
                                top: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.black87,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _volume == 0 ? Icons.volume_off : _volume < 50 ? Icons.volume_down : Icons.volume_up,
                                        color: Colors.white, size: 16,
                                      ),
                                      const SizedBox(width: 4),
                                      Text('${_volume.round()}%', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            // Programme info + controls (right side)
            Expanded(
              child: _previewChannel == null
                  ? const SizedBox.shrink()
                  : Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF16213E),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Channel name + group
                          Text(
                            _previewChannel!.name,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (_previewChannel!.groupTitle != null && _previewChannel!.groupTitle!.isNotEmpty)
                            Text(
                              _previewChannel!.groupTitle!,
                              style: const TextStyle(color: Colors.white38, fontSize: 11),
                              overflow: TextOverflow.ellipsis,
                            ),
                          const SizedBox(height: 8),
                          // Now playing
                          if (programme != null) ...[
                            Row(
                              children: [
                                const Icon(Icons.play_circle_outline, size: 14, color: Colors.cyanAccent),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    programme.title,
                                    style: const TextStyle(color: Colors.white, fontSize: 13),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              _programmeTimeRange(programme) ?? '',
                              style: const TextStyle(color: Colors.white38, fontSize: 11),
                            ),
                          ],
                          if (programme != null && programme.description != null && programme.description!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                programme.description!,
                                style: const TextStyle(color: Colors.white54, fontSize: 11),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          // Next up
                          if (nextProg != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Row(
                                children: [
                                  const Text('Next: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                                  Expanded(
                                    child: Text(
                                      '${nextProg.title}  ${_programmeTimeRange(nextProg) ?? ''}',
                                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const Spacer(),
                          // Bottom row: status + controls
                          Row(
                            children: [
                              // Buffering status
                              StreamBuilder<bool>(
                                stream: playerService.bufferingStream,
                                builder: (context, snapshot) {
                                  final buffering = snapshot.data ?? false;
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (buffering)
                                        const SizedBox(
                                          width: 12, height: 12,
                                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.orangeAccent),
                                        )
                                      else
                                        const Icon(Icons.signal_cellular_alt, size: 14, color: Colors.green),
                                      const SizedBox(width: 4),
                                      Text(
                                        buffering ? 'Buffering' : 'OK',
                                        style: TextStyle(color: buffering ? Colors.orangeAccent : Colors.green, fontSize: 11),
                                      ),
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(width: 4),
                              // Audio indicator
                              StreamBuilder<bool>(
                                stream: playerService.hasAudioStream,
                                builder: (context, snapshot) {
                                  final hasAudio = snapshot.data ?? true;
                                  if (hasAudio) return const SizedBox.shrink();
                                  return const Tooltip(
                                    message: 'No audio track detected',
                                    child: Icon(Icons.volume_off_rounded, size: 14, color: Colors.redAccent),
                                  );
                                },
                              ),
                              const Spacer(),
                              // Debug info
                              SizedBox(
                                height: 28, width: 28,
                                child: IconButton(
                                  onPressed: () => ChannelDebugDialog.show(context, _previewChannel!, playerService),
                                  icon: const Icon(Icons.info_outline, size: 16),
                                  padding: EdgeInsets.zero,
                                  color: Colors.white70,
                                  tooltip: 'Channel debug info',
                                ),
                              ),
                              // Fullscreen
                              SizedBox(
                                height: 28,
                                child: TextButton.icon(
                                  onPressed: () => _goFullscreen(_previewChannel!),
                                  icon: const Icon(Icons.fullscreen_rounded, size: 16),
                                  label: const Text('Fullscreen', style: TextStyle(fontSize: 11)),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.white70,
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupFilter() {
    // Build chip items: All | ★ Favorites | ★ <list names> | [group chips...] | Manage ★
    final List<_FilterChip> items = [
      _FilterChip('All', 'All', null),
      _FilterChip('★ Favorites', 'Favorites', Icons.star_rounded),
    ];
    for (final list in _favoriteLists) {
      items.add(_FilterChip('★ ${list.name}', 'fav:${list.id}', Icons.star_outline_rounded));
    }
    for (final group in _groups) {
      items.add(_FilterChip(group, group, null));
    }

    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final isSelected = item.filterKey == _selectedGroup;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: ChoiceChip(
                    avatar: item.icon != null
                        ? Icon(item.icon, size: 14,
                            color: isSelected ? Colors.amber : Colors.amber.withValues(alpha: 0.6))
                        : null,
                    label: Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 12,
                        color: isSelected ? Colors.white : Colors.white60,
                      ),
                    ),
                    selected: isSelected,
                    selectedColor: item.filterKey == 'Favorites' || item.filterKey.startsWith('fav:')
                        ? const Color(0xFFE17055)
                        : const Color(0xFF6C5CE7),
                    backgroundColor: const Color(0xFF16213E),
                    side: BorderSide.none,
                    onSelected: (_) {
                      setState(() {
                        _selectedGroup = item.filterKey;
                        _applyFilters();
                      });
                    },
                  ),
                );
              },
            ),
          ),
          // Manage favorites button
          IconButton(
            icon: const Icon(Icons.playlist_add_rounded, size: 20, color: Colors.white54),
            tooltip: 'Manage Favorite Lists',
            onPressed: () => _showManageFavoritesDialog(),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelList() {
    if (_filteredChannels.isEmpty) {
      return const Center(
        child: Text(
          'No channels match your filter',
          style: TextStyle(color: Colors.white38),
        ),
      );
    }

    return ListView.builder(
      controller: _channelListController,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: _filteredChannels.length,
      itemBuilder: (context, index) {
        final channel = _filteredChannels[index];
        final isSelected = index == _selectedIndex;
        final isFavorited = _favoritedChannelIds.contains(channel.id);

        return Material(
          color: Colors.transparent,
          child: GestureDetector(
            onSecondaryTapUp: (_) => _showFavoriteListSheet(channel),
            child: InkWell(
              onTap: () => _selectChannel(index),
              onDoubleTap: () => _goFullscreen(channel),
              onLongPress: () => _showFavoriteListSheet(channel),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF6C5CE7).withValues(alpha: 0.3)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: isSelected
                    ? Border.all(
                        color: const Color(0xFF6C5CE7), width: 1.5)
                    : null,
              ),
              child: Row(
                children: [
                  // Channel number
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: isSelected
                            ? Colors.white
                            : Colors.white38,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Channel logo
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: channel.tvgLogo != null &&
                              channel.tvgLogo!.isNotEmpty
                          ? Image.network(
                              channel.tvgLogo!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, e, s) => Container(
                                color: const Color(0xFF16213E),
                                child: const Icon(Icons.tv,
                                    size: 18, color: Colors.white24),
                              ),
                            )
                          : Container(
                              color: const Color(0xFF16213E),
                              child: const Icon(Icons.tv,
                                  size: 18, color: Colors.white24),
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Channel name + group + now-playing
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          channel.name,
                          style: TextStyle(
                            color: isSelected
                                ? Colors.white
                                : Colors.white70,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (channel.groupTitle != null &&
                            channel.groupTitle!.isNotEmpty)
                          Text(
                            channel.groupTitle!,
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (_getChannelNowPlaying(channel) != null)
                          Text(
                            _getChannelNowPlaying(channel)!,
                            style: const TextStyle(
                              color: Color(0xFF6C5CE7),
                              fontSize: 11,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  // Favorite indicator
                  if (isFavorited)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.star_rounded, color: Colors.amber, size: 16),
                    ),
                  // Now-playing indicator
                  if (isSelected)
                    const Icon(Icons.play_arrow_rounded,
                        color: Color(0xFF6C5CE7), size: 20),
                ],
              ),
            ),
          ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Favorite list interactions
  // ---------------------------------------------------------------------------

  /// Bottom sheet to add/remove a channel from favorite lists.
  Future<void> _showFavoriteListSheet(db.Channel channel) async {
    final database = ref.read(databaseProvider);
    final listsForChannel = await database.getListsForChannel(channel.id);
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
                          'Add "${channel.name}" to list',
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
                          await database.addChannelToList(list.id, channel.id);
                          checkedIds.add(list.id);
                        } else {
                          await database.removeChannelFromList(list.id, channel.id);
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
                        await database.addChannelToList(newList.id, channel.id);
                        checkedIds.add(newList.id);
                        // Reload lists
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
    // Refresh favorited state after sheet closes
    final favIds = await database.getAllFavoritedChannelIds();
    if (mounted) {
      setState(() {
        _favoritedChannelIds = favIds;
        _applyFilters();
      });
    }
  }

  /// Dialog to create a new favorite list — returns the name or null.
  Future<String?> _showCreateListDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('New Favorite List', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'e.g. Sports, News, Kids',
            hintStyle: const TextStyle(color: Colors.white38),
            filled: true,
            fillColor: Colors.white12,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create', style: TextStyle(color: Colors.cyanAccent)),
          ),
        ],
      ),
    );
  }

  /// Dialog to manage (create/rename/delete) favorite lists.
  Future<void> _showManageFavoritesDialog() async {
    final database = ref.read(databaseProvider);
    var lists = List<db.FavoriteList>.from(_favoriteLists);

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF16213E),
              title: Row(
                children: [
                  const Icon(Icons.star_rounded, color: Colors.amber, size: 22),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Manage Favorite Lists', style: TextStyle(color: Colors.white, fontSize: 16)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_rounded, color: Colors.cyanAccent, size: 20),
                    tooltip: 'Create new list',
                    onPressed: () async {
                      final name = await _showCreateListDialog();
                      if (name != null && name.isNotEmpty) {
                        await database.createFavoriteList(name);
                        lists = await database.getAllFavoriteLists();
                        setDialogState(() {});
                      }
                    },
                  ),
                ],
              ),
              content: SizedBox(
                width: 340,
                child: lists.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text('No favorite lists yet.\nTap + to create one.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white38)),
                        ),
                      )
                    : ReorderableListView.builder(
                        shrinkWrap: true,
                        itemCount: lists.length,
                        onReorder: (oldIdx, newIdx) async {
                          if (newIdx > oldIdx) newIdx--;
                          final item = lists.removeAt(oldIdx);
                          lists.insert(newIdx, item);
                          setDialogState(() {});
                          // Persist new sort order
                          for (var i = 0; i < lists.length; i++) {
                            await (database.update(database.favoriteLists)
                                  ..where((t) => t.id.equals(lists[i].id)))
                                .write(db.FavoriteListsCompanion(sortOrder: Value(i)));
                          }
                        },
                        itemBuilder: (ctx, index) {
                          final list = lists[index];
                          return ListTile(
                            key: ValueKey(list.id),
                            leading: const Icon(Icons.drag_handle_rounded, color: Colors.white38, size: 18),
                            title: Text('★ ${list.name}', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_rounded, size: 16, color: Colors.white38),
                                  tooltip: 'Rename',
                                  onPressed: () async {
                                    final newName = await _showRenameDialog(list.name);
                                    if (newName != null && newName.isNotEmpty) {
                                      await database.renameFavoriteList(list.id, newName);
                                      lists = await database.getAllFavoriteLists();
                                      setDialogState(() {});
                                    }
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline_rounded, size: 16, color: Colors.redAccent),
                                  tooltip: 'Delete',
                                  onPressed: () async {
                                    final confirmed = await _showDeleteConfirmation(list.name);
                                    if (confirmed == true) {
                                      await database.deleteFavoriteList(list.id);
                                      lists = await database.getAllFavoriteLists();
                                      setDialogState(() {});
                                    }
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Done', style: TextStyle(color: Colors.cyanAccent)),
                ),
              ],
            );
          },
        );
      },
    );
    // Refresh lists after dialog closes
    final updated = await database.getAllFavoriteLists();
    final favIds = await database.getAllFavoritedChannelIds();
    if (mounted) {
      setState(() {
        _favoriteLists = updated;
        _favoritedChannelIds = favIds;
        _applyFilters();
      });
    }
  }

  Future<String?> _showRenameDialog(String currentName) {
    final controller = TextEditingController(text: currentName);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('Rename List', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white12,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Rename', style: TextStyle(color: Colors.cyanAccent)),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showDeleteConfirmation(String listName) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('Delete List?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Are you sure you want to delete "$listName"?\nChannels will not be deleted.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Inline guide view
  // ---------------------------------------------------------------------------

  static const _pixelsPerMinute = 3.0;

  Widget _buildGuideView() {
    if (_filteredChannels.isEmpty) {
      return const Center(
        child: Text('No channels match your filter',
            style: TextStyle(color: Colors.white38)),
      );
    }

    // Auto-scroll to "now" when guide view opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_guideScrollController.hasClients &&
          _guideScrollController.position.pixels == 0.0) {
        final now = DateTime.now();
        final nowMinutes = now.hour * 60 + now.minute;
        final target = (nowMinutes * _pixelsPerMinute - 100)
            .clamp(0.0, _guideScrollController.position.maxScrollExtent);
        _guideScrollController.jumpTo(target);
      }
    });

    final database = ref.read(databaseProvider);
    final today = DateTime.now();
    final dayStart = DateTime(today.year, today.month, today.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    return Column(
      children: [
        // Time ruler
        SizedBox(
          height: 28,
          child: Row(
            children: [
              const SizedBox(width: 120),
              Expanded(
                child: SingleChildScrollView(
                  controller: _guideScrollController,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: List.generate(24, (hour) {
                      final width = 60 * _pixelsPerMinute;
                      return SizedBox(
                        width: width,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Text(
                            '${hour.toString().padLeft(2, '0')}:00',
                            style: const TextStyle(
                                fontSize: 10, color: Colors.white38),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Colors.white12),
        // Channel rows
        Expanded(
          child: ListView.builder(
            itemCount: _filteredChannels.length,
            itemBuilder: (context, index) {
              final channel = _filteredChannels[index];
              return SizedBox(
                height: 48,
                child: Row(
                  children: [
                    // Channel label
                    SizedBox(
                      width: 120,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          channel.name,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white70),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    // Programme blocks
                    Expanded(
                      child: _buildGuideRowProgrammes(
                          channel, database, dayStart, dayEnd),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGuideRowProgrammes(db.Channel channel,
      db.AppDatabase database, DateTime dayStart, DateTime dayEnd) {
    final epgId = _getEpgId(channel);
    if (epgId == null) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Center(
          child:
              Text('No EPG', style: TextStyle(fontSize: 10, color: Colors.white24)),
        ),
      );
    }

    return FutureBuilder<List<db.EpgProgramme>>(
      // TODO: Consider a batch load for all channels to avoid per-row queries
      future: database.getProgrammes(
        epgChannelId: epgId,
        start: dayStart,
        end: dayEnd,
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            color: Colors.white.withValues(alpha: 0.03),
            child: const Center(
              child: Text('No EPG data',
                  style: TextStyle(fontSize: 10, color: Colors.white24)),
            ),
          );
        }

        final programmes = snapshot.data!;
        final now = DateTime.now();

        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            // Sync scroll with the time ruler
            if (notification is ScrollUpdateNotification &&
                _guideScrollController.hasClients) {
              _guideScrollController.jumpTo(notification.metrics.pixels);
            }
            return false;
          },
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            controller: ScrollController(
              initialScrollOffset: _guideScrollController.hasClients
                  ? _guideScrollController.offset
                  : 0,
            ),
            child: Row(
              children: programmes.map((prog) {
                final durationMin =
                    prog.stop.difference(prog.start).inMinutes.clamp(1, 1440);
                final width = durationMin * _pixelsPerMinute;
                final isCurrent =
                    now.isAfter(prog.start) && now.isBefore(prog.stop);
                return Container(
                  width: width,
                  height: 44,
                  margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 0.5),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? const Color(0xFF6C5CE7).withValues(alpha: 0.3)
                        : const Color(0xFF16213E),
                    borderRadius: BorderRadius.circular(3),
                    border: isCurrent
                        ? Border.all(color: const Color(0xFF6C5CE7), width: 1)
                        : null,
                  ),
                  child: Text(
                    prog.title,
                    style: TextStyle(
                      fontSize: 10,
                      color: isCurrent ? Colors.white : Colors.white54,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
            ),
          ),
        );
      },
    );
  }
}

/// Helper model for filter chip items.
class _FilterChip {
  final String label;
  final String filterKey;
  final IconData? icon;
  const _FilterChip(this.label, this.filterKey, this.icon);
}
