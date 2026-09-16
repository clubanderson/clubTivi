import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../data/models/vod_title.dart';
import 'vod_providers.dart';

/// Detail screen for VOD content — a show or movie with backdrop, info,
/// seasons, episodes, and play
class VodDetailScreen extends ConsumerStatefulWidget {
  final int traktId;
  final VodTitle? initialTitle; // Passed via extra for instant display

  const VodDetailScreen({
    super.key,
    required this.traktId,
    this.initialTitle,
  });

  @override
  ConsumerState<VodDetailScreen> createState() => _VodDetailScreenState();
}

class _VodDetailScreenState extends ConsumerState<VodDetailScreen> {
  int? _selectedSeason; // null until initialized
  bool _resolving = false;
  int _lastSeasonCount = 0; // track when seasons change
  final _seasonScrollController = ScrollController();
  Color? _dominantColor; // extracted from backdrop image
  String? _lastBackdropUrl; // avoid re-extracting for the same URL

  static const _seasonPrefPrefix = 'show_last_season_';

  /// Initialize season: use persisted preference, or default to latest season
  void _initSeason(VodTitleDetail detail) {
    // Skip if no seasons yet, or re-init if season count changed
    if (detail.seasons.isEmpty) return;
    if (_selectedSeason != null && detail.seasons.length == _lastSeasonCount) return;
    _lastSeasonCount = detail.seasons.length;
    _loadLastSeason(detail);
  }

