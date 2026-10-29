import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../profile/blocked_players_screen.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_modal.dart';
import '../ui/fieldrush_toast.dart';
import '../ui/fieldrush_video_player.dart';
import '../ui/fieldrush_clip_trim_timeline.dart';
import '../clans/clan.dart';
import '../clans/clan_detail_screen.dart';
import '../clans/clan_repository.dart';
import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../core/field_confirmation_dialog.dart';
import '../profile/goal_clip_downloader.dart';
import '../payments/refund_status.dart';
import '../profile/profile.dart';
import '../profile/profile_repository.dart';
import '../profile/profile_screen.dart';
import 'fixture.dart';
import 'fieldrush_match_replay_screen.dart';
import 'fixture_reliability_roster.dart';
import 'fixture_reliability_roster_panel.dart';
import 'fixture_repository.dart';
import 'fixture_widgets.dart';
import 'match_resolution.dart';
import 'match_resolution_panel.dart';

final _openMatchClipEditors = Expando<bool>('fieldrush-match-clip-editor');

/// Opens only the shared clip editor above the current match destination.
/// The caller continues to own [controller]; it is returned paused at its
/// original position after editing, including when the editor is cancelled.
Future<void> openFieldrushMatchClipEditor(
  BuildContext context, {
  required VideoPlayerController controller,
  required Fixture fixture,
  required ProfileRepository profileRepository,
  required GoalClipDownloader goalClipDownloader,
  String? sourceLabel,
}) async {
  if (!context.mounted || _openMatchClipEditors[controller] == true) return;
  if (!controller.value.isInitialized || controller.value.hasError) {
    showFieldrushToast(context, 'The match recording is not ready yet.');
    return;
  }
  _openMatchClipEditors[controller] = true;
  final initialPosition = controller.value.position;
  var restoredPosition = false;
  try {
    await controller.pause();
    if (!context.mounted) return;
    final range = await Navigator.of(context).push<_ClipRange>(
      MaterialPageRoute<_ClipRange>(
        fullscreenDialog: true,
        builder: (editorContext) => Theme(
          data: FieldrushAuthTheme.theme(editorContext),
          child: _CustomClipEditorPage(
            controller: controller,
            initialPosition: initialPosition,
            thumbnailUrls: _matchClipTimelineThumbnailUrls(
              fixture,
              controller.value.duration,
            ),
          ),
        ),
      ),
    );
    await _restoreMatchClipPosition(controller, initialPosition);
    restoredPosition = true;
    if (!context.mounted || range == null) return;

    final outcome = await showFieldrushModal<_CustomClipOutcome>(
      context: context,
      builder: (_) => const _CustomClipOutcomeSheet(),
    );
    if (!context.mounted || outcome == null) return;
    var title =
        'Match clip · ${_formatVideoTime(Duration(milliseconds: (range.startSeconds * 1000).round()))}';
    if (outcome == _CustomClipOutcome.saveToProfile) {
      final chosenTitle = await showFieldrushModal<String>(
        context: context,
        builder: (_) => _ClipTitleSheet(
          initialTitle: title,
          heading: 'SAVE CLIP TO PROFILE',
          description: 'Give this moment a simple title.',
          actionLabel: 'Save to my profile',
        ),
      );
      if (!context.mounted || chosenTitle == null) return;
      title = chosenTitle;
    }
    final request = ProfileCustomClipRequest(
      sourceType: sourceLabel?.trim().toUpperCase() == 'SOLO'
          ? ProfileHighlightSource.solo
          : ProfileHighlightSource.clan,
      matchId: fixture.id,
      startSeconds: range.startSeconds,
      endSeconds: range.endSeconds,
      title: title,
    );
    await _processMatchClip(
      context,
      outcome: outcome,
      action: (onProgress, isActive) async {
        if (outcome == _CustomClipOutcome.saveToProfile) {
          await profileRepository.createCustomClip(request);
        } else {
          final media = await profileRepository.getCustomClipDownload(request);
          if (!isActive()) return;
          await goalClipDownloader.downloadToGallery(
            url: media.downloadUrl,
            fileName:
                '${fixture.homeClan.tag}_vs_${fixture.awayClan?.tag ?? 'match'}_clip.mp4',
            onProgress: onProgress,
          );
        }
      },
    );
    if (!context.mounted) return;
    showFieldrushToast(
      context,
      outcome == _CustomClipOutcome.saveToProfile
          ? 'Clip added to your profile.'
          : 'Clip saved to your Photos.',
    );
  } catch (error) {
    if (context.mounted) {
      showFieldrushToast(
        context,
        error is _MatchClipOperationTimeout
            ? error.message
            : userFacingError(
                error,
                fallback: 'We could not create this clip. Try again.',
              ),
      );
    }
  } finally {
    if (!restoredPosition) {
      try {
        await _restoreMatchClipPosition(controller, initialPosition);
      } catch (_) {
        // The caller may have disposed its controller while leaving the page.
      }
    }
    _openMatchClipEditors[controller] = null;
  }
}

Future<void> _restoreMatchClipPosition(
  VideoPlayerController controller,
  Duration position,
) async {
  if (!controller.value.isInitialized) return;
  await controller.pause();
  await controller.seekTo(
    Duration(
      milliseconds: position.inMilliseconds.clamp(
        0,
        controller.value.duration.inMilliseconds,
      ),
    ),
  );
}

Future<void> _processMatchClip(
  BuildContext context, {
  required _CustomClipOutcome outcome,
  required Future<void> Function(
    ValueChanged<double> onProgress,
    bool Function() isActive,
  )
  action,
}) async {
  final progress = ValueNotifier<double?>(null);
  final shown = Completer<BuildContext>();
  var acceptingProgress = true;
  final processing = showFieldrushModal<void>(
    context: context,
    dismissible: false,
    builder: (modalContext) {
      if (!shown.isCompleted) shown.complete(modalContext);
      return PopScope(
        canPop: false,
        child: FieldrushModal(
          key: const ValueKey('match-clip-processing'),
          title: outcome == _CustomClipOutcome.saveToProfile
              ? 'Saving your clip'
              : 'Saving clip to Photos',
          description: 'Keep Fieldrush open while your clip is prepared.',
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, value, _) => _WatchMediaProgress(
              label: value == null ? 'Preparing clip' : 'Saving to Photos',
              progress: value,
            ),
          ),
        ),
      );
    },
  );
  BuildContext? modalContext;
  try {
    modalContext = await shown.future;
    if (!context.mounted) return;
    await action(
      (value) {
        if (acceptingProgress && modalContext?.mounted == true) {
          progress.value = value.clamp(0.0, 1.0);
        }
      },
      () =>
          acceptingProgress && context.mounted && modalContext?.mounted == true,
    ).timeout(const Duration(minutes: 3));
  } on TimeoutException {
    throw _MatchClipOperationTimeout(outcome);
  } finally {
    acceptingProgress = false;
    if (modalContext?.mounted == true) {
      final route = ModalRoute.of(modalContext!);
      if (route != null && route.isActive) {
        Navigator.of(modalContext).removeRoute(route);
      }
    }
    await processing;
    progress.dispose();
  }
}

class _MatchClipOperationTimeout implements Exception {
  const _MatchClipOperationTimeout(this.outcome);

  final _CustomClipOutcome outcome;

  String get message => outcome == _CustomClipOutcome.saveToProfile
      ? 'Your clip is taking longer than expected. Check your profile before trying again; it may still appear.'
      : 'Your clip is taking longer than expected. Check Photos before trying again; it may still finish saving.';
}

List<String> _matchClipTimelineThumbnailUrls(
  Fixture fixture,
  Duration duration,
) {
  final playbackUri = Uri.tryParse(fixture.fullGamePlaybackUrl ?? '');
  final videoId = fixture.broadcast?.activeVideoId?.trim();
  if (playbackUri == null ||
      !playbackUri.hasScheme ||
      videoId == null ||
      videoId.isEmpty ||
      !(playbackUri.host.endsWith('cloudflarestream.com') ||
          playbackUri.host.endsWith('videodelivery.net'))) {
    return const [];
  }
  const count = 10;
  final durationSeconds = duration.inMilliseconds / 1000;
  return [
    for (var index = 0; index < count; index++)
      playbackUri
          .replace(
            path: '/$videoId/thumbnails/thumbnail.jpg',
            queryParameters: {
              'time': '${(durationSeconds * index / (count - 1)).round()}s',
              'height': '96',
              'fit': 'crop',
            },
          )
          .toString(),
  ];
}

/// The legacy watch destination retained for live matches.
class FieldrushMatchWatchScreen extends StatefulWidget {
  const FieldrushMatchWatchScreen({
    super.key,
    required this.fixture,
    required this.fixtureRepository,
    this.sourceLabel,
    this.profileRepository,
    this.goalClipDownloader,
    this.refreshFixture,
    this.openClipEditor = false,
    this.showHighlights = false,
    this.initialPosition = Duration.zero,
  });

  final Fixture fixture;
  final FixtureRepository fixtureRepository;
  final String? sourceLabel;
  final ProfileRepository? profileRepository;
  final GoalClipDownloader? goalClipDownloader;
  final Future<Fixture> Function()? refreshFixture;
  final bool openClipEditor;
  final bool showHighlights;
  final Duration initialPosition;

  @override
  State<FieldrushMatchWatchScreen> createState() =>
      _FieldrushMatchWatchScreenState();
}

