import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../clans/clan_repository.dart';
import '../clans/clan_widgets.dart';
import '../clans/clans_screen.dart';
import '../fixtures/fixture_repository.dart';
import '../fixtures/fixtures_screen.dart';
import '../leaderboard/leaderboard_repository.dart';
import '../leaderboard/leaderboard_screen.dart';
import '../profile/profile_repository.dart';
import '../profile/profile_screen.dart';

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
  int _selectedIndex = 0;
  int _clansActivationTick = 0;
  bool _isSigningOut = false;

  void _selectTab(int index) {
    setState(() {
      if (index == 2) {
        _clansActivationTick++;
      }
      _selectedIndex = index;
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
      _DashboardHome(
        authRepository: widget.authRepository,
        isSigningOut: _isSigningOut,
        onSignOut: _signOut,
        onOpenClans: () => _selectTab(2),
      ),
      FixturesScreen(fixtureRepository: _fixtureRepository),
      ClansScreen(
        clanRepository: _clanRepository,
        fixtureRepository: _fixtureRepository,
        activationTick: _clansActivationTick,
      ),
      LeaderboardScreen(
        clanRepository: _clanRepository,
        fixtureRepository: _fixtureRepository,
        leaderboardRepository: _leaderboardRepository,
      ),
      ProfileScreen(
        profileRepository: _profileRepository,
        devModeEnabled: widget.isDev,
        onSwitchUser: _switchUser,
        isSigningOut: _isSigningOut,
        onSignOut: _signOut,
      ),
    ];

    return Scaffold(
      extendBody: true,
      backgroundColor: fieldBackground,
      body: IndexedStack(index: _selectedIndex, children: pages),
      bottomNavigationBar: _FieldBottomNav(
        selectedIndex: _selectedIndex,
        onSelected: _selectTab,
      ),
    );
  }
}

class _FieldBottomNav extends StatelessWidget {
  const _FieldBottomNav({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const _items = [
    _FieldBottomNavItem(
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
      label: 'Home',
    ),
    _FieldBottomNavItem(
      icon: Icons.calendar_month_outlined,
      selectedIcon: Icons.calendar_month_rounded,
      label: 'Fixtures',
    ),
    _FieldBottomNavItem(
      icon: Icons.shield_outlined,
      selectedIcon: Icons.shield_rounded,
      label: 'Clans',
    ),
    _FieldBottomNavItem(
      icon: Icons.emoji_events_outlined,
      selectedIcon: Icons.emoji_events_rounded,
      label: 'Ranks',
    ),
    _FieldBottomNavItem(
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
      label: 'Profile',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(36),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            height: 70,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(36),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.74),
                  Colors.white.withValues(alpha: 0.54),
                  Colors.white.withValues(alpha: 0.42),
                ],
                stops: const [0, 0.42, 1],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.70),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: fieldGray900.withValues(alpha: 0.11),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                ),
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.38),
                  blurRadius: 1,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(
                children: [
                  for (var i = 0; i < _items.length; i++)
                    Expanded(
                      child: _FieldBottomNavButton(
                        item: _items[i],
                        isActive: selectedIndex == i,
                        onTap: () => onSelected(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldBottomNavItem {
  const _FieldBottomNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _FieldBottomNavButton extends StatelessWidget {
  const _FieldBottomNavButton({
    required this.item,
    required this.isActive,
    required this.onTap,
  });

  final _FieldBottomNavItem item;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isActive
        ? fieldGray900
        : fieldGray900.withValues(alpha: 0.74);

    return Semantics(
      selected: isActive,
      button: true,
      label: item.label,
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        borderRadius: BorderRadius.circular(28),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          height: double.infinity,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: isActive
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.72),
                      Colors.white.withValues(alpha: 0.36),
                    ],
                  )
                : null,
            border: isActive
                ? Border.all(color: Colors.white.withValues(alpha: 0.60))
                : null,
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.42),
                      blurRadius: 20,
                      offset: const Offset(0, 0),
                    ),
                    BoxShadow(
                      color: fieldGray900.withValues(alpha: 0.12),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: AnimatedScale(
              scale: isActive ? 1.12 : 1,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: Icon(
                isActive ? item.selectedIcon : item.icon,
                size: isActive ? 30 : 29,
                color: color,
                weight: isActive ? 2.6 : 2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashboardHome extends StatelessWidget {
  const _DashboardHome({
    required this.authRepository,
    required this.isSigningOut,
    required this.onSignOut,
    required this.onOpenClans,
  });

  final AuthRepository authRepository;
  final bool isSigningOut;
  final VoidCallback onSignOut;
  final VoidCallback onOpenClans;

  @override
  Widget build(BuildContext context) {
    final user = authRepository.currentUser;
    final name = _displayName(authRepository);
    final phone = user?.phone ?? 'Signed in';

    return FieldHeaderOverlay(
      header: FieldPageHeader(
        title: 'Field',
        rightAction: IconButton(
          onPressed: isSigningOut ? null : onSignOut,
          tooltip: 'Sign out',
          icon: isSigningOut
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.logout_rounded),
        ),
      ),
      child: ListView(
        padding: fieldHeaderAwarePadding(context, top: 24, bottom: 124),
        children: [
          FieldHeroBanner(
            eyebrow: 'Field FC',
            title: 'The pitch is calling.',
            subtitle: 'Rally your clan and take the field.',
            icon: Icons.sports_soccer_rounded,
            chips: const [
              HeroChip(label: 'Live', value: 'Auth'),
              HeroChip(label: 'Next', value: 'Clans'),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: fieldGray200),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Welcome back',
                  style: TextStyle(
                    color: fieldGray900,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  name ?? phone,
                  style: const TextStyle(
                    color: fieldGray600,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (name != null) ...[
                  const SizedBox(height: 2),
                  Text(phone, style: const TextStyle(color: fieldGray500)),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onOpenClans,
                    icon: const Icon(Icons.shield_rounded),
                    label: const Text('Open Clans'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String? _displayName(AuthRepository authRepository) {
  final metadata = authRepository.currentUser?.userMetadata;
  final displayName = metadata?['display_name'] ?? metadata?['name'];
  if (displayName is String && displayName.trim().isNotEmpty) {
    return displayName.trim();
  }
  return null;
}
