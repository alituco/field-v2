import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/leaderboard/leaderboard_screen.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final region in <String?>['phoenix', 'bahrain', null]) {
    testWidgets('player ladder uses server region $region', (tester) async {
      final rankings = _Rankings();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LeaderboardScreen(
              clanRepository: _Clans(),
              fixtureRepository: _Fixtures(),
              leaderboardRepository: rankings,
              profileRepository: _Profiles(region),
            ),
          ),
        ),
      );
      // The active-season badge intentionally pulses indefinitely.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(rankings.requestedRegion, region ?? 'phoenix');
      await tester.tap(find.text('Players'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.text(
          '${region == 'bahrain' ? 'Bahrain' : 'Phoenix, AZ'} · Season rankings',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

class _Profiles extends Fake implements ProfileRepository {
  _Profiles(this.region);
  final String? region;

  @override
  Future<PlayerProfile> getCurrentProfile() async => PlayerProfile(
    id: 'current-player',
    displayName: 'Current Player',
    username: 'current_player',
    bio: '',
    followingCount: 0,
    fansCount: 0,
    appearances: 0,
    goals: 0,
    assists: 0,
    highlights: const [],
    career: const [],
    playerRating: region == null
        ? null
        : ProfilePlayerRating(
            skillRating: 1200,
            matchesPlayed: 0,
            wins: 0,
            losses: 0,
            draws: 0,
            lastChange: 0,
            region: region!,
            events: const [],
          ),
  );
}

class _Rankings extends Fake implements LeaderboardRepository {
  String? requestedRegion;

  @override
  Future<List<PlayerRatingLeaderboardEntry>> loadPlayerRatingLeaderboard({
    required LeaderboardSeason season,
    String region = 'phoenix',
  }) async {
    requestedRegion = region;
    return [];
  }

  @override
  Future<LeaderboardPlayerStats> loadPlayerStats(
    LeaderboardSeason season,
  ) async => const LeaderboardPlayerStats(
    finalMatchCount: 0,
    clanRecords: {},
    topScorers: [],
    topAssisters: [],
  );
}

class _Clans extends Fake implements ClanRepository {
  @override
  Future<List<Clan>> listClans() async => [];
  @override
  Future<ClanMembership?> getMyClanMembership() async => null;
}

class _Fixtures extends Fake implements FixtureRepository {}
