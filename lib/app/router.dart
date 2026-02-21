import 'package:go_router/go_router.dart';

import '../core/platform_info.dart';
import '../features/channels/channels_screen.dart';
import '../features/guide/guide_screen.dart';
import '../features/player/player_screen.dart';
import '../features/providers/providers_screen.dart';
import '../features/epg_mapping/epg_mapping_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shows/shows_screen.dart';
import '../features/shows/show_detail_screen.dart';
import '../platform/tv/tv_shell.dart';
import '../data/models/show.dart';

GoRouter createRouter() {
  // Routes that live inside the TV sidebar shell
  final sidebarRoutes = [
    GoRoute(
      path: '/',
      builder: (context, state) => const ChannelsScreen(),
    ),
    GoRoute(
      path: '/guide',
      builder: (context, state) => const GuideScreen(),
    ),
    GoRoute(
      path: '/providers',
      builder: (context, state) => const ProvidersScreen(),
    ),
    GoRoute(
      path: '/epg-mapping',
      builder: (context, state) => const EpgMappingScreen(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
  ];

  // Routes outside the shell (player, shows detail, etc.)
  final standaloneRoutes = [
    GoRoute(
      path: '/player',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>? ?? {};
        return PlayerScreen(
          streamUrl: extra['streamUrl'] as String? ?? '',
          channelName: extra['channelName'] as String? ?? '',
          channelLogo: extra['channelLogo'] as String?,
          alternativeUrls:
              (extra['alternativeUrls'] as List<String>?) ?? const [],
          channels:
              (extra['channels'] as List<dynamic>?)
                  ?.cast<Map<String, dynamic>>() ??
              const [],
          currentIndex: extra['currentIndex'] as int? ?? 0,
        );
      },
    ),
    GoRoute(
      path: '/shows',
      builder: (context, state) => const ShowsScreen(),
    ),
    GoRoute(
      path: '/shows/:id',
      builder: (context, state) {
        final traktId = int.tryParse(state.pathParameters['id'] ?? '') ?? 0;
        final show = state.extra as Show?;
        return ShowDetailScreen(traktId: traktId, initialShow: show);
      },
    ),
  ];

  if (PlatformInfo.isTV) {
    return GoRouter(
      initialLocation: '/',
      routes: [
        ShellRoute(
          builder: (context, state, child) => TvShell(child: child),
          routes: sidebarRoutes,
        ),
        ...standaloneRoutes,
      ],
    );
  }

  // Non-TV: flat routes (original behavior)
  return GoRouter(
    initialLocation: '/',
    routes: [
      ...sidebarRoutes,
      ...standaloneRoutes,
    ],
  );
}

/// Global router instance — initialized lazily.
late final GoRouter router = createRouter();
