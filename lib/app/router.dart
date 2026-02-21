import 'package:go_router/go_router.dart';

import '../features/channels/channels_screen.dart';
import '../features/guide/guide_screen.dart';
import '../features/providers/providers_screen.dart';
import '../features/epg_mapping/epg_mapping_screen.dart';
import '../features/settings/settings_screen.dart';

final router = GoRouter(
  initialLocation: '/',
  routes: [
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
  ],
);
