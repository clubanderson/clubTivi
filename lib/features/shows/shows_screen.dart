import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../data/models/show.dart';
import 'shows_providers.dart';

/// Main shows screen with poster grid organized by category
class ShowsScreen extends ConsumerStatefulWidget {
  const ShowsScreen({super.key});

  @override
  ConsumerState<ShowsScreen> createState() => _ShowsScreenState();
}

class _ShowsScreenState extends ConsumerState<ShowsScreen> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  bool _isSearching = false;
  int _selectedCategory = 0;

  static const _categories = [
    'Trending Shows',
    'Popular Shows',
    'Trending Movies',
    'Popular Movies',
  ];

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final apiKeys = ref.watch(showsApiKeysProvider);

    if (!apiKeys.hasTraktKey && !apiKeys.hasTmdbKey) {
      return _buildSetupPrompt(context);
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A1A),
      body: KeyboardListener(
        focusNode: FocusNode(),
        onKeyEvent: _handleKeyEvent,
        child: Column(
          children: [
            _buildHeader(context),
            if (_isSearching) _buildSearchBar(),
            _buildCategoryTabs(),
            Expanded(child: _buildContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildSetupPrompt(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A1A),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.movie_outlined, size: 64, color: Color(0xFF6C5CE7)),
              const SizedBox(height: 24),
              const Text(
                'Shows & Movies',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Configure at least a Trakt or TMDB API key in Settings\nto browse trending shows, movies, and stream via Real-Debrid.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 16),
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: () => context.go('/settings'),
                icon: const Icon(Icons.settings),
                label: const Text('Go to Settings'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C5CE7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => context.go('/'),
          ),
          const SizedBox(width: 12),
          const Text(
            'Shows & Movies',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(
              _isSearching ? Icons.close : Icons.search,
              color: Colors.white70,
            ),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchController.clear();
                  ref.read(showSearchQueryProvider.notifier).state = '';
                }
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Search shows & movies...',
          hintStyle: const TextStyle(color: Colors.white38),
          prefixIcon: const Icon(Icons.search, color: Colors.white38),
          filled: true,
          fillColor: const Color(0xFF1A1A2E),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: (query) {
          ref.read(showSearchQueryProvider.notifier).state = query;
        },
      ),
    );
  }

  Widget _buildCategoryTabs() {
    if (_isSearching) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: _categories.length,
        itemBuilder: (context, index) {
          final selected = index == _selectedCategory;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: Text(_categories[index]),
              selected: selected,
              selectedColor: const Color(0xFF6C5CE7),
              backgroundColor: const Color(0xFF1A1A2E),
              labelStyle: TextStyle(
                color: selected ? Colors.white : Colors.white60,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
              side: BorderSide.none,
              onSelected: (_) => setState(() => _selectedCategory = index),
            ),
          );
        },
      ),
    );
  }

  Widget _buildContent() {
    if (_isSearching) {
      return _buildSearchResults();
    }

    switch (_selectedCategory) {
      case 0:
        return _buildShowGrid(ref.watch(trendingShowsProvider));
      case 1:
        return _buildShowGrid(ref.watch(popularShowsProvider));
      case 2:
        return _buildShowGrid(ref.watch(trendingMoviesProvider));
      case 3:
        return _buildShowGrid(ref.watch(popularMoviesProvider));
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildSearchResults() {
    final query = ref.watch(showSearchQueryProvider);
    if (query.isEmpty) {
      return const Center(
        child: Text(
          'Type to search...',
          style: TextStyle(color: Colors.white38, fontSize: 16),
        ),
      );
    }
    return _buildShowGrid(ref.watch(showSearchResultsProvider));
  }

  Widget _buildShowGrid(AsyncValue<List<Show>> showsAsync) {
    return showsAsync.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: Color(0xFF6C5CE7)),
      ),
      error: (error, _) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            Text(
              'Failed to load: $error',
              style: const TextStyle(color: Colors.white60),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
      data: (shows) {
        if (shows.isEmpty) {
          return const Center(
            child: Text(
              'No results found',
              style: TextStyle(color: Colors.white38, fontSize: 16),
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            childAspectRatio: 0.65,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: shows.length,
          itemBuilder: (context, index) => _ShowPosterCard(
            show: shows[index],
            onTap: () => _openShow(shows[index]),
          ),
        );
      },
    );
  }

  void _openShow(Show show) {
    context.go('/shows/${show.traktId}', extra: show);
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (_isSearching) {
          setState(() {
            _isSearching = false;
            _searchController.clear();
            ref.read(showSearchQueryProvider.notifier).state = '';
          });
        } else {
          context.go('/');
        }
      }
    }
  }
}

class _ShowPosterCard extends StatelessWidget {
  final Show show;
  final VoidCallback onTap;

  const _ShowPosterCard({required this.show, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: show.posterUrl != null && show.posterUrl!.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: show.posterUrl!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      placeholder: (_, __) => Container(
                        color: const Color(0xFF1A1A2E),
                        child: const Center(
                          child: Icon(Icons.movie, color: Colors.white24, size: 40),
                        ),
                      ),
                      errorWidget: (_, __, ___) => _placeholderPoster(),
                    )
                  : _placeholderPoster(),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            show.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (show.year != null)
            Text(
              '${show.year}${show.rating != null ? ' • ★ ${show.rating!.toStringAsFixed(1)}' : ''}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
        ],
      ),
    );
  }

  Widget _placeholderPoster() {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.movie, color: Colors.white24, size: 40),
            const SizedBox(height: 4),
            Text(
              show.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}