  Future<void> _loadLastSeason(VodTitleDetail detail) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt('$_seasonPrefPrefix${widget.traktId}');
    final latestSeason = detail.seasons.isNotEmpty
        ? detail.seasons.map((s) => s.number).reduce((a, b) => a > b ? a : b)
        : 1;
    setState(() {
      _selectedSeason = saved ?? latestSeason;
    });
    _scrollToSelectedSeason(detail);
  }

  void _scrollToSelectedSeason(VodTitleDetail detail) {
    if (_selectedSeason == null || detail.seasons.isEmpty) return;
    final index = detail.seasons.indexWhere((s) => s.number == _selectedSeason);
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_seasonScrollController.hasClients) return;
      final maxScroll = _seasonScrollController.position.maxScrollExtent;
      final viewWidth = _seasonScrollController.position.viewportDimension;
      // Estimate chip position — center it in the viewport
      const chipWidth = 120.0;
      final chipCenter = index * chipWidth + chipWidth / 2 + 20; // +20 for padding
      final target = (chipCenter - viewWidth / 2).clamp(0.0, maxScroll);
      _seasonScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _selectSeason(int season) async {
    setState(() => _selectedSeason = season);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('$_seasonPrefPrefix${widget.traktId}', season);
  }

  /// Extract dominant color from backdrop for subtle page tint.
  void _extractDominantColor(String? url) {
    if (url == null || url.isEmpty || url == _lastBackdropUrl) return;
    _lastBackdropUrl = url;
    PaletteGenerator.fromImageProvider(
      CachedNetworkImageProvider(url),
      maximumColorCount: 8,
    ).then((palette) {
      if (!mounted) return;
      final color = palette.dominantColor?.color ??
          palette.mutedColor?.color ??
          palette.darkMutedColor?.color;
      if (color != null) {
        setState(() => _dominantColor = color);
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _seasonScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.initialTitle?.type ?? VodTitleType.series;
    final detailAsync = ref.watch(
      vodDetailProvider(VodDetailParams(widget.traktId, type: type)),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Future.microtask(() {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/shows');
            }
          });
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      backgroundColor: _dominantColor != null
          ? Color.lerp(const Color(0xFF0A0A1A), _dominantColor!, 0.15)!
          : const Color(0xFF0A0A1A),
      body: detailAsync.when(
        loading: () => _buildWithVodTitle(widget.initialTitle, loading: true),
        error: (err, _) => _buildError(err),
        data: (detail) {
          if (detail == null) {
            // Fallback to initialTitle if provider returned null
            if (widget.initialTitle != null) {
              return _buildDetail(VodTitleDetail(vodTitle: widget.initialTitle!));
            }
            return _buildError('VodTitle not found');
          }
          return _buildDetail(detail);
        },
      ),
    ),
    ),
    );
  }

  Widget _buildWithVodTitle(VodTitle? vodTitle, {bool loading = false}) {
    if (vodTitle == null) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF6C5CE7)),
      );
    }
    return _buildDetail(VodTitleDetail(vodTitle: vodTitle), loading: loading);
  }

  Widget _buildError(Object error) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
          const SizedBox(height: 12),
          Text('$error', style: const TextStyle(color: Colors.white60)),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => context.go('/shows'),
            child: const Text('Go Back'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetail(VodTitleDetail detail, {bool loading = false}) {
    // Initialize season selection (latest or last-viewed)
    _initSeason(detail);
    final effectiveSeason = _selectedSeason ?? (detail.seasons.isNotEmpty
        ? detail.seasons.map((s) => s.number).reduce((a, b) => a > b ? a : b)
        : 1);
    final vodTitle = detail.vodTitle;
    // Extract dominant color from backdrop for page tint
    _extractDominantColor(vodTitle.backdropUrl);
    final bgColor = _dominantColor != null
        ? Color.lerp(const Color(0xFF0A0A1A), _dominantColor!, 0.15)!
        : const Color(0xFF0A0A1A);
    return CustomScrollView(
      slivers: [
        // Backdrop + back button
        SliverAppBar(
          expandedHeight: 240,
          pinned: true,
          backgroundColor: bgColor,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => context.go('/shows'),
          ),
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                if (vodTitle.backdropUrl != null && vodTitle.backdropUrl!.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: vodTitle.backdropUrl!,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(color: const Color(0xFF1A1A2E)),
                  )
                else
                  Container(color: const Color(0xFF1A1A2E)),
                // Gradient overlay
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xDD0A0A1A)],
                      stops: [0.4, 1.0],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // VodTitle info
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title + year
                Text(
                  vodTitle.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                // Meta row
                Wrap(
                  spacing: 12,
                  children: [
                    if (vodTitle.year != null)
                      _chip('${vodTitle.year}'),
                    if (vodTitle.rating != null)
                      _chip('★ ${vodTitle.rating!.toStringAsFixed(1)}'),
                    if (vodTitle.runtime != null)
                      _chip('${vodTitle.runtime} min'),
                    if (vodTitle.status != null)
                      _chip(vodTitle.status!),
                    if (vodTitle.network != null)
                      _chip(vodTitle.network!),
                  ],
                ),
                const SizedBox(height: 8),
                // Genres
                if (vodTitle.genres.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    children: vodTitle.genres
                        .take(5)
                        .map((g) => Chip(
                              label: Text(g, style: const TextStyle(fontSize: 11)),
                              backgroundColor: const Color(0xFF1A1A2E),
                              labelStyle: const TextStyle(color: Colors.white60),
                              side: BorderSide.none,
                              padding: EdgeInsets.zero,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ))
                        .toList(),
                  ),
                const SizedBox(height: 16),
                // Overview
                if (vodTitle.overview != null)
                  Text(
                    vodTitle.overview!,
                    style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.5),
                  ),
                const SizedBox(height: 20),

                // Play button (for movies) or Season selector (for shows)
                if (vodTitle.type == VodTitleType.movie) _buildPlayMovieButton(vodTitle),

                if (loading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: CircularProgressIndicator(color: Color(0xFF6C5CE7)),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // Seasons tabs (for TV shows)
        if (vodTitle.type == VodTitleType.series && detail.seasons.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SizedBox(
              height: 48,
              child: ListView.builder(
                controller: _seasonScrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: detail.seasons.length,
                itemBuilder: (context, index) {
                  final season = detail.seasons[index];
                  final selected = season.number == effectiveSeason;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text('Season ${season.number}'),
                      selected: selected,
                      selectedColor: const Color(0xFF6C5CE7),
                      backgroundColor: const Color(0xFF1A1A2E),
                      labelStyle: TextStyle(
                        color: selected ? Colors.white : Colors.white60,
                      ),
                      side: BorderSide.none,
                      onSelected: (_) => _selectSeason(season.number),
                    ),
                  );
                },
              ),
            ),
          ),
          // Episodes list
          _buildEpisodesList(vodTitle, effectiveSeason),
        ],
      ],
    );
  }

  Widget _buildPlayMovieButton(VodTitle vodTitle) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _resolving ? null : () => _playContent(vodTitle),
        icon: _resolving
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.play_arrow),
        label: Text(_resolving ? 'Finding stream...' : 'Play'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF6C5CE7),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildEpisodesList(VodTitle vodTitle, int seasonNumber) {
    final episodesAsync = ref.watch(
      episodesProvider(EpisodeParams(widget.traktId, seasonNumber)),
    );

    return episodesAsync.when(
      loading: () => const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator(color: Color(0xFF6C5CE7))),
        ),
      ),
      error: (err, _) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Error: $err', style: const TextStyle(color: Colors.redAccent)),
        ),
      ),
      data: (episodes) => SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _EpisodeTile(
            episode: episodes[index],
            vodTitle: vodTitle,
            onPlay: () => _playEpisode(vodTitle, episodes[index]),
          ),
          childCount: episodes.length,
        ),
      ),
    );
  }

  Future<void> _playContent(VodTitle vodTitle) async {
    if (vodTitle.imdbId == null) {
      _showSnackbar('No IMDB ID available for this title');
      return;
    }
    setState(() => _resolving = true);
    try {
      final streams = await ref.read(
        resolveStreamProvider(
          StreamResolveParams(
            vodTitle.imdbId!,
            title: vodTitle.title,
            year: vodTitle.year,
            tmdbId: vodTitle.tmdbId,
            mediaType: vodTitle.type,
            preferredLanguage: _deviceLanguage(context),
          ),
        ).future,
      );
      if (streams.isEmpty) {
        _showSnackbar('No streams found on Torrentio');
        return;
      }
      if (!mounted) return;
      _showStreamPicker(streams, vodTitle.title);
    } catch (e) {
      _showSnackbar('Stream error: $e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _playEpisode(VodTitle vodTitle, Episode episode) async {
    if (vodTitle.imdbId == null) {
      _showSnackbar('No IMDB ID available');
      return;
    }
    setState(() => _resolving = true);
    try {
      final streams = await ref.read(
        resolveStreamProvider(
          StreamResolveParams(
            vodTitle.imdbId!,
            title: vodTitle.title,
            year: vodTitle.year,
            tmdbId: vodTitle.tmdbId,
            mediaType: vodTitle.type,
            season: episode.season,
            episode: episode.number,
            preferredLanguage: _deviceLanguage(context),
          ),
        ).future,
      );
      if (streams.isEmpty) {
        _showSnackbar('No streams found for ${episode.code}');
        return;
      }
      if (!mounted) return;
      _showStreamPicker(streams, '${vodTitle.title} ${episode.code}');
    } catch (e) {
      _showSnackbar('Stream error: $e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// Device UI language code ("en") used to prefer same-language sources.
  /// Null when unavailable — ranking simply skips the locale tie-break.
  String? _deviceLanguage(BuildContext context) =>
      Localizations.maybeLocaleOf(context)?.languageCode;

  void _showStreamPicker(List<ResolvedStream> streams, String title) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        maxChildSize: 0.85,
        minChildSize: 0.3,
        expand: false,
        builder: (ctx, scrollController) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 12),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text(
                  'Select Stream',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  '$title • ${streams.length} sources',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 8),
              const Divider(color: Colors.white12, height: 1),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: streams.length,
                  itemBuilder: (ctx, index) {
                    final stream = streams[index];
                    return ListTile(
                      leading: stream.isXtream
                          ? _xtreamSourceBadge(stream.language)
                          : _streamQualityBadge(stream.quality),
                      title: Text(
                        stream.filename,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          stream.source,
                          if (stream.language != null) stream.language!,
                          if (stream.isDirectPlay) 'direct',
                          if (stream.seeds != null) '👤 ${stream.seeds}',
                        ].join(' • '),
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.download_rounded, color: Colors.white54, size: 24),
                            tooltip: 'Download via browser',
                            onPressed: () {
                              Navigator.pop(ctx);
                              if (stream.isDirectPlay) {
                                _downloadDirect(stream);
                              } else {
                                _resolveAndDownload(stream, title);
                              }
                            },
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.play_circle_fill,
                              color: stream.isXtream
                                  ? Colors.tealAccent
                                  : stream.isCached
                                      ? const Color(0xFF6C5CE7)
                                      : const Color(0xFF6C5CE7).withValues(alpha: 0.6),
                              size: 32,
                            ),
                            tooltip: stream.isDirectPlay ? 'Play directly' : 'Play',
                            onPressed: () {
                              Navigator.pop(ctx);
                              _resolveAndPlay(stream, title);
                            },
                          ),
                        ],
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _resolveAndPlay(stream, title);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _resolveAndPlay(ResolvedStream stream, String title) async {
    // Direct-play Xtream sources already carry a playable URL — skip
    // magnet/debrid resolution entirely.
    if (stream.isDirectPlay) {
      _launchPlayer(stream, title);
      return;
    }
    if (stream.magnetUrl == null) {
      _showSnackbar('No playable source available');
      return;
    }
    _showSnackbar(stream.isCached ? 'Preparing stream…' : 'Preparing stream — this may take a moment…');
    setState(() => _resolving = true);
    try {
      final repo = await ref.read(vodRepositoryProvider.future);
      final resolved = await repo.resolveMagnet(
        stream.magnetUrl!,
        onProgress: (status, progress) {
          if (mounted) {
            final label = _friendlyStatus(status);
            _showSnackbar(progress > 0 ? '$label ($progress%)' : label);
          }
        },
      );
      if (resolved == null) {
        _showSnackbar('Stream unavailable — try another source');
        return;
      }
      if (!mounted) return;
      _launchPlayer(resolved, title);
    } catch (e) {
      _showSnackbar('$e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _resolveAndDownload(ResolvedStream stream, String title) async {
    if (stream.magnetUrl == null) {
      _showSnackbar('No magnet URL available');
      return;
    }
    _showSnackbar(stream.isCached ? 'Preparing download…' : 'Preparing download — this may take a moment…');
    setState(() => _resolving = true);
    try {
      final repo = await ref.read(vodRepositoryProvider.future);
      final resolved = await repo.resolveMagnet(
        stream.magnetUrl!,
        onProgress: (status, progress) {
          if (mounted) {
            final label = _friendlyStatus(status);
            _showSnackbar(progress > 0 ? '$label ($progress%)' : label);
          }
        },
      );
      if (resolved == null || resolved.url.isEmpty) {
        _showSnackbar('Download unavailable — try another source');
        return;
      }
      final uri = Uri.parse(resolved.url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) _showSnackbar('Download started in browser');
      } else {
        _showSnackbar('Could not open download URL');
      }
    } catch (e) {
      _showSnackbar('$e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// Open a direct-play Xtream URL in the browser for download.
  Future<void> _downloadDirect(ResolvedStream stream) async {
    if (stream.url.isEmpty) {
      _showSnackbar('No download URL available');
      return;
    }
    final uri = Uri.parse(stream.url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (mounted) _showSnackbar('Download started in browser');
    } else {
      _showSnackbar('Could not open download URL');
    }
  }

  /// Language badge for Xtream rows ("EN", "AF-EN"); falls back to a
  /// TV icon when the provider name carries no language prefix.
  Widget _xtreamSourceBadge(String? language) {
    const color = Colors.tealAccent;
    return Container(
      width: 52,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: language != null && language.isNotEmpty
          ? Text(
              language,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            )
          : const Icon(Icons.tv_rounded, color: color, size: 20),
    );
  }

  Widget _streamQualityBadge(String? quality) {
    final color = switch (quality) {
      '4K' => Colors.amber,
      '1080p' => Colors.greenAccent,
      '720p' => Colors.lightBlueAccent,
      _ => Colors.white38,
    };
    return Container(
      width: 52,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        quality ?? '?',
        textAlign: TextAlign.center,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }

  void _launchPlayer(ResolvedStream stream, String title) {
    debugPrint('[VOD] Launching player: url=${stream.url}, title=$title');
    if (stream.url.isEmpty) {
      _showSnackbar('Stream URL is empty — try another source');
      return;
    }
    context.push('/player', extra: {
      'streamUrl': stream.url,
      'channelName': title,
      'channelLogo': widget.initialTitle?.posterUrl ?? '',
    });
  }

  String _friendlyStatus(String status) {
    switch (status) {
      case 'magnet_conversion':
        return 'Processing magnet';
      case 'waiting_files_selection':
        return 'Selecting files';
      case 'queued':
        return 'Queued';
      case 'downloading':
        return 'Downloading';
      case 'downloaded':
        return 'Preparing stream';
      case 'uploading':
        return 'Uploading';
      case 'compressing':
        return 'Compressing';
      default:
        return status.replaceAll('_', ' ');
    }
  }

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: const Color(0xFF1A1A2E)),
    );
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white60, fontSize: 13)),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  final Episode episode;
  final VodTitle vodTitle;
  final VoidCallback onPlay;

  const _EpisodeTile({
    required this.episode,
    required this.vodTitle,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(
          children: [
            // Episode thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 120,
                height: 68,
                child: episode.stillUrl != null && episode.stillUrl!.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: episode.stillUrl!,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => _placeholder(),
                      )
                    : _placeholder(),
              ),
            ),
            const SizedBox(width: 12),
            // Episode info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${episode.number}. ${episode.displayTitle}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  if (episode.overview != null)
                    Text(
                      episode.overview!,
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (episode.runtime != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${episode.runtime} min',
                        style: const TextStyle(color: Colors.white24, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
            // Play icon
            const Icon(Icons.play_circle_outline, color: Color(0xFF6C5CE7), size: 32),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: const Center(
        child: Icon(Icons.play_arrow, color: Colors.white24),
      ),
    );
  }
}
