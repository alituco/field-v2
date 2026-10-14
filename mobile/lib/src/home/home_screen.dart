import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../auth/fieldrush_account.dart';
import '../auth/fieldrush_account_screen.dart';
import '../auth/fieldrush_auth_theme.dart';
import '../clans/clan_repository.dart';
import '../clans/clan_widgets.dart';
import '../clans/clans_screen.dart';
import '../fixtures/fixture_repository.dart';
import '../fixtures/fixtures_screen.dart';
import '../leaderboard/leaderboard_repository.dart';
import '../leaderboard/leaderboard_screen.dart';
import '../leaderboard/fieldrush_rating_tracks.dart';
import '../moderation/account_restriction_screen.dart';
import '../moderation/moderation.dart';
import '../open_queue/open_queue_repository.dart';
import '../open_queue/open_queue.dart';
import '../open_queue/fieldrush_booking_flow.dart';
import '../open_queue/fieldrush_checkout_sheet.dart';
import '../open_queue/fieldrush_game_detail_screen.dart';
import '../profile/profile_repository.dart';
import '../profile/fieldrush_you_screen.dart';
import '../profile/fieldrush_you_settings.dart';
import '../reliability/reliability_repository.dart';
import '../support/support_repository.dart';
import '../ui/fieldrush_toast.dart';
import 'dashboard_home.dart';
import 'field_bottom_nav.dart';
import 'home_discovery_repository.dart';
import 'tab_refresh_policy.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.authRepository,
    required this.supportRepository,
    this.accountRepository,
    this.moderationStatus,
    this.isDev = false,
    this.profileSwitcherEnabled = false,
  });

  final AuthRepository authRepository;
  final SupportRepository supportRepository;
  final FieldrushAccountRepository? accountRepository;
  final ModerationStatus? moderationStatus;
  final bool isDev;
  final bool profileSwitcherEnabled;

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
  final ReliabilityRepository _reliabilityRepository =
      SupabaseReliabilityRepository();
  int _selectedIndex = 0;
  int _homeActivationTick = 0;
  int _fixturesActivationTick = 0;
  int _clansActivationTick = 0;
  int _ranksActivationTick = 0;
  int _playerRanksActivationTick = 0;
  int _youActivationTick = 0;
  final _tabRefresh = TabRefreshPolicy();
  final _ratingTrack = ValueNotifier(RatingTrack.outfield);
  bool _isSigningOut = false;
  String? _shownModerationNoticeSignature;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showModerationNotice();
    });
  }

  @override
  void dispose() {
    _ratingTrack.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.moderationStatus != widget.moderationStatus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showModerationNotice();
      });
    }
  }

  void _showModerationNotice() {
    if (!mounted) return;
    final status = widget.moderationStatus;
    if (status == null ||
        (!status.isPlayRestricted && status.state != ModerationState.warning)) {
      return;
    }

    final signature =
        '${status.state.name}:${status.scope.name}:'
        '${status.message}:${status.endsAt?.toIso8601String()}:'
        '${status.warningCount}';
    if (_shownModerationNoticeSignature == signature) return;
    _shownModerationNoticeSignature = signature;
    showFieldrushToastContent(
      context,
      ModerationStatusNoticeContent(status: status),
      duration: const Duration(seconds: 8),
      actionLabel: 'GOT IT',
      onAction: () {},
    );
  }

  void _selectTab(int index) {
    if (index == _selectedIndex) return;
    final refresh = _tabRefresh.activate(index);
    setState(() {
      if (refresh && index == 0) {
        _homeActivationTick++;
      }
      if (refresh && index == 1) _fixturesActivationTick++;
      if (refresh && index == 2) {
        _clansActivationTick++;
      }
      if (refresh && index == 3) {
        _ranksActivationTick++;
      }
      if (refresh && index == 4) _youActivationTick++;
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

  Future<void> _openSoloBooking(OpenQueueGame? game) async {
    await Navigator.of(context).push<OpenQueueBooking>(
      MaterialPageRoute(
        builder: (_) => FieldrushBookingFlow(
          repository: _openQueueRepository,
          initialGame: game,
          onNavigateTab: _selectTab,
        ),
      ),
    );
    if (mounted) {
      _tabRefresh.refreshed(0);
      _tabRefresh.refreshed(1);
      setState(() {
        _fixturesActivationTick++;
        _homeActivationTick++;
      });
    }
  }

  Future<void> _openSoloGame(OpenQueueGame game) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FieldrushGameDetailScreen(
          repository: _openQueueRepository,
          gameId: game.id,
          initialGame: game,
          profileRepository: _profileRepository,
          onNavigateTab: _selectTab,
          onJoin: (game) async {
            await showFieldrushCheckout(
              context: context,
              repository: _openQueueRepository,
              game: game,
            );
          },
        ),
      ),
    );
    if (mounted) {
      _tabRefresh.refreshed(0);
      _tabRefresh.refreshed(1);
      setState(() {
        _fixturesActivationTick++;
        _homeActivationTick++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardHome(
        ratingTrackController: _ratingTrack,
        activationTick: _homeActivationTick,
        profileRepository: _profileRepository,
        clanRepository: _clanRepository,
        fixtureRepository: _fixtureRepository,
        leaderboardRepository: _leaderboardRepository,
        openQueueRepository: _openQueueRepository,
        discoveryRepository: SupabaseHomeDiscoveryRepository(),
        onOpenClans: () => _selectTab(2),
        onOpenFixtures: () => _selectTab(1),
        onOpenRanks: _openPlayerRanks,
        onOpenProfile: () => _selectTab(4),
        onNavigateTab: _selectTab,
      ),
      FixturesScreen(
        fixtureRepository: _fixtureRepository,
        openQueueRepository: _openQueueRepository,
        clanRepository: _clanRepository,
        onNavigateTab: _selectTab,
        activationTick: _fixturesActivationTick,
        onPlay: _openSoloBooking,
        onOpenGame: _openSoloGame,
      ),
      ClansScreen(
        clanRepository: _clanRepository,
        fixtureRepository: _fixtureRepository,
        activationTick: _clansActivationTick,
      ),
      LeaderboardScreen(
        onFindGame: () => _openSoloBooking(null),
        ratingTrackController: _ratingTrack,
        clanRepository: _clanRepository,
        fixtureRepository: _fixtureRepository,
        leaderboardRepository: _leaderboardRepository,
        activationTick: _ranksActivationTick,
        playerActivationTick: _playerRanksActivationTick,
        onOpenYou: () => _selectTab(4),
      ),
      FieldrushYouScreen(
        ratingTrackController: _ratingTrack,
        activationTick: _youActivationTick,
        profileRepository: _profileRepository,
        leaderboardRepository: _leaderboardRepository,
        clanRepository: _clanRepository,
        fixtureRepository: _fixtureRepository,
        openQueueRepository: _openQueueRepository,
        reliabilityRepository: _reliabilityRepository,
        supportRepository: widget.supportRepository,
        accountRepository: widget.accountRepository,
        settingsRepository: SupabaseYouSettingsRepository(),
        onOpenRanks: _openPlayerRanks,
        profileSwitcherEnabled: widget.profileSwitcherEnabled,
        onSwitchUser: _switchUser,
        isSigningOut: _isSigningOut,
        onSignOut: _signOut,
        onOpenAccount: () async {
          if (widget.accountRepository == null) return;
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => FieldrushAccountScreen(
                authRepository: widget.authRepository,
                accountRepository: widget.accountRepository!,
                profileRepository: _profileRepository,
                bottomNavigationBuilder: (confirmLeave) => FieldBottomNav(
                  selectedIndex: 4,
                  onSelected: (index) async {
                    final navigator = Navigator.of(context);
                    if (!await confirmLeave() || !mounted) return;
                    navigator.pop();
                    _selectTab(index);
                  },
                ),
              ),
            ),
          );
        },
      ),
    ];

    return Scaffold(
      key: const ValueKey('home-screen'),
      extendBody: true,
      backgroundColor: _selectedIndex == 0 || _selectedIndex == 4
          ? FieldrushAuthTheme.cream
          : fieldBackground,
      body: IndexedStack(index: _selectedIndex, children: pages),
      bottomNavigationBar: FieldBottomNav(
        selectedIndex: _selectedIndex,
        onSelected: _selectTab,
      ),
    );
  }
}

