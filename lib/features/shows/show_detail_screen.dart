import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../data/models/show.dart';
import 'shows_providers.dart';

/// Detail screen for a show or movie — backdrop, info, seasons, episodes, play
class ShowDetailScreen extends ConsumerStatefulWidget {
  final int traktId;
  final Show? initialShow; // Passed via extra for instant display

  const ShowDetailScreen({
    super.key,
    required this.traktId,
    this.initialShow,
  });

  @override
  ConsumerState<ShowDetailScreen> createState() => _ShowDetailScreenState();
}

class _ShowDetailScreenState extends ConsumerState<ShowDetailScreen> {
  int _selectedSeason = 1;
  bool _resolving = false;

  @override
  Widget build(BuildContext context) {
    final type = widget.initialShow?.type ?? ShowType.show;
    final detailAsync = ref.watch(
      showDetailProvider(ShowDetailParams(widget.traktId, type: type)),
    );

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A1A),
      body: detailAsync.when(
        loading: () => _buildWithShow(widget.initialShow, loading: true),
        error: (err, _) => _buildError(err),
        data: (detail) {
          if (detail == null) {
            // Fallback to initialShow if provider returned null
            if (widget.initialShow != null) {
              return _buildDetail(ShowDetail(show: widget.initialShow!));
            }
            return _buildError('Show not found');
          }
          return _buildDetail(detail);
        },
      ),
    );
  }

  Widget _buildWithShow(Show? show, {bool loading = false}) {
    if (show == null) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF6C5CE7)),
      );
    }
    return _buildDetail(ShowDetail(show: show), loading: loading);
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

  Widget _buildDetail(ShowDetail detail, {bool loading = false}) {
    final show = detail.show;
    return CustomScrollView(
      slivers: [
        // Backdrop + back button
        SliverAppBar(
          expandedHeight: 300,
          pinned: true,
          backgroundColor: const Color(0xFF0A0A1A),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => context.go('/shows'),
          ),
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                if (show.backdropUrl != null && show.backdropUrl!.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: show.backdropUrl!,
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
                      colors: [Colors.transparent, Color(0xFF0A0A1A)],
                      stops: [0.5, 1.0],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Show info
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title + year
                Text(
                  show.title,
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
                    if (show.year != null)
                      _chip('${show.year}'),
                    if (show.rating != null)
                      _chip('★ ${show.rating!.toStringAsFixed(1)}'),
                    if (show.runtime != null)
                      _chip('${show.runtime} min'),
                    if (show.status != null)
                      _chip(show.status!),
                    if (show.network != null)
                      _chip(show.network!),
                  ],
                ),
                const SizedBox(height: 8),
                // Genres
                if (show.genres.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    children: show.genres
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
                if (show.overview != null)
                  Text(
                    show.overview!,
                    style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.5),
                  ),
                const SizedBox(height: 20),

                // Play button (for movies) or Season selector (for shows)
                if (show.type == ShowType.movie) _buildPlayMovieButton(show),

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
        if (show.type == ShowType.show && detail.seasons.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SizedBox(
              height: 48,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: detail.seasons.length,
                itemBuilder: (context, index) {
                  final season = detail.seasons[index];
                  final selected = season.number == _selectedSeason;
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
                      onSelected: (_) => setState(() => _selectedSeason = season.number),
                    ),
                  );
                },
              ),
            ),
          ),
          // Episodes list
          _buildEpisodesList(show),
        ],
      ],
    );
  }

  Widget _buildPlayMovieButton(Show show) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _resolving ? null : () => _playContent(show),
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

  Widget _buildEpisodesList(Show show) {
    final episodesAsync = ref.watch(
      episodesProvider(EpisodeParams(widget.traktId, _selectedSeason)),
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
            show: show,
            onPlay: () => _playEpisode(show, episodes[index]),
          ),
          childCount: episodes.length,
        ),
      ),
    );
  }

  Future<void> _playContent(Show show) async {
    if (show.imdbId == null) {
      _showSnackbar('No IMDB ID available for this title');
      return;
    }
    setState(() => _resolving = true);
    try {
      final streams = await ref.read(
        resolveStreamProvider(StreamResolveParams(show.imdbId!)).future,
      );
      if (streams.isEmpty) {
        _showSnackbar('No cached streams found');
        return;
      }
      // Play the best quality stream
      _launchPlayer(streams.first, show.title);
    } catch (e) {
      _showSnackbar('Stream error: $e');
    } finally {
      setState(() => _resolving = false);
    }
  }

  Future<void> _playEpisode(Show show, Episode episode) async {
    if (show.imdbId == null) {
      _showSnackbar('No IMDB ID available');
      return;
    }
    setState(() => _resolving = true);
    try {
      final streams = await ref.read(
        resolveStreamProvider(StreamResolveParams(
          show.imdbId!,
          season: episode.season,
          episode: episode.number,
        )).future,
      );
      if (streams.isEmpty) {
        _showSnackbar('No cached streams found for ${episode.code}');
        return;
      }
      _launchPlayer(streams.first, '${show.title} ${episode.code}');
    } catch (e) {
      _showSnackbar('Stream error: $e');
    } finally {
      setState(() => _resolving = false);
    }
  }

  void _launchPlayer(ResolvedStream stream, String title) {
    context.go('/player', extra: {
      'streamUrl': stream.url,
      'channelName': title,
      'channelLogo': widget.initialShow?.posterUrl ?? '',
    });
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
  final Show show;
  final VoidCallback onPlay;

  const _EpisodeTile({
    required this.episode,
    required this.show,
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
