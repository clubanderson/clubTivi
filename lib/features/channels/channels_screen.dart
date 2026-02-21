import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
  final _searchController = TextEditingController();
  final _channelListController = ScrollController();

  // Overlay state
  bool _showOverlay = false;
  Timer? _overlayTimer;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _channelListController.dispose();
    _overlayTimer?.cancel();
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
      final q = _searchQuery.toLowerCase();
      channels =
          channels.where((c) => c.name.toLowerCase().contains(q)).toList();
    }
    _filteredChannels = channels;
    if (_selectedIndex >= _filteredChannels.length) {
      _selectedIndex = _filteredChannels.isEmpty ? -1 : 0;
    }
  }

  void _selectChannel(int index) {
    if (index < 0 || index >= _filteredChannels.length) return;
    final channel = _filteredChannels[index];
    final playerService = ref.read(playerServiceProvider);
    playerService.play(channel.streamUrl);
    setState(() {
      _selectedIndex = index;
      _previewChannel = channel;
    });
    _showInfoOverlay(channel, index);
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
    context.push('/player', extra: {
      'streamUrl': channel.streamUrl,
      'channelName': channel.name,
      'channelLogo': channel.tvgLogo,
      'alternativeUrls': <String>[],
    });
  }

  // ---------------------------------------------------------------------------
  // EPG helpers
  // ---------------------------------------------------------------------------

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

  String? _getNowPlayingTitle(db.Channel channel) {
    return _getEpgProgramme(channel)?.title;
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
                child: Row(
                  children: [
                    // Left: preview + now-playing info
                    Expanded(
                      flex: 4,
                      child: Column(
                        children: [
                          _buildVideoPreview(),
                          _buildNowPlayingInfo(),
                        ],
                      ),
                    ),
                    // Right: group filter + channel list
                    Expanded(
                      flex: 6,
                      child: Column(
                        children: [
                          _buildGroupFilter(),
                          Expanded(child: _buildChannelList()),
                        ],
                      ),
                    ),
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
          IconButton(
            icon: const Icon(Icons.search_rounded, color: Colors.white70),
            tooltip: 'Search',
            onPressed: () => setState(() => _showSearch = true),
          ),
          IconButton(
            icon: const Icon(Icons.tv_rounded, color: Colors.white70),
            tooltip: 'Guide',
            onPressed: () => context.push('/guide'),
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

    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(left: 16, right: 8, top: 4),
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
                onDoubleTap: () => _goFullscreen(_previewChannel!),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Video(controller: playerService.videoController),
                    // Channel info overlay at bottom (gradient)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black87,
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _previewChannel!.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (_getNowPlayingTitle(_previewChannel!) !=
                                null)
                              Text(
                                _getNowPlayingTitle(_previewChannel!)!,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                    ),
                    // Cable TV-style channel info overlay
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
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildNowPlayingInfo() {
    if (_previewChannel == null) return const SizedBox.shrink();

    final epgTitle = _getNowPlayingTitle(_previewChannel!);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(left: 16, right: 8, top: 4, bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _previewChannel!.name,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 2),
          if (_previewChannel!.groupTitle != null &&
              _previewChannel!.groupTitle!.isNotEmpty)
            Text(
              _previewChannel!.groupTitle!,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          if (epgTitle != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.play_circle_outline,
                    size: 14, color: Color(0xFF6C5CE7)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    epgTitle,
                    style: const TextStyle(
                      color: Color(0xFF6C5CE7),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _goFullscreen(_previewChannel!),
              icon: const Icon(Icons.fullscreen_rounded),
              label: const Text('Watch Fullscreen'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C5CE7),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
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
                  // Channel name + group
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
}
