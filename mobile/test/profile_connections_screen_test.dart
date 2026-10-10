import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_connections_screen.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tapping a following row opens that player profile', (
    tester,
  ) async {
    String? openedProfileId;

    await tester.pumpWidget(
      MaterialApp(
        home: ProfileConnectionsScreen(
          profileRepository: _ConnectionsRepository(),
          initialTab: ProfileConnectionTab.following,
          onOpenProfile: (profileId) async {
            openedProfileId = profileId;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ali Altaraif'));
    await tester.pump();

    expect(openedProfileId, 'ali-profile');
    expect(tester.takeException(), isNull);
  });
}

class _ConnectionsRepository implements ProfileRepository {
  @override
  String? get currentUserId => 'current-profile';

  @override
  Future<ProfileConnections> getConnections() async {
    const ali = ProfileConnection(
      id: 'ali-profile',
      displayName: 'Ali Altaraif',
      username: 'aliiii',
      isFollowedByMe: true,
    );
    return const ProfileConnections(following: [ali], fans: [], discover: []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
