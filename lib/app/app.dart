import 'package:flutter/material.dart';

import 'router.dart';
import 'theme.dart';

class ClubTiviApp extends StatelessWidget {
  const ClubTiviApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'clubTivi',
      debugShowCheckedModeBanner: false,
      theme: ClubTiviTheme.dark,
      routerConfig: router,
    );
  }
}
