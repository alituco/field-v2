import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../clans/clan_repository.dart';
import '../clans/clan_widgets.dart';
import '../clans/clans_screen.dart';
import '../fixtures/fixture_repository.dart';
import '../fixtures/fixtures_screen.dart';
import '../leaderboard/leaderboard_repository.dart';
import '../leaderboard/leaderboard_screen.dart';
import '../open_queue/open_queue_repository.dart';
import '../profile/profile_repository.dart';
import '../profile/profile_screen.dart';
import 'dashboard_home.dart';
import 'field_bottom_nav.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.authRepository,
    this.isDev = false,
  });

  final AuthRepository authRepository;
  final bool isDev;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ClanRepository _clanRepository = SupabaseClanRepository();
  final FixtureRepository _fixtureRepository = SupabaseFixtureRepository();
  final ProfileRepository _profileRepository = SupabaseProfileRepository();
  final LeaderboardRepository _leaderboardRepository =
      SupabaseLeaderboardRepository();
  final OpenQueueRepository _openQueueRepository =
      SupabaseOpenQueueRepository();
  int _selectedIndex = 0;
  int _clansActivationTick = 0;
  int _ranksActivationTick = 0;
  int _playerRanksActivationTick = 0;
  bool _isSigningOut = false;

  void _selectTab(int index) {
    setState(() {
      if (index == 2) {
        _clansActivationTick++;
      }
      if (index == 3) {
        _ranksActivationTick++;
      }
      _selectedIndex = index;
    });
  }

  void _openPlayerRanks() {
    setState(() {
      _ranksActivationTick++;
      _playerRanksActivationTick++;
      _selectedIndex = 3;
    });
  }

  Future<void> _signOut() async {
    setState(() => _isSigningOut = true);
    try {
      await widget.authRepository.signOut();
    } finally {
      if (mounted) {
        setState(() => _isSigningOut = false);
      }
    }
  }

  Future<void> _switchUser(String profileId) {
    return widget.authRepository.switchToUserForDevelopment(profileId);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardHome(
        profileRepository: _profileRepository,
        clanRepository: _clanRepository,
        fixtureRepository: _fixtureRepository,
        leaderboardRepository: _leaderboardRepository,
        openQueueRepository: _openQueueRepository,
        onOpenClans: () => _selectTab(2),
        onOpenFixtures: () => _selectTab(1),
        onOpenRanks: _openPlayerRanks,
        onOpenProfile: () => _selectTab(4),
        onNavigateTab: _selectTab,
      ),
      FixturesScreen(
        fixtureRepository: _fixtureRepository,
        openQueueRepository: _openQueueRepository,
        onNavigateTab: _selectTab,
      ),
      ClansScreen(
        clanRepository: _clanRepository,
        fixtureRepository: _fixtureRepository,
        activationTick: _clansActivationTick,
      ),
      LeaderboardScreen(
        clanRepository: _clanRepository,
        fixtureRepository: _fixtureRepository,
        leaderboardRepository: _leaderboardRepository,
        activationTick: _ranksActivationTick,
        playerActivationTick: _playerRanksActivationTick,
      ),
      ProfileScreen(
        profileRepository: _profileRepository,
        fixtureRepository: _fixtureRepository,
        openQueueRepository: _openQueueRepository,
        devModeEnabled: widget.isDev,
        onSwitchUser: _switchUser,
        isSigningOut: _isSigningOut,
        onSignOut: _signOut,
      ),
    ];

    return Scaffold(
      backgroundColor: fieldBackground,
      body: IndexedStack(index: _selectedIndex, children: pages),
      bottomNavigationBar: FieldBottomNav(
        selectedIndex: _selectedIndex,
        onSelected: _selectTab,
      ),
    );
  }
}
