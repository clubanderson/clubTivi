import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/fuzzy_match.dart';
import '../../data/datasources/local/database.dart' as db;
import '../player/player_service.dart';
import '../providers/provider_manager.dart';
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
  bool _showGuideView = false;
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

  // Channel history (stack of channel indices for back navigation)
  final List<int> _channelHistory = [];

  @override
  void initState() {
    super.initState();
    _loadChannels();
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

    // Load now-playing EPG data
    final epgChannelIds = allChannels
        .where((c) => c.tvgId != null && c.tvgId!.isNotEmpty)
        .map((c) => c.tvgId!)
        .toSet()
        .toList();
    List<db.EpgProgramme> nowPlaying = [];
    if (epgChannelIds.isNotEmpty) {
      nowPlaying = await database.getNowPlaying(epgChannelIds);
    }

    if (!mounted) return;
    setState(() {
      _allChannels = allChannels;
      _groups = groups;
      _nowPlaying = nowPlaying;
      _isLoading = false;
      _applyFilters();
    });
  }

  void _applyFilters() {
    var channels = _allChannels;
    if (_selectedGroup != 'All') {
      channels =
          channels.where((c) => c.groupTitle == _selectedGroup).toList();
    }
    if (_searchQuery.isNotEmpty) {
      channels =
          channels.where((c) => fuzzyMatchPasses(_searchQuery, [c.name, c.groupTitle, _getChannelNowPlaying(c)])).toList();
    }
    _filteredChannels = channels;
    if (_selectedIndex >= _filteredChannels.length) {
      _selectedIndex = _filteredChannels.isEmpty ? -1 : 0;
    }
  }

  void _selectChannel(int index) {
    if (index < 0 || index >= _filteredChannels.length) return;
    // Push current channel to history before switching
    if (_selectedIndex >= 0 && _selectedIndex != index) {
      _channelHistory.add(_selectedIndex);
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

  void _goBackChannel() {
    if (_channelHistory.isEmpty) return;
    final prevIndex = _channelHistory.removeLast();
    if (prevIndex < 0 || prevIndex >= _filteredChannels.length) return;
    final channel = _filteredChannels[prevIndex];
    final playerService = ref.read(playerServiceProvider);
    playerService.play(channel.streamUrl);
    setState(() {
      _selectedIndex = prevIndex;
      _previewChannel = channel;
    });
    _showInfoOverlay(channel, prevIndex);
  }

  void _clearHistory() {
    setState(() => _channelHistory.clear());
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

  String? _getChannelNowPlaying(db.Channel channel) {
    if (channel.tvgId == null || channel.tvgId!.isEmpty) return null;
    final match =
        _nowPlaying.where((p) => p.epgChannelId == channel.tvgId).toList();
    return match.isNotEmpty ? match.first.title : null;
  }

  db.EpgProgramme? _getEpgProgramme(db.Channel channel) {
    if (channel.tvgId == null || channel.tvgId!.isEmpty) return null;
    final matches =
        _nowPlaying.where((p) => p.epgChannelId == channel.tvgId).toList();
    return matches.isNotEmpty ? matches.first : null;
  }

  db.EpgProgramme? _getNextProgramme(db.Channel channel) {
    if (channel.tvgId == null || channel.tvgId!.isEmpty) return null;
    final matches =
        _nowPlaying.where((p) => p.epgChannelId == channel.tvgId).toList();
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

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.channelUp) {
      final newIndex = (_selectedIndex - 1).clamp(0, _filteredChannels.length - 1);
      if (newIndex != _selectedIndex) {
        _selectChannel(newIndex);
        _scrollToIndex(newIndex);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.channelDown) {
      final newIndex = (_selectedIndex + 1).clamp(0, _filteredChannels.length - 1);
      if (newIndex != _selectedIndex) {
        _selectChannel(newIndex);
        _scrollToIndex(newIndex);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.select) {
      if (_previewChannel != null) {
        _goFullscreen(_previewChannel!);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _adjustVolume(-5);
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _adjustVolume(5);
      return KeyEventResult.handled;
    }

    // Backspace → go back in channel history
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _goBackChannel();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
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

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1A2E),
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(context),
              Expanded(
                child: Column(
                  children: [
                    // Video preview
                    _buildVideoPreview(),
                    // Persistent info bar with channel name, buffering status, fullscreen
                    _buildPreviewInfoBar(),
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
          // Channel history back button
          if (_channelHistory.isNotEmpty)
            Stack(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white70),
                  tooltip: 'Previous channel (Backspace)',
                  onPressed: _goBackChannel,
                ),
                Positioned(
                  right: 4,
                  top: 4,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                      color: Color(0xFF6C5CE7),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${_channelHistory.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          if (_channelHistory.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear_all_rounded, color: Colors.white38),
              tooltip: 'Clear history',
              onPressed: _clearHistory,
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

  Widget _buildVideoPreview() {
    final playerService = ref.watch(playerServiceProvider);

    return SizedBox(
      height: 240,
      child: Container(
        margin: const EdgeInsets.only(left: 16, right: 16, top: 4),
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
                    Icon(Icons.tv_rounded,
                        size: 48, color: Colors.white24),
                    SizedBox(height: 8),
                    Text(
                      'Select a channel to preview',
                      style:
                          TextStyle(color: Colors.white38, fontSize: 13),
                    ),
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
                    // Cable TV-style channel info overlay (temporary on channel change)
                    if (_showOverlay && _previewChannel != null)
                      ChannelInfoOverlay(
                        channelNumber: _selectedIndex + 1,
                        channelName: _previewChannel!.name,
                        channelLogo: _previewChannel!.tvgLogo,
                        groupTitle: _previewChannel!.groupTitle,
                        currentProgramme:
                            _getEpgProgramme(_previewChannel!)?.title,
                        currentProgrammeTime: _programmeTimeRange(
                            _getEpgProgramme(_previewChannel!)),
                        nextProgramme:
                            _getNextProgramme(_previewChannel!)?.title,
                        nextProgrammeTime: _programmeTimeRange(
                            _getNextProgramme(_previewChannel!)),
                        playerService: playerService,
                        onDismissed: () {
                          if (mounted) {
                            setState(() => _showOverlay = false);
                          }
                        },
                      ),
                    // Volume indicator overlay
                    if (_showVolumeOverlay)
                      Positioned(
                        top: 12,
                        right: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
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
                              const SizedBox(width: 6),
                              Text(
                                '${_volume.round()}%',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
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
    );
  }

  /// Persistent info bar below the video: channel name, sparkline, fullscreen.
  Widget _buildPreviewInfoBar() {
    if (_previewChannel == null) return const SizedBox.shrink();

    final playerService = ref.watch(playerServiceProvider);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF16213E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          // Channel name
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _previewChannel!.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (_previewChannel!.groupTitle != null &&
                    _previewChannel!.groupTitle!.isNotEmpty)
                  Text(
                    _previewChannel!.groupTitle!,
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Buffering sparkline (always visible)
          StreamBuilder<bool>(
            stream: playerService.bufferingStream,
            builder: (context, snapshot) {
              final buffering = snapshot.data ?? false;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (buffering)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.orangeAccent,
                      ),
                    )
                  else
                    const Icon(Icons.signal_cellular_alt,
                        size: 14, color: Colors.green),
                  const SizedBox(width: 4),
                  Text(
                    buffering ? 'Buffering' : 'OK',
                    style: TextStyle(
                      color: buffering ? Colors.orangeAccent : Colors.green,
                      fontSize: 11,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(width: 8),
          // Fullscreen button
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
    );
  }

  Widget _buildGroupFilter() {
    final items = ['All', ..._groups];
    return SizedBox(
      height: 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final group = items[index];
          final isSelected = group == _selectedGroup;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: ChoiceChip(
              label: Text(
                group,
                style: TextStyle(
                  fontSize: 12,
                  color: isSelected ? Colors.white : Colors.white60,
                ),
              ),
              selected: isSelected,
              selectedColor: const Color(0xFF6C5CE7),
              backgroundColor: const Color(0xFF16213E),
              side: BorderSide.none,
              onSelected: (_) {
                setState(() {
                  _selectedGroup = group;
                  _applyFilters();
                });
              },
            ),
          );
        },
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

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _selectChannel(index),
            onDoubleTap: () => _goFullscreen(channel),
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
                  // Now-playing indicator
                  if (isSelected)
                    const Icon(Icons.play_arrow_rounded,
                        color: Color(0xFF6C5CE7), size: 20),
                ],
              ),
            ),
          ),
        );
      },
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
    if (channel.tvgId == null || channel.tvgId!.isEmpty) {
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
        epgChannelId: channel.tvgId!,
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
