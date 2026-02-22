import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/fuzzy_match.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/datasources/remote/tmdb_client.dart';
import '../../data/services/app_update_service.dart';
import '../../data/services/epg_refresh_service.dart';
import '../casting/cast_service.dart';
import '../casting/cast_dialog.dart';
import '../player/player_service.dart';
import '../providers/provider_manager.dart';
import '../shows/shows_providers.dart';
import 'channel_debug_dialog.dart';
import 'channel_info_overlay.dart';

class ChannelsScreen extends ConsumerStatefulWidget {
  const ChannelsScreen({super.key});

  @override
  ConsumerState<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends ConsumerState<ChannelsScreen> {
  static bool _updateCheckDone = false;
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
  Set<String> _validEpgChannelIds = {};
  bool _showGuideView = !Platform.isAndroid;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _channelListController = ScrollController();
  late final ScrollController _guideScrollController;
  Timer? _guideIdleTimer;
  DateTime? _guideDayStart; // stored for snap-back calculation

  // Overlay state
  bool _showOverlay = false;
  Timer? _overlayTimer;
  Timer? _nowPlayingTimer;
  final _focusNode = FocusNode();

  // Volume state
  double _volume = 100.0;
  bool _showVolumeOverlay = false;
  Timer? _volumeOverlayTimer;

  // Last channel for back/forth toggle (not a full history stack)
  int _previousIndex = -1;

  // Sidebar state
  bool _sidebarExpanded = true;
  Set<String> _expandedSections = {'favorites'};
  final _sidebarSearchController = TextEditingController();
  final _sidebarFocusNode = FocusScopeNode(debugLabel: 'sidebar');
  final _sidebarAllItemFocusNode = FocusNode(debugLabel: 'sidebar-all');
  FocusNode? _firstChannelFocusNode;
  String _sidebarSearchQuery = '';

  // Top bar auto-hide
  double _topBarOpacity = 1.0;
  Timer? _topBarTimer;
  bool _mouseInTopBar = false;

  // Failover suggestion
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<List<db.Provider>>? _providersSub;
  StreamSubscription<List<db.Channel>>? _channelsSub;
  Timer? _failoverTimer;
  db.Channel? _failoverSuggestion;
  bool _showFailoverBanner = false;
  static const _kFailoverEnabled = 'failover_enabled';
  bool _failoverEnabled = true;

  // Provider list for sidebar
  List<db.Provider> _providers = [];
  // Pre-computed: provider ID → sorted group names
  Map<String, List<String>> _providerGroups = {};

  // Favorite lists state
  List<db.FavoriteList> _favoriteLists = [];
  Set<String> _favoritedChannelIds = {};

  // Time format
  bool _use24HourTime = false;
  static const _kUse24HourTime = 'use_24_hour_time';

  // Per-channel EPG timeshift in hours
  final Map<String, int> _epgTimeshifts = {};
  static const _kEpgTimeshifts = 'epg_timeshifts';

  // IMDB ID cache: show title → IMDB ID (null = lookup in progress/failed)
  final Map<String, String?> _imdbIdCache = {};

  // Persistence keys
  static const _kLastChannelId = 'last_channel_id';
  static const _kLastGroup = 'last_group';

  @override
  void initState() {
    super.initState();
    _guideScrollController = ScrollController();
    _loadChannels();
    _ensureEpgSources();
    _startTopBarFade();
    _initFailoverListener();
    // Watch providers table — reload when providers or channels change
    final database = ref.read(databaseProvider);
    Timer? debounce;
    void debouncedReload() {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 500), () {
        if (mounted) _loadChannels();
      });
    }
    _providersSub = database.select(database.providers).watch().listen((_) => debouncedReload());
    _channelsSub = database.select(database.channels).watch().listen((_) => debouncedReload());
    // Refresh now-playing every 60 seconds so the info panel stays current
    _nowPlayingTimer = Timer.periodic(const Duration(seconds: 60), (_) => _refreshNowPlaying());
    // Check for app updates after a short delay so the UI loads first
    Future.delayed(const Duration(seconds: 3), _checkForUpdateOnStartup);
  }

  Future<void> _checkForUpdateOnStartup() async {
    if (_updateCheckDone || !mounted) return;
    _updateCheckDone = true;
    final release = await AppUpdateService.checkForUpdate();
    if (!mounted || release == null || !release.isNewer) return;

    // Show a non-intrusive banner at the bottom
    ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        backgroundColor: const Color(0xFF1A1A2E),
        content: Text(
          'Update available: v${release.version}',
          style: const TextStyle(color: Colors.white),
        ),
        leading: const Icon(Icons.system_update, color: Color(0xFF6C5CE7)),
        actions: [
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
            },
            child: const Text('LATER'),
          ),
          if (release.apkDownloadUrl != null)
            TextButton(
              onPressed: () {
                ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
                _showDownloadDialog(release.apkDownloadUrl!);
              },
              child: const Text('UPDATE'),
            ),
        ],
      ),
    );
  }

  Future<void> _showDownloadDialog(String apkUrl) async {
    double progress = 0;
    late StateSetter dialogSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          dialogSetState = setState;
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A2E),
            title: const Text('Downloading Update…'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 12),
                Text('${(progress * 100).toStringAsFixed(0)}%'),
              ],
            ),
          );
        },
      ),
    );

    await AppUpdateService.downloadAndInstall(
      apkUrl,
      onProgress: (p) {
        try { dialogSetState(() => progress = p); } catch (_) {}
      },
      onError: (error) {
        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error), backgroundColor: Colors.red),
          );
        }
      },
    );
    // Dismiss dialog after install intent launches
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _refreshNowPlaying() async {
    if (!mounted) return;
    final database = ref.read(databaseProvider);
    final epgChannelIds = <String>{};
    for (final c in _allChannels) {
      final mapped = _epgMappings[c.id];
      if (mapped != null && mapped.isNotEmpty) {
        epgChannelIds.add(mapped);
      } else if (c.tvgId != null && c.tvgId!.isNotEmpty && _validEpgChannelIds.contains(c.tvgId)) {
        epgChannelIds.add(c.tvgId!);
      }
    }
    if (epgChannelIds.isEmpty) return;
    final maxShift = _epgTimeshifts.values.fold<int>(0, (m, v) => v.abs() > m ? v.abs() : m);
    final now = DateTime.now();
    final nowPlaying = maxShift > 0
        ? await database.getNowPlayingWindow(
            epgChannelIds.toList(),
            now.subtract(Duration(hours: maxShift + 1)),
            now.add(Duration(hours: maxShift + 1)))
        : await database.getNowPlaying(epgChannelIds.toList());
    if (!mounted) return;
    setState(() {
      _nowPlaying = nowPlaying;
    });
  }

  void _initFailoverListener() async {
    final prefs = await SharedPreferences.getInstance();
    _failoverEnabled = prefs.getBool(_kFailoverEnabled) ?? true;
    final playerService = ref.read(playerServiceProvider);
    _bufferingSub = playerService.bufferingStream.listen((buffering) {
      if (!_failoverEnabled) return;
      if (buffering) {
        // Start a 5-second timer — if still buffering, suggest alternative
        _failoverTimer?.cancel();
        _failoverTimer = Timer(const Duration(seconds: 5), () {
          if (!mounted) return;
          _suggestAlternative();
        });
      } else {
        _failoverTimer?.cancel();
        if (_showFailoverBanner) {
          setState(() => _showFailoverBanner = false);
        }
      }
    });
  }

  void _suggestAlternative() {
    if (_selectedIndex < 0 || _selectedIndex >= _filteredChannels.length) return;
    final current = _filteredChannels[_selectedIndex];
    final currentName = current.name.toLowerCase()
        .replaceAll(RegExp(r'\b(hd|fhd|shd|sd|4k|uhd)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'(us-?[a-z]*\|?|uk-?[a-z]*\|?|ca-?[a-z]*\|?|mx-?[a-z]*\|?)'), '')
        .replaceAll(RegExp(r'[\s|()[\]]+'), ' ')
        .trim();

    // 1. Best: exact same normalized name on a different provider
    final sameNameDiffProvider = _allChannels.where((c) =>
        c.id != current.id &&
        c.providerId != current.providerId &&
        _normalizeName(c.name) == currentName).toList();

    // 2. Good: exact same normalized name on the same provider (different stream)
    final sameNameSameProvider = _allChannels.where((c) =>
        c.id != current.id &&
        c.providerId == current.providerId &&
        _normalizeName(c.name) == currentName).toList();

    // 3. Fallback: channels containing key words of the current name
    final words = currentName.split(RegExp(r'\s+'))
        .where((w) => w.length > 2).toList();
    final fuzzyMatches = words.isEmpty ? <db.Channel>[] : _allChannels
        .where((c) => c.id != current.id &&
            words.every((w) => c.name.toLowerCase().contains(w)))
        .toList();

    final candidates = [
      ...sameNameDiffProvider,
      ...sameNameSameProvider,
      ...fuzzyMatches,
    ];
    if (candidates.isEmpty) return;

    setState(() {
      _failoverSuggestion = candidates.first;
      _showFailoverBanner = true;
    });
  }

  String _normalizeName(String name) {
    return name.toLowerCase()
        .replaceAll(RegExp(r'\b(hd|fhd|shd|sd|4k|uhd)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'(us-?[a-z]*\|?|uk-?[a-z]*\|?|ca-?[a-z]*\|?|mx-?[a-z]*\|?)'), '')
        .replaceAll(RegExp(r'[\s|()[\]]+'), ' ')
        .trim();
  }

  void _acceptFailover() {
    if (_failoverSuggestion == null) return;
    final idx = _filteredChannels.indexWhere((c) => c.id == _failoverSuggestion!.id);
    if (idx >= 0) {
      _selectChannel(idx);
    } else {
      // Channel not in current filter — play directly
      final playerService = ref.read(playerServiceProvider);
      playerService.play(_failoverSuggestion!.streamUrl);
      setState(() {
        _previewChannel = _failoverSuggestion;
      });
    }
    setState(() {
      _showFailoverBanner = false;
      _failoverSuggestion = null;
    });
  }

  void _startTopBarFade() {
    _topBarTimer?.cancel();
    if (_mouseInTopBar || Platform.isAndroid) return;
    _topBarTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_mouseInTopBar) setState(() => _topBarOpacity = 0.0);
    });
  }

  void _showTopBar() {
    setState(() => _topBarOpacity = 1.0);
    _startTopBarFade();
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
    _sidebarSearchController.dispose();
    _sidebarFocusNode.dispose();
    _sidebarAllItemFocusNode.dispose();
    _channelListController.dispose();
    _guideScrollController.dispose();
    _guideIdleTimer?.cancel();
    _overlayTimer?.cancel();
    _nowPlayingTimer?.cancel();
    _volumeOverlayTimer?.cancel();
    _topBarTimer?.cancel();
    _failoverTimer?.cancel();
    _bufferingSub?.cancel();
    _providersSub?.cancel();
    _channelsSub?.cancel();
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

    // Load EPG mappings (channel ID → prefixed EPG channel ID for programme lookup)
    final mappings = await database.getAllMappings();
    final epgMap = <String, String>{};
    for (final m in mappings) {
      epgMap[m.channelId] = '${m.epgSourceId}_${m.epgChannelId}';
    }

    // Load valid EPG channel IDs from all sources
    final epgSources = await database.getAllEpgSources();
    final validIds = <String>{};
    for (final src in epgSources) {
      final chs = await database.getEpgChannelsForSource(src.id);
      for (final ch in chs) {
        validIds.add(ch.id); // prefixed: sourceId_channelId
      }
    }

    // Load now-playing EPG data using mapped IDs (fall back to tvgId only if valid)
    final epgChannelIds = <String>{};
    for (final c in allChannels) {
      final mapped = epgMap[c.id];
      if (mapped != null && mapped.isNotEmpty) {
        epgChannelIds.add(mapped);
      } else if (c.tvgId != null && c.tvgId!.isNotEmpty && validIds.contains(c.tvgId)) {
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
      _providers = providers;
      _groups = groups;
      // Pre-compute provider groups for sidebar (avoids re-scanning on every build)
      final pGroups = <String, List<String>>{};
      for (final prov in providers) {
        final gSet = <String>{};
        for (final ch in allChannels) {
          if (ch.providerId == prov.id && ch.groupTitle != null && ch.groupTitle!.isNotEmpty) {
            gSet.add(ch.groupTitle!);
          }
        }
        pGroups[prov.id] = gSet.toList()..sort();
      }
      _providerGroups = pGroups;
      _nowPlaying = nowPlaying;
      _epgMappings = epgMap;
      _validEpgChannelIds = validIds;
      _favoriteLists = favLists;
      _favoritedChannelIds = favChannelIds;
      _isLoading = false;
      _applyFilters();
    });

    // Restore last session state
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    _use24HourTime = prefs.getBool(_kUse24HourTime) ?? false;

    // Restore EPG timeshifts
    final tsJson = prefs.getString(_kEpgTimeshifts);
    if (tsJson != null) {
      try {
        final decoded = jsonDecode(tsJson) as Map<String, dynamic>;
        _epgTimeshifts.clear();
        decoded.forEach((k, v) => _epgTimeshifts[k] = v as int);
      } catch (_) {}
    }
    final lastGroup = prefs.getString(_kLastGroup);
    final lastChannelId = prefs.getString(_kLastChannelId);

    if (lastGroup != null && lastGroup != _selectedGroup) {
      setState(() {
        _selectedGroup = lastGroup;
        _applyFilters();
      });
    }

    if (lastChannelId != null && _filteredChannels.isNotEmpty) {
      final idx = _filteredChannels.indexWhere((c) => c.id == lastChannelId);
      if (idx >= 0) {
        _selectChannel(idx);
      }
    }
  }

  Future<void> _saveSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastGroup, _selectedGroup);
    if (_selectedIndex >= 0 && _selectedIndex < _filteredChannels.length) {
      await prefs.setString(_kLastChannelId, _filteredChannels[_selectedIndex].id);
    }
  }

  void _applyFilters() {
    var channels = _allChannels;

    // When sidebar search is active, search ALL channels regardless of group
    if (_sidebarSearchQuery.isNotEmpty) {
      final terms = _sidebarSearchQuery.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      channels = channels
          .where((c) {
            final nowPlaying = _getChannelNowPlaying(c) ?? '';
            final haystack = '${c.name} ${c.groupTitle ?? ''} $nowPlaying'.toLowerCase();
            return terms.every((t) => haystack.contains(t));
          })
          .toList();
    } else {
      // Group filters only apply when not searching
      if (_selectedGroup == 'Favorites') {
        channels =
            channels.where((c) => _favoritedChannelIds.contains(c.id)).toList();
      } else if (_selectedGroup.startsWith('fav:')) {
        final listId = _selectedGroup.substring(4);
        _applyFavoriteListFilter(listId);
        return;
      } else if (_selectedGroup.startsWith('provider:')) {
        final providerId = _selectedGroup.substring(9);
        channels =
            channels.where((c) => c.providerId == providerId).toList();
      } else if (_selectedGroup.startsWith('provgroup:')) {
        // Format: provgroup:{providerId}:{groupTitle}
        final parts = _selectedGroup.substring(10);
        final sepIdx = parts.indexOf(':');
        if (sepIdx > 0) {
          final providerId = parts.substring(0, sepIdx);
          final groupTitle = parts.substring(sepIdx + 1);
          channels = channels
              .where((c) => c.providerId == providerId && c.groupTitle == groupTitle)
              .toList();
        }
      } else if (_selectedGroup != 'All') {
        channels =
            channels.where((c) => c.groupTitle == _selectedGroup).toList();
      }
    }

    // Top-bar search stacks on top
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
    if (_sidebarSearchQuery.isNotEmpty) {
      channels = channels
          .where((c) => c.name.toLowerCase().contains(_sidebarSearchQuery))
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
    // Skip if already selected — don't reload the stream
    if (index == _selectedIndex) return;
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
    _saveSession();
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

  Future<void> _goFullscreen(db.Channel channel) async {
    final channelMaps = _filteredChannels
        .map((c) => <String, dynamic>{
              'name': c.name,
              'streamUrl': c.streamUrl,
              'tvgLogo': c.tvgLogo,
              'groupTitle': c.groupTitle,
              'epgId': _getEpgId(c),
              'alternativeUrls': <String>[],
            })
        .toList();
    await context.push('/player', extra: {
      'streamUrl': channel.streamUrl,
      'channelName': channel.name,
      'channelLogo': channel.tvgLogo,
      'alternativeUrls': <String>[],
      'channels': channelMaps,
      'currentIndex': _selectedIndex >= 0 ? _selectedIndex : 0,
    });
    if (mounted) _showTopBar();
  }

  // ---------------------------------------------------------------------------
  // EPG helpers
  // ---------------------------------------------------------------------------

  /// Get the effective EPG channel ID: mapped ID takes priority, tvgId only if valid.
  String? _getEpgId(db.Channel channel) {
    final mapped = _epgMappings[channel.id];
    if (mapped != null && mapped.isNotEmpty) return mapped;
    if (channel.tvgId != null && channel.tvgId!.isNotEmpty && _validEpgChannelIds.contains(channel.tvgId)) {
      return channel.tvgId;
    }
    return null;
  }

  String _getProviderName(String providerId) {
    for (final p in _providers) {
      if (p.id == providerId) return p.name;
    }
    return '';
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
    final shift = _epgTimeshifts[channel.id] ?? 0;
    final adjusted = DateTime.now().subtract(Duration(hours: shift));
    final matches = _nowPlaying.where((p) =>
        p.epgChannelId == epgId &&
        !p.start.isAfter(adjusted) &&
        p.stop.isAfter(adjusted)).toList();
    return matches.isNotEmpty ? matches.first : null;
  }

  db.EpgProgramme? _getNextProgramme(db.Channel channel) {
    final epgId = _getEpgId(channel);
    if (epgId == null) return null;
    final current = _getEpgProgramme(channel);
    if (current == null) return null;
    final matches = _nowPlaying.where((p) =>
        p.epgChannelId == epgId &&
        !p.start.isBefore(current.stop)).toList();
    matches.sort((a, b) => a.start.compareTo(b.start));
    return matches.isNotEmpty ? matches.first : null;
  }

  String _formatTime(DateTime dt) {
    if (_use24HourTime) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }

  String? _programmeTimeRange(db.EpgProgramme? p, {int timeshiftHours = 0}) {
    if (p == null) return null;
    final shift = Duration(hours: timeshiftHours);
    return '${_formatTime(p.start.add(shift))} - ${_formatTime(p.stop.add(shift))}';
  }

  /// Parse XMLTV episode-num into readable label (e.g. "S2 E5").
  String? _parseEpisodeLabel(String? episodeNum) {
    if (episodeNum == null || episodeNum.isEmpty) return null;
    final se = _parseSeasonEpisode(episodeNum);
    if (se != null) return 'S${se.$1} E${se.$2}';
    return episodeNum;
  }

  /// Parse episode string into (season, episode) integers.
  (int, int)? _parseSeasonEpisode(String? episodeNum) {
    if (episodeNum == null || episodeNum.isEmpty) return null;
    final seFmt = RegExp(r'S(\d+)\s*E(\d+)', caseSensitive: false);
    final seMatch = seFmt.firstMatch(episodeNum);
    if (seMatch != null) {
      return (int.parse(seMatch.group(1)!), int.parse(seMatch.group(2)!));
    }
    final nsFmt = RegExp(r'^(\d+)\.(\d+)');
    final nsMatch = nsFmt.firstMatch(episodeNum);
    if (nsMatch != null) {
      return (int.parse(nsMatch.group(1)!) + 1, int.parse(nsMatch.group(2)!) + 1);
    }
    return null;
  }

  /// Build IMDB URL — exact if IMDB ID cached, otherwise search fallback.
  String _imdbUrl(String title, String? episodeNum) {
    final imdbId = _imdbIdCache[title.toLowerCase()];
    if (imdbId != null) {
      final se = _parseSeasonEpisode(episodeNum);
      if (se != null) {
        return 'https://www.imdb.com/title/$imdbId/episodes/?season=${se.$1}';
      }
      return 'https://www.imdb.com/title/$imdbId/';
    }
    return 'https://www.imdb.com/find/?q=${Uri.encodeComponent(title)}&s=tt&ttype=tv';
  }

  /// Resolve IMDB ID for a show via TMDB (cached, background).
  Future<void> _resolveImdbId(String title) async {
    final key = title.toLowerCase();
    if (_imdbIdCache.containsKey(key)) return;
    _imdbIdCache[key] = null; // mark in-progress
    try {
      final keys = ref.read(showsApiKeysProvider);
      if (!keys.hasTmdbKey) return;
      final tmdb = TmdbClient(apiKey: keys.tmdbApiKey);
      final results = await tmdb.searchTv(title);
      if (results.isEmpty) return;
      final detail = await tmdb.getTvShow(results.first.id);
      if (detail.imdbId != null && detail.imdbId!.isNotEmpty) {
        _imdbIdCache[key] = detail.imdbId;
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  void _resetGuideIdleTimer(DateTime dayStart) {
    _guideIdleTimer?.cancel();
    _guideIdleTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted || !_guideScrollController.hasClients) return;
      final now = DateTime.now();
      // Scroll to 30 minutes before now
      final targetMin = now.difference(dayStart).inMinutes - 30;
      final target = (targetMin * _pixelsPerMinute)
          .clamp(0.0, _guideScrollController.position.maxScrollExtent);
      _guideScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Keyboard navigation
  // ---------------------------------------------------------------------------

  void _handleKeyEvent(KeyEvent event) {
    // On Android/TV, arrow keys are used for D-pad focus navigation.
    // Channel switching uses dedicated channelUp/channelDown keys.
    final isAndroid = Platform.isAndroid;

    if (event.logicalKey == LogicalKeyboardKey.channelUp ||
        (!isAndroid && event.logicalKey == LogicalKeyboardKey.arrowUp)) {
      final newIndex = (_selectedIndex - 1).clamp(0, _filteredChannels.length - 1);
      if (newIndex != _selectedIndex) {
        _selectChannel(newIndex);
        _scrollToIndex(newIndex);
      }
      return;
    }

    if (event.logicalKey == LogicalKeyboardKey.channelDown ||
        (!isAndroid && event.logicalKey == LogicalKeyboardKey.arrowDown)) {
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

    if (!isAndroid && event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _adjustVolume(-5);
      return;
    }

    if (!isAndroid && event.logicalKey == LogicalKeyboardKey.arrowRight) {
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
    if (_isLoading && _allChannels.isEmpty) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_allChannels.isEmpty) {
      return _buildEmptyState(context);
    }

    return PopScope(
      canPop: false,
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: Focus(
          focusNode: _focusNode,
          autofocus: !Platform.isAndroid,
          skipTraversal: Platform.isAndroid,
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (_searchFocusNode.hasFocus) return KeyEventResult.ignored;
            final key = event.logicalKey;
            // Let Flutter's spatial focus system handle D-pad arrows
            if (key == LogicalKeyboardKey.arrowUp ||
                key == LogicalKeyboardKey.arrowDown ||
                key == LogicalKeyboardKey.arrowLeft ||
                key == LogicalKeyboardKey.arrowRight) {
              return KeyEventResult.ignored;
            }
            _handleKeyEvent(event);
            return KeyEventResult.handled;
          },
          child: Scaffold(
            backgroundColor: const Color(0xFF1A1A2E),
            body: SafeArea(
              child: Column(
                children: [
                  if (!Platform.isAndroid) // TV: no top bar, use sidebar for nav
                  MouseRegion(
                    onEnter: (_) {
                      _mouseInTopBar = true;
                      _topBarTimer?.cancel();
                      setState(() => _topBarOpacity = 1.0);
                    },
                    onExit: (_) {
                      _mouseInTopBar = false;
                      _startTopBarFade();
                    },
                    child: AnimatedOpacity(
                      opacity: _topBarOpacity,
                      duration: const Duration(milliseconds: 600),
                      child: _buildTopBar(context),
                    ),
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        // Collapsible sidebar tree
                        _buildSidebar(),
                        // Main content area
                        Expanded(
                          child: Column(
                            children: [
                              _buildPreviewRow(),
                              if (_showFailoverBanner && _failoverSuggestion != null)
                                _buildFailoverBanner(),
                              Expanded(child: _showGuideView ? _buildGuideView() : _buildChannelList()),
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
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (!Platform.isAndroid) _buildTopBar(context),
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
            const SizedBox(height: 24),
            FilledButton.icon(
              autofocus: true,
              onPressed: () => context.push('/providers'),
              icon: const Icon(Icons.add),
              label: const Text('Add Provider'),
            ),
            const Spacer(),
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
          Text(
            'clubTivi',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.4),
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
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
            onPressed: () async {
              await context.push('/providers');
              if (mounted) _loadChannels();
            },
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
          IconButton(
            icon: const Icon(Icons.movie_rounded, color: Colors.white70),
            tooltip: 'Shows & Movies',
            onPressed: () => context.push('/shows'),
          ),
          IconButton(
            icon: Icon(
              ref.read(castServiceProvider).isCasting
                  ? Icons.cast_connected_rounded
                  : Icons.cast_rounded,
              color: ref.read(castServiceProvider).isCasting
                  ? Colors.amber
                  : Colors.white70,
            ),
            tooltip: 'Cast to device',
            onPressed: () async {
              final device = await showCastDialog(context, ref);
              if (device != null && mounted && _selectedIndex >= 0 && _selectedIndex < _filteredChannels.length) {
                final channel = _filteredChannels[_selectedIndex];
                final success = await ref.read(castServiceProvider).castTo(
                  device,
                  channel.streamUrl,
                  title: channel.name,
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
            },
          ),
                ],
              ),
            ),
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
                            // Channel info overlay removed — info shown in panel to the right
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
                          // Top row: name+group left, provider+time right
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
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
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  if (_getProviderName(_previewChannel!.providerId).isNotEmpty)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF6C5CE7).withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        _getProviderName(_previewChannel!.providerId),
                                        style: const TextStyle(fontSize: 10, color: Color(0xFF6C5CE7), fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _formatTime(DateTime.now()),
                                    style: const TextStyle(color: Colors.white60, fontSize: 11),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
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
                              _programmeTimeRange(programme, timeshiftHours: _epgTimeshifts[_previewChannel!.id] ?? 0) ?? '',
                              style: const TextStyle(color: Colors.white38, fontSize: 11),
                            ),
                          ],
                          if (programme != null && programme.description != null && programme.description!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                programme.description!,
                                style: const TextStyle(color: Colors.white54, fontSize: 11),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          // Episode info + IMDB link
                          if (programme != null && programme.episodeNum != null && programme.episodeNum!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Builder(builder: (_) {
                                _resolveImdbId(programme.title);
                                final hasExact = _imdbIdCache[programme.title.toLowerCase()] != null;
                                return GestureDetector(
                                  onTap: () => launchUrl(Uri.parse(_imdbUrl(programme.title, programme.episodeNum))),
                                  child: Row(
                                    children: [
                                      Text(
                                        _parseEpisodeLabel(programme.episodeNum) ?? programme.episodeNum!,
                                        style: const TextStyle(color: Colors.white60, fontSize: 11),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        hasExact ? 'IMDb ↗' : 'IMDb 🔍',
                                        style: const TextStyle(color: Colors.amber, fontSize: 11, decoration: TextDecoration.underline),
                                      ),
                                    ],
                                  ),
                                );
                              }),
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
                                      '${nextProg.title}  ${_programmeTimeRange(nextProg, timeshiftHours: _epgTimeshifts[_previewChannel!.id] ?? 0) ?? ''}',
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
                                child: ExcludeFocus(
                                  excluding: Platform.isAndroid,
                                  child: IconButton(
                                    onPressed: () => ChannelDebugDialog.show(context, _previewChannel!, playerService, mappedEpgId: _getEpgId(_previewChannel!)),
                                    icon: const Icon(Icons.info_outline, size: 16),
                                    padding: EdgeInsets.zero,
                                    color: Colors.white70,
                                    tooltip: 'Channel debug info',
                                  ),
                                ),
                              ),
                              // Fullscreen
                              SizedBox(
                                height: 28, width: 28,
                                child: ExcludeFocus(
                                  excluding: Platform.isAndroid,
                                  child: IconButton(
                                    onPressed: () => _goFullscreen(_previewChannel!),
                                    icon: const Icon(Icons.fullscreen_rounded, size: 16),
                                    padding: EdgeInsets.zero,
                                    color: Colors.white70,
                                    tooltip: 'Fullscreen',
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

  /// Extract quality tag (UHD/4K/FHD/HD/SD) from channel name and return a badge widget.
  Widget? _qualityBadge(String name) {
    final upper = name.toUpperCase();
    String? label;
    Color? color;
    if (upper.contains('4K') || upper.contains('UHD')) {
      label = 'UHD';
      color = const Color(0xFF9B59B6);
    } else if (upper.contains('FHD') || upper.contains('FULLHD') || upper.contains('FULL HD')) {
      label = 'FHD';
      color = const Color(0xFF2ECC71);
    } else if (RegExp(r'\bHD\b').hasMatch(upper)) {
      label = 'HD';
      color = const Color(0xFF3498DB);
    } else if (RegExp(r'\bSD\b').hasMatch(upper)) {
      label = 'SD';
      color = const Color(0xFF95A5A6);
    }
    if (label == null) return null;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color!.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.5),
      ),
      child: Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color)),
    );
  }

  Widget _buildSidebar() {
    final width = _sidebarExpanded ? 220.0 : 44.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: width,
      color: const Color(0xFF111127),
      child: FocusScope(
        node: _sidebarFocusNode,
        child: Column(
          children: [
          // Toggle button
          InkWell(
            onTap: () => setState(() => _sidebarExpanded = !_sidebarExpanded),
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: _sidebarExpanded ? Alignment.centerRight : Alignment.center,
              child: Icon(
                _sidebarExpanded ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                color: Colors.white38,
                size: 20,
              ),
            ),
          ),
          if (_sidebarExpanded) ...[
            // Search field
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: SizedBox(
                height: 30,
                child: TextFormField(
                  controller: _sidebarSearchController,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'Search channels…',
                    hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
                    prefixIcon: const Icon(Icons.search_rounded, size: 14, color: Colors.white24),
                    prefixIconConstraints: const BoxConstraints(minWidth: 30),
                    suffixIcon: _sidebarSearchQuery.isNotEmpty
                        ? GestureDetector(
                            onTap: () {
                              _sidebarSearchController.clear();
                              setState(() => _sidebarSearchQuery = '');
                            },
                            child: const Icon(Icons.close_rounded, size: 14, color: Colors.white24),
                          )
                        : null,
                    suffixIconConstraints: const BoxConstraints(minWidth: 30),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (v) {
                    setState(() {
                      _sidebarSearchQuery = v.toLowerCase();
                      _applyFilters();
                    });
                  },
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
          ],
          // Tree content
          Expanded(
            child: _sidebarExpanded ? _buildSidebarTree() : _buildCollapsedSidebar(),
          ),
          // TV navigation items (Providers, Settings) — only on Android TV
          if (Platform.isAndroid) ...[
            const Divider(height: 1, color: Colors.white10),
            if (_sidebarExpanded) ...[
              _buildSidebarNavItem(Icons.dns_rounded, 'Providers', () async {
                await context.push('/providers');
                if (mounted) _loadChannels();
              }),
              _buildSidebarNavItem(Icons.settings_rounded, 'Settings', () {
                context.push('/settings');
              }),
            ] else ...[
              _sidebarIcon(Icons.dns_rounded, 'Providers', false, () async {
                await context.push('/providers');
                if (mounted) _loadChannels();
              }),
              _sidebarIcon(Icons.settings_rounded, 'Settings', false, () {
                context.push('/settings');
              }),
            ],
          ],
          // Version watermark
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            child: Text(
              _sidebarExpanded ? 'clubTivi v${AppUpdateService.currentVersion}' : 'v${AppUpdateService.currentVersion}',
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white24,
                letterSpacing: 0.5,
              ),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildCollapsedSidebar() {
    // Icons-only when collapsed
    final isAll = _selectedGroup == 'All';
    final isFav = _selectedGroup == 'Favorites' || _selectedGroup.startsWith('fav:');
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        _sidebarIcon(Icons.grid_view_rounded, 'All', isAll, () {
          setState(() { _selectedGroup = 'All'; _applyFilters(); _saveSession(); });
        }),
        _sidebarIcon(Icons.star_rounded, 'Favorites', isFav, () {
          setState(() { _selectedGroup = 'Favorites'; _applyFilters(); _saveSession(); });
        }),
        const Divider(height: 1, color: Colors.white10),
        _sidebarIcon(Icons.folder_rounded, 'Groups', !isAll && !isFav, () {
          setState(() => _sidebarExpanded = true);
        }),
      ],
    );
  }

  Widget _sidebarIcon(IconData icon, String tooltip, bool active, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            if (_firstChannelFocusNode != null) {
              _firstChannelFocusNode!.requestFocus();
            }
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (context) {
            final hasFocus = Focus.of(context).hasFocus;
            return InkWell(
              onTap: onTap,
              child: Container(
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active ? Colors.white.withValues(alpha: 0.08) : Colors.transparent,
                  border: hasFocus ? Border.all(color: Colors.purpleAccent, width: 1.5) : null,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(icon, size: 18, color: active ? Colors.white : Colors.white38),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSidebarNavItem(IconData icon, String label, VoidCallback onTap) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          if (_firstChannelFocusNode != null) _firstChannelFocusNode!.requestFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return InkWell(
            onTap: onTap,
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: hasFocus ? Border.all(color: Colors.purpleAccent, width: 1.5) : null,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: Colors.white54),
                  const SizedBox(width: 8),
                  Text(label, style: const TextStyle(fontSize: 12, color: Colors.white54)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSidebarTree() {
    final q = _sidebarSearchQuery;
    final filteredGroups = q.isEmpty
        ? _groups
        : _groups.where((g) => g.toLowerCase().contains(q)).toList();
    final filteredFavs = q.isEmpty
        ? _favoriteLists
        : _favoriteLists.where((l) => l.name.toLowerCase().contains(q)).toList();
    final filteredProviders = q.isEmpty
        ? _providers
        : _providers.where((p) => p.name.toLowerCase().contains(q)).toList();
    final showAll = q.isEmpty || 'all'.contains(q);
    final showFavSection = q.isEmpty || filteredFavs.isNotEmpty || 'favorites'.contains(q);
    final showProvSection = q.isEmpty || filteredProviders.isNotEmpty || 'providers'.contains(q);

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        if (showAll)
          _buildTreeItem('All (${_allChannels.length})', 'All', Icons.grid_view_rounded, indent: 0, focusNode: _sidebarAllItemFocusNode),
        if (showFavSection)
          _buildTreeSection(
            'favorites',
            Icons.star_rounded,
            'Favorites',
            [
              if (q.isEmpty || 'favorites'.contains(q))
                _buildTreeItem('All Favorites', 'Favorites', Icons.star_rounded, indent: 1),
              for (final list in filteredFavs)
                _buildTreeItem(list.name, 'fav:${list.id}', Icons.star_outline_rounded, indent: 1,
                    onSecondaryTap: () => _renameFavoriteList(list)),
              if (q.isEmpty)
                _buildTreeAction('New List…', Icons.add_rounded, () => _showManageFavoritesDialog(), indent: 1),
            ],
          ),
        if (showFavSection || showProvSection)
          const Divider(height: 1, color: Colors.white10),
        if (showProvSection)
          ..._buildProviderTrees(filteredProviders, q),
        if (showProvSection || filteredGroups.isNotEmpty)
          const Divider(height: 1, color: Colors.white10),
        if (filteredGroups.isNotEmpty)
          _buildTreeSection(
            'groups',
            Icons.folder_rounded,
            'Groups (${filteredGroups.length})',
            [
              for (final group in filteredGroups)
                _buildTreeItem(group, group, null, indent: 1),
            ],
          ),
      ],
    );
  }

  /// Build provider tree nodes: each provider is a collapsible section
  /// containing its category groups as sub-items.
  List<Widget> _buildProviderTrees(List<db.Provider> providers, String query) {
    final widgets = <Widget>[];
    for (final prov in providers) {
      final sortedGroups = _providerGroups[prov.id] ?? [];
      final filteredGroups = query.isEmpty
          ? sortedGroups
          : sortedGroups.where((g) => g.toLowerCase().contains(query)).toList();

      // No subcategories — show as a flat link
      if (filteredGroups.isEmpty) {
        widgets.add(
          _buildTreeItem(
            prov.name,
            'provider:${prov.id}',
            prov.type == 'xtream' ? Icons.bolt_rounded : Icons.playlist_play_rounded,
            indent: 0,
          ),
        );
      } else {
        // Has subcategories — show as expandable tree
        widgets.add(
          _buildTreeSection(
            'prov_${prov.id}',
            prov.type == 'xtream' ? Icons.bolt_rounded : Icons.playlist_play_rounded,
            prov.name,
            [
              for (final group in filteredGroups)
                _buildTreeItem(
                  group,
                  'provgroup:${prov.id}:$group',
                  Icons.folder_open_rounded,
                  indent: 1,
                ),
            ],
            filterKey: 'provider:${prov.id}',
          ),
        );
      }
    }
    return widgets;
  }

  Widget _buildTreeSection(String sectionKey, IconData icon, String label, List<Widget> children, {String? filterKey}) {
    final expanded = _expandedSections.contains(sectionKey);
    final isSelected = filterKey != null && _selectedGroup == filterKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Focus(
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              if (_firstChannelFocusNode != null) {
                _firstChannelFocusNode!.requestFocus();
              }
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter) {
              setState(() {
                // Only change channel list if provider has no subcategories
                if (filterKey != null && children.isEmpty) {
                  _selectedGroup = filterKey;
                  _applyFilters();
                  _saveSession();
                }
                if (expanded) {
                  _expandedSections.remove(sectionKey);
                } else {
                  _expandedSections.add(sectionKey);
                }
              });
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (context) {
              final hasFocus = Focus.of(context).hasFocus;
              return InkWell(
                onTap: () {
                  setState(() {
                    // Only change channel list if provider has no subcategories
                    if (filterKey != null && children.isEmpty) {
                      _selectedGroup = filterKey;
                      _applyFilters();
                      _saveSession();
                    }
                    if (expanded) {
                      _expandedSections.remove(sectionKey);
                    } else {
                      _expandedSections.add(sectionKey);
                    }
                  });
                },
                child: Container(
                  decoration: BoxDecoration(
                    border: hasFocus ? Border.all(color: Colors.purpleAccent, width: 1.5) : null,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        expanded ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                        size: 16,
                        color: Colors.white38,
                      ),
                      const SizedBox(width: 4),
                      Icon(icon, size: 14, color: isSelected ? Colors.amber : Colors.white54),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: isSelected ? Colors.white : Colors.white54,
                            letterSpacing: 0.5,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (expanded) ...children,
      ],
    );
  }

  Widget _buildTreeItem(String label, String filterKey, IconData? icon, {int indent = 0, VoidCallback? onSecondaryTap, Widget? trailing, FocusNode? focusNode}) {
    final isSelected = _selectedGroup == filterKey;
    return GestureDetector(
      onSecondaryTap: onSecondaryTap,
      child: Focus(
        focusNode: focusNode,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            // RIGHT from sidebar → focus channel list
            if (_firstChannelFocusNode != null) {
              _firstChannelFocusNode!.requestFocus();
            }
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            setState(() {
              _selectedGroup = filterKey;
              _applyFilters();
            });
            _saveSession();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (context) {
            final hasFocus = Focus.of(context).hasFocus;
            return InkWell(
              onTap: () {
                setState(() {
                  _selectedGroup = filterKey;
                  _applyFilters();
                });
                _saveSession();
              },
              child: Container(
                height: 30,
                padding: EdgeInsets.only(left: 12.0 + (indent * 16.0), right: 8),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white.withValues(alpha: 0.1) : Colors.transparent,
                  border: hasFocus ? Border.all(color: Colors.purpleAccent, width: 1.5) : null,
                  borderRadius: BorderRadius.circular(4),
                ),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 13,
                          color: isSelected ? Colors.amber : Colors.white38),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          color: isSelected ? Colors.white : Colors.white60,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (trailing != null) trailing,
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTreeAction(String label, IconData icon, VoidCallback onTap, {int indent = 0}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 28,
        padding: EdgeInsets.only(left: 12.0 + (indent * 16.0), right: 8),
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            Icon(icon, size: 13, color: Colors.white24),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.white30, fontStyle: FontStyle.italic),
            ),
          ],
        ),
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

    final listWidget = ListView.builder(
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
            child: Focus(
              autofocus: index == 0 && Platform.isAndroid,
              onFocusChange: (hasFocus) {
                if (hasFocus && Platform.isAndroid) _selectChannel(index);
              },
              onKeyEvent: (node, event) {
                // Track this node so sidebar can navigate back
                if (index == 0) _firstChannelFocusNode = node;
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                final key = event.logicalKey;
                // SELECT/ENTER → fullscreen
                if (key == LogicalKeyboardKey.select ||
                    key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.gameButtonA) {
                  _goFullscreen(channel);
                  return KeyEventResult.handled;
                }
                // LEFT from channel list → focus sidebar
                if (key == LogicalKeyboardKey.arrowLeft) {
                  _sidebarAllItemFocusNode.requestFocus();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored; // Let Flutter handle UP/DOWN naturally
              },
              child: Builder(
                builder: (context) {
                  final focused = Focus.of(context).hasFocus;
                  return InkWell(
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
                    : focused
                        ? const Color(0xFF6C5CE7).withValues(alpha: 0.15)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: focused
                    ? Border.all(color: Colors.white, width: 2.0)
                    : isSelected
                        ? Border.all(
                            color: const Color(0xFF6C5CE7), width: 1.5)
                        : null,
              ),
              child: Row(
                children: [
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
                        Row(
                          children: [
                            Flexible(
                              child: Text(
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
                            ),
                            if (_qualityBadge(channel.name) != null)
                              _qualityBadge(channel.name)!,
                          ],
                        ),
                        if (channel.groupTitle != null &&
                            channel.groupTitle!.isNotEmpty)
                          Text(
                            '${channel.groupTitle!} · ${_getProviderName(channel.providerId)}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
                            overflow: TextOverflow.ellipsis,
                          )
                        else if (_getProviderName(channel.providerId).isNotEmpty)
                          Text(
                            _getProviderName(channel.providerId),
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
          );
          },
          ),
          ),
          ),
        );
      },
    );

    return Stack(
      children: [
        listWidget,
        Positioned(
          left: 0, right: 0, bottom: 0,
          height: 40,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    const Color(0xFF0A0A0F),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Favorite list interactions
  // ---------------------------------------------------------------------------

  /// Bottom sheet to add/remove a channel from favorite lists.
  Future<void> _renameChannel(db.Channel channel) async {
    final controller = TextEditingController(text: channel.name);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Channel'),
        content: TextFormField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Channel Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result.isNotEmpty && result != channel.name) {
      final database = ref.read(databaseProvider);
      await database.renameChannel(channel.id, channel.providerId, result);
      // Update local lists immediately so the UI reflects the rename
      setState(() {
        final updateList = (List<db.Channel> list) {
          final idx = list.indexWhere((c) => c.id == channel.id && c.providerId == channel.providerId);
          if (idx >= 0) {
            list[idx] = list[idx].copyWith(name: result);
          }
        };
        updateList(_allChannels);
        updateList(_filteredChannels);
        if (_previewChannel?.id == channel.id) {
          _previewChannel = _filteredChannels.firstWhere(
            (c) => c.id == channel.id,
            orElse: () => _previewChannel!,
          );
        }
      });
    }
  }

  /// Show inline EPG mapping dialog for a single channel.
  Future<void> _showInlineEpgMapping(db.Channel channel) async {
    final database = ref.read(databaseProvider);
    // Load all EPG channels from all enabled sources
    final sources = await database.getAllEpgSources();
    final candidates = <_EpgCandidate>[];
    for (final src in sources) {
      if (!src.enabled) continue;
      final chs = await database.getEpgChannelsForSource(src.id);
      for (final ch in chs) {
        candidates.add(_EpgCandidate(ch.channelId, ch.displayName, src.id, src.name));
      }
    }

    if (!mounted) return;
    final searchCtrl = TextEditingController();
    final result = await showDialog<_EpgCandidate>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final query = searchCtrl.text.toLowerCase();
          final filtered = query.isEmpty
              ? candidates
              : candidates.where((c) =>
                  c.displayName.toLowerCase().contains(query) ||
                  c.channelId.toLowerCase().contains(query)).toList();
          return AlertDialog(
            title: Text('Map: ${channel.name}'),
            content: SizedBox(
              width: 400,
              height: 400,
              child: Column(
                children: [
                  TextField(
                    controller: searchCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Search EPG channels...',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Text('${filtered.length} EPG channels',
                      style: const TextStyle(fontSize: 12, color: Colors.white54)),
                  const SizedBox(height: 4),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final c = filtered[i];
                        return ListTile(
                          dense: true,
                          title: Text(c.displayName),
                          subtitle: Text('${c.channelId} • ${c.sourceName}',
                              style: const TextStyle(fontSize: 10)),
                          onTap: () => Navigator.pop(ctx, c),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ],
          );
        },
      ),
    );
    searchCtrl.dispose();

    if (result != null && mounted) {
      await database.upsertMapping(db.EpgMappingsCompanion.insert(
        channelId: channel.id,
        providerId: channel.providerId,
        epgChannelId: result.channelId,
        epgSourceId: result.sourceId,
        confidence: const Value(1.0),
        source: const Value('manual'),
        locked: const Value(true),
      ));
      await _loadChannels(); // Refresh to pick up new mapping
    }
  }

  /// Show dialog to set EPG timeshift for a channel.
  Future<void> _showTimeshiftDialog(db.Channel channel) async {
    final current = _epgTimeshifts[channel.id] ?? 0;
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) {
        int selected = current;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Timeshift EPG'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(channel.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                const Text('Shift programme times by:', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: () => setDialogState(() => selected--),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text(
                      '${selected > 0 ? '+' : ''}${selected}h',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      onPressed: () => setDialogState(() => selected++),
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  selected == 0 ? 'No shift' : 'Programmes shifted ${selected > 0 ? 'forward' : 'back'} ${selected.abs()}h',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
            actions: [
              if (current != 0)
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 0),
                  child: const Text('Reset'),
                ),
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, selected),
                child: const Text('Apply'),
              ),
            ],
          ),
        );
      },
    );
    if (result != null && result != current) {
      setState(() {
        if (result == 0) {
          _epgTimeshifts.remove(channel.id);
        } else {
          _epgTimeshifts[channel.id] = result;
        }
      });
      // Persist timeshifts
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kEpgTimeshifts, jsonEncode(_epgTimeshifts));
      _refreshNowPlaying();
    }
  }

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

    final database = ref.read(databaseProvider);
    final today = DateTime.now();
    final dayStart = DateTime.now().subtract(const Duration(hours: 3));
    final dayEnd = DateTime(today.year, today.month, today.day).add(const Duration(days: 1));

    final totalMinutes = dayEnd.difference(dayStart).inMinutes;
    final totalWidth = totalMinutes * _pixelsPerMinute;

    // Auto-scroll to "now" when guide view opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_guideScrollController.hasClients &&
          _guideScrollController.position.pixels == 0.0) {
        final now = DateTime.now();
        final nowMinFromStart = now.difference(dayStart).inMinutes;
        final target = (nowMinFromStart * _pixelsPerMinute - 100)
            .clamp(0.0, _guideScrollController.position.maxScrollExtent);
        _guideScrollController.jumpTo(target);
      }
    });

    final now = DateTime.now();
    final nowMinFromStart = now.difference(dayStart).inMinutes;
    final nowOffset = nowMinFromStart * _pixelsPerMinute;

    return Column(
      children: [
        // Time ruler row with "now" marker
        SizedBox(
          height: 28,
          child: Row(
            children: [
              const SizedBox(width: 200),
              Expanded(
                child: SingleChildScrollView(
                  controller: _guideScrollController,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: totalWidth,
                    child: Stack(
                      children: [
                        // Hour labels
                        ...() {
                          final labels = <Widget>[];
                          var t = DateTime(dayStart.year, dayStart.month, dayStart.day, dayStart.hour);
                          if (t.isBefore(dayStart)) t = t.add(const Duration(hours: 1));
                          while (t.isBefore(dayEnd)) {
                            final offsetMin = t.difference(dayStart).inMinutes;
                            labels.add(Positioned(
                              left: offsetMin * _pixelsPerMinute,
                              top: 0,
                              bottom: 0,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    _formatTime(t),
                                    style: const TextStyle(fontSize: 10, color: Colors.white38),
                                  ),
                                ),
                              ),
                            ));
                            t = t.add(const Duration(hours: 1));
                          }
                          return labels;
                        }(),
                        // "Now" marker with time label
                        Positioned(
                          left: nowOffset - 18,
                          top: 0,
                          bottom: 0,
                          child: SizedBox(
                            width: 36,
                            child: Center(
                              child: Text(
                                _formatTime(now),
                                style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Colors.white12),
        // Channel rows — single ListView, each item has name + programmes
        Expanded(
          child: GestureDetector(
            onHorizontalDragUpdate: (details) {
              if (_guideScrollController.hasClients) {
                final newOffset = (_guideScrollController.offset - details.delta.dx)
                    .clamp(0.0, _guideScrollController.position.maxScrollExtent);
                _guideScrollController.jumpTo(newOffset);
              }
              _resetGuideIdleTimer(dayStart);
            },
            onHorizontalDragEnd: (_) => _resetGuideIdleTimer(dayStart),
            child: ListenableBuilder(
              listenable: _guideScrollController,
              builder: (context, _) {
                final hOffset = _guideScrollController.hasClients
                    ? _guideScrollController.offset
                    : 0.0;
                return Stack(
                  children: [
                    ListView.builder(
                      itemCount: _filteredChannels.length,
                      itemBuilder: (context, index) {
                        final channel = _filteredChannels[index];
                        final isFav = _favoritedChannelIds.contains(channel.id);
                        final isSelected = index == _selectedIndex;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _selectChannel(index),
                          onSecondaryTapUp: (details) => _showGuideChannelMenu(
                            channel, details.globalPosition,
                          ),
                          child: Container(
                            height: 48,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF6C5CE7).withValues(alpha: 0.25)
                                  : Colors.transparent,
                              border: Border(
                                bottom: const BorderSide(color: Colors.white10, width: 0.5),
                                left: isSelected
                                    ? const BorderSide(color: Color(0xFF6C5CE7), width: 3)
                                    : BorderSide.none,
                              ),
                            ),
                            child: Row(
                              children: [
                                // Fixed channel name
                                Container(
                                  width: 200,
                                  decoration: const BoxDecoration(
                                    border: Border(right: BorderSide(color: Colors.white10, width: 0.5)),
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  child: Row(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: channel.tvgLogo != null && channel.tvgLogo!.isNotEmpty
                                            ? Image.network(
                                                channel.tvgLogo!,
                                                width: 28, height: 28, fit: BoxFit.contain,
                                                errorBuilder: (_, __, ___) => Container(
                                                  width: 28, height: 28,
                                                  color: const Color(0xFF16213E),
                                                  child: const Icon(Icons.tv, size: 14, color: Colors.white24),
                                                ),
                                              )
                                            : Container(
                                                width: 28, height: 28,
                                                color: const Color(0xFF16213E),
                                                child: const Icon(Icons.tv, size: 14, color: Colors.white24),
                                              ),
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              channel.name,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: isSelected ? Colors.white : Colors.white70,
                                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            Text(
                                              _getProviderName(channel.providerId),
                                              style: const TextStyle(fontSize: 9, color: Colors.white30),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (isFav)
                                              const Icon(Icons.star_rounded, color: Colors.amber, size: 12),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                // Programme blocks — clipped + translated
                                Expanded(
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      return ClipRect(
                                        child: OverflowBox(
                                          alignment: Alignment.centerLeft,
                                          maxWidth: totalWidth,
                                          child: Transform.translate(
                                            offset: Offset(-hOffset, 0),
                                            child: _buildGuideRowProgrammes(channel, database, dayStart, dayEnd, totalMinutes: totalMinutes, totalWidth: totalWidth),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    // "Now" vertical line overlay
                    Positioned(
                      left: 200 + nowOffset - hOffset,
                      top: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          width: 1.5,
                          color: Colors.white.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  void _showGuideChannelMenu(db.Channel channel, Offset position) {
    final isFav = _favoritedChannelIds.contains(channel.id);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx, position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'play',
          child: Row(children: [
            const Icon(Icons.play_arrow, size: 18),
            const SizedBox(width: 8),
            const Text('Play'),
          ]),
        ),
        PopupMenuItem(
          value: 'fullscreen',
          child: Row(children: [
            const Icon(Icons.fullscreen, size: 18),
            const SizedBox(width: 8),
            const Text('Fullscreen'),
          ]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'favorite',
          child: Row(children: [
            Icon(isFav ? Icons.star : Icons.star_border, size: 18, color: Colors.amber),
            const SizedBox(width: 8),
            Text(isFav ? 'Remove from Favorites' : 'Add to Favorites...'),
          ]),
        ),
        PopupMenuItem(
          value: 'epg_map',
          child: Row(children: [
            const Icon(Icons.link, size: 18),
            const SizedBox(width: 8),
            const Text('Map to EPG...'),
          ]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'reminder',
          child: Row(children: [
            const Icon(Icons.alarm, size: 18),
            const SizedBox(width: 8),
            const Text('Set Reminder'),
          ]),
        ),
        PopupMenuItem(
          value: 'record',
          child: Row(children: [
            const Icon(Icons.fiber_manual_record, size: 18, color: Colors.red),
            const SizedBox(width: 8),
            const Text('Record'),
          ]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'rename',
          child: Row(children: [
            const Icon(Icons.edit, size: 18),
            const SizedBox(width: 8),
            const Text('Rename Channel'),
          ]),
        ),
        PopupMenuItem(
          value: 'timeshift',
          child: Row(children: [
            const Icon(Icons.schedule, size: 18),
            const SizedBox(width: 8),
            Text('Timeshift EPG${_epgTimeshifts.containsKey(channel.id) ? ' (${_epgTimeshifts[channel.id]! > 0 ? '+' : ''}${_epgTimeshifts[channel.id]!}h)' : ''}'),
          ]),
        ),
        PopupMenuItem(
          value: 'debug',
          child: Row(children: [
            const Icon(Icons.bug_report, size: 18),
            const SizedBox(width: 8),
            const Text('Debug Info'),
          ]),
        ),
      ],
    ).then((value) {
      if (value == null || !mounted) return;
      switch (value) {
        case 'play':
          final idx = _filteredChannels.indexOf(channel);
          if (idx >= 0) _selectChannel(idx);
        case 'fullscreen':
          final idx = _filteredChannels.indexOf(channel);
          if (idx >= 0) { _selectChannel(idx); _goFullscreen(channel); }
        case 'favorite':
          _showFavoriteListSheet(channel);
        case 'epg_map':
          _showInlineEpgMapping(channel);
        case 'reminder':
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Reminders coming soon')),
          );
        case 'record':
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Recording coming soon')),
          );
        case 'rename':
          _renameChannel(channel);
        case 'timeshift':
          _showTimeshiftDialog(channel);
        case 'debug':
          final ps = ref.read(playerServiceProvider);
          showDialog(
            context: context,
            builder: (_) => ChannelDebugDialog(channel: channel, playerService: ps, mappedEpgId: _getEpgId(channel)),
          );
      }
    });
  }

  Widget _buildGuideRowProgrammes(db.Channel channel,
      db.AppDatabase database, DateTime dayStart, DateTime dayEnd,
      {required int totalMinutes, required double totalWidth}) {
    final epgId = _getEpgId(channel);
    if (epgId == null) {
      return const Center(
        child: Text('No EPG', style: TextStyle(fontSize: 10, color: Colors.white24)),
      );
    }

    final shiftHours = _epgTimeshifts[channel.id] ?? 0;
    final fetchShift = Duration(hours: shiftHours);

    return FutureBuilder<List<db.EpgProgramme>>(
      future: database.getProgrammes(
        epgChannelId: epgId,
        start: dayStart.subtract(fetchShift),
        end: dayEnd.subtract(fetchShift),
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(
            child: Text('No EPG data',
                style: TextStyle(fontSize: 10, color: Colors.white24)),
          );
        }

        final programmes = snapshot.data!;
        final now = DateTime.now();
        final shift = Duration(hours: _epgTimeshifts[channel.id] ?? 0);

        return SizedBox(
          width: totalWidth,
          child: Stack(
            children: programmes.map((prog) {
              final shiftedStart = prog.start.add(shift);
              final shiftedStop = prog.stop.add(shift);
              final startMin = shiftedStart.difference(dayStart).inMinutes.clamp(0, totalMinutes);
              final endMin = shiftedStop.difference(dayStart).inMinutes.clamp(0, totalMinutes);
              final durationMin = (endMin - startMin).clamp(1, totalMinutes);
              final left = startMin * _pixelsPerMinute;
              final width = durationMin * _pixelsPerMinute;
              final isCurrent =
                  now.isAfter(shiftedStart) && now.isBefore(shiftedStop);
              return Positioned(
                left: left,
                width: width,
                top: 2,
                bottom: 2,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 0.5),
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
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  Widget _buildFailoverBanner() {
    final suggestion = _failoverSuggestion!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.orange.withValues(alpha: 0.15),
      child: Row(
        children: [
          const Icon(Icons.swap_horiz_rounded, size: 16, color: Colors.orangeAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: const TextStyle(fontSize: 12, color: Colors.white70),
                children: [
                  const TextSpan(text: 'Buffering detected. Try '),
                  TextSpan(
                    text: suggestion.name,
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const TextSpan(text: '?'),
                ],
              ),
            ),
          ),
          TextButton(
            onPressed: _acceptFailover,
            style: TextButton.styleFrom(
              foregroundColor: Colors.orangeAccent,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
            ),
            child: const Text('Switch', style: TextStyle(fontSize: 11)),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 14, color: Colors.white38),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(maxWidth: 24, maxHeight: 24),
            onPressed: () => setState(() {
              _showFailoverBanner = false;
              _failoverSuggestion = null;
            }),
          ),
        ],
      ),
    );
  }

  void _renameFavoriteList(db.FavoriteList list) async {
    final controller = TextEditingController(text: list.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Rename List', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 300,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(hintText: 'List name', hintStyle: TextStyle(color: Colors.white38)),
            onFieldSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName != null && newName.isNotEmpty && newName != list.name) {
      final database = ref.read(databaseProvider);
      await database.renameFavoriteList(list.id, newName);
      _loadChannels();
    }
  }
}

/// Helper for inline EPG mapping dialog.
class _EpgCandidate {
  final String channelId;
  final String displayName;
  final String sourceId;
  final String sourceName;
  const _EpgCandidate(this.channelId, this.displayName, this.sourceId, this.sourceName);
}
