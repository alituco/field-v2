import 'package:flutter/material.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_modal.dart';
import '../ui/fieldrush_toast.dart';
import '../home/navigation_profile_scope.dart';

import '../auth/fieldrush_account.dart';
import '../auth/fieldrush_auth_theme.dart';
import '../clans/clan_repository.dart';
import '../core/user_facing_error.dart';
import '../core/read_timeout.dart';
import '../fixtures/fixture.dart';
import '../fixtures/fixture_detail_screen.dart';
import '../fixtures/fixture_repository.dart';
import '../leaderboard/leaderboard.dart';
import '../leaderboard/leaderboard_repository.dart';
import '../leaderboard/fieldrush_rating_tracks.dart';
import '../leaderboard/fieldrush_seasons.dart';
import '../open_queue/fieldrush_game_detail_screen.dart';
import '../open_queue/fieldrush_booking_flow.dart';
import '../open_queue/open_queue_repository.dart';
import '../reliability/reliability.dart';
import '../reliability/reliability_repository.dart';
import '../reliability/fieldrush_reliability_screen.dart';
import '../ranking/fieldrush_divisions_screen.dart';
import '../referrals/referrals.dart';
import '../referrals/referral_repository.dart';
import '../referrals/referral_share.dart';
import '../referrals/fieldrush_referral_widgets.dart';
import '../referrals/fieldrush_referral_screens.dart';
import '../support/contact_support_sheet.dart';
import '../support/support_repository.dart';
import 'dev_user_switcher_sheet.dart';
import 'fieldrush_match_history_screen.dart';
import 'fieldrush_you_settings.dart';
import 'fieldrush_you_widgets.dart';
import 'profile.dart';
import 'player_safety_repository.dart';
import 'blocked_players_screen.dart';
import 'profile_clip_screen.dart';
import 'profile_clips_screen.dart';
import 'profile_connections_screen.dart';
import 'profile_repository.dart';
import 'player_history_repository.dart';
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
    this.ratingTrackController,
    this.onNavigateTab,
    this.referralRepository,
    this.historyRepository,
    this.playerSafetyRepository,
  });

  final ProfileRepository profileRepository;
  final PlayerSafetyRepository? playerSafetyRepository;
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
  final ValueNotifier<RatingTrack>? ratingTrackController;
  final ValueChanged<int>? onNavigateTab;
  final ReferralRepository? referralRepository;
  final PlayerHistoryRepository? historyRepository;

  @override
  State<FieldrushYouScreen> createState() => _FieldrushYouScreenState();
}

class _FieldrushYouScreenState extends State<FieldrushYouScreen> {
  late final PlayerHistoryRepository _defaultHistoryRepository =
      SupabasePlayerHistoryRepository();
  PlayerHistoryRepository get _historyRepository =>
      widget.historyRepository ?? _defaultHistoryRepository;
  PlayerProfile? _profile;
  FieldrushAccount? _account;
  PlayerRatingLeaderboardEntry? _rating;
  FieldrushPlayerRatings? _ratings;
  RatingTrack _ratingTrack = RatingTrack.outfield;
  ReliabilityStatus? _reliability;
  YouNotificationPreferences? _notifications;
  YouWallet? _wallet;
  LeaderboardSeason _season = activeLeaderboardSeason;
  bool _loading = true;
  bool _profileDetailsReady = false;
  bool _profileDetailsLoading = true;
  String? _requestUserId;
  bool _ratingLoading = true;
  bool _reliabilityLoading = true;
  bool _walletLoading = true;
  bool _notificationsLoading = true;
  final Set<String> _failedSections = {};
  Object? _error;
  int _loadVersion = 0;
  bool _openingGame = false;
  ReferralSummary? _referrals;
  bool _referralsLoading = true;
  bool _sharingReferral = false;

