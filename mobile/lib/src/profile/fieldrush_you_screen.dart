import 'package:flutter/material.dart';
import '../ui/field_loading.dart';
import '../home/navigation_profile_scope.dart';

import '../auth/fieldrush_account.dart';
import '../auth/fieldrush_auth_theme.dart';
import '../clans/clan_repository.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture.dart';
import '../fixtures/fixture_detail_screen.dart';
import '../fixtures/fixture_repository.dart';
import '../leaderboard/leaderboard.dart';
import '../leaderboard/leaderboard_repository.dart';
import '../open_queue/fieldrush_game_detail_screen.dart';
import '../open_queue/open_queue_repository.dart';
import '../reliability/reliability.dart';
import '../reliability/reliability_repository.dart';
import '../reliability/reliability_status_card.dart';
import '../support/contact_support_sheet.dart';
import '../support/support_repository.dart';
import 'dev_user_switcher_sheet.dart';
import 'fieldrush_match_history_screen.dart';
import 'fieldrush_you_settings.dart';
import 'fieldrush_you_widgets.dart';
import 'profile.dart';
import 'profile_clip_screen.dart';
import 'profile_connections_screen.dart';
import 'profile_repository.dart';
import 'profile_screen.dart';

/// The signed-in player's private You tab. Public player profiles have a
/// separate route and never load account, wallet or notification settings.
class FieldrushYouScreen extends StatefulWidget {
  const FieldrushYouScreen({
    super.key,
    required this.profileRepository,
    required this.leaderboardRepository,
    required this.clanRepository,
    required this.fixtureRepository,
    required this.openQueueRepository,
    required this.settingsRepository,
    required this.onOpenAccount,
    required this.onOpenRanks,
    required this.onSignOut,
    this.accountRepository,
    this.reliabilityRepository,
    this.supportRepository,
    this.activationTick = 0,
    this.profileSwitcherEnabled = false,
    this.onSwitchUser,
    this.isSigningOut = false,
  });

  final ProfileRepository profileRepository;
  final LeaderboardRepository leaderboardRepository;
  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;
  final OpenQueueRepository openQueueRepository;
  final YouSettingsRepository settingsRepository;
  final FieldrushAccountRepository? accountRepository;
  final ReliabilityRepository? reliabilityRepository;
  final SupportRepository? supportRepository;
  final Future<void> Function() onOpenAccount;
  final VoidCallback onOpenRanks;
  final Future<void> Function() onSignOut;
  final int activationTick;
  final bool profileSwitcherEnabled;
  final Future<void> Function(String)? onSwitchUser;
  final bool isSigningOut;

  @override
  State<FieldrushYouScreen> createState() => _FieldrushYouScreenState();
}