class _FieldrushMatchWatchScreenState extends State<FieldrushMatchWatchScreen> {
  late Fixture _fixture = widget.fixture;
  late final ProfileRepository _profiles =
      widget.profileRepository ?? SupabaseProfileRepository();
  late final GoalClipDownloader _downloader =
      widget.goalClipDownloader ?? DeviceGoalClipDownloader();
  Timer? _timer;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_fixture.isLive || _fixture.broadcast?.shouldPoll == true) {
        unawaited(_refresh(quiet: true));
      }
    });
  }

  Future<void> _refresh({bool quiet = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final fresh =
          await (widget.refreshFixture?.call() ??
              widget.fixtureRepository.getFixture(_fixture.id));
      if (mounted) setState(() => _fixture = fresh);
    } catch (error) {
      if (mounted && !quiet) {
        showFieldrushToast(
          context,
          userFacingError(
            error,
            fallback: 'Could not refresh the video. Try again.',
          ),
        );
      }
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Scaffold(
      backgroundColor: FieldrushAuthTheme.cream,
      appBar: AppBar(
        title: const Text(
          'Watch match',
          style: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w800),
        ),
      ),
      body: FieldRefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _BroadcastPanel(
              fixture: _fixture,
              sourceLabel: widget.sourceLabel,
              profileRepository: _profiles,
              goalClipDownloader: _downloader,
              initialPosition: widget.initialPosition,
              openClipEditor: widget.openClipEditor,
              startWithFullGame: !widget.showHighlights,
            ),
            const SizedBox(height: 20),
            Text(
              '${_fixture.homeClan.name} vs ${_fixture.awayClan?.name ?? 'To be confirmed'}',
              style: const TextStyle(
                fontFamily: 'Outfit',
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: FieldrushAuthTheme.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _fixture.isLive
                  ? 'Live from the pitch'
                  : 'Match replay · Watch, trim and save your moments',
              style: const TextStyle(
                color: FieldrushAuthTheme.muted,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class FixtureDetailScreen extends StatefulWidget {
  const FixtureDetailScreen({
    super.key,
    required this.fixture,
    required this.fixtureRepository,
    required this.myClanMembership,
    this.refreshFixture,
    this.sourceLabel,
    this.showTeamRatings = true,
    this.playerRatingUpdate,
    this.initiallyShowWatch = false,
    this.clanRepository,
    this.profileRepository,
    this.goalClipDownloader,
  });

  final Fixture fixture;
  final FixtureRepository fixtureRepository;
  final MyClanMembership? myClanMembership;
  final Future<Fixture> Function()? refreshFixture;
  final String? sourceLabel;
  final bool showTeamRatings;
  final FixturePlayerRatingUpdate? playerRatingUpdate;
  final bool initiallyShowWatch;
  final ClanRepository? clanRepository;
  final ProfileRepository? profileRepository;
  final GoalClipDownloader? goalClipDownloader;

  @override
  State<FixtureDetailScreen> createState() => _FixtureDetailScreenState();
}

enum _FixtureDetailSection { watch, timeline, lineups }

class _FixtureDetailScreenState extends State<FixtureDetailScreen> {
  late Fixture _fixture = widget.fixture;
  late final ProfileRepository _profileRepository;
  late final GoalClipDownloader _goalClipDownloader;
  late final ClanRepository _clanRepository;
  late _FixtureDetailSection _selectedSection;
  Timer? _refreshTimer;
  bool _isJoining = false;
  bool _isCancelling = false;
  bool _isCompleting = false;
  bool _isRefreshing = false;
  bool _safetyRefreshPending = false;
  int _identityReadGeneration = 0;
  bool _isLoadingRoster = false;
  bool _isSavingRoster = false;
  bool _isLoadingMatchResolution = false;
  bool _didChange = false;
  String? _openingClanId;
  String? _errorText;
  String? _rosterErrorText;
  FixtureReliabilityRoster? _reliabilityRoster;
  MatchResolutionCase? _matchResolutionCase;
  bool _clanGamesEnabled = false;

  @override
  void initState() {
    super.initState();
    _profileRepository =
        widget.profileRepository ?? SupabaseProfileRepository();
    _goalClipDownloader =
        widget.goalClipDownloader ?? DeviceGoalClipDownloader();
    _clanRepository = widget.clanRepository ?? SupabaseClanRepository();
    _selectedSection = widget.initiallyShowWatch
        ? _FixtureDetailSection.watch
        : _FixtureDetailSection.timeline;
    _configureRefreshTimer();
    unawaited(_refreshFixture(quiet: true));
    unawaited(_loadReliabilityRoster(quiet: true));
    unawaited(_loadMatchResolution());
    unawaited(_loadClanAvailability());
  }

  Future<void> _loadClanAvailability() async {
    final enabled = await clanGamesAvailable(widget.fixtureRepository);
    if (mounted) setState(() => _clanGamesEnabled = enabled);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  bool get _canJoin {
    final membership = widget.myClanMembership;
    return _clanGamesEnabled &&
        membership != null &&
        membership.canManageMatches &&
        _fixture.isOpen &&
        _fixture.homeClanId != membership.clan.id;
  }

  bool get _canShowCompleteAction {
    return false;
  }

  bool get _canCancelClanBooking {
    final membership = widget.myClanMembership;
    return widget.fixtureRepository is FixtureReliabilityBookingRepository &&
        membership != null &&
        membership.canManageMatches &&
        !_fixture.hasPendingOperationalResolution &&
        (membership.clan.id == _fixture.homeClanId ||
            membership.clan.id == _fixture.awayClanId) &&
        (_fixture.status == FixtureStatus.open ||
            _fixture.status == FixtureStatus.scheduled ||
            _fixture.status == FixtureStatus.live);
  }

  bool get _canSeePayments {
    final membership = widget.myClanMembership;
    if (membership == null) return false;
    final isParticipating =
        membership.clan.id == _fixture.homeClanId ||
        membership.clan.id == _fixture.awayClanId;
    final isUpcoming =
        _fixture.status == FixtureStatus.open ||
        _fixture.status == FixtureStatus.scheduled;
    return isParticipating && isUpcoming;
  }

  bool get _shouldShowReliabilityRoster {
    final membership = widget.myClanMembership;
    return widget.sourceLabel?.toUpperCase() != 'SOLO' &&
        widget.fixtureRepository is FixtureReliabilityRosterRepository &&
        membership != null &&
        !_fixture.hasPendingOperationalResolution &&
        (membership.clan.id == _fixture.homeClanId ||
            membership.clan.id == _fixture.awayClanId) &&
        (_fixture.status == FixtureStatus.open ||
            _fixture.status == FixtureStatus.scheduled);
  }

  bool get _canComplete {
    final membership = widget.myClanMembership;
    if (membership == null || !membership.canManageMatches) return false;
    if (!_canShowCompleteAction) return false;

    return membership.clan.id == _fixture.homeClanId ||
        membership.clan.id == _fixture.awayClanId;
  }

  Future<void> _joinFixture() async {
    final membership = widget.myClanMembership;
    if (membership == null || !membership.canManageMatches) {
      showFieldrushToast(
        context,
        'Only clan owners and leaders can join matches.',
      );
      return;
    }

    setState(() {
      _isJoining = true;
      _errorText = null;
    });

    try {
      final repository = widget.fixtureRepository;
      if (repository case final FixtureReliabilityBookingRepository pricing) {
        var quote = await pricing.previewJoinFixtureCharge(
          fixtureId: _fixture.id,
          clanId: membership.clan.id,
        );
        var quoteUpdated = false;
        while (mounted) {
          if (!mounted) return;
          final confirmed = await showFieldConfirmDialog(
            context: context,
            icon: Icons.receipt_long_rounded,
            eyebrow: quoteUpdated ? 'Updated checkout' : 'Exact checkout',
            title: quoteUpdated
                ? 'Checkout changed · ${quote.totalLabel}'
                : 'Join for ${quote.totalLabel}?',
            message:
                'The server calculated ${quote.baseAmountLabel} for the match fee${quote.reliabilityDepositRequired ? ' plus a refundable ${quote.depositLabel} reliability deposit' : ''}.',
            detail: quote.reliabilityDepositRequired
                ? 'The deposit stays held while the match is live and returns as Field credit after a clean completed match.'
                : 'No clan reliability deposit is required.',
            confirmLabel: 'Pay ${quote.totalLabel}',
            cancelLabel: 'Not now',
          );
          if (!confirmed || !mounted) return;
          final latestQuote = await pricing.previewJoinFixtureCharge(
            fixtureId: _fixture.id,
            clanId: membership.clan.id,
          );
          if (quote.hasSameCheckoutTermsAs(latestQuote)) break;
          quote = latestQuote;
          quoteUpdated = true;
        }
        if (!mounted) return;
      }
      final fixture = await widget.fixtureRepository.joinFixture(
        fixtureId: _fixture.id,
        awayClanId: membership.clan.id,
      );
      if (!mounted) return;
      setState(() {
        _fixture = fixture;
        _didChange = true;
      });
      _configureRefreshTimer();
      unawaited(_loadReliabilityRoster(quiet: true));
      unawaited(_loadMatchResolution());
      showFieldrushToast(context, 'Match joined. Game on.');
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not join this match. Try again.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isJoining = false);
      }
    }
  }

  Future<void> _cancelClanBooking() async {
    final repository = widget.fixtureRepository;
    if (!_canCancelClanBooking ||
        repository is! FixtureReliabilityBookingRepository) {
      return;
    }
    final reliabilityRepository =
        repository as FixtureReliabilityBookingRepository;
    setState(() {
      _isCancelling = true;
      _errorText = null;
    });
    try {
      var quote = await reliabilityRepository.previewFixtureCancellation(
        _fixture.id,
      );
      if (!mounted) return;
      if (!quote.canCancel) {
        throw StateError('This clan match can no longer be cancelled.');
      }
      String? reason;
      var quoteUpdated = false;
      while (mounted) {
        if (!mounted) return;
        reason = await showFieldrushModal<String>(
          context: context,
          builder: (_) => _ClanCancellationSheet(
            quote: quote,
            initialReason: reason,
            quoteUpdated: quoteUpdated,
          ),
        );
        if (reason == null || !mounted) return;
        final latestQuote = await reliabilityRepository
            .previewFixtureCancellation(_fixture.id);
        if (quote.hasSameConsequencesAs(latestQuote)) break;
        quote = latestQuote;
        quoteUpdated = true;
      }
      if (!mounted || reason == null) return;
      final cancelled = await reliabilityRepository.cancelFixtureBooking(
        fixtureId: _fixture.id,
        reason: reason,
      );
      if (!mounted) return;
      await _refreshFixture();
      if (!mounted) return;
      showFieldrushToast(
        context,
        cancellationRefundMessage(
          refundAmountFils: cancelled.refundAmountFils,
          destination: cancelled.refundDestination,
          status: cancelled.refundStatus,
          isClan: true,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = userFacingError(
          error,
          fallback: 'We could not cancel this clan match.',
        );
      });
    } finally {
      if (mounted) setState(() => _isCancelling = false);
    }
  }

  Future<void> _completeFixture() async {
    if (!_canComplete) {
      showFieldrushToast(
        context,
        'Only participating clan owners and leaders can finalize scores.',
      );
      return;
    }

    final scores = await showModalBottomSheet<_ScoreSubmission>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _CompleteScoreSheet(fixture: _fixture),
    );
    if (scores == null) return;

    setState(() {
      _isCompleting = true;
      _errorText = null;
    });

    try {
      final fixture = await widget.fixtureRepository.completeFixture(
        fixtureId: _fixture.id,
        homeScore: scores.homeScore,
        awayScore: scores.awayScore,
      );
      if (!mounted) return;
      setState(() {
        _fixture = fixture;
        _didChange = true;
      });
      _configureRefreshTimer();
      showFieldrushToast(context, 'Score finalized. SR updated.');
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not finalize this match. Try again.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isCompleting = false);
      }
    }
  }

  Future<void> _openPlayerProfile(String profileId) async {
    if (profileId.trim().isEmpty) return;
    _refreshTimer?.cancel();
    setState(() {
      _safetyRefreshPending = true;
      _errorText = null;
      _identityReadGeneration++;
    });
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: fieldBackground,
          body: ProfileScreen(
            profileRepository: _profileRepository,
            profileId: profileId,
          ),
        ),
      ),
    );
    if (mounted) await _refreshFixture(requireFreshIdentity: true);
  }

  Future<void> _openClan(FixtureClan fixtureClan) async {
    if (_openingClanId != null || fixtureClan.id.trim().isEmpty) return;
    setState(() => _openingClanId = fixtureClan.id);

    try {
      final results = await Future.wait<dynamic>([
        _clanRepository.listClans(),
        _clanRepository.getMyClanMembership(),
      ]);
      final clans = results[0] as List<Clan>;
      Clan? target;
      for (final clan in clans) {
        if (clan.id == fixtureClan.id) {
          target = clan;
          break;
        }
      }
      if (target == null) {
        throw StateError('Clan not found.');
      }
      if (!mounted) return;

      _refreshTimer?.cancel();
      setState(() {
        _safetyRefreshPending = true;
        _errorText = null;
        _identityReadGeneration++;
      });
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ClanDetailScreen(
            clan: target!,
            clanRepository: _clanRepository,
            fixtureRepository: widget.fixtureRepository,
            currentMembership: results[1] as ClanMembership?,
          ),
        ),
      );
      if (mounted) await _refreshFixture(requireFreshIdentity: true);
    } catch (error) {
      if (!mounted) return;
      showFieldrushToast(
        context,
        userFacingError(
          error,
          fallback: 'We could not open that clan. Try again.',
        ),
      );
    } finally {
      if (mounted) setState(() => _openingClanId = null);
    }
  }

  Future<void> _refreshFixture({
    bool quiet = false,
    bool requireFreshIdentity = false,
  }) async {
    if (requireFreshIdentity) {
      _identityReadGeneration++;
      _isRefreshing = false;
    }
    if (_isRefreshing) return;
    final identityGeneration = _identityReadGeneration;
    if (!quiet) {
      setState(() => _errorText = null);
    }
    _isRefreshing = true;

    try {
      final fixture =
          await (widget.refreshFixture?.call() ??
              widget.fixtureRepository.getFixture(_fixture.id));
      if (!mounted || identityGeneration != _identityReadGeneration) {
        return;
      }
      setState(() {
        _safetyRefreshPending = false;
        _fixture = fixture;
        _didChange = true;
      });
      _configureRefreshTimer();
      unawaited(_loadReliabilityRoster(quiet: true));
      unawaited(_loadMatchResolution());
    } catch (error) {
      if (!mounted || quiet || identityGeneration != _identityReadGeneration) {
        return;
      }
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not refresh this match. Try again.',
        ),
      );
    } finally {
      if (identityGeneration == _identityReadGeneration) _isRefreshing = false;
    }
  }

  Future<void> _loadReliabilityRoster({bool quiet = false}) async {
    if (!_shouldShowReliabilityRoster || _isLoadingRoster) return;
    final repository =
        widget.fixtureRepository as FixtureReliabilityRosterRepository;
    if (mounted) {
      setState(() {
        _isLoadingRoster = true;
        if (!quiet) _rosterErrorText = null;
      });
    }
    try {
      final roster = await repository.getMyFixtureReliabilityRoster(
        _fixture.id,
      );
      if (!mounted) return;
      setState(() {
        _reliabilityRoster = roster;
        _rosterErrorText = null;
      });
    } catch (error) {
      if (!mounted || (quiet && _reliabilityRoster != null)) return;
      setState(() {
        _rosterErrorText = userFacingError(
          error,
          fallback: 'We could not load your clan roster. Try again.',
        );
      });
    } finally {
      if (mounted) setState(() => _isLoadingRoster = false);
    }
  }

  Future<void> _loadMatchResolution() async {
    final repository = widget.fixtureRepository;
    if (repository is! MatchResolutionRepository || _isLoadingMatchResolution) {
      return;
    }
    final resolutionRepository = repository as MatchResolutionRepository;
    _isLoadingMatchResolution = true;
    try {
      final resolutionCase = await resolutionRepository.getMatchResolutionCase(
        matchKind: _matchResolutionKind,
        matchId: _fixture.id,
      );
      if (!mounted) return;
      setState(() => _matchResolutionCase = resolutionCase);
    } catch (_) {
      // Match details are public, while resolution finances and disputes are
      // participant-only. A non-participant should still be able to view the
      // match without seeing an authorization error or private case details.
    } finally {
      _isLoadingMatchResolution = false;
    }
  }

  MatchResolutionKind get _matchResolutionKind =>
      widget.sourceLabel?.trim().toUpperCase() == 'SOLO'
      ? MatchResolutionKind.solo
      : MatchResolutionKind.clan;

  Future<void> _openReliabilityRoster() async {
    final roster = _reliabilityRoster;
    final repository = widget.fixtureRepository;
    if (roster == null ||
        repository is! FixtureReliabilityRosterRepository ||
        _isSavingRoster) {
      return;
    }
    final reliabilityRepository =
        repository as FixtureReliabilityRosterRepository;
    final profileIds = await showFixtureReliabilityRosterSheet(
      context: context,
      roster: roster,
    );
    if (profileIds == null || !mounted) return;

    setState(() {
      _isSavingRoster = true;
      _rosterErrorText = null;
    });
    try {
      final saved = await reliabilityRepository.saveMyFixtureReliabilityRoster(
        fixtureId: _fixture.id,
        clanId: roster.clanId,
        profileIds: profileIds,
      );
      if (!mounted) return;
      setState(() {
        _reliabilityRoster = saved;
        _didChange = true;
      });
      showFieldrushToast(
        context,
        '${saved.confirmedCount} players confirmed for matchday.',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _rosterErrorText = userFacingError(
          error,
          fallback: 'We could not save this matchday roster.',
        );
      });
    } finally {
      if (mounted) setState(() => _isSavingRoster = false);
    }
  }

  Widget _buildReliabilityRoster() {
    final roster = _reliabilityRoster;
    if (roster != null) {
      return FixtureReliabilityRosterCard(
        roster: roster,
        onOpen: _openReliabilityRoster,
      );
    }
    final error = _rosterErrorText;
    if (error != null) {
      return FixtureReliabilityRosterErrorCard(
        message: error,
        onRetry: () => _loadReliabilityRoster(),
      );
    }
    return const FixtureReliabilityRosterLoadingCard();
  }

  void _configureRefreshTimer() {
    _refreshTimer?.cancel();
    if (_fixture.isLive) {
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _refreshFixture(quiet: true),
      );
      return;
    }
    if (_fixture.status == FixtureStatus.scheduled) {
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _refreshFixture(quiet: true),
      );
      return;
    }
    if (_fixture.broadcast?.shouldPoll == true) {
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _refreshFixture(quiet: true),
      );
    }
  }

  Future<Fixture> _loadReplayFixture() =>
      widget.refreshFixture?.call() ??
      widget.fixtureRepository.getFixture(_fixture.id);

  Future<void> _openReplay(Duration position) async {
    if (!_fixture.isFinal) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FieldrushMatchReplayScreen(
          fixture: _fixture,
          fixtureRepository: widget.fixtureRepository,
          profileRepository: _profileRepository,
          goalClipDownloader: _goalClipDownloader,
          refreshFixture: _loadReplayFixture,
          sourceLabel: widget.sourceLabel,
          initialPosition: position,
        ),
      ),
    );
  }

  Widget _buildSelectedSection() {
    return switch (_selectedSection) {
      _FixtureDetailSection.watch => _BroadcastPanel(
        fixture: _fixture,
        sourceLabel: widget.sourceLabel,
        profileRepository: _profileRepository,
        goalClipDownloader: _goalClipDownloader,
        onOpenReplay: _fixture.isFinal ? _openReplay : null,
      ),
      _FixtureDetailSection.timeline => Column(
        children: [
          _InfoGrid(fixture: _fixture),
          if (_canSeePayments) ...[
            const SizedBox(height: 18),
            _TeamPaymentsPanel(
              fixture: _fixture,
              onOpenProfile: _openPlayerProfile,
            ),
          ],
          if (_fixture.isFinal &&
              !_fixture.hasPendingOperationalResolution &&
              widget.playerRatingUpdate != null) ...[
            const SizedBox(height: 18),
            _PlayerRatingUpdateCard(update: widget.playerRatingUpdate!),
          ],
          if (_fixture.isFinal &&
              !_fixture.hasPendingOperationalResolution &&
              (_fixture.homeSrChange != null ||
                  _fixture.awaySrChange != null)) ...[
            const SizedBox(height: 18),
            _RatingUpdates(fixture: _fixture),
          ],
          const SizedBox(height: 18),
          if (_fixture.timeline.isEmpty)
            const _EmptyFixtureSection(
              icon: Icons.timeline_rounded,
              title: 'No timeline yet',
              message: 'Match events will appear here as the game is played.',
            )
          else
            _MatchTimeline(
              fixture: _fixture,
              onOpenProfile: _openPlayerProfile,
            ),
        ],
      ),
      _FixtureDetailSection.lineups =>
        _fixture.homeLineup.isEmpty && _fixture.awayLineup.isEmpty
            ? const _EmptyFixtureSection(
                icon: Icons.groups_2_rounded,
                title: 'Lineups not available yet',
                message:
                    'The team formations will appear here once players are assigned.',
              )
            : _FormationLineupsPanel(
                fixture: _fixture,
                onOpenProfile: _openPlayerProfile,
              ),
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_safetyRefreshPending) {
      return PlayerContentRefreshScreen(
        error: _errorText,
        onRetry: () => _refreshFixture(requireFreshIdentity: true),
      );
    }
    final bottomAction = _canJoin
        ? _JoinActionBar(
            canJoin: _canJoin,
            isJoining: _isJoining,
            onJoin: _joinFixture,
          )
        : _canCancelClanBooking
        ? _CancelClanBookingActionBar(
            isCancelling: _isCancelling,
            onCancel: _cancelClanBooking,
          )
        : _canShowCompleteAction
        ? _CompleteActionBar(
            canComplete: _canComplete,
            isCompleting: _isCompleting,
            onComplete: _completeFixture,
          )
        : null;

    final title = widget.sourceLabel == null
        ? 'Match Details'
        : '${widget.sourceLabel} Match';

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: fieldBackground,
        body: FieldHeaderOverlay(
          header: _FixtureDetailHeader(
            title: title,
            onBack: () => Navigator.of(context).pop(_didChange),
          ),
          child: ListView(
            padding: EdgeInsets.only(bottom: bottomAction == null ? 32 : 116),
            children: [
              SizedBox(
                width: double.infinity,
                child: _Scoreboard(
                  fixture: _fixture,
                  sourceLabel: widget.sourceLabel,
                  showTeamRatings: widget.showTeamRatings,
                  onHomeClanTap: widget.sourceLabel?.toUpperCase() == 'SOLO'
                      ? null
                      : () => _openClan(_fixture.homeClan),
                  onAwayClanTap:
                      widget.sourceLabel?.toUpperCase() == 'SOLO' ||
                          _fixture.awayClan == null
                      ? null
                      : () => _openClan(_fixture.awayClan!),
                  openingClanId: _openingClanId,
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _FixtureSectionSwitcher(
                  selected: _selectedSection,
                  onSelected: (section) {
                    if (_selectedSection == section) return;
                    setState(() => _selectedSection = section);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    if (_errorText != null) ...[
                      const SizedBox(height: 14),
                      _ErrorCallout(message: _errorText!),
                    ],
                    if (_fixture.hasPendingOperationalResolution &&
                        _matchResolutionCase == null) ...[
                      const SizedBox(height: 18),
                      _OperationalResolutionPanel(fixture: _fixture),
                    ],
                    if (_fixture.isCancelled) ...[
                      const SizedBox(height: 18),
                      _CancellationPanel(fixture: _fixture),
                    ],
                    if (_matchResolutionCase case final resolutionCase?) ...[
                      const SizedBox(height: 18),
                      MatchResolutionPanel(
                        resolutionCase: resolutionCase,
                        repository:
                            widget.fixtureRepository
                                as MatchResolutionRepository,
                        matchKind: _matchResolutionKind,
                        matchId: _fixture.id,
                        onChanged: (updated) {
                          if (mounted) {
                            setState(() => _matchResolutionCase = updated);
                          }
                        },
                      ),
                    ],
                    if (_shouldShowReliabilityRoster) ...[
                      const SizedBox(height: 18),
                      _buildReliabilityRoster(),
                    ],
                    const SizedBox(height: 18),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: KeyedSubtree(
                        key: ValueKey(_selectedSection),
                        child: _buildSelectedSection(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: bottomAction,
      ),
    );
  }
}

class _FixtureDetailHeader extends StatelessWidget {
  const _FixtureDetailHeader({required this.title, required this.onBack});

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return Container(
      key: const ValueKey('fixture-detail-header'),
      height: topInset + 64,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.42),
            Colors.black.withValues(alpha: 0.12),
            Colors.transparent,
          ],
        ),
      ),
      padding: EdgeInsets.fromLTRB(16, topInset, 16, 0),
      child: Row(
        children: [
          Material(
            color: Colors.white.withValues(alpha: 0.13),
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onBack,
              customBorder: const CircleBorder(),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.24),
                  ),
                ),
                child: const Icon(
                  Icons.arrow_back_rounded,
                  color: Colors.white,
                  size: 21,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          const SizedBox(
            width: 4,
            height: 25,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [fieldEmerald500, fieldBlue600],
                ),
                borderRadius: BorderRadius.all(Radius.circular(99)),
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              title.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                height: 1,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FixtureSectionSwitcher extends StatelessWidget {
  const _FixtureSectionSwitcher({
    required this.selected,
    required this.onSelected,
  });

  final _FixtureDetailSection selected;
  final ValueChanged<_FixtureDetailSection> onSelected;

  @override
  Widget build(BuildContext context) {
    const items = [
      (_FixtureDetailSection.watch, Icons.play_circle_outline_rounded, 'WATCH'),
      (_FixtureDetailSection.timeline, Icons.timeline_rounded, 'TIMELINE'),
      (_FixtureDetailSection.lineups, Icons.groups_2_rounded, 'LINEUPS'),
    ];

    return Container(
      key: const ValueKey('fixture-main-switcher'),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: fieldGray100,
        border: Border.all(color: fieldGray200),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          for (final item in items)
            Expanded(
              child: _FixtureSectionButton(
                icon: item.$2,
                label: item.$3,
                selected: selected == item.$1,
                onTap: () => onSelected(item.$1),
              ),
            ),
        ],
      ),
    );
  }
}

class _FixtureSectionButton extends StatelessWidget {
  const _FixtureSectionButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.white : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: ValueKey('fixture-section-${label.toLowerCase()}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x12111827),
                      blurRadius: 8,
                      offset: Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? fieldEmerald600 : fieldGray500,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: selected ? fieldGray900 : fieldGray500,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyFixtureSection extends StatelessWidget {
  const _EmptyFixtureSection({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 34),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(icon, color: fieldGray400, size: 28),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 12,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Scoreboard extends StatelessWidget {
  const _Scoreboard({
    required this.fixture,
    required this.sourceLabel,
    required this.showTeamRatings,
    required this.onHomeClanTap,
    required this.onAwayClanTap,
    required this.openingClanId,
  });

  final Fixture fixture;
  final String? sourceLabel;
  final bool showTeamRatings;
  final VoidCallback? onHomeClanTap;
  final VoidCallback? onAwayClanTap;
  final String? openingClanId;

  @override
  Widget build(BuildContext context) {
    final homeWin =
        fixture.shouldDisplayScore &&
        fixture.homeScore != null &&
        fixture.awayScore != null &&
        fixture.homeScore! > fixture.awayScore!;
    final awayWin =
        fixture.shouldDisplayScore &&
        fixture.homeScore != null &&
        fixture.awayScore != null &&
        fixture.awayScore! > fixture.homeScore!;

    return Container(
      key: const ValueKey('fixture-scoreboard'),
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        22,
        fieldPageHeaderExtent(context) + 14,
        22,
        12,
      ),
      decoration: BoxDecoration(
        gradient: const RadialGradient(
          center: Alignment(0.8, -0.8),
          radius: 1.4,
          colors: [Color(0xFF374151), Color(0xFF111827), Color(0xFF000000)],
          stops: [0, 0.52, 1],
        ),
        borderRadius: BorderRadius.zero,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            top: -54,
            right: -54,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fieldEmerald500.withValues(alpha: 0.10),
              ),
            ),
          ),
          Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (sourceLabel != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        sourceLabel!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                  ],
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: fixture.isLive
                          ? const Color(0xFFEF4444)
                          : fixture.isFinal
                          ? Colors.white.withValues(alpha: 0.18)
                          : fieldEmerald600,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      fixture.detailStatusLabel.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
              if (fixture.isLive) ...[
                const SizedBox(height: 10),
                _LiveMinutePill(clock: fixture.clock),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _ScoreboardClan(
                      clan: fixture.homeClan,
                      winner: homeWin,
                      showRating: showTeamRatings,
                      averagePlayerRating: fixture.homeAveragePlayerRating,
                      onTap: onHomeClanTap,
                      isOpening: openingClanId == fixture.homeClanId,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: fixture.hasPendingOperationalResolution
                        ? _OperationalScoreState(fixture: fixture)
                        : fixture.shouldDisplayScore
                        ? Row(
                            children: [
                              _ScoreNumber(
                                value: fixture.homeScore ?? 0,
                                highlight: homeWin,
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 8),
                                child: Text(
                                  '-',
                                  style: TextStyle(
                                    color: fieldGray500,
                                    fontSize: 21,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              _ScoreNumber(
                                value: fixture.awayScore ?? 0,
                                highlight: awayWin,
                              ),
                            ],
                          )
                        : Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 15,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: const Text(
                              'VS',
                              style: TextStyle(
                                color: fieldGray400,
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                  ),
                  Expanded(
                    child: fixture.awayClan == null
                        ? const _TbdClan()
                        : _ScoreboardClan(
                            clan: fixture.awayClan!,
                            winner: awayWin,
                            showRating: showTeamRatings,
                            averagePlayerRating:
                                fixture.awayAveragePlayerRating,
                            onTap: onAwayClanTap,
                            isOpening: openingClanId == fixture.awayClanId,
                          ),
                  ),
                ],
              ),
              if (!showTeamRatings &&
                  fixture.matchAveragePlayerRating != null) ...[
                const SizedBox(height: 12),
                _MatchAverageRatingPill(
                  average: fixture.matchAveragePlayerRating!,
                  spread: fixture.teamRatingSpread,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _OperationalScoreState extends StatelessWidget {
  const _OperationalScoreState({required this.fixture});

  final Fixture fixture;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('fixture-operational-score-state'),
      constraints: const BoxConstraints(maxWidth: 76),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Text(
        fixture.statusLabel.toUpperCase(),
        maxLines: 2,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          height: 1.15,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _OperationalResolutionPanel extends StatelessWidget {
  const _OperationalResolutionPanel({required this.fixture});

  final Fixture fixture;

  @override
  Widget build(BuildContext context) {
    final noData = fixture.operationalState == MatchOperationalState.noData;
    return Container(
      key: const ValueKey('fixture-operational-resolution-panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        border: Border.all(color: const Color(0xFFFDE68A)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            noData ? Icons.pending_actions_rounded : Icons.fact_check_outlined,
            color: const Color(0xFFB45309),
            size: 22,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  noData
                      ? 'No data · ${fixture.operationalStatusDetail ?? 'Match data missing'}'
                      : fixture.statusLabel,
                  style: const TextStyle(
                    color: Color(0xFF78350F),
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  noData
                      ? fixture.operationalReasonCode == 'RESULT_MISSING'
                            ? 'The final result was not recorded. An admin can verify attendance, refunds, and the official outcome.'
                            : 'No match data was recorded. An admin can review attendance, refunds, and the final outcome.'
                      : 'An admin is reviewing this match. Scores, attendance outcomes, and rating changes are not final.',
                  style: const TextStyle(
                    color: Color(0xFF92400E),
                    fontSize: 12,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
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

class _ScoreboardClan extends StatelessWidget {
  const _ScoreboardClan({
    required this.clan,
    required this.winner,
    required this.showRating,
    required this.averagePlayerRating,
    required this.onTap,
    required this.isOpening,
  });

  final FixtureClan clan;
  final bool winner;
  final bool showRating;
  final int? averagePlayerRating;
  final VoidCallback? onTap;
  final bool isOpening;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        FixtureClanAvatar(clan: clan, size: 56),
        const SizedBox(height: 7),
        Text(
          clan.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: winner ? const Color(0xFFA7F3D0) : Colors.white,
            fontSize: 13,
            height: 1.1,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (onTap != null) ...[
          const SizedBox(height: 3),
          if (isOpening)
            const SizedBox.square(
              dimension: 12,
              child: FieldLoadingIndicator(color: fieldEmerald200),
            )
          else
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'VIEW CLAN',
                  style: TextStyle(
                    color: fieldEmerald200,
                    fontSize: 8,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
                SizedBox(width: 1),
                Icon(
                  Icons.chevron_right_rounded,
                  color: fieldEmerald200,
                  size: 12,
                ),
              ],
            ),
        ],
        if (showRating && clan.skillRating != null) ...[
          const SizedBox(height: 5),
          Text(
            '${clan.skillRating} CLAN SR',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldEmerald200,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.35,
            ),
          ),
          if (clan.regionRank case final regionRank?) ...[
            const SizedBox(height: 2),
            Text(
              '#$regionRank ${_regionName(clan.region).toUpperCase()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: fieldGray400,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.25,
              ),
            ),
          ],
          const SizedBox(height: 3),
        ] else if (averagePlayerRating case final rating?) ...[
          const SizedBox(height: 5),
          Text(
            '$rating AVG PLAYER RATING',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldEmerald200,
              fontSize: 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 3),
        ] else
          const SizedBox(height: 3),
      ],
    );

    if (onTap == null) return content;
    return Semantics(
      button: true,
      label: 'View ${clan.name} clan',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: ValueKey('fixture-clan-link-${clan.id}'),
          onTap: isOpening ? null : onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            child: content,
          ),
        ),
      ),
    );
  }
}

class _MatchAverageRatingPill extends StatelessWidget {
  const _MatchAverageRatingPill({required this.average, required this.spread});

  final int average;
  final int? spread;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'MATCH AVG $average SR${spread == null ? '' : '  ·  $spread SR SPREAD'}',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _TbdClan extends StatelessWidget {
  const _TbdClan();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.shield_rounded, color: fieldGray400),
        ),
        const SizedBox(height: 10),
        const Text(
          'TBD',
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 44),
      ],
    );
  }
}

class _ScoreNumber extends StatelessWidget {
  const _ScoreNumber({required this.value, required this.highlight});

  final int value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Text(
      value.toString(),
      style: TextStyle(
        color: highlight ? const Color(0xFF34D399) : Colors.white,
        fontSize: 40,
        fontWeight: FontWeight.w900,
      ),
    );
  }
}

class _LiveMinutePill extends StatefulWidget {
  const _LiveMinutePill({required this.clock});

  final FixtureClock? clock;

  @override
  State<_LiveMinutePill> createState() => _LiveMinutePillState();
}

class _LiveMinutePillState extends State<_LiveMinutePill> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _LiveMinutePill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clock != widget.clock) _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    _timer?.cancel();
    if (widget.clock?.isRunning ?? false) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = widget.clock?.elapsedSeconds() ?? 0;
    final minute = elapsed == 0 ? 0 : (elapsed ~/ 60) + 1;
    final label = widget.clock?.isRunning ?? false
        ? 'LIVE $minute\''
        : '$minute\'';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _MatchTimeline extends StatelessWidget {
  const _MatchTimeline({required this.fixture, required this.onOpenProfile});

  final Fixture fixture;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final events = fixture.timeline.take(18).toList();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.timeline_rounded, color: fieldBlue600),
              SizedBox(width: 8),
              Text(
                'TIMELINE',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          for (final event in events) ...[
            _TimelineRow(
              fixture: fixture,
              event: event,
              onOpenProfile: onOpenProfile,
            ),
            if (event != events.last) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.fixture,
    required this.event,
    required this.onOpenProfile,
  });

  final Fixture fixture;
  final FixtureTimelineEvent event;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final eventStyle = _timelineEventStyle(event.eventType);
    final title = _timelineTitle(event);
    final subtitle = _timelineSubtitle(fixture, event);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: eventStyle.background,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(eventStyle.icon, color: eventStyle.color, size: 19),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: event.profileId == null
                    ? null
                    : () => onOpenProfile(event.profileId!),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: event.profileId == null
                          ? fieldGray900
                          : fieldBlue600,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              InkWell(
                onTap: event.assistProfileId == null
                    ? null
                    : () => onOpenProfile(event.assistProfileId!),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: event.assistProfileId == null
                          ? fieldGray500
                          : fieldBlue600,
                      fontSize: 12,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          event.minute == 0
              ? '0:00'
              : '${event.minute}:${event.second.toString().padLeft(2, '0')}',
          style: const TextStyle(
            color: fieldGray500,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _InfoGrid extends StatelessWidget {
  const _InfoGrid({required this.fixture});

  final Fixture fixture;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _InfoTile(
                icon: Icons.calendar_month_rounded,
                iconColor: fieldEmerald600,
                iconBackground: const Color(0xFFECFDF5),
                label: fixture.day,
                value: fixture.monthDay,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _InfoTile(
                icon: Icons.access_time_rounded,
                iconColor: fieldBlue600,
                iconBackground: const Color(0xFFEFF6FF),
                label: 'Time',
                value: fixture.timeSlot.split(' - ').first,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _InfoTile(
          icon: Icons.location_on_rounded,
          iconColor: const Color(0xFFD97706),
          iconBackground: const Color(0xFFFFFBEB),
          label: 'Venue',
          value: fixture.venue,
        ),
      ],
    );
  }
}

class _FormationLineupsPanel extends StatelessWidget {
  const _FormationLineupsPanel({
    required this.fixture,
    required this.onOpenProfile,
  });

  final Fixture fixture;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final homePlayers = _visibleLineup(fixture.homeLineup);
    final awayPlayers = _visibleLineup(fixture.awayLineup);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D111827),
            blurRadius: 12,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.groups_2_rounded, color: fieldBlue600, size: 19),
              SizedBox(width: 8),
              Text(
                'TEAM LINEUPS',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            fixture.teamRatingSpread == null
                ? 'Both 6-a-side formations, including each keeper.'
                : 'Balanced to a ${fixture.teamRatingSpread} SR average spread.',
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          AspectRatio(
            aspectRatio: 0.5,
            child: _FormationPitch(
              homeName: fixture.homeClan.name,
              awayName: fixture.awayClan?.name ?? 'Away Team',
              homeAverage: fixture.homeAveragePlayerRating,
              awayAverage: fixture.awayAveragePlayerRating,
              homePlayers: _formationEntries(homePlayers),
              awayPlayers: _formationEntries(awayPlayers),
              onOpenProfile: onOpenProfile,
            ),
          ),
        ],
      ),
    );
  }
}

class _FormationPitch extends StatelessWidget {
  const _FormationPitch({
    required this.homeName,
    required this.awayName,
    required this.homeAverage,
    required this.awayAverage,
    required this.homePlayers,
    required this.awayPlayers,
    required this.onOpenProfile,
  });

  final String homeName;
  final String awayName;
  final int? homeAverage;
  final int? awayAverage;
  final List<_FormationEntry> homePlayers;
  final List<_FormationEntry> awayPlayers;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      key: const ValueKey('fixture-formation-pitch'),
      borderRadius: BorderRadius.circular(22),
      child: CustomPaint(
        painter: const _PitchPainter(),
        child: Stack(
          children: [
            Positioned(
              top: 13,
              left: 13,
              right: 13,
              child: _PitchTeamLabel(
                name: homeName,
                averageRating: homeAverage,
                alignRight: false,
              ),
            ),
            Positioned.fill(
              top: 44,
              bottom: 44,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 7),
                child: Column(
                  children: [
                    Expanded(
                      child: _TeamFormation(
                        entries: homePlayers,
                        direction: _FormationDirection.down,
                        onOpenProfile: onOpenProfile,
                      ),
                    ),
                    Expanded(
                      child: _TeamFormation(
                        entries: awayPlayers,
                        direction: _FormationDirection.up,
                        onOpenProfile: onOpenProfile,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 13,
              left: 13,
              right: 13,
              child: _PitchTeamLabel(
                name: awayName,
                averageRating: awayAverage,
                alignRight: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _FormationDirection { down, up }

class _TeamFormation extends StatelessWidget {
  const _TeamFormation({
    required this.entries,
    required this.direction,
    required this.onOpenProfile,
  });

  final List<_FormationEntry> entries;
  final _FormationDirection direction;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(
        child: Text(
          'LINEUP PENDING',
          style: TextStyle(
            color: Color(0xBFFFFFFF),
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 1,
          ),
        ),
      );
    }

    const orderedRoles = ['GK', 'DEF', 'MID', 'ATT'];
    final roles = direction == _FormationDirection.down
        ? orderedRoles
        : orderedRoles.reversed.toList();

    return Column(
      children: [
        for (final role in roles)
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final entry in entries.where(
                  (entry) => entry.role == role,
                ))
                  _FormationPlayerMarker(
                    entry: entry,
                    onTap: () => onOpenProfile(entry.player.id),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FormationPlayerMarker extends StatelessWidget {
  const _FormationPlayerMarker({required this.entry, required this.onTap});

  final _FormationEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final player = entry.player;
    final avatarUrl = player.avatarUrl?.trim();
    final rating = player.displayedRating;
    return SizedBox(
      width: 96,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: player.isMe ? fieldEmerald200 : Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x35111827),
                        blurRadius: 5,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: CircleAvatar(
                    radius: 22,
                    backgroundColor: player.side.toUpperCase() == 'AWAY'
                        ? fieldGray900
                        : fieldGray100,
                    backgroundImage: avatarUrl != null && avatarUrl.isNotEmpty
                        ? NetworkImage(avatarUrl)
                        : null,
                    child: avatarUrl != null && avatarUrl.isNotEmpty
                        ? null
                        : Text(
                            player.initials,
                            style: TextStyle(
                              color: player.side.toUpperCase() == 'AWAY'
                                  ? Colors.white
                                  : fieldGray700,
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  player.isMe
                      ? '${player.displayName} (You)'
                      : player.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    height: 1,
                    fontWeight: FontWeight.w900,
                    shadows: [Shadow(color: Color(0x80111827), blurRadius: 3)],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  rating == null ? entry.role : '${entry.role} · $rating SR',
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 8,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    shadows: [Shadow(color: Color(0x80111827), blurRadius: 2)],
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

class _PitchTeamLabel extends StatelessWidget {
  const _PitchTeamLabel({
    required this.name,
    required this.averageRating,
    required this.alignRight,
  });

  final String name;
  final int? averageRating;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xC9111827),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          '${name.toUpperCase()}${averageRating == null ? '' : ' · $averageRating AVG SR'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 8,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

class _PitchPainter extends CustomPainter {
  const _PitchPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = const Color(0xFF07845F));

    final stripePaint = Paint()..color = Colors.white.withValues(alpha: 0.055);
    final stripeHeight = size.height / 8;
    for (var index = 0; index < 8; index += 2) {
      canvas.drawRect(
        Rect.fromLTWH(0, index * stripeHeight, size.width, stripeHeight),
        stripePaint,
      );
    }

    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.52)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    final inset = Rect.fromLTWH(14, 14, size.width - 28, size.height - 28);
    canvas.drawRRect(
      RRect.fromRectAndRadius(inset, const Radius.circular(16)),
      linePaint,
    );
    canvas.drawLine(
      Offset(14, size.height / 2),
      Offset(size.width - 14, size.height / 2),
      linePaint,
    );
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width * 0.16,
      linePaint,
    );
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      2.2,
      Paint()..color = Colors.white.withValues(alpha: 0.62),
    );
    final boxWidth = size.width * 0.48;
    final boxHeight = size.height * 0.12;
    canvas.drawRect(
      Rect.fromLTWH((size.width - boxWidth) / 2, 14, boxWidth, boxHeight),
      linePaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(
        (size.width - boxWidth) / 2,
        size.height - 14 - boxHeight,
        boxWidth,
        boxHeight,
      ),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _PitchPainter oldDelegate) => false;
}

class _FormationEntry {
  const _FormationEntry({required this.player, required this.role});

  final FixtureLineupPlayer player;
  final String role;
}

List<FixtureLineupPlayer> _visibleLineup(List<FixtureLineupPlayer> players) {
  final played = players.where((player) => player.played).toList();
  final visible = played.isEmpty ? players : played;
  return visible.take(7).toList();
}

List<_FormationEntry> _formationEntries(List<FixtureLineupPlayer> players) {
  const fallback = ['GK', 'DEF', 'DEF', 'MID', 'MID', 'ATT', 'ATT'];
  return [
    for (var index = 0; index < players.length; index++)
      _FormationEntry(
        player: players[index],
        role: _formationRole(
          players[index].role,
          fallback[index % fallback.length],
        ),
      ),
  ];
}

String _formationRole(String rawRole, String fallback) {
  final role = rawRole.trim().toUpperCase();
  if (role == 'GK' || role.contains('GOALKEEP')) return 'GK';
  if (role == 'DEF' || role.contains('DEFEND')) return 'DEF';
  if (role == 'MID' || role.contains('MIDFIELD')) return 'MID';
  if (role == 'ATT' || role.contains('ATTACK') || role.contains('FORWARD')) {
    return 'ATT';
  }
  return fallback;
}

class _CancellationPanel extends StatelessWidget {
  const _CancellationPanel({required this.fixture});

  final Fixture fixture;

  @override
  Widget build(BuildContext context) {
    final actorName = fixture.cancellationActor?.displayName;
    final actorLabel = actorName == null || actorName.trim().isEmpty
        ? fixture.cancellationCode == 'NO_OPPONENT_24H'
              ? 'Automatic cancellation'
              : 'Cancellation source not recorded'
        : 'Cancelled by $actorName';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        border: Border.all(color: const Color(0xFFFED7AA)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEDD5),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.event_busy_rounded,
                  color: Color(0xFFEA580C),
                  size: 21,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  fixture.cancellationTitle,
                  style: const TextStyle(
                    color: Color(0xFF9A3412),
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            fixture.cancellationDisplayReason,
            style: const TextStyle(
              color: Color(0xFF7C2D12),
              fontSize: 13,
              height: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 13),
          const Divider(height: 1, color: Color(0xFFFED7AA)),
          const SizedBox(height: 11),
          Row(
            children: [
              const Icon(
                Icons.info_outline_rounded,
                color: Color(0xFFC2410C),
                size: 16,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  actorLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF9A3412),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (fixture.cancelledAt != null)
                Text(
                  _cancellationTimestamp(fixture.cancelledAt!),
                  style: const TextStyle(
                    color: Color(0xFF9A3412),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _cancellationTimestamp(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'AM' : 'PM';
  return '${months[local.month - 1]} ${local.day}, $hour:$minute $period';
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.025),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: iconBackground,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: fieldGray500,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: fieldGray900,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
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

class _TeamPaymentsPanel extends StatelessWidget {
  const _TeamPaymentsPanel({
    required this.fixture,
    required this.onOpenProfile,
  });

  final Fixture fixture;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long_rounded, color: fieldEmerald600),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'TEAM PAYMENTS',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fieldGray900,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                fixture.teamPriceLabel.toUpperCase(),
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _PaymentRow(
            clan: fixture.homeClan,
            payer: fixture.homePayer,
            paidAt: fixture.homePaidAt,
            onOpenProfile: onOpenProfile,
          ),
          if (fixture.awayClan != null) ...[
            const Divider(height: 22, color: fieldGray100),
            _PaymentRow(
              clan: fixture.awayClan!,
              payer: fixture.awayPayer,
              paidAt: fixture.awayPaidAt,
              onOpenProfile: onOpenProfile,
            ),
          ],
        ],
      ),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({
    required this.clan,
    required this.payer,
    required this.paidAt,
    required this.onOpenProfile,
  });

  final FixtureClan clan;
  final FixtureParticipant? payer;
  final DateTime? paidAt;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final hasPayer = payer != null && payer!.id.isNotEmpty;
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFECFDF5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(clan.emblem, style: const TextStyle(fontSize: 23)),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                clan.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              InkWell(
                onTap: hasPayer ? () => onOpenProfile(payer!.id) : null,
                borderRadius: BorderRadius.circular(5),
                child: Text(
                  hasPayer
                      ? 'Paid by ${payer!.displayName}'
                      : 'Payment not recorded',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: hasPayer ? fieldBlue600 : fieldGray500,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (paidAt != null)
          Text(
            _shortPaymentDate(paidAt!),
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
      ],
    );
  }
}

String _shortPaymentDate(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = value.toLocal();
  return '${months[local.month - 1]} ${local.day}';
}

class _PlayerRatingUpdateCard extends StatelessWidget {
  const _PlayerRatingUpdateCard({required this.update});

  final FixturePlayerRatingUpdate update;

  @override
  Widget build(BuildContext context) {
    final change = update.ratingChange;
    final positive = change > 0;
    final negative = change < 0;
    final changeColor = positive
        ? fieldEmerald600
        : negative
        ? const Color(0xFFDC2626)
        : fieldGray500;
    final changeBackground = positive
        ? fieldEmerald50
        : negative
        ? const Color(0xFFFEF2F2)
        : fieldGray100;
    final result = update.result?.trim().toUpperCase();

    return Container(
      key: const ValueKey('fixture-player-rating-update'),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.trending_up_rounded,
                color: fieldBlue600,
                size: 22,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'PLAYER RATING UPDATE',
                  style: TextStyle(
                    color: fieldGray900,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (result != null && result.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: switch (result) {
                      'WIN' => fieldEmerald50,
                      'LOSS' => const Color(0xFFFEF2F2),
                      _ => fieldGray100,
                    },
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    result,
                    style: TextStyle(
                      color: switch (result) {
                        'WIN' => fieldEmerald700,
                        'LOSS' => const Color(0xFFDC2626),
                        _ => fieldGray600,
                      },
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _PlayerRatingValue(label: 'BEFORE', value: update.ratingBefore),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  color: fieldGray300,
                  size: 20,
                ),
              ),
              _PlayerRatingValue(label: 'AFTER', value: update.ratingAfter),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: changeBackground,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${change > 0 ? '+' : ''}$change SR',
                  style: TextStyle(
                    color: changeColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          if (update.hasMarginAdjustment) ...[
            const SizedBox(height: 14),
            _PlayerRatingMarginAdjustment(update: update),
          ],
        ],
      ),
    );
  }
}

class _PlayerRatingMarginAdjustment extends StatelessWidget {
  const _PlayerRatingMarginAdjustment({required this.update});

  final FixturePlayerRatingUpdate update;

  @override
  Widget build(BuildContext context) {
    final adjustment = update.marginBonusApplied!;
    final isWinBonus = adjustment > 0;
    final margin = update.scoreMargin;
    final marginLabel = margin == null ? '' : '$margin-GOAL ';
    final baseChange = update.baseRatingChange;
    final detail = [
      '${_signedRating(adjustment)} SR included in this update',
      if (baseChange != null) 'standard result ${_signedRating(baseChange)} SR',
    ].join(' · ');
    final foreground = isWinBonus ? fieldEmerald700 : const Color(0xFFC2410C);
    final background = isWinBonus ? fieldEmerald50 : const Color(0xFFFFF7ED);

    return Container(
      key: const ValueKey('fixture-player-rating-margin-adjustment'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isWinBonus
                ? Icons.auto_awesome_rounded
                : Icons.stacked_line_chart_rounded,
            color: foreground,
            size: 17,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isWinBonus
                      ? '${marginLabel}WIN BONUS'
                      : '${marginLabel}MARGIN ADJUSTMENT',
                  style: TextStyle(
                    color: foreground,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 11,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
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

String _signedRating(int value) => '${value > 0 ? '+' : ''}$value';

class _PlayerRatingValue extends StatelessWidget {
  const _PlayerRatingValue({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: fieldGray400,
            fontSize: 8,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          '$value',
          style: const TextStyle(
            color: fieldGray900,
            fontSize: 20,
            height: 1,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _RatingUpdates extends StatelessWidget {
  const _RatingUpdates({required this.fixture});

  final Fixture fixture;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.emoji_events_rounded, color: Color(0xFFF59E0B)),
              SizedBox(width: 8),
              Text(
                'RATING UPDATES',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _SrChangeTile(
                  clan: fixture.homeClan,
                  change: fixture.homeSrChange ?? 0,
                ),
              ),
              Container(width: 1, height: 46, color: fieldGray100),
              Expanded(
                child: _SrChangeTile(
                  clan: fixture.awayClan,
                  change: fixture.awaySrChange ?? 0,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SrChangeTile extends StatelessWidget {
  const _SrChangeTile({required this.clan, required this.change});

  final FixtureClan? clan;
  final int change;

  @override
  Widget build(BuildContext context) {
    final positive = change >= 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            clan?.name ?? 'TBD',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Icon(
                positive
                    ? Icons.trending_up_rounded
                    : Icons.trending_down_rounded,
                color: positive ? fieldEmerald600 : const Color(0xFFEF4444),
                size: 18,
              ),
              const SizedBox(width: 4),
              Text(
                '${positive ? '+' : ''}$change SR',
                style: TextStyle(
                  color: positive ? fieldEmerald600 : const Color(0xFFEF4444),
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BroadcastPanel extends StatefulWidget {
  const _BroadcastPanel({
    required this.fixture,
    required this.sourceLabel,
    required this.profileRepository,
    required this.goalClipDownloader,
    this.initialPosition = Duration.zero,
    this.openClipEditor = false,
    this.startWithFullGame = false,
    this.onOpenReplay,
  });

  final Fixture fixture;
  final String? sourceLabel;
  final ProfileRepository profileRepository;
  final GoalClipDownloader goalClipDownloader;
  final Duration initialPosition;
  final bool openClipEditor;
  final bool startWithFullGame;
  final Future<void> Function(Duration position)? onOpenReplay;

  @override
  State<_BroadcastPanel> createState() => _BroadcastPanelState();
}

enum _CompletedVideoView { highlights, fullGame }

enum _MatchVideoAction { downloadFullGame, createClip }

enum _CustomClipOutcome { saveToProfile, download }

class _ClipRange {
  const _ClipRange({required this.startSeconds, required this.endSeconds});

  final double startSeconds;
  final double endSeconds;

  double get durationSeconds => endSeconds - startSeconds;
}

class _BroadcastPanelState extends State<_BroadcastPanel> {
  VideoPlayerController? _controller;
  Timer? _retryTimer;
  String? _loadedUrl;
  String? _playerError;
  bool _isLoading = false;
  bool _isAdvancingHighlight = false;
  bool _openingReplay = false;
  int _activeHighlightIndex = 0;
  int _playerLoadGeneration = 0;
  Duration _fullGamePosition = Duration.zero;
  _CompletedVideoView _completedView = _CompletedVideoView.highlights;
  late List<FixtureHighlightMoment> _highlightMoments;
  final Set<String> _savedGoalEventIds = <String>{};
  String? _savingGoalEventId;
  String? _downloadingGoalEventId;
  double? _goalDownloadProgress;
  bool _isDownloadingFullGame = false;
  double? _fullGameDownloadProgress;
  bool _isCreatingCustomClip = false;
  bool _editorOpen = false;
  bool _openedInitialEditor = false;
  bool _fullscreenOpen = false;
  bool _needsPlayerSync = false;
  double? _customClipDownloadProgress;

  Fixture get fixture => widget.fixture;

  bool get _showHighlights {
    return fixture.isFinal && _completedView == _CompletedVideoView.highlights;
  }

  @override
  void initState() {
    super.initState();
    _fullGamePosition = widget.initialPosition;
    if (widget.startWithFullGame || widget.openClipEditor) {
      _completedView = _CompletedVideoView.fullGame;
    }
    _highlightMoments = _highlightMomentsFor(fixture);
    unawaited(_syncPlayer());
  }

  @override
  void didUpdateWidget(covariant _BroadcastPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldHighlightSignature = _highlightSignature(_highlightMoments);
    _highlightMoments = _highlightMomentsFor(fixture);
    final highlightsChanged =
        oldHighlightSignature != _highlightSignature(_highlightMoments);
    if (!oldWidget.fixture.isFinal && widget.fixture.isFinal) {
      _completedView = _CompletedVideoView.highlights;
      _activeHighlightIndex = 0;
      _fullGamePosition = Duration.zero;
    }
    final oldUrl = _playbackUrl(oldWidget.fixture);
    final nextUrl = _playbackUrl(widget.fixture);
    if (oldUrl != nextUrl ||
        oldWidget.fixture.broadcast?.status !=
            widget.fixture.broadcast?.status) {
      unawaited(_syncPlayer(force: oldUrl == nextUrl));
    } else if (highlightsChanged && _showHighlights) {
      unawaited(_resetHighlightPlayback());
    }
  }

  @override
  void dispose() {
    _playerLoadGeneration += 1;
    _retryTimer?.cancel();
    final controller = _controller;
    controller?.removeListener(_handlePlaybackTick);
    unawaited(controller?.dispose());
    super.dispose();
  }

  Future<void> _syncPlayer({bool force = false}) async {
    // Both routes share this controller. Apply refreshed stream metadata after
    // returning rather than disposing the player underneath an active route.
    if (_editorOpen || _fullscreenOpen) {
      _needsPlayerSync = true;
      return;
    }
    _needsPlayerSync = false;
    final loadGeneration = ++_playerLoadGeneration;
    final url = _playbackUrl(fixture);
    if (url == null) {
      _retryTimer?.cancel();
      final previous = _controller;
      previous?.removeListener(_handlePlaybackTick);
      _controller = null;
      _loadedUrl = null;
      if (previous != null) await previous.dispose();
      if (mounted && loadGeneration == _playerLoadGeneration) {
        setState(() {
          _isLoading = false;
          _playerError = null;
        });
      }
      return;
    }

    if (!force &&
        _loadedUrl == url &&
        _controller?.value.isInitialized == true) {
      return;
    }

    _retryTimer?.cancel();
    final previous = _controller;
    previous?.removeListener(_handlePlaybackTick);
    _controller = null;
    _loadedUrl = null;
    if (previous != null) await previous.dispose();
    if (!mounted || loadGeneration != _playerLoadGeneration) return;
    setState(() {
      _isLoading = true;
      _playerError = null;
    });

    final next = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await next.initialize();
      await next.setLooping(false);
      if (!mounted ||
          loadGeneration != _playerLoadGeneration ||
          _playbackUrl(fixture) != url) {
        await next.dispose();
        return;
      }
      _highlightMoments = _highlightMomentsFor(fixture, next);
      if (_showHighlights) {
        _activeHighlightIndex = 0;
        final highlights = _availableHighlights(next);
        if (highlights.isNotEmpty) {
          await next.seekTo(highlights.first.start);
        }
      } else if (fixture.isFinal) {
        await next.seekTo(_boundedPosition(_fullGamePosition, next));
      }
      if (!mounted || loadGeneration != _playerLoadGeneration) {
        await next.dispose();
        return;
      }
      next.addListener(_handlePlaybackTick);
      setState(() {
        _controller = next;
        _loadedUrl = url;
        _isLoading = false;
      });
      if (widget.openClipEditor && !_openedInitialEditor && fixture.isFinal) {
        _openedInitialEditor = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_openCustomClipEditor());
        });
      }
    } catch (_) {
      await next.dispose();
      if (!mounted || loadGeneration != _playerLoadGeneration) return;
      setState(() {
        _isLoading = false;
        _playerError = _playerFailureMessage;
      });
      if (fixture.broadcast?.shouldPoll == true || fixture.isFinal) {
        _retryTimer = Timer(
          const Duration(seconds: 10),
          () => unawaited(_syncPlayer(force: true)),
        );
      }
    }
  }

  String? _playbackUrl(Fixture value) {
    if (value.isLive) return value.livePlaybackUrl;
    if (value.isFinal) return value.fullGamePlaybackUrl;
    return null;
  }

  String get _playerFailureMessage {
    if (fixture.isLive) return 'The live stream is not ready yet.';
    if (_showHighlights) return 'Highlights are still loading.';
    return 'The full game replay is still loading.';
  }

  List<FixtureHighlightMoment> _availableHighlights(
    VideoPlayerController? controller,
  ) {
    if (controller?.value.isInitialized != true ||
        controller!.value.duration <= Duration.zero) {
      return _highlightMoments;
    }
    return _highlightMoments
        .where((moment) => moment.start < controller.value.duration)
        .toList(growable: false);
  }

  List<FixtureHighlightMoment> _highlightMomentsFor(
    Fixture value, [
    VideoPlayerController? controller,
  ]) {
    final playbackController = controller ?? _controller;
    if (playbackController?.value.isInitialized == true &&
        playbackController!.value.duration > Duration.zero) {
      return value.highlightMomentsForReplay(playbackController.value.duration);
    }
    return value.highlightMoments;
  }

  String _highlightSignature(List<FixtureHighlightMoment> moments) {
    return moments
        .map(
          (moment) =>
              '${moment.event.id}:${moment.start.inMilliseconds}:${moment.end.inMilliseconds}',
        )
        .join('|');
  }

  Future<void> _resetHighlightPlayback() async {
    final controller = _controller;
    if (controller?.value.isInitialized != true) {
      if (_playbackUrl(fixture) != null) {
        unawaited(_syncPlayer(force: true));
      }
      return;
    }
    await _playHighlightAt(0, autoplay: controller!.value.isPlaying);
  }

  Future<void> _playHighlightAt(
    int requestedIndex, {
    bool autoplay = true,
  }) async {
    if (_isAdvancingHighlight) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final highlights = _availableHighlights(controller);
    if (highlights.isEmpty) return;
    final index = requestedIndex.clamp(0, highlights.length - 1);

    _isAdvancingHighlight = true;
    try {
      if (controller.value.isPlaying) await controller.pause();
      if (!mounted || controller != _controller) return;
      setState(() => _activeHighlightIndex = index);
      await controller.seekTo(
        _boundedPosition(highlights[index].start, controller),
      );
      if (!mounted || controller != _controller) return;
      if (autoplay) await controller.play();
    } finally {
      _isAdvancingHighlight = false;
    }
  }

  Duration _boundedPosition(
    Duration position,
    VideoPlayerController controller,
  ) {
    if (position.isNegative) return Duration.zero;
    final duration = controller.value.duration;
    if (duration > Duration.zero && position > duration) return duration;
    return position;
  }

  Future<void> _selectCompletedView(_CompletedVideoView view) async {
    if (!fixture.isFinal || view == _completedView) return;

    final controller = _controller;
    if (_completedView == _CompletedVideoView.fullGame &&
        controller?.value.isInitialized == true) {
      _fullGamePosition = controller!.value.position;
    }
    if (controller?.value.isPlaying == true) await controller!.pause();
    if (!mounted) return;

    setState(() {
      _completedView = view;
      _activeHighlightIndex = 0;
      _playerError = null;
    });

    if (controller?.value.isInitialized != true) return;
    if (view == _CompletedVideoView.highlights) {
      await _playHighlightAt(0, autoplay: false);
    } else {
      await controller!.seekTo(_boundedPosition(_fullGamePosition, controller));
    }
  }

  void _handlePlaybackTick() {
    final controller = _controller;
    if (!_showHighlights ||
        _isAdvancingHighlight ||
        controller == null ||
        !controller.value.isInitialized ||
        !controller.value.isPlaying) {
      return;
    }

    final highlights = _availableHighlights(controller);
    if (highlights.isEmpty) return;
    final index = _activeHighlightIndex.clamp(0, highlights.length - 1);
    final end = _boundedPosition(highlights[index].end, controller);
    if (controller.value.position + const Duration(milliseconds: 250) < end) {
      return;
    }
    unawaited(_advanceHighlight(controller, highlights, index));
  }

  Future<void> _advanceHighlight(
    VideoPlayerController controller,
    List<FixtureHighlightMoment> highlights,
    int currentIndex,
  ) async {
    if (_isAdvancingHighlight) return;
    if (currentIndex < highlights.length - 1) {
      await _playHighlightAt(currentIndex + 1);
      return;
    }

    _isAdvancingHighlight = true;
    try {
      await controller.pause();
      await controller.seekTo(
        _boundedPosition(highlights[currentIndex].end, controller),
      );
    } finally {
      _isAdvancingHighlight = false;
    }
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (fixture.isFinal && widget.onOpenReplay != null && !_fullscreenOpen) {
      if (_openingReplay) return;
      _openingReplay = true;
      try {
        final position = _showHighlights
            ? _fullGamePosition
            : controller.value.position;
        await controller.pause();
        if (mounted) await widget.onOpenReplay!(position);
      } finally {
        _openingReplay = false;
      }
      return;
    }
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      if (_showHighlights) {
        final highlights = _availableHighlights(controller);
        if (highlights.isEmpty) return;
        final index = _activeHighlightIndex.clamp(0, highlights.length - 1);
        final end = _boundedPosition(highlights[index].end, controller);
        if (controller.value.position + const Duration(milliseconds: 250) >=
            end) {
          final nextIndex = index == highlights.length - 1 ? 0 : index + 1;
          await _playHighlightAt(nextIndex);
          return;
        }
      }
      await controller.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _openFullscreen() async {
    final controller = _controller;
    if (_fullscreenOpen ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    final highlights = _showHighlights
        ? _availableHighlights(controller)
        : const <FixtureHighlightMoment>[];
    _fullscreenOpen = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _FullscreenVideoPage(
            controller: controller,
            allowSeeking: fixture.isFinal,
            highlights: highlights,
            modeLabel: fixture.isLive
                ? 'LIVE'
                : _showHighlights
                ? 'HIGHLIGHTS'
                : 'FULL GAME',
            onTogglePlayback: _togglePlayback,
          ),
        ),
      );
    } finally {
      _fullscreenOpen = false;
      if (mounted && _needsPlayerSync) await _syncPlayer(force: true);
      if (mounted) setState(() {});
    }
  }

  ProfileHighlightSource get _clipSourceType {
    return widget.sourceLabel?.trim().toUpperCase() == 'SOLO'
        ? ProfileHighlightSource.solo
        : ProfileHighlightSource.clan;
  }

  bool _canAddGoalToProfile(FixtureHighlightMoment moment) {
    final profileId = widget.profileRepository.currentUserId;
    return profileId != null &&
        profileId.isNotEmpty &&
        (moment.event.profileId == profileId ||
            moment.event.assistProfileId == profileId) &&
        moment.event.id.trim().isNotEmpty;
  }

  Future<void> _addGoalToProfile(FixtureHighlightMoment moment) async {
    final eventId = moment.event.id.trim();
    if (!_canAddGoalToProfile(moment) ||
        _savingGoalEventId != null ||
        _savedGoalEventIds.contains(eventId)) {
      return;
    }

    final isAssist =
        moment.event.assistProfileId ==
            widget.profileRepository.currentUserId &&
        moment.event.profileId != widget.profileRepository.currentUserId;
    final title = await _showGoalClipTitleSheet(moment);
    if (!mounted || title == null) return;
    setState(() => _savingGoalEventId = eventId);
    try {
      final highlight = await widget.profileRepository.createGoalClip(
        ProfileGoalClipRequest(
          sourceType: _clipSourceType,
          matchId: fixture.id,
          eventId: eventId,
          title: title,
        ),
      );
      if (!mounted) return;
      setState(() => _savedGoalEventIds.add(eventId));
      showFieldrushToast(
        context,
        highlight.isReady
            ? '${isAssist ? 'Assist' : 'Goal'} added to your profile.'
            : '${isAssist ? 'Assist' : 'Goal'} is being prepared for your profile.',
      );
    } catch (error) {
      if (!mounted) return;
      showFieldrushToast(
        context,
        userFacingError(
          error,
          fallback: 'We could not add this clip. Try again.',
        ),
      );
    } finally {
      if (mounted) setState(() => _savingGoalEventId = null);
    }
  }

  Future<String?> _showGoalClipTitleSheet(FixtureHighlightMoment moment) {
    final currentProfileId = widget.profileRepository.currentUserId;
    final isAssist =
        moment.event.assistProfileId == currentProfileId &&
        moment.event.profileId != currentProfileId;
    return showFieldrushModal<String>(
      context: context,
      builder: (_) => _ClipTitleSheet(
        initialTitle:
            "${isAssist ? 'Assist' : 'Goal'} · ${moment.event.minute}'",
        heading: isAssist ? 'ADD ASSIST TO PROFILE' : 'ADD GOAL TO PROFILE',
        description: 'Give your clip a simple title.',
        actionLabel: 'Add to my profile',
      ),
    );
  }

  Future<void> _downloadGoalClip(FixtureHighlightMoment moment) async {
    final eventId = moment.event.id.trim();
    if (eventId.isEmpty || _downloadingGoalEventId != null) return;
    setState(() {
      _downloadingGoalEventId = eventId;
      _goalDownloadProgress = 0;
    });
    try {
      final media = await widget.profileRepository.getGoalClipDownload(
        sourceType: _clipSourceType,
        matchId: fixture.id,
        eventId: eventId,
      );
      await widget.goalClipDownloader.downloadToGallery(
        url: media.downloadUrl,
        fileName:
            'Goal_${moment.event.minute}_${fixture.homeClan.tag}_vs_${fixture.awayClan?.tag ?? 'match'}.mp4',
        onProgress: (progress) {
          if (mounted) setState(() => _goalDownloadProgress = progress);
        },
      );
      if (!mounted) return;
      showFieldrushToast(context, 'Goal saved to your Photos.');
    } catch (error) {
      _showMediaError(error, 'We could not download this goal. Try again.');
    } finally {
      if (mounted) {
        setState(() {
          _downloadingGoalEventId = null;
          _goalDownloadProgress = null;
        });
      }
    }
  }

  Future<void> _confirmFullGameDownload() async {
    if (_isDownloadingFullGame || _isCreatingCustomClip) return;
    final confirmed = await showFieldConfirmDialog(
      context: context,
      icon: Icons.download_rounded,
      eyebrow: 'Save recording',
      title: 'Download the full game?',
      message:
          'The full recording can be a large file. Keep Fieldrush open while it saves to Photos.',
      detail: 'Highlights and custom clips are much smaller downloads.',
      confirmLabel: 'Download game',
      cancelLabel: 'Not now',
    );
    if (confirmed && mounted) await _downloadFullGame();
  }

  Future<void> _downloadFullGame() async {
    setState(() {
      _isDownloadingFullGame = true;
      _fullGameDownloadProgress = null;
    });
    try {
      ProfileFullGameDownload result = await widget.profileRepository
          .prepareFullGameDownload(
            sourceType: _clipSourceType,
            matchId: fixture.id,
          );
      for (var attempt = 0; result.isProcessing && attempt < 45; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        result = await widget.profileRepository.prepareFullGameDownload(
          sourceType: _clipSourceType,
          matchId: fixture.id,
        );
      }
      if (result.status == ProfileFullGameDownloadStatus.failed) {
        throw StateError(
          result.errorMessage ??
              'The full-game download could not be prepared.',
        );
      }
      final downloadUrl = result.downloadUrl;
      if (!result.isReady || downloadUrl == null) {
        throw StateError(
          'The full game is still being prepared. Try again in a moment.',
        );
      }
      await widget.goalClipDownloader.downloadToGallery(
        url: downloadUrl,
        fileName:
            '${fixture.homeClan.tag}_vs_${fixture.awayClan?.tag ?? 'match'}_full_game.mp4',
        onProgress: (progress) {
          if (mounted) setState(() => _fullGameDownloadProgress = progress);
        },
      );
      if (!mounted) return;
      showFieldrushToast(context, 'Full game saved to your Photos.');
    } catch (error) {
      _showMediaError(error, 'We could not download the full game. Try again.');
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingFullGame = false;
          _fullGameDownloadProgress = null;
        });
      }
    }
  }

  Future<void> _openCustomClipEditor() async {
    if (_isDownloadingFullGame || _isCreatingCustomClip || _editorOpen) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      _showMediaError(
        StateError('The match recording is not ready yet.'),
        'The match recording is not ready yet.',
      );
      return;
    }

    final initialPosition = controller.value.position;
    _editorOpen = true;
    _ClipRange? range;
    try {
      if (controller.value.isPlaying) await controller.pause();
      if (_showHighlights) {
        await _selectCompletedView(_CompletedVideoView.fullGame);
        await controller.seekTo(_boundedPosition(initialPosition, controller));
      }
      if (!mounted) return;
      range = await Navigator.of(context).push<_ClipRange>(
        MaterialPageRoute<_ClipRange>(
          fullscreenDialog: true,
          builder: (_) => Theme(
            data: FieldrushAuthTheme.theme(context),
            child: _CustomClipEditorPage(
              controller: controller,
              thumbnailUrls: _clipTimelineThumbnailUrls(
                controller.value.duration,
              ),
              initialPosition: controller.value.position,
            ),
          ),
        ),
      );
      if (mounted && controller == _controller) {
        await controller.seekTo(_boundedPosition(initialPosition, controller));
        _fullGamePosition = initialPosition;
      }
    } catch (error) {
      if (mounted) {
        _showMediaError(error, 'Could not open the clip editor. Try again.');
      }
      return;
    } finally {
      _editorOpen = false;
      if (mounted && _needsPlayerSync) await _syncPlayer(force: true);
    }
    if (!mounted || range == null) return;

    final outcome = await showFieldrushModal<_CustomClipOutcome>(
      context: context,
      builder: (_) => const _CustomClipOutcomeSheet(),
    );
    if (!mounted || outcome == null) return;

    String title =
        'Match clip · ${_formatVideoTime(Duration(milliseconds: (range.startSeconds * 1000).round()))}';
    if (outcome == _CustomClipOutcome.saveToProfile) {
      final chosenTitle = await showFieldrushModal<String>(
        context: context,
        builder: (_) => _ClipTitleSheet(
          initialTitle: title,
          heading: 'SAVE CLIP TO PROFILE',
          description: 'Give this moment a simple title.',
          actionLabel: 'Save to my profile',
        ),
      );
      if (!mounted || chosenTitle == null) return;
      title = chosenTitle;
    }

    setState(() {
      _isCreatingCustomClip = true;
      _customClipDownloadProgress = outcome == _CustomClipOutcome.download
          ? 0
          : null;
    });
    final request = ProfileCustomClipRequest(
      sourceType: _clipSourceType,
      matchId: fixture.id,
      startSeconds: range.startSeconds,
      endSeconds: range.endSeconds,
      title: title,
    );
    try {
      if (outcome == _CustomClipOutcome.saveToProfile) {
        await widget.profileRepository.createCustomClip(request);
        if (!mounted) return;
        showFieldrushToast(context, 'Clip added to your profile.');
      } else {
        final media = await widget.profileRepository.getCustomClipDownload(
          request,
        );
        await widget.goalClipDownloader.downloadToGallery(
          url: media.downloadUrl,
          fileName:
              '${fixture.homeClan.tag}_vs_${fixture.awayClan?.tag ?? 'match'}_clip.mp4',
          onProgress: (progress) {
            if (mounted) setState(() => _customClipDownloadProgress = progress);
          },
        );
        if (!mounted) return;
        showFieldrushToast(context, 'Clip saved to your Photos.');
      }
    } catch (error) {
      _showMediaError(error, 'We could not create this clip. Try again.');
    } finally {
      if (mounted) {
        setState(() {
          _isCreatingCustomClip = false;
          _customClipDownloadProgress = null;
        });
      }
    }
  }

  void _handleVideoAction(_MatchVideoAction action) {
    switch (action) {
      case _MatchVideoAction.downloadFullGame:
        unawaited(_confirmFullGameDownload());
        break;
      case _MatchVideoAction.createClip:
        unawaited(_openCustomClipEditor());
        break;
    }
  }

  Future<void> _showVideoActions() async {
    final action = await showFieldrushModal<_MatchVideoAction>(
      context: context,
      builder: (context) => FieldrushModal(
        title: 'Match video options',
        actions: [
          _ClipOutcomeButton(
            key: const ValueKey('download-full-game'),
            icon: Icons.download_rounded,
            title: 'Download full game',
            detail: 'Save the entire recording',
            filled: false,
            onTap: () =>
                Navigator.of(context).pop(_MatchVideoAction.downloadFullGame),
          ),
          _ClipOutcomeButton(
            key: const ValueKey('create-match-clip'),
            icon: Icons.content_cut_rounded,
            title: 'Create a clip',
            detail: 'Choose up to 60 seconds',
            filled: false,
            onTap: () =>
                Navigator.of(context).pop(_MatchVideoAction.createClip),
          ),
        ],
      ),
    );
    if (action != null && mounted) _handleVideoAction(action);
  }

  List<String> _clipTimelineThumbnailUrls(Duration duration) {
    return _matchClipTimelineThumbnailUrls(fixture, duration);
  }

  Widget _buildVideoActionOverlay() {
    if (_isDownloadingFullGame || _isCreatingCustomClip) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xCC111827),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white24),
        ),
        child: _WatchMediaProgress(
          progress: _isDownloadingFullGame
              ? _fullGameDownloadProgress
              : _customClipDownloadProgress,
          label: _isDownloadingFullGame ? 'Full game' : 'Creating clip',
          onDark: true,
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xB3111827),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white24),
      ),
      child: IconButton(
        key: const ValueKey('watch-actions-menu'),
        tooltip: 'Match video options',
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
        onPressed: () => unawaited(_showVideoActions()),
      ),
    );
  }

  void _showMediaError(Object error, String fallback) {
    if (!mounted) return;
    showFieldrushToast(context, userFacingError(error, fallback: fallback));
  }

  @override
  Widget build(BuildContext context) {
    final isLive = fixture.isLive;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: FieldrushAuthTheme.border),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(15),
            child: Row(
              children: [
                Icon(
                  Icons.play_circle_rounded,
                  color: isLive
                      ? const Color(0xFFEF4444)
                      : FieldrushAuthTheme.forest,
                ),
                const SizedBox(width: 8),
                Text(
                  isLive
                      ? 'LIVE STREAM'
                      : fixture.isFinal
                      ? 'WATCH MATCH'
                      : 'MATCH VIDEO',
                  style: const TextStyle(
                    color: FieldrushAuthTheme.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                if (isLive) ...[
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      'LIVE',
                      style: TextStyle(
                        color: Color(0xFFDC2626),
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (fixture.isFinal) ...[
            const Divider(height: 1, color: FieldrushAuthTheme.border),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Container(
                key: const ValueKey('completed-video-switcher'),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: FieldrushAuthTheme.cream,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  children: [
                    for (final view in _CompletedVideoView.values)
                      Expanded(
                        child: Semantics(
                          selected: _completedView == view,
                          button: true,
                          child: Material(
                            color: _completedView == view
                                ? FieldrushAuthTheme.forest
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(999),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(999),
                              onTap: () =>
                                  unawaited(_selectCompletedView(view)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 11,
                                ),
                                child: Text(
                                  view == _CompletedVideoView.highlights
                                      ? 'Highlights'
                                      : 'Full Game',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13,
                                    color: _completedView == view
                                        ? Colors.white
                                        : FieldrushAuthTheme.muted,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: FieldrushAuthTheme.ink,
              child: _buildPlayerBody(),
            ),
          ),
          if (fixture.isFinal) _buildCompletedPlaybackControls(),
          if (!fixture.isFinal && !fixture.isCancelled)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              color: FieldrushAuthTheme.cream,
              child: const Row(
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    size: 17,
                    color: FieldrushAuthTheme.muted,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Highlights will be available after the game',
                      style: TextStyle(
                        color: FieldrushAuthTheme.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlayerBody() {
    final isLive = fixture.isLive;
    final isProcessing =
        fixture.broadcast?.isProcessing == true ||
        fixture.broadcast?.isStopping == true;
    final controller = _controller;
    final highlights = _availableHighlights(controller);
    final hasNoUsableHighlights =
        _highlightMoments.isEmpty ||
        (controller?.value.isInitialized == true && highlights.isEmpty);

    if (_showHighlights && hasNoUsableHighlights) {
      final recordedGoals = fixture.timeline.where((event) {
        return event.eventType.toUpperCase() == 'GOAL' &&
            event.note?.toLowerCase() != 'admin correction';
      }).length;
      final isWaitingForHighlightTiming =
          recordedGoals > 0 && isProcessing && _highlightMoments.isEmpty;
      return _buildEmptyState(
        icon: Icons.auto_awesome_rounded,
        title: isWaitingForHighlightTiming
            ? 'Preparing highlights...'
            : recordedGoals == 0
            ? 'No goal highlights from this match'
            : 'Highlights are not available for this recording',
        detail: isWaitingForHighlightTiming
            ? 'They will appear as soon as the recording is ready.'
            : fixture.fullGamePlaybackUrl == null
            ? 'The full game replay is not available yet.'
            : 'You can still watch the full game.',
        actionLabel: fixture.fullGamePlaybackUrl == null
            ? null
            : 'Watch full game',
        onAction: fixture.fullGamePlaybackUrl == null
            ? null
            : () =>
                  unawaited(_selectCompletedView(_CompletedVideoView.fullGame)),
      );
    }

    if (controller != null && controller.value.isInitialized) {
      final activeHighlight = _showHighlights && highlights.isNotEmpty
          ? highlights[_activeHighlightIndex.clamp(0, highlights.length - 1)]
          : null;
      return _InlineVideoPlayer(
        controller: controller,
        isLive: isLive,
        rangeStart: activeHighlight?.start ?? Duration.zero,
        rangeEnd: activeHighlight?.end ?? controller.value.duration,
        label: activeHighlight == null
            ? isLive
                  ? 'LIVE'
                  : 'FULL GAME'
            : _highlightLabel(highlights),
        seekKey: ValueKey(
          activeHighlight == null ? 'full-game-seek' : 'highlight-video-seek',
        ),
        onTogglePlayback: _togglePlayback,
        onOpenFullscreen: _openFullscreen,
        actionOverlay: fixture.isFinal && fixture.fullGamePlaybackUrl != null
            ? _buildVideoActionOverlay()
            : null,
      );
    }

    if (_isLoading) {
      return const _VideoSkeleton();
    }

    final message =
        _playerError ??
        (isLive
            ? 'Connecting to live stream...'
            : _showHighlights && isProcessing
            ? 'Preparing highlights...'
            : _showHighlights
            ? 'Highlights are not available yet'
            : fixture.isFinal && isProcessing
            ? 'Preparing the full game replay...'
            : fixture.isFinal
            ? 'Full game replay is not available yet'
            : fixture.isCancelled
            ? 'No video is available for this match'
            : 'Broadcast starts on match day');
    final detail = _showHighlights && isProcessing
        ? 'They will appear as soon as the recording is ready.'
        : null;
    return _buildEmptyState(
      icon: _showHighlights
          ? Icons.auto_awesome_rounded
          : fixture.isFinal
          ? Icons.movie_creation_outlined
          : isLive
          ? Icons.sensors_rounded
          : Icons.schedule_rounded,
      title: message,
      detail: detail,
      actionLabel: _playerError == null ? null : 'Try again',
      onAction: _playerError == null
          ? null
          : () => unawaited(_syncPlayer(force: true)),
    );
  }

  String _highlightLabel(List<FixtureHighlightMoment> highlights) {
    final index = _activeHighlightIndex.clamp(0, highlights.length - 1);
    final event = highlights[index].event;
    final scorer = event.playerName == 'Unknown' ? 'Goal' : event.playerName;
    return '$scorer · ${event.minute}\' · ${index + 1}/${highlights.length}';
  }

  Widget _buildCompletedPlaybackControls() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }

    if (_showHighlights) {
      final highlights = _availableHighlights(controller);
      if (highlights.isEmpty) return const SizedBox.shrink();
      final selected =
          highlights[_activeHighlightIndex.clamp(0, highlights.length - 1)];
      return _GoalJumpBar(
        highlights: highlights,
        activeIndex: _activeHighlightIndex,
        onSelect: (index) => unawaited(_playHighlightAt(index)),
        canAddSelected: _canAddGoalToProfile(selected),
        isSavingSelected: _savingGoalEventId == selected.event.id,
        isSelectedSaved: _savedGoalEventIds.contains(selected.event.id),
        isDownloadingSelected: _downloadingGoalEventId == selected.event.id,
        downloadProgress: _downloadingGoalEventId == selected.event.id
            ? _goalDownloadProgress
            : null,
        onAddSelected: () => unawaited(_addGoalToProfile(selected)),
        onDownloadSelected: () => unawaited(_downloadGoalClip(selected)),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Keep your best moments',
              style: TextStyle(
                color: FieldrushAuthTheme.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            key: const ValueKey('watch-quick-clip'),
            onPressed: _isCreatingCustomClip || _isDownloadingFullGame
                ? null
                : () => unawaited(_openCustomClipEditor()),
            icon: const Icon(Icons.content_cut_rounded, size: 16),
            label: const Text('Clip'),
            style: OutlinedButton.styleFrom(
              foregroundColor: FieldrushAuthTheme.forest,
              backgroundColor: FieldrushAuthTheme.cream,
              side: const BorderSide(color: FieldrushAuthTheme.border),
              shape: const StadiumBorder(),
              textStyle: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    String? detail,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white60, size: 34),
          const SizedBox(height: 8),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 5),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                detail,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 10),
            TextButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ],
      ),
    );
  }
}

class _ClipTitleSheet extends StatefulWidget {
  const _ClipTitleSheet({
    required this.initialTitle,
    required this.heading,
    required this.description,
    required this.actionLabel,
  });

  final String initialTitle;
  final String heading;
  final String description;
  final String actionLabel;

  @override
  State<_ClipTitleSheet> createState() => _ClipTitleSheetState();
}

class _ClipTitleSheetState extends State<_ClipTitleSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialTitle,
  );
  String? _validationMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = _controller.text.trim();
    if (value.length < 2 || value.length > 80) {
      setState(() {
        _validationMessage = 'Use a title between 2 and 80 characters.';
      });
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return FieldrushModal(
      title: widget.heading,
      description: widget.description,
      content: TextField(
        key: const ValueKey('goal-clip-title-field'),
        controller: _controller,
        autofocus: true,
        maxLength: 80,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        decoration: InputDecoration(
          labelText: 'Clip title',
          hintText: 'Top corner finish',
          errorText: _validationMessage,
        ),
      ),
      actions: [
        FilledButton.icon(
          key: const ValueKey('save-goal-clip'),
          onPressed: _save,
          icon: const Icon(Icons.add_rounded),
          label: Text(widget.actionLabel),
          style: FieldrushModal.primaryButtonStyle(),
        ),
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          style: FieldrushModal.secondaryButtonStyle(),
          child: const Text('Not now'),
        ),
      ],
    );
  }
}

class _CustomClipEditorPage extends StatefulWidget {
  const _CustomClipEditorPage({
    required this.controller,
    required this.initialPosition,
    required this.thumbnailUrls,
  });

  final VideoPlayerController controller;
  final Duration initialPosition;
  final List<String> thumbnailUrls;

  @override
  State<_CustomClipEditorPage> createState() => _CustomClipEditorPageState();
}

class _CustomClipEditorPageState extends State<_CustomClipEditorPage> {
  static const _maxClipSeconds = 60.0;
  static const _seekDebounceDuration = Duration(milliseconds: 45);
  static const _previewEndTolerance = Duration(milliseconds: 120);

  late final double _recordingSeconds;
  late RangeValues _range;
  late double _timelineStart;
  late double _timelineEnd;
  Timer? _seekDebounce;
  Future<void> _seekTail = Future<void>.value();
  int _seekGeneration = 0;
  bool _lastMovedStart = false;
  bool _isPreviewing = false;
  bool _isStoppingAtEnd = false;
  bool _isClosing = false;
  bool _isDraggingPlayhead = false;
  double? _draggedPlayheadSeconds;

  @override
  void initState() {
    super.initState();
    _recordingSeconds = (widget.controller.value.duration.inMilliseconds / 1000)
        .clamp(1.0, double.infinity)
        .toDouble();
    final current = (widget.initialPosition.inMilliseconds / 1000)
        .clamp(0.0, _recordingSeconds)
        .toDouble();
    var start = (current - 10).clamp(0.0, _recordingSeconds).toDouble();
    var end = (current + 20).clamp(0.0, _recordingSeconds).toDouble();
    if (end - start > _maxClipSeconds) end = start + _maxClipSeconds;
    if (end - start < 1) {
      end = (start + 1).clamp(0.0, _recordingSeconds).toDouble();
      start = (end - 1).clamp(0.0, _recordingSeconds).toDouble();
    }
    _range = RangeValues(start, end);
    _setTimelineWindowAround(current);
    widget.controller.addListener(_handleControllerTick);
  }

  @override
  void dispose() {
    _seekDebounce?.cancel();
    _seekGeneration += 1;
    widget.controller.removeListener(_handleControllerTick);
    super.dispose();
  }

  double get _clipDuration => _range.end - _range.start;
  double get _clipCenter => (_range.start + _range.end) / 2;

  Duration _durationAt(double seconds) {
    return Duration(
      milliseconds: (seconds * Duration.millisecondsPerSecond).round(),
    );
  }

  String _time(double seconds) => _formatVideoTime(_durationAt(seconds));

  void _setTimelineWindowAround(double center) {
    final windowLength = _recordingSeconds < 120 ? _recordingSeconds : 120.0;
    final maxStart = (_recordingSeconds - windowLength).clamp(
      0.0,
      _recordingSeconds,
    );
    _timelineStart = (center - (windowLength / 2))
        .clamp(0.0, maxStart)
        .toDouble();
    _timelineEnd = _timelineStart + windowLength;
  }

  void _handleControllerTick() {
    if (!_isPreviewing || _isStoppingAtEnd || !mounted) return;
    final value = widget.controller.value;
    if (!value.isInitialized || !value.isPlaying) return;
    final end = _durationAt(_range.end);
    if (value.position + _previewEndTolerance < end) return;
    _isStoppingAtEnd = true;
    unawaited(_stopPreviewAtEnd());
  }

  Future<void> _stopPreviewAtEnd() async {
    final generation = _seekGeneration;
    try {
      await _enqueueControllerAction(generation, () async {
        await widget.controller.pause();
        if (!_isCurrentAction(generation)) return;
        await widget.controller.seekTo(_durationAt(_range.end));
        if (_isCurrentAction(generation)) setState(() => _isPreviewing = false);
      });
    } finally {
      _isStoppingAtEnd = false;
    }
  }

  void _queueSeek(double seconds, {bool immediate = false}) {
    if (_isClosing) return;
    _seekDebounce?.cancel();
    final generation = ++_seekGeneration;
    final target = seconds.clamp(0.0, _recordingSeconds).toDouble();
    if (immediate) {
      unawaited(_performSeek(target, generation));
      return;
    }
    _seekDebounce = Timer(
      _seekDebounceDuration,
      () => unawaited(_performSeek(target, generation)),
    );
  }

  bool _isCurrentAction(int generation) =>
      mounted && !_isClosing && generation == _seekGeneration;

  Future<void> _enqueueControllerAction(
    int generation,
    Future<void> Function() action,
  ) {
    // Keep one native HLS seek in flight. Superseded slider positions are
    // skipped, so a slow old request cannot move the preview backwards.
    return _seekTail = _seekTail
        .catchError((Object _) {})
        .then((_) async {
          if (_isCurrentAction(generation)) await action();
        })
        .catchError((Object _) {
          if (mounted && generation == _seekGeneration) {
            showFieldrushToast(
              context,
              'Could not preview that moment. Try again.',
            );
          }
        });
  }

  Future<void> _performSeek(double seconds, int generation) =>
      _enqueueControllerAction(generation, () async {
        if (widget.controller.value.isPlaying) await widget.controller.pause();
        if (!_isCurrentAction(generation)) return;
        if (_isPreviewing) setState(() => _isPreviewing = false);
        await widget.controller.seekTo(_durationAt(seconds));
        if (!_isCurrentAction(generation) || _isDraggingPlayhead) return;
        if (_draggedPlayheadSeconds != null) {
          setState(() => _draggedPlayheadSeconds = null);
        }
      });

  void _updateRange(RangeValues next, {bool immediate = false}) {
    final movedStart = (next.start - _range.start).abs();
    final movedEnd = (next.end - _range.end).abs();
    _lastMovedStart = movedStart > movedEnd;
    var start = next.start.clamp(_timelineStart, _timelineEnd).toDouble();
    var end = next.end.clamp(_timelineStart, _timelineEnd).toDouble();
    if (end - start > _maxClipSeconds) {
      if (_lastMovedStart) {
        start = end - _maxClipSeconds;
      } else {
        end = start + _maxClipSeconds;
      }
    }
    if (end - start < 1) {
      if ((start - _range.start).abs() > (end - _range.end).abs()) {
        start = end - 1;
      } else {
        end = start + 1;
      }
    }
    start = start.clamp(_timelineStart, _timelineEnd).toDouble();
    end = end.clamp(_timelineStart, _timelineEnd).toDouble();
    if (end - start < 1) {
      start = (end - 1).clamp(_timelineStart, _timelineEnd).toDouble();
      end = (start + 1).clamp(_timelineStart, _timelineEnd).toDouble();
    }
    setState(() {
      _range = RangeValues(start, end);
      _draggedPlayheadSeconds = null;
    });
    _queueSeek(_lastMovedStart ? start : end, immediate: immediate);
  }

  void _finishRangeDrag() {
    _queueSeek(_lastMovedStart ? _range.start : _range.end, immediate: true);
  }

  void _adjustStart(double delta) {
    final lowerBound = (_range.end - _maxClipSeconds)
        .clamp(_timelineStart, _timelineEnd)
        .toDouble();
    final start = (_range.start + delta)
        .clamp(lowerBound, _range.end - 1)
        .toDouble();
    _updateRange(RangeValues(start, _range.end), immediate: true);
  }

  void _adjustEnd(double delta) {
    final upperBound = (_range.start + _maxClipSeconds)
        .clamp(_timelineStart, _timelineEnd)
        .toDouble();
    final end = (_range.end + delta)
        .clamp(_range.start + 1, upperBound)
        .toDouble();
    _updateRange(RangeValues(_range.start, end), immediate: true);
  }

  void _moveClipThroughMatch(double requestedCenter, {bool immediate = false}) {
    final duration = _clipDuration;
    final maxStart = (_recordingSeconds - duration).clamp(
      0.0,
      _recordingSeconds,
    );
    final start = (requestedCenter - (duration / 2))
        .clamp(0.0, maxStart)
        .toDouble();
    final end = start + duration;
    final center = (start + end) / 2;
    setState(() {
      _range = RangeValues(start, end);
      _setTimelineWindowAround(center);
      _draggedPlayheadSeconds = null;
    });
    _queueSeek(center, immediate: immediate);
  }

  void _startPlayheadDrag(double seconds) {
    _seekDebounce?.cancel();
    _seekGeneration += 1;
    setState(() {
      _isPreviewing = false;
      _isDraggingPlayhead = true;
      _draggedPlayheadSeconds = seconds;
    });
    _queueSeek(seconds, immediate: true);
  }

  void _dragPlayhead(double seconds) {
    setState(() => _draggedPlayheadSeconds = seconds);
    _queueSeek(seconds);
  }

  void _finishPlayheadDrag(double seconds) {
    setState(() {
      _isDraggingPlayhead = false;
      _draggedPlayheadSeconds = seconds;
    });
    _queueSeek(seconds, immediate: true);
  }

  Future<void> _previewSelection() async {
    if (_isClosing) return;
    _seekDebounce?.cancel();
    final generation = ++_seekGeneration;
    await _enqueueControllerAction(generation, () async {
      if (widget.controller.value.isPlaying) await widget.controller.pause();
      if (!_isCurrentAction(generation)) return;
      await widget.controller.seekTo(_durationAt(_range.start));
      if (!_isCurrentAction(generation)) return;
      setState(() {
        _isPreviewing = true;
        _draggedPlayheadSeconds = null;
      });
      await widget.controller.play();
    });
  }

  Future<void> _togglePlayback() async {
    if (_isClosing) return;
    _seekDebounce?.cancel();
    final generation = ++_seekGeneration;
    await _enqueueControllerAction(generation, () async {
      if (widget.controller.value.isPlaying) {
        await widget.controller.pause();
        if (_isCurrentAction(generation)) setState(() => _isPreviewing = false);
        return;
      }
      final positionSeconds =
          widget.controller.value.position.inMilliseconds / 1000;
      if (positionSeconds < _range.start ||
          positionSeconds >= _range.end - 0.12) {
        await widget.controller.seekTo(_durationAt(_range.start));
      }
      if (!_isCurrentAction(generation)) return;
      setState(() {
        _isPreviewing = true;
        _draggedPlayheadSeconds = null;
      });
      await widget.controller.play();
    });
  }

  Future<void> _close([_ClipRange? result]) async {
    if (_isClosing) return;
    _isClosing = true;
    _seekDebounce?.cancel();
    _seekGeneration += 1;
    await _seekTail;
    if (!mounted) return;
    if (widget.controller.value.isPlaying) await widget.controller.pause();
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<_ClipRange>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        backgroundColor: FieldrushAuthTheme.cream,
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildVideoPreview(),
              Expanded(child: _buildEditorPanel()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return SizedBox(
      height: 58,
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('custom-clip-cancel'),
            tooltip: 'Cancel clip',
            onPressed: () => unawaited(_close()),
            color: FieldrushAuthTheme.ink,
            icon: const Icon(Icons.close_rounded),
          ),
          const Expanded(
            child: Text(
              'Create match clip',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: FieldrushAuthTheme.ink,
                fontFamily: 'Outfit',
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildVideoPreview() {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final rawPosition = value.position.inMilliseconds / 1000;
        final shownPosition = rawPosition
            .clamp(_range.start, _range.end)
            .toDouble();
        final progress = _clipDuration <= 0
            ? 0.0
            : ((shownPosition - _range.start) / _clipDuration)
                  .clamp(0.0, 1.0)
                  .toDouble();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              key: const ValueKey('custom-clip-video-preview'),
              aspectRatio: 16 / 9,
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: AspectRatio(
                        aspectRatio: value.aspectRatio == 0
                            ? 16 / 9
                            : value.aspectRatio,
                        child: VideoPlayer(widget.controller),
                      ),
                    ),
                    GestureDetector(
                      key: const ValueKey('custom-clip-video-tap-target'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => unawaited(_togglePlayback()),
                    ),
                    Center(
                      child: AnimatedOpacity(
                        opacity: value.isPlaying ? 0 : 1,
                        duration: const Duration(milliseconds: 160),
                        child: IgnorePointer(
                          ignoring: value.isPlaying,
                          child: IconButton(
                            key: const ValueKey('custom-clip-video-play'),
                            tooltip: 'Play selected clip',
                            onPressed: () => unawaited(_togglePlayback()),
                            iconSize: 38,
                            padding: const EdgeInsets.all(12),
                            style: IconButton.styleFrom(
                              backgroundColor: FieldrushAuthTheme.cream
                                  .withValues(alpha: 0.94),
                              foregroundColor: FieldrushAuthTheme.ink,
                              minimumSize: const Size(62, 62),
                            ),
                            icon: const Icon(Icons.play_arrow_rounded),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            LinearProgressIndicator(
              key: const ValueKey('custom-clip-preview-progress'),
              value: progress,
              minHeight: 3,
              backgroundColor: FieldrushAuthTheme.border,
              valueColor: const AlwaysStoppedAnimation<Color>(
                FieldrushAuthTheme.forest,
              ),
            ),
            SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: value.isPlaying
                          ? 'Pause preview'
                          : 'Play preview',
                      onPressed: () => unawaited(_togglePlayback()),
                      color: FieldrushAuthTheme.ink,
                      icon: Icon(
                        value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${_time(shownPosition - _range.start)} / ${_time(_clipDuration)}',
                      style: const TextStyle(
                        color: FieldrushAuthTheme.muted,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      '60 sec max',
                      style: TextStyle(
                        color: FieldrushAuthTheme.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEditorPanel() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(color: FieldrushAuthTheme.cream),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          18,
          18,
          18,
          18 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'SELECT YOUR MOMENT',
              style: TextStyle(
                color: FieldrushAuthTheme.ink,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 3),
            const Text(
              'Move through the match, trim both ends, then preview it before continuing.',
              style: TextStyle(
                color: FieldrushAuthTheme.muted,
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 15),
            _buildMatchNavigator(),
            const SizedBox(height: 14),
            _buildTrimEditor(),
            const SizedBox(height: 14),
            _buildEndpointControls(),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: widget.controller,
                builder: (context, value, _) {
                  return OutlinedButton.icon(
                    key: const ValueKey('custom-clip-preview-selection'),
                    onPressed: value.isPlaying && _isPreviewing
                        ? () => unawaited(_togglePlayback())
                        : () => unawaited(_previewSelection()),
                    icon: Icon(
                      value.isPlaying && _isPreviewing
                          ? Icons.pause_rounded
                          : Icons.replay_rounded,
                    ),
                    label: Text(
                      value.isPlaying && _isPreviewing
                          ? 'Pause preview'
                          : 'Preview selection',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: FieldrushAuthTheme.ink,
                      side: const BorderSide(color: FieldrushAuthTheme.border),
                      textStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 9),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                key: const ValueKey('custom-clip-continue'),
                onPressed: () => unawaited(
                  _close(
                    _ClipRange(
                      startSeconds: _range.start,
                      endSeconds: _range.end,
                    ),
                  ),
                ),
                icon: const Icon(Icons.arrow_forward_rounded),
                label: const Text('Continue'),
                style: FilledButton.styleFrom(
                  backgroundColor: FieldrushAuthTheme.forest,
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMatchNavigator() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'MOVE THROUGH MATCH',
              style: TextStyle(
                color: FieldrushAuthTheme.muted,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.8,
              ),
            ),
            const Spacer(),
            Text(
              _time(_clipCenter),
              style: const TextStyle(
                color: FieldrushAuthTheme.ink,
                fontSize: 12,
                fontWeight: FontWeight.w900,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 56,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _ClipFilmstrip(thumbnailUrls: widget.thumbnailUrls),
                ColoredBox(
                  color: FieldrushAuthTheme.cream.withValues(alpha: 0.12),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    activeTrackColor: FieldrushAuthTheme.forest,
                    inactiveTrackColor: FieldrushAuthTheme.border,
                    thumbColor: FieldrushAuthTheme.forest,
                    overlayColor: FieldrushAuthTheme.forest.withValues(
                      alpha: 0.18,
                    ),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 8,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 16,
                    ),
                  ),
                  child: Slider(
                    key: const ValueKey('custom-clip-match-position'),
                    min: 0,
                    max: _recordingSeconds,
                    value: _clipCenter.clamp(0.0, _recordingSeconds),
                    label: _time(_clipCenter),
                    onChanged: _moveClipThroughMatch,
                    onChangeEnd: (value) =>
                        _moveClipThroughMatch(value, immediate: true),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTrimEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'TRIM CLIP',
              style: TextStyle(
                color: FieldrushAuthTheme.muted,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.8,
              ),
            ),
            const Spacer(),
            Text(
              '${_time(_timelineStart)} – ${_time(_timelineEnd)}',
              style: const TextStyle(
                color: FieldrushAuthTheme.muted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        FieldrushClipTrimTimeline(
          sliderKey: const ValueKey('custom-clip-range'),
          min: _timelineStart,
          max: _timelineEnd,
          values: _range,
          background: const _ClipTrimTrackBackground(),
          formatTime: _time,
          onChanged: _updateRange,
          onChangeEnd: (_) => _finishRangeDrag(),
        ),
        const SizedBox(height: 6),
        ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) {
            final controllerSeconds = value.position.inMilliseconds / 1000;
            final playhead = (_draggedPlayheadSeconds ?? controllerSeconds)
                .clamp(_range.start, _range.end)
                .toDouble();
            return Row(
              children: [
                const Icon(
                  Icons.drag_indicator_rounded,
                  size: 17,
                  color: FieldrushAuthTheme.muted,
                ),
                const SizedBox(width: 3),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: FieldrushAuthTheme.forest,
                      inactiveTrackColor: FieldrushAuthTheme.border,
                      thumbColor: FieldrushAuthTheme.ink,
                      overlayColor: FieldrushAuthTheme.ink.withValues(
                        alpha: 0.1,
                      ),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 15,
                      ),
                    ),
                    child: Slider(
                      key: const ValueKey('custom-clip-playhead'),
                      min: _range.start,
                      max: _range.end,
                      value: playhead,
                      label: _time(playhead),
                      semanticFormatterCallback: (_) =>
                          'Preview frame at ${_time(playhead)}',
                      onChangeStart: _startPlayheadDrag,
                      onChanged: _dragPlayhead,
                      onChangeEnd: _finishPlayheadDrag,
                    ),
                  ),
                ),
                SizedBox(
                  width: 42,
                  child: Text(
                    _time(playhead),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: FieldrushAuthTheme.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildEndpointControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: FieldrushAuthTheme.border),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ClipEndpoint(
              label: 'START',
              value: _time(_range.start),
              onPreview: () => _queueSeek(_range.start, immediate: true),
              onBack: () => _adjustStart(-1),
              onForward: () => _adjustStart(1),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.arrow_forward_rounded,
                  color: FieldrushAuthTheme.muted,
                  size: 19,
                ),
                const SizedBox(height: 3),
                Text(
                  '${_clipDuration.round()} SEC',
                  key: const ValueKey('custom-clip-duration'),
                  style: const TextStyle(
                    color: FieldrushAuthTheme.forest,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _ClipEndpoint(
              label: 'END',
              value: _time(_range.end),
              onPreview: () => _queueSeek(_range.end, immediate: true),
              onBack: () => _adjustEnd(-1),
              onForward: () => _adjustEnd(1),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClipFilmstrip extends StatelessWidget {
  const _ClipFilmstrip({required this.thumbnailUrls});

  final List<String> thumbnailUrls;

  @override
  Widget build(BuildContext context) {
    if (thumbnailUrls.isEmpty) return const _ClipTrimTrackBackground();
    return Row(
      children: [
        for (var index = 0; index < thumbnailUrls.length; index++)
          Expanded(
            child: Image.network(
              thumbnailUrls[index],
              height: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _ClipFrameFallback(index: index),
            ),
          ),
      ],
    );
  }
}

class _ClipTrimTrackBackground extends StatelessWidget {
  const _ClipTrimTrackBackground();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var index = 0; index < 10; index++)
          Expanded(child: _ClipFrameFallback(index: index)),
      ],
    );
  }
}

class _ClipFrameFallback extends StatelessWidget {
  const _ClipFrameFallback({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final even = index.isEven;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: even
              ? const [FieldrushAuthTheme.watermark, FieldrushAuthTheme.border]
              : const [Color(0xFFE8EDDF), Color(0xFFDCE5D7)],
        ),
        border: const Border(
          right: BorderSide(color: FieldrushAuthTheme.cream, width: 0.5),
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.sports_soccer_rounded,
          color: FieldrushAuthTheme.muted,
          size: 15,
        ),
      ),
    );
  }
}

class _ClipEndpoint extends StatelessWidget {
  const _ClipEndpoint({
    required this.label,
    required this.value,
    required this.onPreview,
    required this.onBack,
    required this.onForward,
  });

  final String label;
  final String value;
  final VoidCallback onPreview;
  final VoidCallback onBack;
  final VoidCallback onForward;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: FieldrushAuthTheme.muted,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 5),
        InkWell(
          onTap: onPreview,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            child: Text(
              value,
              style: const TextStyle(
                color: FieldrushAuthTheme.ink,
                fontSize: 19,
                fontWeight: FontWeight.w900,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Move $label back 1 second',
              onPressed: onBack,
              visualDensity: VisualDensity.compact,
              iconSize: 17,
              icon: const Icon(Icons.remove_rounded),
            ),
            const Text(
              '1s',
              style: TextStyle(
                color: FieldrushAuthTheme.muted,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            IconButton(
              tooltip: 'Move $label forward 1 second',
              onPressed: onForward,
              visualDensity: VisualDensity.compact,
              iconSize: 17,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
      ],
    );
  }
}

class _CustomClipOutcomeSheet extends StatelessWidget {
  const _CustomClipOutcomeSheet();

  @override
  Widget build(BuildContext context) {
    return FieldrushModal(
      title: 'WHAT DO YOU WANT TO DO?',
      description:
          'You can keep this moment on Fieldrush or save it straight to Photos.',
      actions: [
        _ClipOutcomeButton(
          key: const ValueKey('custom-clip-save'),
          icon: Icons.person_add_alt_1_rounded,
          title: 'Save to my profile',
          detail: 'Add a title and show it in your Clips',
          filled: true,
          onTap: () =>
              Navigator.of(context).pop(_CustomClipOutcome.saveToProfile),
        ),
        _ClipOutcomeButton(
          key: const ValueKey('custom-clip-download'),
          icon: Icons.download_rounded,
          title: 'Download now',
          detail: 'Save it to your phone without posting it',
          filled: false,
          onTap: () => Navigator.of(context).pop(_CustomClipOutcome.download),
        ),
      ],
    );
  }
}

class _ClipOutcomeButton extends StatelessWidget {
  const _ClipOutcomeButton({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    required this.filled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = filled ? Colors.white : FieldrushAuthTheme.ink;
    final child = Row(
      children: [
        Icon(icon, color: foreground, size: 23),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: FieldrushModal.bodyStyle.copyWith(
                  color: foreground,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                detail,
                style: FieldrushModal.bodyStyle.copyWith(
                  color: filled
                      ? Colors.white.withValues(alpha: .8)
                      : FieldrushAuthTheme.muted,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Icon(Icons.chevron_right_rounded, color: foreground, size: 20),
      ],
    );
    return filled
        ? FilledButton(
            onPressed: onTap,
            style: FieldrushModal.primaryButtonStyle(),
            child: child,
          )
        : OutlinedButton(
            onPressed: onTap,
            style: FieldrushModal.secondaryButtonStyle(),
            child: child,
          );
  }
}

class _WatchMediaProgress extends StatelessWidget {
  const _WatchMediaProgress({
    required this.label,
    this.progress,
    this.onDark = false,
  });

  final String label;
  final double? progress;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final value = progress?.clamp(0.0, 1.0).toDouble();
    return Semantics(
      label: _progressActionLabel(label, value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value == null)
            SizedBox.square(
              dimension: 17,
              child: FieldLoadingIndicator(
                label: label,
                color: onDark ? Colors.white : FieldrushAuthTheme.forest,
              ),
            )
          else
            SizedBox(
              width: 38,
              child: LinearProgressIndicator(
                value: value,
                minHeight: 4,
                borderRadius: BorderRadius.circular(4),
                color: onDark ? Colors.white : FieldrushAuthTheme.forest,
                backgroundColor: onDark
                    ? Colors.white24
                    : FieldrushAuthTheme.border,
              ),
            ),
          const SizedBox(width: 7),
          Text(
            _progressActionLabel(label, value),
            style: TextStyle(
              color: onDark ? Colors.white : FieldrushAuthTheme.muted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

String _progressActionLabel(String label, double? progress) {
  if (progress == null) return '$label...';
  return '$label ${(progress.clamp(0.0, 1.0) * 100).round()}%';
}

class _GoalJumpBar extends StatelessWidget {
  const _GoalJumpBar({
    required this.highlights,
    required this.activeIndex,
    required this.onSelect,
    required this.canAddSelected,
    required this.isSavingSelected,
    required this.isSelectedSaved,
    required this.isDownloadingSelected,
    required this.downloadProgress,
    required this.onAddSelected,
    required this.onDownloadSelected,
  });

  final List<FixtureHighlightMoment> highlights;
  final int activeIndex;
  final ValueChanged<int> onSelect;
  final bool canAddSelected;
  final bool isSavingSelected;
  final bool isSelectedSaved;
  final bool isDownloadingSelected;
  final double? downloadProgress;
  final VoidCallback onAddSelected;
  final VoidCallback onDownloadSelected;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = activeIndex.clamp(0, highlights.length - 1);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 10),
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'MATCH GOALS',
                style: TextStyle(
                  fontFamily: 'Outfit',
                  color: FieldrushAuthTheme.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              Text(
                '${selectedIndex + 1} / ${highlights.length}',
                style: const TextStyle(
                  color: FieldrushAuthTheme.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 216),
            child: ListView.separated(
              key: const ValueKey('highlight-goal-list'),
              shrinkWrap: true,
              primary: false,
              padding: EdgeInsets.zero,
              itemCount: highlights.length,
              separatorBuilder: (_, _) => const SizedBox(height: 5),
              itemBuilder: (context, index) {
                final selected = index == selectedIndex;
                final event = highlights[index].event;
                final name = event.playerName == 'Unknown'
                    ? 'Goal ${index + 1}'
                    : event.playerName;
                return Semantics(
                  selected: selected,
                  button: true,
                  child: Material(
                    color: selected
                        ? FieldrushAuthTheme.watermark
                        : FieldrushAuthTheme.cream,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      key: ValueKey('highlight-goal-$index'),
                      onTap: () => onSelect(index),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 34,
                              child: Text(
                                "${event.minute}'",
                                style: const TextStyle(
                                  fontFamily: 'Outfit',
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: FieldrushAuthTheme.forest,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'Outfit',
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                      color: FieldrushAuthTheme.ink,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    selected
                                        ? 'Now selected · Goal ${index + 1}'
                                        : 'Goal ${index + 1}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: FieldrushAuthTheme.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              selected
                                  ? Icons.play_circle_fill_rounded
                                  : Icons.play_circle_outline_rounded,
                              size: 26,
                              color: FieldrushAuthTheme.forest,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                key: const ValueKey('download-highlight-clip'),
                onPressed: isDownloadingSelected ? null : onDownloadSelected,
                icon: const Icon(Icons.download_rounded, size: 17),
                label: Text(
                  isDownloadingSelected
                      ? _progressActionLabel('Saving', downloadProgress)
                      : 'Save goal',
                ),
                style: TextButton.styleFrom(
                  foregroundColor: FieldrushAuthTheme.forest,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (canAddSelected)
                TextButton.icon(
                  key: const ValueKey('add-goal-to-profile'),
                  onPressed: isSavingSelected || isSelectedSaved
                      ? null
                      : onAddSelected,
                  icon: Icon(
                    isSelectedSaved ? Icons.check_rounded : Icons.add_rounded,
                    size: 17,
                  ),
                  label: Text(
                    isSavingSelected
                        ? 'Preparing your clip...'
                        : isSelectedSaved
                        ? 'Added to your profile'
                        : 'Add to profile',
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: FieldrushAuthTheme.forest,
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InlineVideoPlayer extends StatelessWidget {
  const _InlineVideoPlayer({
    required this.controller,
    required this.isLive,
    required this.rangeStart,
    required this.rangeEnd,
    required this.label,
    required this.seekKey,
    required this.onTogglePlayback,
    required this.onOpenFullscreen,
    this.actionOverlay,
  });
  final VideoPlayerController controller;
  final bool isLive;
  final Duration rangeStart, rangeEnd;
  final String label;
  final Key seekKey;
  final Future<void> Function() onTogglePlayback;
  final VoidCallback onOpenFullscreen;
  final Widget? actionOverlay;
  @override
  Widget build(BuildContext context) => FieldrushVideoPlayer(
    controller: controller,
    isLive: isLive,
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
    label: label,
    seekKey: seekKey,
    onTogglePlayback: onTogglePlayback,
    onOpenFullscreen: onOpenFullscreen,
    actionOverlay: actionOverlay,
  );
}

String _formatVideoTime(Duration value) {
  final totalSeconds = value.inSeconds < 0 ? 0 : value.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _VideoSkeleton extends StatelessWidget {
  const _VideoSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(22),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0xFF374151),
              shape: BoxShape.circle,
            ),
            child: SizedBox(width: 54, height: 54),
          ),
          SizedBox(height: 14),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0xFF374151),
              borderRadius: BorderRadius.all(Radius.circular(5)),
            ),
            child: SizedBox(width: 170, height: 12),
          ),
        ],
      ),
    );
  }
}

class _FullscreenVideoPage extends StatefulWidget {
  const _FullscreenVideoPage({
    required this.controller,
    required this.allowSeeking,
    required this.highlights,
    required this.modeLabel,
    required this.onTogglePlayback,
  });

  final VideoPlayerController controller;
  final bool allowSeeking;
  final List<FixtureHighlightMoment> highlights;
  final String modeLabel;
  final Future<void> Function() onTogglePlayback;

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  @override
  void initState() {
    super.initState();
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
  }

  @override
  void dispose() {
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]),
    );
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  _PlaybackWindow _playbackWindow(VideoPlayerValue value) {
    if (widget.highlights.isEmpty) {
      return _PlaybackWindow(
        start: Duration.zero,
        end: value.duration,
        label: widget.modeLabel,
      );
    }

    var selected = widget.highlights.first;
    for (final highlight in widget.highlights) {
      if (value.position < highlight.start) break;
      selected = highlight;
    }
    final event = selected.event;
    final scorer = event.playerName == 'Unknown' ? 'Goal' : event.playerName;
    final goalIndex = widget.highlights.indexOf(selected) + 1;
    return _PlaybackWindow(
      start: selected.start,
      end: selected.end > value.duration ? value.duration : selected.end,
      label:
          'GOAL $goalIndex OF ${widget.highlights.length}  ·  $scorer  ·  ${event.minute}\'',
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: widget.controller,
        builder: (context, value, _) {
          final window = _playbackWindow(value);
          return FieldrushVideoPlayer.fullscreen(
            controller: widget.controller,
            isLive: !widget.allowSeeking,
            label: window.label,
            rangeStart: window.start,
            rangeEnd: window.end,
            onTogglePlayback: widget.onTogglePlayback,
            onPlaybackStarted: null,
          );
        },
      ),
    ),
  );
}

class _PlaybackWindow {
  const _PlaybackWindow({
    required this.start,
    required this.end,
    required this.label,
  });

  final Duration start;
  final Duration end;
  final String label;
}

class _ClanCancellationSheet extends StatefulWidget {
  const _ClanCancellationSheet({
    required this.quote,
    this.initialReason,
    this.quoteUpdated = false,
  });

  final ClanFixtureCancellationPreview quote;
  final String? initialReason;
  final bool quoteUpdated;

  @override
  State<_ClanCancellationSheet> createState() => _ClanCancellationSheetState();
}

class _ClanCancellationSheetState extends State<_ClanCancellationSheet> {
  late final _reasonController = TextEditingController(
    text: widget.initialReason,
  );

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final quote = widget.quote;
    return FieldrushModal(
      key: const ValueKey('clan-cancellation-sheet'),
      eyebrow: widget.quoteUpdated
          ? 'Cancellation terms updated'
          : 'Cancel clan match',
      title: quote.createsForfeit
          ? 'This creates an official ${quote.forfeitScore}–0 forfeit'
          : 'Review the policy outcome',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: FieldrushAuthTheme.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _CancellationFact(
                  label: 'Clan strikes',
                  value: '${quote.strikeDelta}',
                ),
                const SizedBox(height: 9),
                _CancellationFact(
                  label: quote.refundDestinationLabel,
                  value: '${quote.refundLabel} · ${quote.refundPercent}%',
                ),
                const SizedBox(height: 9),
                _CancellationFact(
                  label: 'Reliability deposit',
                  value: quote.depositForfeited
                      ? 'Forfeited'
                      : quote.depositRefundFils > 0
                      ? 'Returned · ${quote.depositRefundLabel} included'
                      : 'Not required',
                ),
                if (quote.createsForfeit) ...[
                  const SizedBox(height: 9),
                  const _CancellationFact(
                    label: 'Player SR',
                    value: 'No change · match not played',
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            key: const ValueKey('clan-cancellation-reason'),
            controller: _reasonController,
            autofocus: true,
            maxLength: 1000,
            minLines: 2,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Reason for the audit trail',
              hintText: 'Briefly explain why the clan is cancelling…',
            ),
          ),
        ],
      ),
      actions: [
        FilledButton(
          key: const ValueKey('clan-cancellation-confirm'),
          onPressed:
              !quote.canCancel || _reasonController.text.trim().length < 5
              ? null
              : () => Navigator.of(context).pop(_reasonController.text.trim()),
          style: FieldrushModal.primaryButtonStyle(destructive: true),
          child: const Text('Confirm cancellation'),
        ),
        OutlinedButton(
          key: const ValueKey('clan-cancellation-keep-match'),
          onPressed: () => Navigator.of(context).pop(),
          style: FieldrushModal.secondaryButtonStyle(),
          child: const Text('Keep match'),
        ),
      ],
    );
  }
}

class _CancellationFact extends StatelessWidget {
  const _CancellationFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: FieldrushModal.bodyStyle)),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: FieldrushModal.bodyStyle.copyWith(
              color: FieldrushAuthTheme.ink,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

class _CancelClanBookingActionBar extends StatelessWidget {
  const _CancelClanBookingActionBar({
    required this.isCancelling,
    required this.onCancel,
  });

  final bool isCancelling;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: fieldGray100)),
        ),
        child: OutlinedButton.icon(
          onPressed: isCancelling ? null : onCancel,
          icon: isCancelling
              ? const SizedBox(
                  width: 17,
                  height: 17,
                  child: FieldLoadingIndicator(),
                )
              : const Icon(Icons.event_busy_rounded),
          label: Text(
            isCancelling ? 'Loading policy outcome…' : 'Cancel clan match',
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFB91C1C),
            side: const BorderSide(color: Color(0xFFFECACA)),
            minimumSize: const Size.fromHeight(50),
          ),
        ),
      ),
    );
  }
}

class _JoinActionBar extends StatelessWidget {
  const _JoinActionBar({
    required this.canJoin,
    required this.isJoining,
    required this.onJoin,
  });

  final bool canJoin;
  final bool isJoining;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          border: const Border(top: BorderSide(color: fieldGray100)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton.icon(
            onPressed: canJoin && !isJoining ? onJoin : null,
            icon: isJoining
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: FieldLoadingIndicator(),
                  )
                : const Icon(Icons.sports_mma_rounded),
            label: Text(isJoining ? 'Joining...' : 'Join Match'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              disabledBackgroundColor: fieldGray300,
              disabledForegroundColor: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _CompleteActionBar extends StatelessWidget {
  const _CompleteActionBar({
    required this.canComplete,
    required this.isCompleting,
    required this.onComplete,
  });

  final bool canComplete;
  final bool isCompleting;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          border: const Border(top: BorderSide(color: fieldGray100)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton.icon(
            onPressed: canComplete && !isCompleting ? onComplete : null,
            icon: isCompleting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: FieldLoadingIndicator(),
                  )
                : const Icon(Icons.fact_check_rounded),
            label: Text(isCompleting ? 'Finalizing...' : 'Finalize Score'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              disabledBackgroundColor: fieldGray300,
              disabledForegroundColor: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _ScoreSubmission {
  const _ScoreSubmission({required this.homeScore, required this.awayScore});

  final int homeScore;
  final int awayScore;
}

class _CompleteScoreSheet extends StatefulWidget {
  const _CompleteScoreSheet({required this.fixture});

  final Fixture fixture;

  @override
  State<_CompleteScoreSheet> createState() => _CompleteScoreSheetState();
}

class _CompleteScoreSheetState extends State<_CompleteScoreSheet> {
  late final TextEditingController _homeController;
  late final TextEditingController _awayController;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _homeController = TextEditingController(
      text: (widget.fixture.homeScore ?? 0).toString(),
    );
    _awayController = TextEditingController(
      text: (widget.fixture.awayScore ?? 0).toString(),
    );
  }

  @override
  void dispose() {
    _homeController.dispose();
    _awayController.dispose();
    super.dispose();
  }

  void _submit() {
    final homeScore = int.tryParse(_homeController.text.trim());
    final awayScore = int.tryParse(_awayController.text.trim());

    if (homeScore == null || awayScore == null) {
      setState(() => _errorText = 'Enter both scores.');
      return;
    }

    if (homeScore > 99 || awayScore > 99) {
      setState(() => _errorText = 'Scores must be between 0 and 99.');
      return;
    }

    Navigator.of(
      context,
    ).pop(_ScoreSubmission(homeScore: homeScore, awayScore: awayScore));
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final fixture = widget.fixture;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: fieldGray900,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.fact_check_rounded,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Finalize Score',
                          style: TextStyle(
                            color: fieldGray900,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'This immediately updates SR.',
                          style: TextStyle(
                            color: fieldGray500,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _ScoreInputCard(
                      clan: fixture.homeClan,
                      controller: _homeController,
                      textInputAction: TextInputAction.next,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      '-',
                      style: TextStyle(
                        color: fieldGray400,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Expanded(
                    child: _ScoreInputCard(
                      clan: fixture.awayClan,
                      controller: _awayController,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                ],
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                _ErrorCallout(message: _errorText!),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  onPressed: _submit,
                  icon: const Icon(Icons.trending_up_rounded),
                  label: const Text('Apply SR'),
                  style: FilledButton.styleFrom(
                    backgroundColor: fieldEmerald600,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScoreInputCard extends StatelessWidget {
  const _ScoreInputCard({
    required this.clan,
    required this.controller,
    required this.textInputAction,
    this.onSubmitted,
  });

  final FixtureClan? clan;
  final TextEditingController controller;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: fieldBackground,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          clan == null
              ? Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: fieldGray200),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.shield_rounded,
                    color: fieldGray400,
                    size: 22,
                  ),
                )
              : FixtureClanAvatar(clan: clan!, size: 44),
          const SizedBox(height: 8),
          Text(
            clan?.tag ?? 'TBD',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: fieldGray600,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            textInputAction: textInputAction,
            textAlign: TextAlign.center,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(2),
            ],
            onSubmitted: onSubmitted,
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 34,
              fontWeight: FontWeight.w900,
            ),
            decoration: InputDecoration(
              counterText: '',
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: fieldGray200),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: fieldGray200),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: fieldEmerald500, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _teamTagFor(Fixture fixture, String? clanId) {
  if (clanId == fixture.homeClanId) return fixture.homeClan.tag;
  if (clanId == fixture.awayClanId) return fixture.awayClan?.tag ?? 'AWAY';
  return 'MATCH';
}

String _regionName(String region) {
  if (region.isEmpty) return 'Region';
  return '${region[0].toUpperCase()}${region.substring(1).toLowerCase()}';
}

({IconData icon, Color color, Color background}) _timelineEventStyle(
  String eventType,
) {
  return switch (eventType) {
    'GOAL' => (
      icon: Icons.sports_soccer_rounded,
      color: fieldEmerald600,
      background: Color(0xFFECFDF5),
    ),
    'BLUE_CARD' => (
      icon: Icons.square_rounded,
      color: fieldBlue600,
      background: Color(0xFFEFF6FF),
    ),
    'BLUE_CARD_EXPIRED' => (
      icon: Icons.keyboard_return_rounded,
      color: Color(0xFF2563EB),
      background: Color(0xFFEFF6FF),
    ),
    'MATCH_STARTED' || 'MATCH_RESUMED' => (
      icon: Icons.play_arrow_rounded,
      color: fieldEmerald600,
      background: Color(0xFFECFDF5),
    ),
    'MATCH_PAUSED' => (
      icon: Icons.pause_rounded,
      color: Color(0xFFD97706),
      background: Color(0xFFFFFBEB),
    ),
    'MATCH_ENDED' => (
      icon: Icons.flag_rounded,
      color: fieldGray700,
      background: fieldGray100,
    ),
    'CORRECTION' => (
      icon: Icons.edit_note_rounded,
      color: Color(0xFF7C3AED),
      background: Color(0xFFF5F3FF),
    ),
    _ => (
      icon: Icons.bolt_rounded,
      color: fieldGray700,
      background: fieldGray100,
    ),
  };
}

String _timelineTitle(FixtureTimelineEvent event) {
  return switch (event.eventType) {
    'GOAL' => 'Goal · ${event.playerName}',
    'BLUE_CARD' => 'Blue card · ${event.playerName}',
    'BLUE_CARD_EXPIRED' => 'Returned · ${event.playerName}',
    'MATCH_STARTED' => 'Match started',
    'MATCH_PAUSED' => 'Match paused',
    'MATCH_RESUMED' => 'Match resumed',
    'MATCH_ENDED' => 'Match ended',
    'CORRECTION' => 'Admin correction',
    _ => event.eventType.replaceAll('_', ' '),
  };
}

String _timelineSubtitle(Fixture fixture, FixtureTimelineEvent event) {
  final team = _teamTagFor(fixture, event.clanId);
  final note = event.note == null || event.note!.isEmpty ? null : event.note;

  if (event.eventType == 'GOAL' && event.assistProfileId != null) {
    return '$team · assist ${event.assistName}';
  }
  if (note != null) return '$team · $note';
  return team;
}

class _ErrorCallout extends StatelessWidget {
  const _ErrorCallout({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        message,
        style: const TextStyle(
          color: Color(0xFF991B1B),
          fontSize: 13,
          height: 1.35,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
