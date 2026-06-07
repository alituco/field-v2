import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../clans/clan_repository.dart';
import '../clans/clan_widgets.dart';
import '../clans/clans_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.authRepository});

  final AuthRepository authRepository;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ClanRepository _clanRepository = SupabaseClanRepository();
  int _selectedIndex = 0;
  bool _isSigningOut = false;

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

  @override
  Widget build(BuildContext context) {
    final pages = [
      _DashboardHome(
        authRepository: widget.authRepository,
        isSigningOut: _isSigningOut,
        onSignOut: _signOut,
        onOpenClans: () => setState(() => _selectedIndex = 2),
      ),
      const _ComingSoonScreen(
        title: 'Fixtures',
        icon: Icons.calendar_month_rounded,
        message: 'Match scheduling lands after clans are in place.',
      ),
      ClansScreen(clanRepository: _clanRepository),
      const _ComingSoonScreen(
        title: 'Ranks',
        icon: Icons.emoji_events_rounded,
        message: 'Clan leaderboards will use the same skill rating system.',
      ),
      _ProfileScreen(
        authRepository: widget.authRepository,
        isSigningOut: _isSigningOut,
        onSignOut: _signOut,
      ),
    ];

    return Scaffold(
      backgroundColor: fieldBackground,
      body: IndexedStack(index: _selectedIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        height: 68,
        indicatorColor: const Color(0xFFD1FAE5),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (index) =>
            setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month_rounded),
            label: 'Fixtures',
          ),
          NavigationDestination(
            icon: Icon(Icons.shield_outlined),
            selectedIcon: Icon(Icons.shield_rounded),
            label: 'Clans',
          ),
          NavigationDestination(
            icon: Icon(Icons.emoji_events_outlined),
            selectedIcon: Icon(Icons.emoji_events_rounded),
            label: 'Ranks',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
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

    return Column(
      children: [
        FieldPageHeader(
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
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
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
        ),
      ],
    );
  }
}

class _ComingSoonScreen extends StatelessWidget {
  const _ComingSoonScreen({
    required this.title,
    required this.icon,
    required this.message,
  });

  final String title;
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FieldPageHeader(title: title),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: fieldEmerald600, size: 42),
                  const SizedBox(height: 14),
                  Text(
                    title,
                    style: const TextStyle(
                      color: fieldGray900,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: fieldGray500,
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileScreen extends StatelessWidget {
  const _ProfileScreen({
    required this.authRepository,
    required this.isSigningOut,
    required this.onSignOut,
  });

  final AuthRepository authRepository;
  final bool isSigningOut;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final name = _displayName(authRepository) ?? 'Player';
    final phone = authRepository.currentUser?.phone ?? '';

    return Column(
      children: [
        FieldPageHeader(title: 'Profile'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: fieldGray200),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [fieldEmerald500, fieldBlue600],
                        ),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Center(
                        child: Text(
                          name.characters.first.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: const TextStyle(
                              color: fieldGray900,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            phone,
                            style: const TextStyle(color: fieldGray500),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: isSigningOut ? null : onSignOut,
                  icon: isSigningOut
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.logout_rounded),
                  label: const Text('Sign out'),
                ),
              ),
            ],
          ),
        ),
      ],
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