class _FieldrushYouScreenState extends State<FieldrushYouScreen> {
  PlayerProfile? _profile;
  FieldrushAccount? _account;
  PlayerRatingLeaderboardEntry? _rating;
  ReliabilityStatus? _reliability;
  YouNotificationPreferences? _notifications;
  YouWallet? _wallet;
  LeaderboardSeason _season = activeLeaderboardSeason;
  bool _loading = true;
  Object? _error;
  int _loadVersion = 0;
  bool _openingGame = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant FieldrushYouScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activationTick != widget.activationTick) _load();
  }

  Future<void> _load() async {
    final version = ++_loadVersion;
    final navigationProfile = FieldNavigationProfileScope.beginRead(context);
    setState(() {
      // A refresh must not replace an already loaded rank/profile with a
      // skeleton on every navigation. First load still uses the full skeleton.
      _loading = _profile == null;
      _error = null;
    });
    Future<T?> optional<T>(Future<T> future) async {
      try {
        return await future;
      } catch (_) {
        return null;
      }
    }

    final season = activeLeaderboardSeason;
    try {
      final data = await Future.wait<Object?>([
        widget.profileRepository.getCurrentProfile(),
        optional(widget.leaderboardRepository.loadCurrentPlayerRating(season)),
        widget.accountRepository == null
            ? Future<FieldrushAccount?>.value()
            : optional(widget.accountRepository!.loadAccount()),
        widget.reliabilityRepository == null
            ? Future<ReliabilityStatus?>.value()
            : optional(widget.reliabilityRepository!.getMyStatus()),
        optional(widget.settingsRepository.loadNotifications()),
        optional(widget.settingsRepository.loadWallet()),
      ]);
      if (!mounted || version != _loadVersion) return;
      navigationProfile?.complete(data[0] as PlayerProfile);
      setState(() {
        _profile = data[0] as PlayerProfile;
        _rating = data[1] as PlayerRatingLeaderboardEntry?;
        _account = data[2] as FieldrushAccount?;
        _reliability = data[3] as ReliabilityStatus?;
        _notifications = data[4] as YouNotificationPreferences?;
        _wallet = data[5] as YouWallet?;
        _season = season;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  String get _cityLabel {
    final city = _account?.homeCity?.trim();
    if (city != null && city.isNotEmpty) return city;
    return switch (_account?.rankingRegion ?? _profile?.playerRating?.region) {
      'phoenix' => 'Phoenix, AZ',
      'bahrain' => 'Bahrain',
      _ => 'City unavailable',
    };
  }

  String? get _walletLabel {
    final wallet = _wallet;
    if (wallet == null) return 'Unavailable';
    final nonzero = wallet.balances.where((b) => b.balanceFils != 0).toList();
    if (nonzero.length > 1) return '${nonzero.length} balances';
    if (nonzero.isNotEmpty) return nonzero.single.label;
    return wallet.primaryBalance.label;
  }

  Future<void> _openAccount() async {
    await widget.onOpenAccount();
    if (mounted) await _load();
  }

  Future<void> _openConnections(ProfileConnectionTab tab) async {
    await Navigator.of(context).push<ProfileConnectionCounts>(
      MaterialPageRoute<ProfileConnectionCounts>(
        builder: (_) => ProfileConnectionsScreen(
          profileRepository: widget.profileRepository,
          username: _profile?.username,
          initialTab: tab,
          onOpenProfile: (id) async {
            if (id == widget.profileRepository.currentUserId) return;
            await Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => ProfileScreen(
                  profileId: id,
                  profileRepository: widget.profileRepository,
                  clanRepository: widget.clanRepository,
                  fixtureRepository: widget.fixtureRepository,
                  openQueueRepository: widget.openQueueRepository,
                  supportRepository: widget.supportRepository,
                ),
              ),
            );
          },
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openClip(ProfileHighlight clip) async {
    await Navigator.of(context).push<ProfileHighlight>(
      MaterialPageRoute(
        builder: (_) => ProfileClipScreen(
          highlight: clip,
          profileRepository: widget.profileRepository,
          canManage: true,
        ),
      ),
    );
    if (mounted) await _load();
  }

  void _openHistory() {
    final profile = _profile;
    if (profile == null) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (historyContext) => FieldrushMatchHistoryScreen(
          profile: profile,
          onOpenGame: (game) => _openGame(game, historyContext),
        ),
      ),
    );
  }

  Future<void> _openGame(
    ProfilePreviousGame game,
    BuildContext historyContext,
  ) async {
    if (_openingGame) return;
    _openingGame = true;
    try {
      final detail = game.isSolo
          ? await widget.openQueueRepository.getMatchDetail(game.id)
          : null;
      final fixture = game.isSolo
          ? null
          : await widget.fixtureRepository.getFixture(game.id);
      if (!mounted ||
          !historyContext.mounted ||
          ModalRoute.of(historyContext)?.isCurrent != true) {
        return;
      }
      final event = _profile?.playerRating?.events
          .where((e) => e.sourceId == game.id && e.isSolo == game.isSolo)
          .firstOrNull;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => game.isSolo
              ? FieldrushGameDetailScreen(
                  repository: widget.openQueueRepository,
                  gameId: game.id,
                  initialDetail: detail,
                  profileRepository: widget.profileRepository,
                  fixtureRepository: widget.fixtureRepository,
                  playerRatingUpdate: event == null
                      ? detail?.viewerRatingUpdate
                      : FixturePlayerRatingUpdate(
                          ratingBefore: event.ratingBefore,
                          ratingChange: event.ratingChange,
                          ratingAfter: event.ratingAfter,
                          result: event.result,
                          scoreMargin: event.scoreMargin,
                          marginMultiplier: event.marginMultiplier,
                          baseRatingChange: event.baseRatingChange,
                          marginBonusApplied: event.marginBonusApplied,
                        ),
                )
              : Theme(
                  data: FieldrushAuthTheme.theme(context),
                  child: FixtureDetailScreen(
                    fixture: fixture!,
                    fixtureRepository: widget.fixtureRepository,
                    clanRepository: widget.clanRepository,
                    profileRepository: widget.profileRepository,
                    myClanMembership: null,
                    sourceLabel: game.typeLabel,
                    playerRatingUpdate: event == null
                        ? null
                        : FixturePlayerRatingUpdate(
                            ratingBefore: event.ratingBefore,
                            ratingChange: event.ratingChange,
                            ratingAfter: event.ratingAfter,
                            result: event.result,
                            scoreMargin: event.scoreMargin,
                            marginMultiplier: event.marginMultiplier,
                            baseRatingChange: event.baseRatingChange,
                            marginBonusApplied: event.marginBonusApplied,
                          ),
                  ),
                ),
        ),
      );
    } catch (error) {
      if (mounted &&
          historyContext.mounted &&
          ModalRoute.of(historyContext)?.isCurrent == true) {
        _showError(error, 'We could not open this match. Try again.');
      }
    } finally {
      _openingGame = false;
    }
  }

  Future<void> _openNotifications() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            YouNotificationsScreen(repository: widget.settingsRepository),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openWallet() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => YouWalletScreen(repository: widget.settingsRepository),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openReliability() async {
    final repository = widget.reliabilityRepository;
    if (repository == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Theme(
          data: FieldrushAuthTheme.theme(context),
          child: Scaffold(
            backgroundColor: FieldrushAuthTheme.cream,
            appBar: AppBar(title: const Text('Reliability')),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [ReliabilityStatusCard(repository: repository)],
            ),
          ),
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Theme(
        data: FieldrushAuthTheme.theme(context),
        child: AlertDialog(
          title: const Text('Sign out?'),
          content: const Text(
            'You can sign back in with your phone or linked Google account.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Stay signed in'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.onSignOut();
    } catch (error) {
      if (mounted) _showError(error, 'We could not sign you out. Try again.');
    }
  }

  Future<void> _support() async {
    final repository = widget.supportRepository;
    if (repository == null) return;
    final receipt = await showContactSupportSheet(
      context: context,
      repository: repository,
    );
    if (mounted && receipt != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Request sent · reference ${receipt.shortReference}'),
        ),
      );
    }
  }

  void _showError(Object error, String fallback) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(userFacingError(error, fallback: fallback))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: ColoredBox(
        color: FieldrushAuthTheme.cream,
        child: SafeArea(
          bottom: false,
          child: profile == null
              ? _loading
                    ? ListView(
                        key: const ValueKey('you-loading'),
                        padding: const EdgeInsets.only(bottom: 132),
                        children: const [FieldrushYouLoadingContent()],
                      )
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Could not load your profile',
                                style: TextStyle(
                                  fontFamily: 'Outfit',
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                userFacingError(
                                  _error,
                                  fallback: 'Try again in a moment.',
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: _load,
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      )
              : FieldRefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    key: const ValueKey('you-content'),
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 132),
                    children: [
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'Could not refresh your profile. Pull down to retry.',
                            style: const TextStyle(
                              color: FieldrushAuthTheme.danger,
                            ),
                          ),
                        ),
                      FieldrushYouContent(
                        profile: profile,
                        rating: _rating,
                        ratingLoading: _loading,
                        ratingUnavailable: !_loading && _rating == null,
                        recentResults: fieldrushSeasonResults(
                          profile,
                          _season,
                          region: _rating?.region,
                        ),
                        cityLabel: _cityLabel,
                        emailUnverified:
                            _account != null && !_account!.emailVerified,
                        reliability: _reliability,
                        reliabilityLoading: _loading,
                        reliabilityUnavailable:
                            !_loading && _reliability == null,
                        walletLabel: _loading ? 'Loading…' : _walletLabel,
                        notificationLabel: _loading
                            ? 'Loading…'
                            : _notifications == null
                            ? 'Unavailable'
                            : '${_notifications!.enabledCount} on',
                        paymentMethodsLabel: 'At checkout',
                        onEdit: _openAccount,
                        onFollowing: () =>
                            _openConnections(ProfileConnectionTab.following),
                        onFans: () =>
                            _openConnections(ProfileConnectionTab.fans),
                        onRanks: widget.onOpenRanks,
                        onMatchHistory: _openHistory,
                        onClip: _openClip,
                        onReliability: _openReliability,
                        onNotifications: _openNotifications,
                        onWallet: _openWallet,
                        onPaymentMethods: () =>
                            Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) => const YouPaymentMethodsScreen(),
                              ),
                            ),
                        onSignOut: _signOut,
                        isSigningOut: widget.isSigningOut,
                        onSupport: widget.supportRepository == null
                            ? null
                            : _support,
                        onSwitchUser:
                            !widget.profileSwitcherEnabled ||
                                widget.onSwitchUser == null
                            ? null
                            : () => showDevUserSwitcher(
                                context: context,
                                profileRepository: widget.profileRepository,
                                currentUserId: profile.id,
                                onSwitchUser: widget.onSwitchUser!,
                              ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

List<ProfileRatingEvent> fieldrushSeasonResults(
  PlayerProfile profile,
  LeaderboardSeason season, {
  String? region,
}) {
  final offset = region == 'bahrain'
      ? const Duration(hours: 3)
      : const Duration(hours: -7);
  final start = DateTime.parse('${season.startsOn}T00:00:00Z');
  final end = DateTime.parse(
    '${season.endsOn}T00:00:00Z',
  ).add(const Duration(days: 1));
  final events =
      (profile.playerRating?.currentPeriodEvents ?? <ProfileRatingEvent>[])
          .where((event) {
            final marketTime = event.playedAt.toUtc().add(offset);
            return !marketTime.isBefore(start) &&
                marketTime.isBefore(end) &&
                ['WIN', 'DRAW', 'LOSS'].contains(event.result);
          })
          .toList()
        ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
  return events.take(5).toList();
}
