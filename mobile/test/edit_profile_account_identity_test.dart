import 'package:field/src/profile/edit_profile_screen.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'legacy profile editor keeps account identity read-only and saves bio',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _Repository();
      const profile = PlayerProfile(
        id: 'player',
        displayName: 'Alexanderson-With-A-Long-Name R.',
        username: 'alex.r',
        bio: 'Old bio',
        followingCount: 0,
        fansCount: 0,
        appearances: 0,
        goals: 0,
        assists: 0,
        highlights: [],
        career: [],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EditProfileScreen(
            profile: profile,
            profileRepository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      expect(tester.widget<TextField>(fields.at(0)).readOnly, isTrue);
      expect(tester.widget<TextField>(fields.at(1)).readOnly, isTrue);
      expect(tester.widget<TextField>(fields.at(2)).readOnly, isFalse);
      expect(
        find.textContaining(
          'Manage your name and username in Account settings.',
        ),
        findsOneWidget,
      );
      await tester.enterText(fields.at(2), 'My updated bio');
      await tester.tap(find.text('SAVE PROFILE'));
      await tester.pumpAndSettle();
      expect(repository.saved?.bio, 'My updated bio');
      expect(repository.saved?.displayName, profile.displayName);
      expect(repository.saved?.username, 'alex.r');
      expect(tester.takeException(), isNull);
    },
  );
}

class _Repository extends Fake implements ProfileRepository {
  ProfileUpdate? saved;

  @override
  Future<void> updateCurrentProfile(ProfileUpdate update) async {
    saved = update;
  }
}