class ModerationStatusNoticeContent extends StatelessWidget {
  const ModerationStatusNoticeContent({super.key, required this.status});

  final ModerationStatus status;

  @override
  Widget build(BuildContext context) {
    final isWarning = status.state == ModerationState.warning;
    final message = status.message.isNotEmpty
        ? status.message
        : isWarning
        ? 'A warning has been added to your account. Please keep Field safe and respectful.'
        : 'You cannot join or schedule matches right now, but you can still browse Field.';
    final endLabel = !isWarning && status.endsAt != null
        ? 'Until ${formatModerationDateTime(status.endsAt!)}'
        : null;
    final warningCountLabel = !isWarning
        ? null
        : status.warningCount > 0
        ? '${status.warningCount} account '
              '${status.warningCount == 1 ? 'warning' : 'warnings'}'
        : 'Warning recorded on your account';

    return Row(
      key: Key(
        isWarning ? 'account-warning-notice' : 'play-restriction-notice',
      ),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: const Color(0xFFF59E0B).withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            isWarning
                ? Icons.warning_amber_rounded
                : Icons.sports_soccer_rounded,
            color: const Color(0xFFFBBF24),
            size: 21,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isWarning ? 'ACCOUNT WARNING' : 'PLAY ACCESS PAUSED',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                message,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.78),
                  fontSize: 13,
                  height: 1.3,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (warningCountLabel != null) ...[
                const SizedBox(height: 3),
                Text(
                  warningCountLabel,
                  style: const TextStyle(
                    color: Color(0xFFFBBF24),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
              if (endLabel != null) ...[
                const SizedBox(height: 3),
                Text(
                  endLabel,
                  style: const TextStyle(
                    color: fieldEmerald500,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