  @override
  void initState() {
    super.initState();
    _ratingTrack = widget.ratingTrackController?.value ?? RatingTrack.outfield;
    widget.ratingTrackController?.addListener(_syncRatingTrack);
    _load();
  }

  @override
  void didUpdateWidget(covariant FieldrushYouScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ratingTrackController != widget.ratingTrackController) {
      oldWidget.ratingTrackController?.removeListener(_syncRatingTrack);
      widget.ratingTrackController?.addListener(_syncRatingTrack);
      _syncRatingTrack();
    }
    final userChanged =
        _requestUserId != widget.profileRepository.currentUserId;
    if (userChanged) {
      _profile = null;
      _profileDetailsReady = false;
      _account = null;
      _rating = null;
      _ratings = null;
      _reliability = null;
      _notifications = null;
      _wallet = null;
      _referrals = null;
    }
    if (userChanged ||
        oldWidget.profileRepository != widget.profileRepository ||
        oldWidget.accountRepository != widget.accountRepository ||
        oldWidget.referralRepository != widget.referralRepository ||
        oldWidget.activationTick != widget.activationTick) {
      _load();
    }
  }

  @override
  void dispose() {
    widget.ratingTrackController?.removeListener(_syncRatingTrack);
    super.dispose();
  }

  void _syncRatingTrack() {
    if (!mounted) return;
    setState(() {
      _ratingTrack =
          widget.ratingTrackController?.value ?? RatingTrack.outfield;
      if (_ratings != null) _rating = _ratings!.forTrack(_ratingTrack);
    });
  }

  void _chooseRatingTrack(RatingTrack track) {
    if (widget.ratingTrackController != null) {
      widget.ratingTrackController!.value = track;
    } else {
      setState(() {
        _ratingTrack = track;
        _rating = _ratings?.forTrack(track);
      });
    }
  }

  void _openDivisions() {
    final navigator = Navigator.of(context);
    navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => FieldrushDivisionsScreen(
          rating: _ratings?.forTrack(_ratingTrack) ?? _rating,
          prediction: _ratings?.predictionFor(_ratingTrack),
          track: _ratingTrack,
          season: _season,
          cityName: _ratings?.primaryCityName ?? _rating?.region,
          selectedTab: 4,
          onOpenRanks: () {
            navigator.pop();
            widget.onOpenRanks();
          },
          onNavigateTab: widget.onNavigateTab == null
              ? null
              : (index) {
                  navigator.pop();
                  widget.onNavigateTab!(index);
                },
        ),
      ),
    );
  }

  Future<void> _load() async {
    final version = ++_loadVersion;
    final repository = widget.profileRepository;
    final userId = _requestUserId = repository.currentUserId;
    final navigationProfile = FieldNavigationProfileScope.beginRead(context);
    setState(() {
      _loading = _profile == null;
      _profileDetailsLoading = !_profileDetailsReady;
      _ratingLoading = _rating == null;
      _reliabilityLoading = _reliability == null;
      _walletLoading = _wallet == null;
      _notificationsLoading = _notifications == null;
      _referralsLoading = _referrals == null;
      _error = null;
      _failedSections.clear();
    });
    bool current() =>
        mounted &&
        version == _loadVersion &&
        identical(widget.profileRepository, repository) &&
        repository.currentUserId == userId;
    Future<void> section<T>(
      String label,
      Future<T> Function() request,
      void Function(T) receive, {
      VoidCallback? finished,
    }) async {
      try {
        final value = await request().timeout(fieldReadTimeout);
        if (current()) setState(() => receive(value));
      } catch (error) {
        if (current()) {
          setState(() {
            if (label != 'your profile' || _profile == null) {
              _failedSections.add(label);
            }
            if (label == 'your profile' || label == 'profile details') {
              _error = error;
            }
          });
        }
      } finally {
        if (current() && finished != null) setState(finished);
      }
    }

    // Identity, rank and optional settings publish independently. A slow wallet
    // or notifications request must not hide a completed profile or SR update.
    await Future.wait<void>([
      if (repository is ProfileSummaryRepository)
        section(
          'your profile',
          (repository as ProfileSummaryRepository).getCurrentProfileSummary,
          (profile) {
            if (!_profileDetailsReady) {
              navigationProfile?.complete(profile);
              _profile = profile;
              _loading = false;
            }
          },
        ),
      section(
        'profile details',
        widget.profileRepository.getCurrentProfile,
        (profile) {
          navigationProfile?.complete(profile);
          _profile = profile;
          _profileDetailsReady = true;
          _failedSections.remove('your profile');
        },
        finished: () {
          _loading = false;
          _profileDetailsLoading = false;
        },
      ),
      section(
        'rating',
        () async {
          final season = await loadActiveLeaderboardSeason(
            widget.leaderboardRepository,
          ).timeout(fieldReadTimeout);
          final repository = widget.leaderboardRepository;
          final Object rating = repository is TrackLeaderboardRepository
              ? await (repository as TrackLeaderboardRepository)
                    .loadPlayerRatings(season: season)
              : await repository.loadCurrentPlayerRating(season);
          return (season: season, rating: rating);
        },
        (value) {
          _season = value.season;
          _ratings = value.rating is FieldrushPlayerRatings
              ? value.rating as FieldrushPlayerRatings
              : null;
          _rating =
              _ratings?.forTrack(_ratingTrack) ??
              (value.rating is PlayerRatingLeaderboardEntry
                  ? value.rating as PlayerRatingLeaderboardEntry
                  : null);
        },
        finished: () => _ratingLoading = false,
      ),
      if (widget.accountRepository case final repository?)
        section('account', repository.loadAccount, (value) => _account = value),
      if (widget.referralRepository case final repository?)
        section(
          'referrals',
          repository.load,
          (value) => _referrals = value,
          finished: () => _referralsLoading = false,
        ),
      section(
        'reliability',
        () async => await widget.reliabilityRepository?.getMyStatus(),
        (value) => _reliability = value,
        finished: () => _reliabilityLoading = false,
      ),
      section(
        'notification settings',
        widget.settingsRepository.loadNotifications,
        (value) => _notifications = value,
        finished: () => _notificationsLoading = false,
      ),
      section(
        'wallet',
        widget.settingsRepository.loadWallet,
        (value) => _wallet = value,
        finished: () => _walletLoading = false,
      ),
    ]);
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

  Future<void> _shareReferral() async {
    final code = _referrals?.ownCode;
    if (code == null || code.isEmpty || _sharingReferral) return;
    _sharingReferral = true;
    try {
      await shareFieldrushReferralCode(context, code);
    } catch (error) {
      if (mounted) {
        showFieldrushToast(
          context,
          userFacingError(
            error,
            fallback: 'Could not open sharing. Try again.',
          ),
        );
      }
    } finally {
      _sharingReferral = false;
    }
  }

  void _openReferralPlayer(String id) {
    if (id == _profile?.id) return;
    Navigator.of(context).push<void>(
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
  }

  Future<void> _openReferrals({bool enterCode = false}) async {
    final repository = widget.referralRepository;
    if (repository == null) return;
    final navigator = Navigator.of(context);
    final ownerRoute = ModalRoute.of(context);
    void navigate(int index) {
      navigator.popUntil((route) => route == ownerRoute);
      widget.onNavigateTab?.call(index);
    }

    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => enterCode
            ? FieldrushReferralCodeScreen(
                repository: repository,
                onOpenPlayer: _openReferralPlayer,
                onNavigateTab: widget.onNavigateTab == null ? null : navigate,
              )
            : FieldrushReferralsScreen(
                repository: repository,
                onOpenPlayer: _openReferralPlayer,
                onNavigateTab: widget.onNavigateTab == null ? null : navigate,
              ),
      ),
    );
    if (mounted) await _load();
  }

  Widget? get _referralSection {
    if (widget.referralRepository == null) return null;
    final summary = _referrals;
    if (summary != null) {
      return FieldrushReferralCard(
        summary: summary,
        onShare: _shareReferral,
        onOpenLeaderboard: () => _openReferrals(),
        onOpenCode: () => _openReferrals(enterCode: true),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'REFERRALS',
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.54,
              color: FieldrushAuthTheme.muted,
            ),
          ),
          const SizedBox(height: 11),
          if (_referralsLoading)
            const SizedBox(
              height: 40,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FieldLoadingIndicator(),
              ),
            )
          else
            TextButton(
              onPressed: _load,
              child: const Text('Could not load referrals. Retry'),
            ),
        ],
      ),
    );
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
          ownerLabel: _profile == null ? null : '@${_profile!.username}',
          ownerAvatarUrl: _profile?.avatarUrl,
          ownerInitials: _profile?.initials,
          fixtureRepository: widget.fixtureRepository,
          openQueueRepository: widget.openQueueRepository,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openAllClips() async {
    final profile = _profile;
    if (profile == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProfileClipsScreen(
          profile: profile,
          repository: widget.profileRepository,
          canManage: true,
          fixtureRepository: widget.fixtureRepository,
          openQueueRepository: widget.openQueueRepository,
        ),
      ),
    );
    if (mounted) await _load();
  }

  void _openHistory() {
    final profile = _profile;
    if (profile == null || !_profileDetailsReady) return;
    final ownerRoute = ModalRoute.of(context);
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (historyContext) => FieldrushMatchHistoryScreen(
          profile: profile,
          ratingEvents: _ratings?.mergeHistory(
            profile.playerRating?.events ?? const [],
          ),
          onOpenGame: (game) => _openGame(game, historyContext),
          historyRepository: _historyRepository,
          onFindAnotherGame: () => _findAnotherGame(ownerRoute),
        ),
      ),
    );
  }

  Future<void> _findAnotherGame(Route<dynamic>? ownerRoute) async {
    final navigator = Navigator.of(context);
    navigator.popUntil(
      (route) => ownerRoute == null ? route.isFirst : route == ownerRoute,
    );
    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => FieldrushBookingFlow(
          repository: widget.openQueueRepository,
          onNavigateTab: widget.onNavigateTab == null
              ? null
              : (index) {
                  navigator.popUntil(
                    (route) => ownerRoute == null
                        ? route.isFirst
                        : route == ownerRoute,
                  );
                  widget.onNavigateTab!(index);
                },
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openGame(
    ProfilePreviousGame game,
    BuildContext historyContext,
  ) async {
    if (_openingGame) return;
    _openingGame = true;
    try {
      final detail = game.isSolo
          ? await widget.openQueueRepository
                .getMatchDetail(game.id)
                .timeout(fieldReadTimeout)
          : null;
      final fixture = game.isSolo
          ? null
          : await widget.fixtureRepository
                .getFixture(game.id)
                .timeout(fieldReadTimeout);
      if (!mounted ||
          !historyContext.mounted ||
          ModalRoute.of(historyContext)?.isCurrent != true) {
        return;
      }
      final events =
          _ratings?.mergeHistory(_profile?.playerRating?.events ?? const []) ??
          _profile?.playerRating?.events;
      final event = events
          ?.where((e) => e.sourceId == game.id && e.isSolo == game.isSolo)
          .firstOrNull;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => game.isSolo
              ? FieldrushGameDetailScreen(
                  repository: widget.openQueueRepository,
                  gameId: game.id,
                  initialDetail: detail,
                  ratingStatus: event?.ratingStatus,
                  ratingExplanation: event?.publicRatingExplanation,
                  countedAsPlayed: event?.countedAsPlayed,
                  profileRepository: widget.profileRepository,
                  fixtureRepository: widget.fixtureRepository,
                  playerRatingUpdate: event == null
                      ? detail?.viewerRatingUpdate
                      : !event.hasPublicRating
                      ? null
                      : FixturePlayerRatingUpdate(
                          ratingBefore: event.ratingBefore!,
                          ratingChange: event.ratingChange!,
                          ratingAfter: event.ratingAfter!,
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
                    playerRatingUpdate: event == null || !event.hasPublicRating
                        ? null
                        : FixturePlayerRatingUpdate(
                            ratingBefore: event.ratingBefore!,
                            ratingChange: event.ratingChange!,
                            ratingAfter: event.ratingAfter!,
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

  PlayerSafetyRepository? get _safetyRepository =>
      widget.playerSafetyRepository ??
      playerSafetyFor(widget.profileRepository);

  Future<void> _openBlockedPlayers() async {
    final repository = _safetyRepository;
    if (repository == null) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BlockedPlayersScreen(repository: repository),
      ),
    );
    if (mounted) await _load();
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
        builder: (_) => FieldrushReliabilityScreen(
          repository: repository,
          onNavigateTab: widget.onNavigateTab,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _signOut() async {
    final confirmed = await showFieldrushModal<bool>(
      context: context,
      builder: (context) => FieldrushModal(
        title: 'Sign out?',
        description:
            'You can sign back in with your phone or linked Google account.',
        actions: [
          FilledButton(
            key: const ValueKey('fieldrush-sign-out-confirm'),
            onPressed: () => Navigator.pop(context, true),
            style: FieldrushModal.primaryButtonStyle(destructive: true),
            child: const Text('Sign out'),
          ),
          OutlinedButton(
            key: const ValueKey('fieldrush-sign-out-cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay signed in'),
          ),
        ],
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
      showFieldrushToast(
        context,
        'Request sent · reference ${receipt.shortReference}',
      );
    }
  }

  void _showError(Object error, String fallback) {
    showFieldrushToast(context, userFacingError(error, fallback: fallback));
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
                      if (_failedSections.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Could not refresh ${_failedSections.join(', ')}.',
                                style: const TextStyle(
                                  color: FieldrushAuthTheme.danger,
                                ),
                              ),
                              TextButton(
                                onPressed: _load,
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      FieldrushYouContent(
                        referralSection: _referralSection,
                        profile: profile,
                        profileDetailsLoading: _profileDetailsLoading,
                        profileDetailsUnavailable:
                            !_profileDetailsReady && !_profileDetailsLoading,
                        rating: _rating,
                        ratings: _ratings,
                        track: _ratingTrack,
                        onTrack: _ratings == null ? null : _chooseRatingTrack,
                        ratingLoading: _ratingLoading,
                        ratingUnavailable: !_ratingLoading && _rating == null,
                        recentResults:
                            _ratings?.eventsFor(_ratingTrack) ??
                            fieldrushSeasonResults(
                              profile,
                              _season,
                              region: _rating?.region,
                            ),
                        cityLabel: _cityLabel,
                        emailUnverified:
                            _account != null &&
                            widget.accountRepository?.emailDeliveryEnabled ==
                                true &&
                            !_account!.emailVerified,
                        reliability: _reliability,
                        reliabilityLoading: _reliabilityLoading,
                        reliabilityUnavailable:
                            !_reliabilityLoading && _reliability == null,
                        walletLabel: _walletLoading ? 'Loading…' : _walletLabel,
                        notificationLabel: _notificationsLoading
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
                        onRanks: _openDivisions,
                        onMatchHistory: _openHistory,
                        onClip: _openClip,
                        onAllClips: _openAllClips,
                        onReliability: _openReliability,
                        onNotifications: _openNotifications,
                        onBlockedPlayers: _safetyRepository == null
                            ? null
                            : _openBlockedPlayers,
                        onWallet: _openWallet,
                        onPaymentMethods: () =>
                            Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) => YouPaymentMethodsScreen(
                                  historyRepository: _historyRepository,
                                ),
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
