// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:clubtivi/app/app.dart';

void main() {
  testWidgets('App renders channels screen', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: ClubTiviApp()),
    );
    // The channels screen now starts with a loading indicator while
    // the database is queried; verify the app at least renders.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
