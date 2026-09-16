import 'package:go_router/go_router.dart';

import '../core/platform_info.dart';
import '../features/channels/channels_screen.dart';
import '../features/guide/guide_screen.dart';
import '../features/player/player_screen.dart';
import '../features/providers/providers_screen.dart';
import '../features/epg_mapping/epg_mapping_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/debrid_services_screen.dart';
import '../features/vod/vod_screen.dart';
import '../features/vod/vod_detail_screen.dart';
import '../features/splash/splash_screen.dart';
import '../platform/tv/tv_shell.dart';
import '../data/models/vod_title.dart';

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
    GoRoute(
      path: '/debrid-services',
      builder: (context, state) => const DebridServicesScreen(),
    ),
  ];

  // Routes outside the shell (player, shows detail, splash, etc.)
  final standaloneRoutes = [
    GoRoute(
      path: '/splash',
      builder: (context, state) => const SplashScreen(),
    ),
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
      builder: (context, state) => const VodScreen(),
    ),
    GoRoute(
      path: '/shows/:id',
      builder: (context, state) {
        final traktId = int.tryParse(state.pathParameters['id'] ?? '') ?? 0;
        final vodTitle = state.extra as VodTitle?;
        return VodDetailScreen(traktId: traktId, initialTitle: vodTitle);
      },
    ),
  ];

  if (PlatformInfo.isTV) {
    return GoRouter(
      initialLocation: '/splash',
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
    initialLocation: '/splash',
    routes: [
      ...sidebarRoutes,
      ...standaloneRoutes,
    ],
  );
}

/// Global router instance — initialized lazily.
late final GoRouter router = createRouter();
