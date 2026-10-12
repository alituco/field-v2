import 'package:field/src/profile/fieldrush_player_profile.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'staging_test_helpers.dart';

Future<Finder> _loadedViewedPlayer(
  WidgetTester tester, {
  required String expectedProfileId,
}) async {
  final screens = find.byType(ProfileScreen);
  await pumpUntilFound(
    tester,
    screens,
    reason: 'The player profile route did not open.',
  );
  final content = find.descendant(
    of: screens.last,
    matching: find.byType(FieldrushPlayerProfileContent),
  );
  await pumpUntilFound(
    tester,
    content,
    reason: 'The viewed player profile did not finish loading.',
  );
  expect(content, findsOneWidget);
  expect(
    tester.widget<FieldrushPlayerProfileContent>(content).profile.id,
    expectedProfileId,
    reason: 'The viewed profile loaded a different player.',
  );
  return content;
}

Future<void> returnFromViewedPlayerProfile(
  WidgetTester tester, {
  required String expectedProfileId,
}) async {
  final content = await _loadedViewedPlayer(
    tester,
    expectedProfileId: expectedProfileId,
  );
  await tapWhenVisible(
    tester,
    find.descendant(
      of: content,
      matching: find.byKey(const ValueKey('player-back')),
    ),
    reason: 'The loaded player profile did not expose a tappable Back control.',
  );
}

Future<void> openViewedPlayerReport(
  WidgetTester tester, {
  required String expectedProfileId,
}) async {
  final content = await _loadedViewedPlayer(
    tester,
    expectedProfileId: expectedProfileId,
  );
  await tapAfterScroll(
    tester,
    find.descendant(
      of: content,
      matching: find.byKey(const ValueKey('player-report')),
    ),
    reason:
        'The loaded player profile did not expose its Report player action.',
  );
}
