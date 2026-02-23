import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, Platform;

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/countdown_snackbar.dart';
import '../../core/fuzzy_match.dart';
import '../../core/platform_info.dart';
import '../../core/weather_clock_widget.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/datasources/remote/tmdb_client.dart';
import '../../data/services/app_update_service.dart';
import '../../data/services/epg_refresh_service.dart';
import '../../data/services/stream_alternatives_service.dart';
import '../player/player_service.dart';
import '../player/stream_info_badges.dart';
import '../providers/provider_manager.dart';
import '../shows/shows_providers.dart';
import 'channel_debug_dialog.dart';

class ChannelsScreen extends ConsumerStatefulWidget {
  const ChannelsScreen({super.key});

  @override
  ConsumerState<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends ConsumerState<ChannelsScreen> {
  static bool _updateCheckDone = false;
  bool _initialLoadDone = false;
  String _loadStatus = '';
  List<db.Channel> _allChannels = [];
  List<db.Channel> _filteredChannels = [];
  List<String> _groups = [];
  String _selectedGroup = 'All';
  String _searchQuery = '';
  // _showSearch removed — search bar is always visible in the top navbar
  int _selectedIndex = -1;
  db.Channel? _previewChannel;
  List<db.EpgProgramme> _nowPlaying = [];

  /// Maps channel ID → mapped EPG channel ID (from epg_mappings table)
  Map<String, String> _epgMappings = {};
  /// Maps channel ID → user-set vanity name (original name preserved in DB)
  Map<String, String> _vanityNames = {};
  Set<String> _validEpgChannelIds = {};
  Map<String, String> _rawToPrefixedEpg = {}; // XMLTV channelId → prefixed id
  Map<String, String> _epgNameToId = {}; // normalized EPG displayName → prefixed id
  Map<String, String> _epgCallSignToId = {}; // call sign (e.g. WABC) → prefixed id
  bool _showGuideView = true;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  List<String> _searchHistory = [];
  static const _kSearchHistory = 'search_history';
  static const _kMaxSearchHistory = 20;
  final _channelListController = ScrollController();
  late final ScrollController _guideScrollController;
  Timer? _guideIdleTimer;
  DateTime? _guideDayStart; // stored for snap-back calculation
  Timer? _searchDebounce;

  // Overlay state
  bool _showOverlay = false;
  // _showDebugOverlay removed — debug info is now a dialog
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
  final _firstChannelFocusNode = FocusNode(debugLabel: 'channel-first');
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
  // Track which providers' channels have been loaded into _allChannels
  final Set<String> _loadedProviders = {};
  // True while background is still loading all channels
  bool _backgroundLoading = false;
  // Favorite lists state
  List<db.FavoriteList> _favoriteLists = [];
  Set<String> _favoritedChannelIds = {};

  // Multi-select mode for failover group creation
  bool _multiSelectMode = false;
  Set<String> _multiSelectedChannelIds = {};

  // Failover groups state
  List<db.FailoverGroup> _failoverGroups = [];
  /// groupId → ordered list of channel IDs
  Map<int, List<String>> _failoverGroupMembers = {};
  /// channelId → list of group memberships (for fast player lookup)
  Map<String, List<db.FailoverGroupMembership>> _failoverGroupIndex = {};
  final Set<int> _expandedFailoverGroups = {};

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
    _loadSearchHistory();
    // Resolve missing logos on startup (in background)
    ref.read(providerManagerProvider).resolveAllMissingLogos().catchError((_) {});
    // Auto-failover toast
    final ps = ref.read(playerServiceProvider);
    ps.onFailover = (message) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            width: 250,
          ),
        );
        // Update channel list selection to reflect the failover target
        final newId = ps.lastFailoverChannelId;
        if (newId != null) {
          final idx = _filteredChannels.indexWhere((c) => c.id == newId);
          if (idx >= 0 && idx != _selectedIndex) {
            setState(() {
              _previousIndex = _selectedIndex;
              _selectedIndex = idx;
              _previewChannel = _filteredChannels[idx];
            });
            if (_channelListController.hasClients) {
              _scrollToIndex(idx);
            }
          }
        }
      }
    };
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
    // Collect EPG channel IDs for all favorited channels + their failover alts
    final epgChannelIds = <String>{};
    final favChannels = _allChannels.where((c) => _favoritedChannelIds.contains(c.id));
    for (final c in favChannels) {
      final epgId = _getEpgId(c);
      if (epgId != null) epgChannelIds.add(epgId);
    }
    // Also include any currently filtered channels (e.g. failover alts in view)
    for (final c in _filteredChannels) {
      final epgId = _getEpgId(c);
      if (epgId != null) epgChannelIds.add(epgId);
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

  /// Extract a broadcast call-sign sort key from a channel name.
  /// Channels with call signs (W/K + 2-3 letters) sort first (uppercase),
  /// others sort by cleaned name (lowercase) so they come after.
  static String _callSignSortKey(String name) {
    // Strip provider prefixes like "US-P|", "US: ", "UK- ", "CA-", "MX-"
    var s = name.replaceAll(RegExp(r'^[A-Z]{2}[\s:-]*[A-Z]*\|'), '');
    s = s.replaceAll(RegExp(r'^(US|UK|CA|MX)[\s:-]+', caseSensitive: false), '');
    // Strip bracketed tags [US], [SP], [H]
    s = s.replaceAll(RegExp(r'\[.*?\]'), '');
    // Strip quality tags
    s = s.replaceAll(RegExp(r'\b(HD|FHD|SHD|SD|4K|UHD)\b', caseSensitive: false), '');
    // Strip common location names
    s = s.replaceAll(RegExp(r'\b(New York|Los Angeles|Chicago|Houston|Phoenix|Philadelphia|San Antonio|San Diego|Dallas|San Jose|Austin|Jacksonville|Fort Worth|Columbus|Charlotte|Indianapolis|San Francisco|Seattle|Denver|Washington|Nashville|Oklahoma City|El Paso|Boston|Portland|Las Vegas|Memphis|Louisville|Baltimore|Milwaukee|Albuquerque|Tucson|Fresno|Mesa|Sacramento|Atlanta|Kansas City|Colorado Springs|Omaha|Raleigh|Long Beach|Virginia Beach|Miami|Oakland|Minneapolis|Tampa|Tulsa|Arlington|New Orleans|Cleveland|Orlando|Cincinnati|Pittsburgh|Detroit|St\.? Louis)\b', caseSensitive: false), '');
    s = s.trim();
    // Try to find a broadcast call sign: W or K followed by 2-3 letters
    final csMatch = RegExp(r'\b([WK][A-Z]{2,3})\b', caseSensitive: false).firstMatch(s);
    if (csMatch != null) {
      final cs = csMatch.group(1)!.toUpperCase();
      // Validate it looks like a real call sign (not a common word)
      if (cs.length >= 3 && cs.length <= 4) return cs;
    }
    // No call sign found — return cleaned name lowercase (sorts after uppercase)
    return s.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), ' ').trim().toLowerCase();
  }

  /// Normalize a channel/EPG display name for fuzzy EPG matching.
  /// Strips country tags, quality tags, provider prefixes, call signs in parens.
  static String _normalizeForEpgMatch(String name) {
    return name.toLowerCase()
        .replaceAll(RegExp(r'\[.*?\]'), '')           // [US], [SP], [H]
        .replaceAll(RegExp(r'\(.*?\)'), '')            // (WABC), (S)
        .replaceAll(RegExp(r'\b(hd|fhd|shd|sd|4k|uhd|us|uk|ca|mx)\b'), '')
        .replaceAll(RegExp(r'us-?[a-z]*\|'), '')      // US-P| prefix
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')        // non-alphanum → space
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Extract a broadcast call sign (3-4 uppercase letters starting with W or K)
  /// from a channel name. Checks parenthesized call signs like (WABC) first,
  /// then tvgId patterns, then words in the name.
  static final _callSignInParens = RegExp(r'\(([WK][A-Z]{2,3})\)');
  static final _callSignInTvgId = RegExp(r'[.\-_]([wk][a-z]{2,3})(?:[.\-_]|$)', caseSensitive: false);
  static final _callSignWord = RegExp(r'\b([WK][A-Z]{2,3})\b');

  static String? _extractCallSign(String name, String? tvgId) {
    // 1. Check parenthesized call sign: (WABC)
    final parenMatch = _callSignInParens.firstMatch(name);
    if (parenMatch != null) return parenMatch.group(1)!.toUpperCase();
    // 2. Check tvgId for embedded call sign: abcwabc.us, ABC.(WABC).New.York
    if (tvgId != null && tvgId.isNotEmpty) {
      final tvgMatch = _callSignInTvgId.firstMatch(tvgId);
      if (tvgMatch != null) return tvgMatch.group(1)!.toUpperCase();
      // Also try last segment before .us: e.g. "cbs2wcbs.us" → extract WCBS
      final dotParts = tvgId.replaceAll(RegExp(r'\.us$', caseSensitive: false), '').split('.');
      for (final part in dotParts) {
        final m = RegExp(r'([wk][a-z]{2,3})$', caseSensitive: false).firstMatch(part);
        if (m != null) return m.group(1)!.toUpperCase();
      }
    }
    // 3. Check name for standalone call sign word
    final wordMatch = _callSignWord.firstMatch(name.replaceAll(RegExp(r'\(.*?\)'), ''));
    if (wordMatch != null) return wordMatch.group(1)!.toUpperCase();
    return null;
  }

  /// Clear the search bar and re-apply filters.
  void _clearSearch() {
    if (_searchQuery.isEmpty) return;
    // Save non-empty query to history before clearing
    _addSearchHistory(_searchQuery);
    _searchQuery = '';
    _searchController.clear();
    _applyFilters();
  }

  /// Add a query to search history (persisted via SharedPreferences).
  void _addSearchHistory(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _searchHistory.remove(trimmed);
    _searchHistory.insert(0, trimmed);
    if (_searchHistory.length > _kMaxSearchHistory) {
      _searchHistory = _searchHistory.sublist(0, _kMaxSearchHistory);
    }
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList(_kSearchHistory, _searchHistory);
    });
  }

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    _searchHistory = prefs.getStringList(_kSearchHistory) ?? [];
  }

  void _acceptFailover() {
    if (_failoverSuggestion == null) return;
    final idx = _filteredChannels.indexWhere((c) => c.id == _failoverSuggestion!.id);
    if (idx >= 0) {
      _selectChannel(idx);
    } else {
      // Channel not in current filter — play directly
      final playerService = ref.read(playerServiceProvider);
      playerService.play(_failoverSuggestion!.streamUrl,
        channelId: _failoverSuggestion!.id,
        epgChannelId: _getEpgId(_failoverSuggestion!),
        tvgId: _failoverSuggestion!.tvgId,
        channelName: _failoverSuggestion!.name,
        vanityName: _vanityNames[_failoverSuggestion!.id],
        originalName: _failoverSuggestion!.tvgName,
      );
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
    _firstChannelFocusNode.dispose();
    _channelListController.dispose();
    _guideScrollController.dispose();
    _guideIdleTimer?.cancel();
    _searchDebounce?.cancel();
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
    final isFirstLoad = _allChannels.isEmpty;

    // ── Micro-phase 1: providers + favIds (tiny queries) ──
    if (mounted) setState(() => _loadStatus = 'Loading providers…');
    final results = await Future.wait([
      database.getAllProviders(),
      database.getAllFavoriteLists(),
      database.getAllFavoritedChannelIds(),
      SharedPreferences.getInstance(),
    ]);
    final providers = results[0] as List<db.Provider>;
    final favLists = results[1] as List<db.FavoriteList>;
    final favChannelIds = results[2] as Set<String>;
    final prefs = results[3] as SharedPreferences;

    // Vanity names (sync parse from already-loaded prefs)
    final vanityJson = prefs.getString('channel_vanity_names');
    if (vanityJson != null) {
      try {
        final decoded = jsonDecode(vanityJson) as Map<String, dynamic>;
        _vanityNames = decoded.map((k, v) => MapEntry(k, v as String));
      } catch (_) {}
    }

    // ── Micro-phase 2: favorite channels (direct ID query, ~18 rows) ──
    if (mounted) setState(() => _loadStatus = 'Loading ${favChannelIds.length} favorites…');
    List<db.Channel> favChannels = [];
    if (favChannelIds.isNotEmpty) {
      favChannels = await database.getChannelsByIds(favChannelIds);
    }

    if (!mounted) return;
    if (mounted) setState(() => _loadStatus = 'Found ${providers.length} providers, ${favChannels.length} favorites');
    // FIRST RENDER — user sees Favorites immediately
    setState(() {
      _initialLoadDone = true;
      _allChannels = favChannels;
      _providers = providers;
      _favoriteLists = favLists;
      _favoritedChannelIds = favChannelIds;
      _selectedGroup = 'Favorites';
      _applyFilters();
    });
    if (isFirstLoad) _restoreSession();

    // ── Background: sidebar groups + failover groups (non-blocking) ──
    final bgResults = await Future.wait([
      database.getProviderGroups(),
      database.getAllFailoverGroups(),
    ]);
    final pGroups = bgResults[0] as Map<String, List<String>>;
    final foGroups = bgResults[1] as List<db.FailoverGroup>;
    final allGroupNames = <String>{};
    for (final gl in pGroups.values) allGroupNames.addAll(gl);

    final foGroupMembers = <int, List<String>>{};
    for (final g in foGroups) {
      final members = await database.getFailoverGroupMembers(g.id);
      foGroupMembers[g.id] = members.map((m) => m.channelId).toList();
    }
    final foGroupIndex = await database.getFailoverGroupIndex();

    if (!mounted) return;
    setState(() {
      _providerGroups = pGroups;
      _groups = allGroupNames.toList()..sort();
      _failoverGroups = foGroups;
      _failoverGroupMembers = foGroupMembers;
      _failoverGroupIndex = foGroupIndex;
    });

    // ── Background: EPG for favorites ──
    _loadEpgData(database, favChannels, favChannelIds);

    // ── Background: load all provider channels incrementally ──
    _backgroundLoading = true;
    for (final provider in providers) {
      if (!mounted) return;
      final channels = await database.getChannelsForProvider(provider.id);
      if (!mounted) return;
      final existingIds = _allChannels.map((c) => c.id).toSet();
      final newChannels = channels.where((c) => !existingIds.contains(c.id)).toList();
      _loadedProviders.add(provider.id);
      setState(() {
        _allChannels = [..._allChannels, ...newChannels];
        if (_selectedGroup == 'All' || _selectedGroup == 'provider:${provider.id}' ||
            _selectedGroup.startsWith('provgroup:${provider.id}:')) {
          _applyFilters();
        }
      });
    }
    _backgroundLoading = false;

    // Re-index EPG with full channel set
    if (mounted) _loadEpgData(database, _allChannels, favChannelIds);
  }

  /// On-demand: load a single provider's channels into _allChannels.
  Future<void> _loadProviderChannels(String providerId) async {
    if (_loadedProviders.contains(providerId)) return;
    final database = ref.read(databaseProvider);
    final channels = await database.getChannelsForProvider(providerId);
    if (!mounted) return;
    _loadedProviders.add(providerId);
    final existingIds = _allChannels.map((c) => c.id).toSet();
    final newChannels = channels.where((c) => !existingIds.contains(c.id)).toList();
    setState(() {
      _allChannels = [..._allChannels, ...newChannels];
      _applyFilters();
    });
  }

  /// Loads EPG sources, mappings, and now-playing data in the background.
  /// Updates state incrementally so the UI is never blocked.
  Future<void> _loadEpgData(
    db.AppDatabase database,
    List<db.Channel> allChannels,
    Set<String> favChannelIds,
  ) async {
    final epgSources = await database.getAllEpgSources();
    final currentSourceIds = epgSources.map((s) => s.id).toSet();
    final validIds = <String>{};
    final rawToPrefixed = <String, String>{};
    final epgNameToId = <String, String>{};
    final epgCallSignToId = <String, String>{}; // WABC → prefixed id
    for (final src in epgSources) {
      final chs = await database.getEpgChannelsForSource(src.id);
      for (final ch in chs) {
        validIds.add(ch.id);
        rawToPrefixed[ch.channelId.toLowerCase()] = ch.id;
        final normName = _normalizeForEpgMatch(ch.displayName);
        if (normName.isNotEmpty) epgNameToId[normName] = ch.id;
        // Index by call sign extracted from channelId (e.g. WABC.us → WABC)
        final rawUpper = ch.channelId.toUpperCase();
        final csMatch = RegExp(r'^([WK][A-Z]{2,3})\.').firstMatch(rawUpper);
        if (csMatch != null) {
          epgCallSignToId.putIfAbsent(csMatch.group(1)!, () => ch.id);
        }
        // Also index from local station IDs like abc.ny.newyork.wabc
        final dotParts = ch.channelId.split('.');
        if (dotParts.length >= 4) {
          final lastPart = dotParts.last.toUpperCase();
          if (RegExp(r'^[WK][A-Z]{2,3}$').hasMatch(lastPart)) {
            epgCallSignToId.putIfAbsent(lastPart, () => ch.id);
          }
        }
      }
    }

    final mappings = await database.getAllMappings();
    final epgMap = <String, String>{};
    for (final m in mappings) {
      final directKey = '${m.epgSourceId}_${m.epgChannelId}';
      if (currentSourceIds.contains(m.epgSourceId)) {
        epgMap[m.channelId] = directKey;
      } else {
        for (final srcId in currentSourceIds) {
          final candidate = '${srcId}_${m.epgChannelId}';
          if (validIds.contains(candidate)) {
            epgMap[m.channelId] = candidate;
            break;
          }
        }
      }
    }

    // Build failover name index + EPG scope
    final normNameIndex = <String, List<String>>{};
    for (final c in allChannels) {
      final norm = _normalizeName(c.name);
      (normNameIndex[norm] ??= []).add(c.id);
    }
    final epgScopeIds = <String>{...favChannelIds};
    final favChannels = allChannels.where((c) => favChannelIds.contains(c.id));
    for (final fav in favChannels) {
      final normName = _normalizeName(fav.name);
      final alts = normNameIndex[normName];
      if (alts != null) epgScopeIds.addAll(alts);
    }

    // Collect EPG channel IDs for now-playing lookup
    final epgChannelIds = <String>{};
    for (final c in allChannels) {
      if (!epgScopeIds.contains(c.id)) continue;
      final mapped = epgMap[c.id];
      if (mapped != null && mapped.isNotEmpty) {
        epgChannelIds.add(mapped);
        continue;
      }
      if (c.tvgId != null && c.tvgId!.isNotEmpty) {
        final prefixed = rawToPrefixed[c.tvgId!.toLowerCase()];
        if (prefixed != null) { epgChannelIds.add(prefixed); continue; }
      }
      // Fallback: match by normalized channel name
      final normName = _normalizeForEpgMatch(c.name);
      if (normName.isNotEmpty) {
        final byName = epgNameToId[normName];
        if (byName != null) { epgChannelIds.add(byName); continue; }
      }
      // Fallback: match by call sign (WABC, WCBS, WNYW)
      final callSign = _extractCallSign(c.name, c.tvgId);
      if (callSign != null) {
        final byCs = epgCallSignToId[callSign];
        if (byCs != null) epgChannelIds.add(byCs);
      }
    }
    List<db.EpgProgramme> nowPlaying = [];
    if (epgChannelIds.isNotEmpty) {
      nowPlaying = await database.getNowPlaying(epgChannelIds.toList());
    }

    if (!mounted) return;
    setState(() {
      _nowPlaying = nowPlaying;
      _epgMappings = epgMap;
      _validEpgChannelIds = validIds;
      _rawToPrefixedEpg = rawToPrefixed;
      _epgNameToId = epgNameToId;
      _epgCallSignToId = epgCallSignToId;
    });
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

    // Refresh EPG now-playing after restoring timeshifts and group
    _refreshNowPlaying();
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
            channels.where((c) => _favoritedChannelIds.contains(c.id)).toList()
              ..sort((a, b) => _callSignSortKey(_channelDisplayName(a)).compareTo(_callSignSortKey(_channelDisplayName(b))));
      } else if (_selectedGroup.startsWith('fav:')) {
        final listId = _selectedGroup.substring(4);
        _applyFavoriteListFilter(listId);
        return;
      } else if (_selectedGroup.startsWith('provider:')) {
        final providerId = _selectedGroup.substring(9);
        if (!_loadedProviders.contains(providerId)) {
          _loadProviderChannels(providerId);
          _filteredChannels = [];
          return;
        }
        channels =
            channels.where((c) => c.providerId == providerId).toList();
      } else if (_selectedGroup.startsWith('provgroup:')) {
        // Format: provgroup:{providerId}:{groupTitle}
        final parts = _selectedGroup.substring(10);
        final sepIdx = parts.indexOf(':');
        if (sepIdx > 0) {
          final providerId = parts.substring(0, sepIdx);
          final groupTitle = parts.substring(sepIdx + 1);
          if (!_loadedProviders.contains(providerId)) {
            _loadProviderChannels(providerId);
            _filteredChannels = [];
            return;
          }
          channels = channels
              .where((c) => c.providerId == providerId && c.groupTitle == groupTitle)
              .toList();
        }
      } else if (_selectedGroup != 'All') {
        channels =
            channels.where((c) => c.groupTitle == _selectedGroup).toList();
      }
    }

    // Top-bar search: when active, search ALL channels across ALL providers
    // regardless of group selection. Single-pass haystack for speed.
    if (_searchQuery.isNotEmpty) {
      final tokens = _searchQuery.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      if (tokens.isNotEmpty) {
        channels = _allChannels.where((c) {
          final haystack = '${c.name}\x00${_vanityNames[c.id] ?? ''}\x00${c.groupTitle ?? ''}\x00${c.tvgId ?? ''}'
              .toLowerCase();
          return tokens.every((t) => haystack.contains(t));
        }).toList();
      }
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
      final tokens = _searchQuery.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      if (tokens.isNotEmpty) {
        // Search ALL channels, not just favorites
        channels = _allChannels.where((c) {
          final haystack = '${c.name}\x00${_vanityNames[c.id] ?? ''}\x00${c.groupTitle ?? ''}\x00${c.tvgId ?? ''}'
              .toLowerCase();
          return tokens.every((t) => haystack.contains(t));
        }).toList();
      }
    }
    if (_sidebarSearchQuery.isNotEmpty) {
      channels = channels
          .where((c) {
            final q = _sidebarSearchQuery;
            return c.name.toLowerCase().contains(q) ||
                (_vanityNames[c.id]?.toLowerCase().contains(q) ?? false);
          })
          .toList();
    }
    channels.sort((a, b) => _callSignSortKey(_channelDisplayName(a)).compareTo(_callSignSortKey(_channelDisplayName(b))));
    if (!mounted) return;
    setState(() {
      _filteredChannels = channels;
      if (_selectedIndex >= _filteredChannels.length) {
        _selectedIndex = _filteredChannels.isEmpty ? -1 : 0;
      }
    });
    // Ensure EPG data is loaded for the favorite list channels
    _refreshNowPlaying();
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

    // Check if channel belongs to a failover group → pass group URLs
    final groupMemberships = _failoverGroupIndex[channel.id];
    List<String>? failoverUrls;
    if (groupMemberships != null && groupMemberships.isNotEmpty) {
      final groupId = groupMemberships.first.group.id;
      final memberIds = _failoverGroupMembers[groupId] ?? [];
      final channelById = <String, db.Channel>{};
      for (final c in _allChannels) {
        channelById[c.id] = c;
      }
      failoverUrls = memberIds
          .map((id) => channelById[id]?.streamUrl)
          .whereType<String>()
          .where((url) => url != channel.streamUrl)
          .toList();
    }

    playerService.play(channel.streamUrl,
      channelId: channel.id,
      epgChannelId: _getEpgId(channel),
      tvgId: channel.tvgId,
      channelName: channel.name,
      vanityName: _vanityNames[channel.id],
      originalName: channel.tvgName,
      failoverGroupUrls: failoverUrls,
    );
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
    playerService.play(channel.streamUrl,
      channelId: channel.id,
      epgChannelId: _getEpgId(channel),
      tvgId: channel.tvgId,
      channelName: channel.name,
      vanityName: _vanityNames[channel.id],
      originalName: channel.tvgName,
    );
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
              'id': c.id,
              'providerId': c.providerId,
              'name': _channelDisplayName(c),
              'originalName': c.name,
              'streamUrl': c.streamUrl,
              'tvgLogo': c.tvgLogo,
              'tvgId': c.tvgId,
              'tvgName': c.tvgName,
              'groupTitle': c.groupTitle,
              'streamType': c.streamType,
              'epgId': _getEpgId(c),
              'epgChannelId': _getEpgId(c),
              'vanityName': _vanityNames[c.id],
              'alternativeUrls': <String>[],
            })
        .toList();
    await context.push('/player', extra: {
      'streamUrl': channel.streamUrl,
      'channelName': _channelDisplayName(channel),
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

  /// Get the effective EPG channel ID: mapped ID takes priority, then tvgId, then name match.
  String? _getEpgId(db.Channel channel) {
    final mapped = _epgMappings[channel.id];
    if (mapped != null && mapped.isNotEmpty) return mapped;
    if (channel.tvgId != null && channel.tvgId!.isNotEmpty) {
      final prefixed = _rawToPrefixedEpg[channel.tvgId!.toLowerCase()];
      if (prefixed != null) return prefixed;
    }
    // Fallback: match by normalized channel name against EPG display names
    final normName = _normalizeForEpgMatch(channel.name);
    if (normName.isNotEmpty) {
      final byName = _epgNameToId[normName];
      if (byName != null) return byName;
    }
    // Fallback: match by broadcast call sign (WABC, WCBS, etc.)
    final callSign = _extractCallSign(channel.name, channel.tvgId);
    if (callSign != null) {
      final byCs = _epgCallSignToId[callSign];
      if (byCs != null) return byCs;
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

  /// Display name for a channel — vanity name if set, otherwise original name.
  String _channelDisplayName(db.Channel channel) =>
      _vanityNames[channel.id] ?? channel.name;

  /// Get failover alternative details for a channel (for debug dialog).
  List<AlternativeDetail> _getFailoverAlts(db.Channel channel) {
    try {
      return ref.read(streamAlternativesProvider).getAlternativeDetails(
        channelId: channel.id,
        epgChannelId: _getEpgId(channel),
        tvgId: channel.tvgId,
        channelName: channel.name,
        vanityName: _vanityNames[channel.id],
        originalName: channel.tvgName,
        excludeUrl: channel.streamUrl,
      );
    } catch (_) {
      return [];
    }
  }

  /// All current/upcoming programme titles for a channel (for search).
  List<String> _getChannelProgrammeTitles(db.Channel channel) {
    final epgId = _getEpgId(channel);
    if (epgId == null) return const [];
    return _nowPlaying
        .where((p) => p.epgChannelId == epgId)
        .map((p) => p.title)
        .toList();
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

    // Open debug info dialog with 'D' key
    if (!isAndroid && event.logicalKey == LogicalKeyboardKey.keyD) {
      if (_previewChannel != null) {
        final ps = ref.read(playerServiceProvider);
        final alts = _getFailoverAlts(_previewChannel!);
        ChannelDebugDialog.show(context, _previewChannel!, ps,
            mappedEpgId: _getEpgId(_previewChannel!),
            originalName: _previewChannel!.tvgName ?? _previewChannel!.name,
            currentProviderName: ref.read(streamAlternativesProvider).providerName(_previewChannel!.providerId),
            alternatives: alts);
      }
      return;
    }

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
    if (!_initialLoadDone) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0A1A),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 48, height: 48,
                child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFF6C5CE7)),
              ),
              const SizedBox(height: 20),
              Text(_loadStatus,
                style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
        ),
      );
    }
    if (_allChannels.isEmpty && _providers.isEmpty) {
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
          Expanded(
            child: SizedBox(
              height: 36,
              child: RawAutocomplete<String>(
                textEditingController: _searchController,
                focusNode: _searchFocusNode,
                optionsBuilder: (textEditingValue) {
                  if (textEditingValue.text.isEmpty && _searchHistory.isNotEmpty) {
                    return _searchHistory;
                  }
                  if (_searchHistory.isEmpty) return const Iterable<String>.empty();
                  final q = textEditingValue.text.toLowerCase();
                  return _searchHistory.where((h) => h.toLowerCase().contains(q));
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
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
                      prefixIcon: const Icon(Icons.search_rounded, size: 18, color: Colors.white38),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.close,
                                  size: 18, color: Colors.white54),
                              onPressed: () {
                                setState(() {
                                  _clearSearch();
                                });
                                _focusNode.requestFocus();
                              },
                            )
                          : null,
                    ),
                    onChanged: (value) {
                      _searchDebounce?.cancel();
                      _searchQuery = value;
                      _searchDebounce = Timer(const Duration(seconds: 2), () {
                        if (mounted) setState(() => _applyFilters());
                      });
                    },
                    onSubmitted: (value) {
                      if (value.trim().isNotEmpty) _addSearchHistory(value.trim());
                      _focusNode.requestFocus();
                    },
                  );
                },
                optionsViewBuilder: (context, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 8,
                      color: const Color(0xFF1A1A2E),
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 240, maxWidth: 400),
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          shrinkWrap: true,
                          itemCount: options.length,
                          itemBuilder: (context, index) {
                            final option = options.elementAt(index);
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.history, size: 16, color: Colors.white38),
                              title: Text(option, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                              trailing: IconButton(
                                icon: const Icon(Icons.close, size: 14, color: Colors.white24),
                                onPressed: () {
                                  setState(() {
                                    _searchHistory.remove(option);
                                    SharedPreferences.getInstance().then((prefs) {
                                      prefs.setStringList(_kSearchHistory, _searchHistory);
                                    });
                                  });
                                },
                              ),
                              onTap: () => onSelected(option),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
                onSelected: (selection) {
                  _searchController.text = selection;
                  setState(() {
                    _searchQuery = selection;
                    _applyFilters();
                  });
                  _focusNode.requestFocus();
                },
              ),
            ),
          ),
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
            icon: const Icon(Icons.settings_rounded, color: Colors.white70),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
          // Cast icon removed — available in fullscreen player
                ],
              ),
            ),
          ),
          const Spacer(),
          const WeatherClockWidget(),
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
                          // Top row: name+group left, badges+provider+time right
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _channelDisplayName(_previewChannel!),
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
                              // Stream info badges + provider + time
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _StreamInfoBadges(playerService: playerService),
                                      if (_getProviderName(_previewChannel!.providerId).isNotEmpty) ...[
                                        const SizedBox(width: 6),
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
                                      ],
                                    ],
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
                                    onPressed: () {
                                      if (_previewChannel == null) return;
                                      final ps = ref.read(playerServiceProvider);
                                      ChannelDebugDialog.show(context, _previewChannel!, ps,
                                          mappedEpgId: _getEpgId(_previewChannel!),
                                          originalName: _previewChannel!.tvgName ?? _previewChannel!.name,
                                          currentProviderName: ref.read(streamAlternativesProvider).providerName(_previewChannel!.providerId),
                                          alternatives: _getFailoverAlts(_previewChannel!));
                                    },
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
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(color: Color(0xFF111127)),
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
            // Search field — only on iOS (Android TV uses D-pad nav, desktop uses top bar)
            if (Platform.isIOS) ...[
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
          ],
          // Tree content
          Expanded(
            child: _sidebarExpanded ? _buildSidebarTree() : _buildCollapsedSidebar(),
          ),
          // Settings — anchored at bottom of sidebar
          const Divider(height: 1, color: Colors.white10),
          if (_sidebarExpanded) ...[
            _buildSidebarNavItem(Icons.settings_rounded, 'Settings', () {
              context.push('/settings');
            }),
          ] else ...[
            _sidebarIcon(Icons.settings_rounded, 'Settings', false, () {
              context.push('/settings');
            }),
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
          setState(() { _clearSearch(); _selectedGroup = 'All'; _applyFilters(); _saveSession(); });
        }),
        _sidebarIcon(Icons.star_rounded, 'Favorites', isFav, () {
          setState(() { _clearSearch(); _selectedGroup = 'Favorites'; _applyFilters(); _saveSession(); });
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
            _firstChannelFocusNode.requestFocus();
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
          _firstChannelFocusNode.requestFocus();
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
        // Shows & Movies
        const Divider(height: 1, color: Colors.white10),
        _buildTreeItem('Shows & Movies', 'action:shows', Icons.movie_rounded, indent: 0),
        // Quick actions
        const Divider(height: 1, color: Colors.white10),
        _buildTreeItem('Recordings', 'action:recordings', Icons.videocam_rounded, indent: 0),
        _buildTreeItem('Play File', 'action:play_file', Icons.play_circle_outline_rounded, indent: 0),
        _buildTreeItem('Play URL', 'action:play_url', Icons.link_rounded, indent: 0),
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
              _firstChannelFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter) {
              setState(() {
                _clearSearch();
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
                    _clearSearch();
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

  void _handleQuickAction(String action) {
    switch (action) {
      case 'recordings':
        _showRecordings();
        break;
      case 'play_file':
        _playLocalFile();
        break;
      case 'shows':
        context.push('/shows');
        break;
      case 'play_url':
        _playUrlStream();
        break;
      case 'settings':
        context.push('/settings');
        break;
    }
  }

  Future<void> _showRecordings() async {
    final prefs = await SharedPreferences.getInstance();
    final folder = prefs.getString('recordings_folder');
    if (!mounted) return;
    if (folder == null || folder.isEmpty) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        countdownSnackBar(
          'No recording folder set. Go to Settings → Recordings to choose one.',
          seconds: 5,
        ),
      );
      return;
    }
    // List recordings from the folder
    final dir = Directory(folder);
    if (!await dir.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recording folder no longer exists. Update in Settings.'), duration: Duration(seconds: 5)),
        );
      }
      return;
    }
    final files = await dir.list().where((f) =>
        f.path.endsWith('.mp4') || f.path.endsWith('.ts') || f.path.endsWith('.mkv')).toList();
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No recordings found.'), duration: Duration(seconds: 5)),
      );
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Recordings'),
        children: [
          for (final f in files)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, f.path),
              child: Row(
                children: [
                  const Icon(Icons.videocam_rounded, size: 18, color: Colors.white54),
                  const SizedBox(width: 12),
                  Expanded(child: Text(f.path.split('/').last, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null && mounted) {
      final playerService = ref.read(playerServiceProvider);
      await playerService.play(picked);
      if (mounted) context.push('/player');
    }
  }

  Future<void> _playLocalFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mkv', 'ts', 'avi', 'mov', 'm3u8', 'mpd'],
      dialogTitle: 'Choose a video file',
    );
    if (result != null && result.files.single.path != null && mounted) {
      final playerService = ref.read(playerServiceProvider);
      await playerService.play(result.files.single.path!);
      if (mounted) context.push('/player');
    }
  }

  Future<void> _playUrlStream() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
            return AnimatedPadding(
              duration: const Duration(milliseconds: 200),
              padding: EdgeInsets.only(bottom: bottomInset),
              child: AlertDialog(
                title: const Text('Play Network Stream'),
                content: SizedBox(
                  width: 500,
                  child: TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      hintText: 'http:// or rtsp:// stream URL',
                      isDense: true,
                    ),
                    onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
                  ),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                    child: const Text('Play'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    if (url != null && url.isNotEmpty && mounted) {
      final playerService = ref.read(playerServiceProvider);
      await playerService.play(url);
      if (mounted) context.push('/player');
    }
  }

  Widget _buildTreeItem(String label, String filterKey, IconData? icon, {int indent = 0, VoidCallback? onSecondaryTap, Widget? trailing, FocusNode? focusNode}) {
    final isSelected = _selectedGroup == filterKey;
    return GestureDetector(
      onSecondaryTap: onSecondaryTap,
      child: Focus(
        focusNode: focusNode,
        autofocus: isSelected && Platform.isAndroid,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            // RIGHT from sidebar → focus channel list
            _firstChannelFocusNode.requestFocus();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            if (filterKey.startsWith('action:')) {
              _handleQuickAction(filterKey.substring(7));
              return KeyEventResult.handled;
            }
            setState(() {
              _clearSearch();
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
                // Handle quick actions
                if (filterKey.startsWith('action:')) {
                  _handleQuickAction(filterKey.substring(7));
                  return;
                }
                setState(() {
                  _clearSearch();
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

    // Build failover group rows to show above the channel list
    final failoverGroupWidgets = <Widget>[];
    if (_failoverGroups.isNotEmpty && !_multiSelectMode && _searchQuery.isEmpty && _sidebarSearchQuery.isEmpty) {
      // Build channel lookup map for performance
      final channelById = <String, db.Channel>{};
      for (final c in _allChannels) {
        channelById[c.id] = c;
      }
      for (final group in _failoverGroups) {
        final memberIds = _failoverGroupMembers[group.id] ?? [];
        final members = memberIds
            .map((id) => channelById[id])
            .whereType<db.Channel>()
            .toList();
        if (members.isNotEmpty) {
          failoverGroupWidgets.add(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: _buildFailoverGroupRow(group, members),
            ),
          );
        }
      }
    }

    final listWidget = ListView.builder(
      controller: _channelListController,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: _filteredChannels.length + (failoverGroupWidgets.isNotEmpty ? failoverGroupWidgets.length + 1 : 0),
      itemBuilder: (context, index) {
        // Inject failover group rows at the top
        if (failoverGroupWidgets.isNotEmpty) {
          if (index < failoverGroupWidgets.length) {
            return failoverGroupWidgets[index];
          }
          if (index == failoverGroupWidgets.length) {
            return const Divider(color: Colors.white12, height: 16);
          }
          index = index - failoverGroupWidgets.length - 1;
        }
        final channel = _filteredChannels[index];
        final isSelected = index == _selectedIndex;
        final isFavorited = _favoritedChannelIds.contains(channel.id);

        return Material(
          color: Colors.transparent,
          child: GestureDetector(
            onSecondaryTapUp: (_) => _showFavoriteListSheet(channel),
            child: Focus(
              focusNode: index == 0 ? _firstChannelFocusNode : null,
              autofocus: index == 0 && Platform.isAndroid,
              onFocusChange: (hasFocus) {
                if (hasFocus && Platform.isAndroid) _selectChannel(index);
              },
              onKeyEvent: (node, event) {
                // Track this node so sidebar can navigate back
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
                  final isMultiSelected = _multiSelectMode && _multiSelectedChannelIds.contains(channel.id);
                  return InkWell(
                    onTap: () {
                      final shiftHeld = HardwareKeyboard.instance.logicalKeysPressed
                          .any((k) => k == LogicalKeyboardKey.shiftLeft || k == LogicalKeyboardKey.shiftRight);
                      if (shiftHeld) {
                        // Shift+click: enter multi-select or toggle selection
                        setState(() {
                          if (!_multiSelectMode) {
                            _multiSelectMode = true;
                            _multiSelectedChannelIds = {channel.id};
                          } else {
                            if (_multiSelectedChannelIds.contains(channel.id)) {
                              _multiSelectedChannelIds.remove(channel.id);
                            } else {
                              _multiSelectedChannelIds.add(channel.id);
                            }
                          }
                        });
                      } else if (_multiSelectMode) {
                        setState(() {
                          if (_multiSelectedChannelIds.contains(channel.id)) {
                            _multiSelectedChannelIds.remove(channel.id);
                          } else {
                            _multiSelectedChannelIds.add(channel.id);
                          }
                        });
                      } else {
                        _selectChannel(index);
                      }
                    },
                    onDoubleTap: () {
                      if (!_multiSelectMode) {
                        setState(() {
                          _multiSelectMode = true;
                          _multiSelectedChannelIds = {channel.id};
                        });
                      } else {
                        _showFavoriteListSheet(channel);
                      }
                    },
                    onLongPress: _multiSelectMode ? null : () => _goFullscreen(channel),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isMultiSelected
                    ? const Color(0xFF6C5CE7).withValues(alpha: 0.25)
                    : isSelected
                    ? const Color(0xFF6C5CE7).withValues(alpha: 0.3)
                    : focused
                        ? const Color(0xFF6C5CE7).withValues(alpha: 0.15)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: focused
                    ? Border.all(color: Colors.white, width: 2.0)
                    : isMultiSelected
                        ? Border.all(color: const Color(0xFF6C5CE7), width: 1.5)
                    : isSelected
                        ? Border.all(
                            color: const Color(0xFF6C5CE7), width: 1.5)
                        : null,
              ),
              child: Row(
                children: [
                  // Multi-select checkbox
                  if (_multiSelectMode)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        isMultiSelected ? Icons.check_box : Icons.check_box_outline_blank,
                        size: 20,
                        color: isMultiSelected ? const Color(0xFF6C5CE7) : Colors.white38,
                      ),
                    ),
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
                                _channelDisplayName(channel),
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
                        if (_getProviderName(channel.providerId).isNotEmpty ||
                            (channel.groupTitle != null && channel.groupTitle!.isNotEmpty))
                          Text(
                            [
                              if (_getProviderName(channel.providerId).isNotEmpty)
                                _getProviderName(channel.providerId),
                              if (channel.groupTitle != null && channel.groupTitle!.isNotEmpty)
                                channel.groupTitle!,
                            ].join(' · '),
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
        // Multi-select floating action bar
        if (_multiSelectMode)
          Positioned(
            left: 8, right: 8, bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF6C5CE7), width: 1),
                boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 8)],
              ),
              child: Row(
                children: [
                  Text(
                    '${_multiSelectedChannelIds.length} selected',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() {
                      _multiSelectMode = false;
                      _multiSelectedChannelIds.clear();
                    }),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _multiSelectedChannelIds.length >= 2
                        ? _createFailoverGroupFromSelection
                        : null,
                    icon: const Icon(Icons.shield_outlined, size: 16),
                    label: const Text('Create Failover Group'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF6C5CE7),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Failover group creation from multi-select
  // ---------------------------------------------------------------------------

  Future<void> _createFailoverGroupFromSelection() async {
    if (_multiSelectedChannelIds.length < 2) return;
    final controller = TextEditingController();
    // Pre-fill with the first selected channel's name
    final firstChannel = _allChannels.where((c) => _multiSelectedChannelIds.contains(c.id)).firstOrNull;
    if (firstChannel != null) {
      controller.text = _channelDisplayName(firstChannel);
    }
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Create Failover Group', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_multiSelectedChannelIds.length} channels selected. '
                'The failover engine will cycle through these channels in order.',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Group Name',
                  hintText: 'e.g. ESPN Failover',
                  hintStyle: TextStyle(color: Colors.white24),
                ),
                onFieldSubmitted: (v) => Navigator.pop(ctx, v.trim()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;

    final database = ref.read(databaseProvider);
    final group = await database.createFailoverGroup(name);
    // Preserve selection order as priority
    final orderedIds = _filteredChannels
        .where((c) => _multiSelectedChannelIds.contains(c.id))
        .map((c) => c.id)
        .toList();
    await database.addChannelsToFailoverGroup(group.id, orderedIds);

    setState(() {
      _multiSelectMode = false;
      _multiSelectedChannelIds.clear();
    });

    // Reload to pick up new group
    _loadChannels();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failover group "$name" created with ${orderedIds.length} channels'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          width: 350,
        ),
      );
    }
  }

  Widget _buildFailoverGroupRow(db.FailoverGroup group, List<db.Channel> members) {
    final isExpanded = _expandedFailoverGroups.contains(group.id);
    return Column(
      children: [
        InkWell(
          onTap: () {
            // Tap plays the group (first channel with failover through all members)
            if (_multiSelectMode) return;
            if (members.isNotEmpty) _playFailoverGroup(group, members);
          },
          onSecondaryTap: () => _showFailoverGroupActions(group),
          onDoubleTap: () {
            // Double-tap toggles expand/collapse
            setState(() {
              if (isExpanded) {
                _expandedFailoverGroups.remove(group.id);
              } else {
                _expandedFailoverGroups.add(group.id);
              }
            });
          },
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF16213E).withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF6C5CE7).withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.shield_outlined, size: 16, color: Color(0xFF6C5CE7)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    group.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${members.length} ch',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(width: 4),
                // Expand/collapse chevron
                InkWell(
                  onTap: () {
                    setState(() {
                      if (isExpanded) {
                        _expandedFailoverGroups.remove(group.id);
                      } else {
                        _expandedFailoverGroups.add(group.id);
                      }
                    });
                  },
                  child: Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 20, color: Colors.white54,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (isExpanded)
          ...members.asMap().entries.map((entry) {
            final idx = entry.key;
            final ch = entry.value;
            final globalIdx = _filteredChannels.indexWhere((c) => c.id == ch.id);
            final isPlaying = globalIdx == _selectedIndex && globalIdx >= 0;
            return Padding(
              padding: const EdgeInsets.only(left: 24),
              child: InkWell(
                onTap: () {
                  if (globalIdx >= 0) _selectChannel(globalIdx);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      Text(
                        '#${idx + 1}',
                        style: const TextStyle(color: Colors.white24, fontSize: 11),
                      ),
                      const SizedBox(width: 8),
                      if (ch.tvgLogo != null && ch.tvgLogo!.isNotEmpty)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.network(
                            ch.tvgLogo!,
                            width: 24, height: 24,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const SizedBox(width: 24, height: 24),
                          ),
                        )
                      else
                        const SizedBox(width: 24, height: 24),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _channelDisplayName(ch),
                          style: TextStyle(
                            color: isPlaying ? Colors.white : Colors.white60,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isPlaying)
                        const Icon(Icons.play_arrow_rounded, color: Color(0xFF6C5CE7), size: 16),
                    ],
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }

  void _playFailoverGroup(db.FailoverGroup group, List<db.Channel> members) {
    if (members.isEmpty) return;
    final first = members.first;
    final globalIdx = _filteredChannels.indexWhere((c) => c.id == first.id);

    final playerService = ref.read(playerServiceProvider);
    // Pass all group member URLs as failover alternatives
    final altUrls = members.skip(1).map((c) => c.streamUrl).toList();

    playerService.play(first.streamUrl,
      channelId: first.id,
      epgChannelId: _getEpgId(first),
      tvgId: first.tvgId,
      channelName: first.name,
      vanityName: _vanityNames[first.id],
      originalName: first.tvgName,
      failoverGroupUrls: altUrls,
    );

    if (globalIdx >= 0) {
      setState(() {
        _selectedIndex = globalIdx;
        _previewChannel = first;
      });
      _showInfoOverlay(first, globalIdx);
      _saveSession();
    }
  }

  void _showFailoverGroupActions(db.FailoverGroup group) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_circle_outline, color: Colors.white70),
              title: const Text('Play Group', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                final members = (_failoverGroupMembers[group.id] ?? [])
                    .map((id) => _allChannels.where((c) => c.id == id).firstOrNull)
                    .whereType<db.Channel>()
                    .toList();
                _playFailoverGroup(group, members);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.white70),
              title: const Text('Rename', style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(ctx);
                final controller = TextEditingController(text: group.name);
                final newName = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: const Color(0xFF1A1A2E),
                    title: const Text('Rename Failover Group', style: TextStyle(color: Colors.white)),
                    content: TextFormField(
                      controller: controller,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      onFieldSubmitted: (v) => Navigator.pop(ctx, v.trim()),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                        child: const Text('Rename'),
                      ),
                    ],
                  ),
                );
                controller.dispose();
                if (newName != null && newName.isNotEmpty && mounted) {
                  final database = ref.read(databaseProvider);
                  await database.renameFailoverGroup(group.id, newName);
                  _loadChannels();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('Delete Group', style: TextStyle(color: Colors.redAccent)),
              onTap: () async {
                Navigator.pop(ctx);
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: const Color(0xFF1A1A2E),
                    title: const Text('Delete Failover Group?', style: TextStyle(color: Colors.white)),
                    content: Text('Delete "${group.name}"? The channels will not be removed.',
                        style: const TextStyle(color: Colors.white70)),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirm == true && mounted) {
                  final database = ref.read(databaseProvider);
                  await database.deleteFailoverGroup(group.id);
                  _loadChannels();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Favorite list interactions
  // ---------------------------------------------------------------------------

  /// Bottom sheet to add/remove a channel from favorite lists.
  Future<void> _renameChannel(db.Channel channel) async {
    final currentVanity = _vanityNames[channel.id];
    final controller = TextEditingController(text: currentVanity ?? channel.name);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Display Name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Original: ${channel.tvgName ?? channel.name}',
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
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
      // Remove vanity name — revert to original
      _vanityNames.remove(channel.id);
    } else if (result.isNotEmpty && result != channel.name) {
      _vanityNames[channel.id] = result;
    } else {
      return;
    }

    // Persist vanity names
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('channel_vanity_names', jsonEncode(_vanityNames));

    if (!mounted) return;
    setState(() {});
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
    Timer? autoCloseTimer;
    void resetAutoClose(NavigatorState nav) {
      autoCloseTimer?.cancel();
      autoCloseTimer = Timer(const Duration(seconds: 5), () {
        if (nav.canPop()) nav.pop();
      });
    }
    bool autoCloseStarted = false;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        if (!autoCloseStarted) {
          autoCloseStarted = true;
          resetAutoClose(Navigator.of(ctx));
        }
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
                        resetAutoClose(Navigator.of(ctx));
                      },
                    );
                  }),
                  const Divider(color: Colors.white12),
                  TextButton.icon(
                    onPressed: () async {
                      autoCloseTimer?.cancel();
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
                      if (ctx.mounted) resetAutoClose(Navigator.of(ctx));
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
    autoCloseTimer?.cancel();
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

  Future<String?> _showRenameDialog(String currentName) async {
    final controller = TextEditingController(text: currentName);
    try {
      return await showDialog<String>(
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
    } finally {
      controller.dispose();
    }
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
                        return Focus(
                          focusNode: index == 0 ? _firstChannelFocusNode : null,
                          autofocus: index == 0 && Platform.isAndroid,
                          onFocusChange: (hasFocus) {
                            if (hasFocus && Platform.isAndroid) _selectChannel(index);
                          },
                          onKeyEvent: (node, event) {
                            if (event is! KeyDownEvent) return KeyEventResult.ignored;
                            final key = event.logicalKey;
                            if (key == LogicalKeyboardKey.select ||
                                key == LogicalKeyboardKey.enter ||
                                key == LogicalKeyboardKey.gameButtonA) {
                              _goFullscreen(channel);
                              return KeyEventResult.handled;
                            }
                            if (key == LogicalKeyboardKey.arrowLeft) {
                              _sidebarAllItemFocusNode.requestFocus();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          child: Builder(
                          builder: (context) {
                          final hasFocus = Focus.of(context).hasFocus;
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
                                  : hasFocus
                                      ? const Color(0xFF6C5CE7).withValues(alpha: 0.15)
                                      : Colors.transparent,
                              border: Border(
                                bottom: const BorderSide(color: Colors.white10, width: 0.5),
                                left: isSelected
                                    ? const BorderSide(color: Color(0xFF6C5CE7), width: 3)
                                    : hasFocus
                                        ? const BorderSide(color: Color(0xFF6C5CE7), width: 2)
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
                                              [
                                                _getProviderName(channel.providerId),
                                                if (channel.groupTitle != null && channel.groupTitle!.isNotEmpty)
                                                  channel.groupTitle!,
                                              ].join(' · '),
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
                        },  // Builder builder
                        ),  // Builder
                        );  // Focus
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
          ChannelDebugDialog.show(context, channel, ps,
              mappedEpgId: _getEpgId(channel),
              originalName: channel.tvgName ?? channel.name,
              currentProviderName: ref.read(streamAlternativesProvider).providerName(channel.providerId),
              alternatives: _getFailoverAlts(channel));
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

              // For the current programme, clamp text so it stays visible
              // when the cell starts before the visible scroll area
              double textPadLeft = 4.0;
              if (isCurrent && _guideScrollController.hasClients) {
                final scrollOffset = _guideScrollController.position.pixels;
                if (left < scrollOffset && left + width > scrollOffset) {
                  textPadLeft = (scrollOffset - left) + 4.0;
                  // Don't push text past 60% of cell width
                  textPadLeft = textPadLeft.clamp(4.0, width * 0.6);
                }
              }

              return Positioned(
                left: left,
                width: width,
                top: 2,
                bottom: 2,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 0.5),
                  padding: EdgeInsets.only(left: textPadLeft, right: 4, top: 2, bottom: 2),
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
      if (!mounted) return;
      final database = ref.read(databaseProvider);
      await database.renameFavoriteList(list.id, newName);
      if (!mounted) return;
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

/// Reads mpv properties to show resolution, aspect ratio, and audio channel badges.
class _StreamInfoBadges extends StreamInfoBadges {
  const _StreamInfoBadges({required super.playerService});
}
