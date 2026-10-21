import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/field_confirmation_dialog.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture.dart';
import '../fixtures/fieldrush_match_replay_screen.dart';
import '../fixtures/fixture_repository.dart';
import '../home/field_bottom_nav.dart';
import '../home/fieldrush_home_widgets.dart';
import '../payments/refund_status.dart';
import '../profile/profile_repository.dart';
import '../profile/profile_screen.dart';
import '../ranking/player_rating_visibility.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_toast.dart';
import '../ui/fieldrush_video_player.dart';
import 'fieldrush_game_detail_party.dart';
import 'fieldrush_game_loading.dart';
import 'open_queue.dart';
import 'open_queue_repository.dart';

const _cream = FieldrushAuthTheme.cream;
const _ink = FieldrushAuthTheme.ink;
const _muted = FieldrushAuthTheme.muted;
const _green = FieldrushAuthTheme.forest;
const _border = FieldrushAuthTheme.border;
const _wash = Color(0xFFF2EFE3);
const _lime = Color(0xFFC7DD9B);
const _light = Color(0xFFE4F0D5);

TextStyle _body(
  double size, {
  Color color = _muted,
  FontWeight weight = FontWeight.w700,
}) => TextStyle(
  fontFamily: 'PlusJakartaSans',
  fontSize: size,
  height: 1.4,
  fontWeight: weight,
  color: color,
);
TextStyle _display(double size, {Color color = _ink}) => TextStyle(
  fontFamily: 'Outfit',
  fontSize: size,
  height: 1.05,
  letterSpacing: -.5,
  fontWeight: FontWeight.w800,
  color: color,
);

/// The Fieldrush game, roster and match-media surfaces. Joining is deliberately
/// delegated to the selection/review/payment flow, never to bookGame directly.
class FieldrushGameDetailScreen extends StatefulWidget {
  const FieldrushGameDetailScreen({
    super.key,
    required this.repository,
    required this.gameId,
    this.initialGame,
    this.initialDetail,
    this.playerRatingUpdate,
    this.ratingStatus,
    this.ratingExplanation,
    this.countedAsPlayed,
    this.ratingProfileId,
    this.onJoin,
    this.onNavigateTab,
    this.profileRepository,
    this.fixtureRepository,
    this.initiallyShowWatch = false,
  });

  final OpenQueueRepository repository;
  final String gameId;
  final OpenQueueGame? initialGame;
  final OpenQueueMatchDetail? initialDetail;
  final FixturePlayerRatingUpdate? playerRatingUpdate;
  final String? ratingStatus;
  final String? ratingExplanation;
  final bool? countedAsPlayed;
  final String? ratingProfileId;
  final Future<void> Function(OpenQueueGame game)? onJoin;
  final ValueChanged<int>? onNavigateTab;
  final ProfileRepository? profileRepository;
  final FixtureRepository? fixtureRepository;
  final bool initiallyShowWatch;

  @override
  State<FieldrushGameDetailScreen> createState() =>
      _FieldrushGameDetailScreenState();
}

enum _Section { watch, timeline, lineup }

class _FieldrushGameDetailScreenState extends State<FieldrushGameDetailScreen> {
  late OpenQueueMatchDetail? _detail = widget.initialDetail;
  OpenQueueBooking? _booking;
  String? _error;
  late bool _loading = widget.initialDetail == null;
  bool _acting = false;
  bool _refreshing = false;
  int _loadGeneration = 0;
  bool _bookingKnown = false;
  late _Section _section = widget.initiallyShowWatch
      ? _Section.watch
      : _Section.lineup;
  Timer? _timer;

  OpenQueueGame? get _game => _detail?.game ?? widget.initialGame;
  OpenQueuePlayer? get _ratingPlayer => _detail?.players
      .where(
        (p) => widget.ratingProfileId == null
            ? p.isMe
            : p.id == widget.ratingProfileId,
      )
      .firstOrNull;
  String? get _ratingStatus =>
      _ratingPlayer?.ratingStatus ??
      _detail?.ratingStatus ??
      widget.ratingStatus;
  bool? get _countedAsPlayed =>
      _ratingPlayer?.countedAsPlayed ?? widget.countedAsPlayed;
  String? get _ratingMessage =>
      _ratingPlayer?.publicRatingExplanation ??
      publicRatingAppearanceExplanation(
        widget.ratingExplanation,
        _countedAsPlayed,
      ) ??
      _detail?.ratingExplanation ??
      publicRatingStatusLabel(_ratingStatus);
  FixturePlayerRatingUpdate? get _ratingUpdate {
    if (!permitsPublicRatingResult(_ratingStatus) ||
        _ratingPlayer?.ratingVisible == false) {
      return null;
    }
    final player = _ratingPlayer;
    // Current per-player settlement evidence outranks a history-card snapshot.
    if (player != null && player.countedAsPlayed != null) {
      final before = player.displayedRating;
      final delta = player.publicRatingChange;
      if (before == null || delta == null) return null;
      return FixturePlayerRatingUpdate(
        ratingBefore: before,
        ratingChange: delta,
        ratingAfter: before + delta,
      );
    }
    final update =
        widget.playerRatingUpdate ??
        (widget.ratingProfileId == null ? _detail?.viewerRatingUpdate : null);
    return _countedAsPlayed == false && update?.ratingChange == 0
        ? null
        : update;
  }

  bool get _isBooked =>
      _booking != null || (!_bookingKnown && (_game?.hasMyBooking ?? false));

  @override
  void initState() {
    super.initState();
    unawaited(_load(quiet: _detail != null));
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted && !_acting && (ModalRoute.of(context)?.isCurrent ?? false)) {
        unawaited(_load(quiet: true));
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false, bool requireFresh = false}) async {
    if (_refreshing && !requireFresh) return;
    final generation = ++_loadGeneration;
    _refreshing = true;
    if (!quiet) setState(() => _error = null);
    try {
      final detail = await widget.repository.getMatchDetail(widget.gameId);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _detail = detail;
        _error = null;
        _bookingKnown = false;
        // A completed cancellation (including one on another device) must not
        // retain a stale confirmed booking if its supplemental lookup fails.
        if (_booking?.id != detail.game.myBookingId) _booking = null;
      });
      // A booking lookup failure must not hide an otherwise valid fixture.
      try {
        final repository = widget.repository;
        final booking = repository is OpenQueueBookingLookupRepository
            ? await (repository as OpenQueueBookingLookupRepository)
                  .getMyUpcomingBookingForGame(widget.gameId)
            : (await repository.getMyUpcomingBookings())
                  .where((item) => item.gameId == widget.gameId)
                  .firstOrNull;
        if (mounted && generation == _loadGeneration) {
          setState(() {
            _booking = booking;
            _bookingKnown = true;
          });
        }
      } catch (_) {
        // Keep the server's booking flag and retry on the next refresh.
      }
    } catch (error) {
      if (mounted &&
          generation == _loadGeneration &&
          (!quiet || _detail == null)) {
        setState(
          () => _error = userFacingError(
            error,
            fallback: 'We could not load this game. Pull down to retry.',
          ),
        );
      }
    } finally {
      if (generation == _loadGeneration) {
        _refreshing = false;
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  void _message(String message) {
    if (mounted) showFieldrushToast(context, message);
  }

  Future<void> _join() async {
    final game = _game;
    if (game == null || widget.onJoin == null || _acting || _detail == null) {
      return;
    }
    setState(() => _acting = true);
    try {
      await widget.onJoin!(game);
      if (mounted) await _load(requireFresh: true);
    } catch (error) {
      _message(
        userFacingError(
          error,
          fallback: 'We could not open the booking flow. Please try again.',
        ),
      );
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _cancel() async {
    final bookingId = _booking?.id ?? _game?.myBookingId;
    if (bookingId == null || _acting) return;
    setState(() => _acting = true);
    try {
      var preview = await widget.repository.previewCancellation(bookingId);
      var updated = false;
      while (mounted) {
        if (!mounted) return;
        final confirmed = await showFieldConfirmDialog(
          context: context,
          icon: Icons.event_busy_outlined,
          eyebrow: updated
              ? 'Updated ${preview.outcomeLabel}'
              : preview.outcomeLabel,
          title: updated ? 'Cancellation terms changed' : 'Leave this game?',
          message: preview.displayExplanation?.trim().isNotEmpty == true
              ? preview.displayExplanation!
              : 'Your position will reopen. These terms use server time and the policy active for this game.',
          detail: [
            preview.refundDestinationLabel,
            if (preview.effectiveRefundBps > 0 && preview.refundAmountFils > 0)
              preview.refundLabel,
            if (preview.strikeDelta > 0)
              '+${preview.strikeDelta} reliability ${preview.strikeDelta == 1 ? 'strike' : 'strikes'}',
            if (preview.depositForfeited) 'Reliability deposit forfeited',
          ].join('\n'),
          cancelLabel: 'Stay in game',
          confirmLabel: preview.canCancel
              ? 'Confirm cancellation'
              : 'Unavailable',
          confirmEnabled: preview.canCancel,
          destructive: true,
        );
        if (!confirmed || !mounted) return;
        final latest = await widget.repository.previewCancellation(bookingId);
        if (preview.hasSameConsequencesAs(latest)) break;
        preview = latest;
        updated = true;
      }
      if (!mounted) return;
      final cancelled = await widget.repository.cancelBooking(bookingId);
      if (!mounted) return;
      setState(() {
        _booking = null;
        _bookingKnown = true;
      });
      _message(
        cancellationRefundMessage(
          refundAmountFils:
              cancelled.refundAmountFils ?? preview.refundAmountFils,
          destination: cancelled.refundDestination ?? preview.refundDestination,
          status: cancelled.refundStatus,
        ),
      );
      await _load(requireFresh: true);
    } catch (error) {
      _message(
        userFacingError(
          error,
          fallback:
              'Cancellation is unavailable. Your spot has not been changed.',
        ),
      );
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _directions() async {
    final game = _game;
    final destination = game?.directionsUri;
    if (game == null || destination == null) return;
    final location = game.locationLabel ?? game.venue;
    try {
      final opened = await launchUrl(
        destination,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) _message('Directions could not be opened. Venue: $location');
    } catch (_) {
      _message('Directions could not be opened. Venue: $location');
    }
  }

  Future<void> _openPlayer(String id) async {
    if (id.trim().isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: _cream,
          body: ProfileScreen(
            profileRepository:
                widget.profileRepository ?? SupabaseProfileRepository(),
            profileId: id,
            openQueueRepository: widget.repository,
          ),
        ),
      ),
    );
  }

  Future<void> _roster() async {
    final detail = _detail;
    if (detail == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FieldrushGameRosterScreen(
          detail: detail,
          onPlayer: _openPlayer,
          onNavigateTab: widget.onNavigateTab,
        ),
      ),
    );
    if (mounted) await _load(requireFresh: true);
  }

  Future<void> _clips(Duration position, {bool highlights = false}) async {
    final detail = _detail;
    if (detail == null || detail.game.status != 'FINAL') return;
    final goals = highlights
        ? detail.toFixture().highlightMoments
        : const <FixtureHighlightMoment>[];
    await _openReplay(
      goals.isEmpty ? position : goals.first.start,
      openClipEditor: !highlights,
    );
  }

  Future<void> _openReplay(
    Duration position, {
    bool openClipEditor = false,
  }) async {
    final detail = _detail;
    if (detail == null || detail.game.status != 'FINAL') return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FieldrushMatchReplayScreen(
          fixture: detail.toFixture(),
          fixtureRepository:
              widget.fixtureRepository ?? SupabaseFixtureRepository(),
          sourceLabel: 'SOLO',
          initialPosition: position,
          openClipEditor: openClipEditor,
          profileRepository: widget.profileRepository,
          refreshFixture: () async => (await widget.repository.getMatchDetail(
            widget.gameId,
          )).toFixture(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final game = _game;
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: Scaffold(
        extendBody: true,
        backgroundColor: _cream,
        bottomNavigationBar: widget.onNavigateTab == null
            ? null
            : FieldBottomNav(
                selectedIndex: 1,
                onSelected: (index) {
                  widget.onNavigateTab!(index);
                  Navigator.of(context).popUntil((route) => route.isFirst);
                },
              ),
        body: SafeArea(
          bottom: false,
          child: FieldRefreshIndicator(
            color: _green,
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 132),
              children: [
                _DetailHeader(
                  title: 'Solo game',
                  titleAccessory: game == null
                      ? null
                      : FieldrushGameDivisionRange(
                          key: const ValueKey('game-header-divisions'),
                          game: game,
                          compact: true,
                        ),
                  trailing: game == null
                      ? null
                      : Text(
                          _isBooked &&
                                  (game.status == 'OPEN' ||
                                      game.status == 'FULL')
                              ? 'YOU’RE IN'
                              : game.status == 'OPEN' && !game.isFull
                              ? 'OPEN'
                              : game.statusLabel.toUpperCase(),
                          style: _body(
                            10,
                            color: game.status == 'LIVE'
                                ? FieldrushAuthTheme.danger
                                : _green,
                          ),
                        ),
                ),
                if (_loading && game == null) const FieldrushGameLoading(),
                if (_error != null)
                  _Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _error!,
                          style: _body(12, color: FieldrushAuthTheme.danger),
                        ),
                        TextButton(
                          onPressed: _load,
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                if (game != null) ...[
                  const SizedBox(height: 16),
                  _hero(game),
                  if (_ratingUpdate case final ratingUpdate?
                      when game.status == 'FINAL') ...[
                    const SizedBox(height: 12),
                    _ratingSummary(ratingUpdate),
                  ],
                  if (_ratingMessage case final explanation?) ...[
                    const SizedBox(height: 12),
                    _Card(
                      child: Text(
                        explanation,
                        key: const ValueKey('game-rating-explanation'),
                        style: _body(12),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: _wash,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        for (final section in _Section.values)
                          Expanded(
                            child: Semantics(
                              selected: section == _section,
                              child: TextButton(
                                key: ValueKey('game-tab-${section.name}'),
                                onPressed: () =>
                                    setState(() => _section = section),
                                style: TextButton.styleFrom(
                                  backgroundColor: section == _section
                                      ? Colors.white
                                      : Colors.transparent,
                                  foregroundColor: section == _section
                                      ? _ink
                                      : _muted,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  textStyle: _body(12),
                                ),
                                child: Text(switch (section) {
                                  _Section.lineup => 'Lineup',
                                  _Section.timeline => 'Timeline',
                                  _Section.watch => 'Stream',
                                }),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_detail == null && _loading)
                    const FieldLoadingContent(label: 'Loading lineup', rows: 4),
                  if (_detail case final detail?)
                    switch (_section) {
                      _Section.lineup => _lineup(detail),
                      _Section.timeline => _timeline(detail),
                      _Section.watch => _GameWatch(
                        detail: detail,
                        onClips: _clips,
                        onReplay: _openReplay,
                        onHighlights: () =>
                            _clips(Duration.zero, highlights: true),
                      ),
                    },
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _hero(OpenQueueGame game) {
    final status = game.status.toUpperCase();
    final upcoming = status == 'OPEN' || status == 'FULL';
    final available = game.supportedRoles.any(game.canBook);
    final count = game.confirmedCount;
    final time = game.startTimeLabel.split(' ');
    final team = game.hasActiveTeamAssignment
        ? _booking?.assignedTeam ?? game.myBookingTeam
        : null;
    final role = _booking?.role ?? game.myBookingRole;
    final teamText = team?.isNotEmpty == true
        ? '${team!.toUpperCase() == 'WHITE' ? 'White' : 'Black'} team${role == null ? '' : ' · ${role.label}'}'
        : game.teamAssignmentAt != null
        ? 'Teams drawn ${_localClock(game.localDateTime(game.teamAssignmentAt!))}'
        : 'Teams are drawn before kick-off';
    return Container(
      key: const ValueKey('fieldrush-game-hero'),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      decoration: BoxDecoration(
        color: _green,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: time.first,
                          style: _display(56, color: Colors.white),
                        ),
                        if (time.length > 1)
                          TextSpan(
                            text: ' ${time.last}',
                            style: _display(18, color: _lime),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${game.calendarDateLabel}\n${game.venue.isEmpty ? 'Venue to be confirmed' : game.venue}',
                    style: _body(11.5, color: _light),
                  ),
                ),
              ),
            ],
          ),
          if (game.locationLabel case final String address) ...[
            const SizedBox(height: 12),
            Text(
              address,
              key: const ValueKey('fieldrush-game-address'),
              style: _body(11.5, color: _light),
            ),
          ],
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .18),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (game.hasPendingOperationalResolution) ...[
                  Text(
                    game.operationalStatusLabel ?? 'Under review',
                    style: _display(22, color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    game.operationalStatusDetail ??
                        'Match details will update after review.',
                    style: _body(11.5, color: _light),
                  ),
                ] else if (status == 'LIVE' || status == 'FINAL') ...[
                  Row(
                    children: [
                      Text(
                        status == 'LIVE' ? '● LIVE' : 'FULL TIME',
                        style: _body(10, color: _lime),
                      ),
                      const Spacer(),
                      if (_detail?.clock != null && status == 'LIVE')
                        Text(
                          '${_detail!.clock!.elapsedSeconds() ~/ 60}′',
                          style: _body(12, color: _light),
                        ),
                    ],
                  ),
                  const SizedBox(height: 13),
                  Row(
                    children: [
                      Expanded(child: _score('WHITE', game.whiteScore)),
                      Expanded(
                        child: _score('BLACK', game.blackScore, right: true),
                      ),
                    ],
                  ),
                  if (status == 'FINAL' &&
                      (game.whiteScore == null || game.blackScore == null))
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Result not published yet',
                        style: _body(11, color: _light),
                      ),
                    ),
                ] else if (status == 'CANCELLED') ...[
                  Text(
                    'Game cancelled',
                    style: _display(24, color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This game is no longer taking place.',
                    style: _body(12, color: _light),
                  ),
                ] else ...[
                  Row(
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '$count',
                              style: _display(22, color: Colors.white),
                            ),
                            TextSpan(
                              text: '/${game.capacity} in',
                              style: _display(20, color: _lime),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Text(
                        game.isFull
                            ? 'FULL'
                            : '${math.max(0, game.capacity - count)} SPOTS',
                        style: _body(10.5, color: _light),
                      ),
                    ],
                  ),
                  const SizedBox(height: 11),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: game.capacity > 0
                          ? (count / game.capacity).clamp(0, 1)
                          : 0,
                      minHeight: 9,
                      backgroundColor: Colors.white24,
                      color: const Color(0xFFA7C957),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (game.hasConfigurableMinimum) ...[
                    Text(
                      game.minimumPlayersProgressLabel,
                      style: _body(11, color: _light),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'At kickoff and during play: ${game.requiredMinimumPlayers} actual players total, with at least one on each team.',
                      style: _body(10.5, color: _light),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: .14),
                  ),
                  const SizedBox(height: 11),
                  Row(
                    children: [
                      Icon(
                        team == null
                            ? Icons.lock_outline_rounded
                            : Icons.check_circle_outline_rounded,
                        color: _lime,
                        size: 15,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          teamText,
                          style: _body(11.5, color: _light),
                        ),
                      ),
                      if (_isBooked)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            'YOU’RE IN',
                            style: _body(9, color: _lime),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (upcoming && !game.hasPendingOperationalResolution) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('game-main-action'),
                    onPressed: _acting || _detail == null
                        ? null
                        : _isBooked
                        ? _cancel
                        : available && widget.onJoin != null
                        ? _join
                        : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: _lime,
                      foregroundColor: _ink,
                      disabledBackgroundColor: Colors.white24,
                      disabledForegroundColor: _light,
                      minimumSize: const Size(0, 50),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: _acting
                        ? Text(_isBooked ? 'Leaving…' : 'Joining…')
                        : Text(
                            _isBooked
                                ? 'Leave game'
                                : available
                                ? 'Join · ${game.priceLabel}'
                                : game.isFull
                                ? 'Game full'
                                : 'Booking closed',
                            style: _body(12.5, color: _ink),
                          ),
                  ),
                ),
                const SizedBox(width: 9),
                OutlinedButton(
                  onPressed: game.directionsUri == null ? null : _directions,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white54),
                    minimumSize: const Size(0, 50),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  child: Text(
                    'Directions',
                    style: _body(12.5, color: Colors.white),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _ratingSummary(FixturePlayerRatingUpdate rating) => _Card(
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Label('PLAYER SR'),
              const SizedBox(height: 7),
              Text(
                '${rating.ratingBefore} → ${rating.ratingAfter}',
                style: _display(23),
              ),
              const SizedBox(height: 4),
              Text('Rating from this match', style: _body(10.5)),
            ],
          ),
        ),
        Container(
          key: const ValueKey('fieldrush-match-rating-change'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: rating.ratingChange < 0 ? const Color(0xFFF8E8E4) : _light,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Text(
            '${rating.ratingChange > 0 ? '+' : ''}${rating.ratingChange} SR',
            style: _display(
              22,
              color: rating.ratingChange < 0
                  ? FieldrushAuthTheme.danger
                  : _green,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _score(String label, int? score, {bool right = false}) => Column(
    crossAxisAlignment: right
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start,
    children: [
      Text(label, style: _body(9.5, color: _lime).copyWith(letterSpacing: 1.2)),
      const SizedBox(height: 8),
      Text(score?.toString() ?? '—', style: _display(38, color: Colors.white)),
    ],
  );

  Widget _lineup(OpenQueueMatchDetail detail) {
    final game = detail.game;
    final rated = detail.players
        .where((p) => p.displayedRating != null)
        .toList();
    final average =
        game.matchAverageSr ??
        (rated.isEmpty
            ? null
            : (rated.map((p) => p.displayedRating!).reduce((a, b) => a + b) /
                      rated.length)
                  .round());
    final me = detail.players.where((p) => p.isMe).firstOrNull;
    final ratings = rated.map((p) => p.displayedRating!).toList()..sort();
    final assigned =
        (game.hasActiveTeamAssignment ||
            game.status == 'LIVE' ||
            game.status == 'FINAL') &&
        detail.players.any(
          (p) =>
              p.team == openQueueWhiteTeamId || p.team == openQueueBlackTeamId,
        );
    return Column(
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _Label('LOBBY AVERAGE'),
                  const Spacer(),
                  Text('${game.confirmedCount} players', style: _body(10.5)),
                ],
              ),
              const SizedBox(height: 15),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        average?.toString() ?? '—',
                        style: _display(54),
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      'SKILL\nRATING',
                      style: _body(9.5).copyWith(height: 1.2, letterSpacing: 1),
                    ),
                  ),
                  const Spacer(),
                  if (me?.displayedRating != null)
                    Text(
                      'YOU ${me!.displayedRating}',
                      style: _body(11, color: _green),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              if (ratings.isEmpty)
                Text(
                  'Skill ratings appear when player ratings are available.',
                  style: _body(11, weight: FontWeight.w600),
                )
              else ...[
                _RatingRange(
                  minimum: ratings.first,
                  maximum: ratings.last,
                  average: average!,
                  mine: me?.displayedRating,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('${ratings.first} lowest', style: _body(10.5)),
                    const Spacer(),
                    Text('highest ${ratings.last}', style: _body(10.5)),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (_isBooked && (game.status == 'OPEN' || game.status == 'FULL'))
          FieldrushGameDetailParty(
            repository: widget.repository,
            game: game,
            viewerProfileId: _booking?.profileId ?? me?.id,
            onChanged: () => _load(quiet: true),
            onViewProfile: _openPlayer,
          ),
        _Card(
          padding: EdgeInsets.zero,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: _roster,
            child: Padding(
              padding: const EdgeInsets.all(17),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _Label('IN THIS GAME'),
                        const SizedBox(height: 11),
                        if (detail.players.isEmpty)
                          Text('No players published yet', style: _body(11))
                        else
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: [
                              for (final player in detail.players.take(7))
                                _PlayerBadge(
                                  name: player.displayName,
                                  isMe: player.isMe,
                                  size: 29,
                                ),
                              if (detail.players.length > 7)
                                Text(
                                  '+${detail.players.length - 7}',
                                  style: _body(11),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${game.confirmedCount}',
                              style: _display(22),
                            ),
                            TextSpan(
                              text: '/${game.capacity}',
                              style: _display(13, color: _muted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text('See all ›', style: _body(10.5, color: _green)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (assigned)
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const _Label('TEAMS'),
                    const Spacer(),
                    Text('Tap a player', style: _body(10.5)),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text('WHITE', style: _body(10, color: _ink)),
                    const Spacer(),
                    Text('BLACK', style: _body(10, color: _ink)),
                  ],
                ),
                const SizedBox(height: 10),
                _TeamPitch(players: detail.players, onPlayer: _openPlayer),
                const SizedBox(height: 12),
                Text(
                  'Wear your assigned team colour. Tap See all for the full roster.',
                  style: _body(11, weight: FontWeight.w600),
                ),
              ],
            ),
          ),
        _Card(
          key: const ValueKey('fieldrush-game-facts'),
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _Fact(
                'Format',
                '${game.hasConfigurableMinimum ? 'Up to ' : ''}${game.capacity ~/ 2}-a-side · ${game.endsAt.difference(game.startsAt).inMinutes} min slot',
              ),
              if (game.hasConfigurableMinimum)
                _Fact('Players needed', game.minimumPlayersLabel),
              _Fact(
                'Rated',
                publicRatingStatusLabel(_ratingStatus) ??
                    (_countedAsPlayed == false
                        ? 'Appearance not counted'
                        : _countedAsPlayed == true
                        ? 'Yes · counted appearance'
                        : _ratingStatus != null &&
                              permitsPublicRatingResult(_ratingStatus)
                        ? 'Match rated · individual eligibility applies'
                        : permitsPublicRatingResult(_ratingStatus)
                        ? 'Yes · counts to skill rating'
                        : 'Rating under review'),
              ),
              _Fact(
                'Teams',
                game.teamAssignmentAt == null
                    ? 'Timing to be confirmed'
                    : 'Drawn ${_localClock(game.localDateTime(game.teamAssignmentAt!))}',
              ),
              _Fact(
                'Cancellation',
                _isBooked
                    ? 'Preview exact terms before leaving'
                    : 'Shown before payment',
                last: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _timeline(OpenQueueMatchDetail detail) {
    final events = [...detail.timeline]
      ..sort(
        (a, b) =>
            (a.minute * 60 + a.second).compareTo(b.minute * 60 + b.second),
      );
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _Label('TIMELINE'),
              const Spacer(),
              Text('${events.length} events', style: _body(10.5)),
            ],
          ),
          if (events.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 13),
              child: Text(
                detail.game.status == 'FINAL'
                    ? 'No match events have been published.'
                    : detail.game.status == 'CANCELLED'
                    ? 'This game was cancelled.'
                    : 'Nothing yet. Match events appear here once they are recorded by the referee.',
                style: _body(11.5, weight: FontWeight.w600),
              ),
            ),
          for (final event in events)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${event.minute}′',
                      style: _body(11, color: _green),
                    ),
                  ),
                  Icon(
                    switch (event.eventType.toUpperCase()) {
                      'GOAL' => Icons.sports_soccer_rounded,
                      'YELLOW_CARD' || 'RED_CARD' => Icons.style_rounded,
                      _ => Icons.flag_outlined,
                    },
                    size: 18,
                    color: event.eventType == 'RED_CARD'
                        ? FieldrushAuthTheme.danger
                        : event.eventType == 'YELLOW_CARD'
                        ? const Color(0xFFB58B21)
                        : _green,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: InkWell(
                      onTap: event.profileId == null
                          ? null
                          : () => _openPlayer(event.profileId!),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            event.player?.displayName ??
                                event.eventType.replaceAll('_', ' '),
                            style: _body(12.5, color: _ink),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            event.assist != null
                                ? 'Assist · ${event.assistName}'
                                : event.note?.isNotEmpty == true
                                ? event.note!
                                : event.eventType
                                      .replaceAll('_', ' ')
                                      .toLowerCase(),
                            style: _body(10.5, weight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (event.clanId == openQueueWhiteTeamId ||
                      event.clanId == openQueueBlackTeamId)
                    Text(
                      event.clanId == openQueueWhiteTeamId ? 'WHITE' : 'BLACK',
                      style: _body(9, color: _ink),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class FieldrushGameRosterScreen extends StatelessWidget {
  const FieldrushGameRosterScreen({
    super.key,
    required this.detail,
    required this.onPlayer,
    this.onNavigateTab,
  });
  final OpenQueueMatchDetail detail;
  final ValueChanged<String> onPlayer;
  final ValueChanged<int>? onNavigateTab;

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Scaffold(
      backgroundColor: _cream,
      extendBody: true,
      bottomNavigationBar: onNavigateTab == null
          ? null
          : FieldBottomNav(
              selectedIndex: 1,
              onSelected: (index) {
                onNavigateTab!(index);
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
            ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 132),
          children: [
            _DetailHeader(
              title: 'Players',
              subtitle:
                  '${detail.game.calendarDateLabel} · ${detail.game.startTimeLabel}',
              trailing: Text(
                '${detail.game.confirmedCount}/${detail.game.capacity}',
                style: _display(22),
              ),
            ),
            if (detail.players.isEmpty)
              _Card(
                child: Text(
                  'No player details have been published for this game yet.',
                  style: _body(12),
                ),
              ),
            for (final role in detail.game.supportedRoles)
              if (detail.players.any((p) => p.role == role)) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 22, 4, 0),
                  child: Row(
                    children: [
                      _Label('${role.label.toUpperCase()}S'),
                      const Spacer(),
                      Text(
                        '${detail.players.where((p) => p.role == role).length}',
                        style: _body(11),
                      ),
                    ],
                  ),
                ),
                _Card(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final player in detail.players.where(
                        (p) => p.role == role,
                      ))
                        InkWell(
                          onTap: () => onPlayer(player.id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            child: Row(
                              children: [
                                _PlayerBadge(
                                  name: player.displayName,
                                  isMe: player.isMe,
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Text(
                                    player.displayName,
                                    style: _body(13.5, color: _ink),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (player.isMe)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: Text(
                                      'YOU',
                                      style: _body(9, color: _green),
                                    ),
                                  ),
                                Text(
                                  '${player.displayedRating ?? '—'}',
                                  style: _display(15),
                                ),
                                const SizedBox(width: 3),
                                Text('SR', style: _body(9)),
                                const SizedBox(width: 12),
                                const Icon(
                                  Icons.chevron_right_rounded,
                                  size: 16,
                                  color: _muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
              child: Text(
                'Roster at the time you opened this page. Return to the game for updates.',
                style: _body(11.5, weight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.title,
    this.titleAccessory,
    this.subtitle,
    this.trailing,
  });
  final String title;
  final Widget? titleAccessory;
  final String? subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 36,
        height: 36,
        child: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          tooltip: 'Back',
          style: IconButton.styleFrom(
            backgroundColor: Colors.white,
            side: const BorderSide(color: _border),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: EdgeInsets.zero,
          ),
          icon: const Icon(Icons.chevron_left_rounded, size: 21, color: _ink),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 9,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(title, style: _display(18)),
                if (titleAccessory != null) titleAccessory!,
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  subtitle!,
                  style: _body(11, weight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
      if (trailing != null) ...[const SizedBox(width: 8), trailing!],
    ],
  );
}

class _Card extends StatelessWidget {
  const _Card({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: padding,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: _body(
      11,
      color: const Color(0xFF24472C),
      weight: FontWeight.w800,
    ).copyWith(letterSpacing: 1.2),
  );
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.last = false});
  final String label;
  final String value;
  final bool last;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    decoration: BoxDecoration(
      border: last
          ? null
          : const Border(bottom: BorderSide(color: Color(0xFFF0ECE0))),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: _body(12.5, weight: FontWeight.w600).copyWith(height: 1),
        ),
        const SizedBox(width: 15),
        Expanded(
          child: Text(
            value,
            style: _body(12.5, color: _ink).copyWith(height: 1),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    ),
  );
}

class _PlayerBadge extends StatelessWidget {
  const _PlayerBadge({
    required this.name,
    this.isMe = false,
    this.size = 34,
    this.black = false,
  });
  final String name;
  final bool isMe;
  final double size;
  final bool black;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: isMe
          ? _green
          : black
          ? _ink
          : _wash,
      borderRadius: BorderRadius.circular(size * .34),
      border: Border.all(color: isMe ? _green : _border),
    ),
    child: Text(
      name
          .trim()
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .take(2)
          .map((s) => s.characters.first)
          .join()
          .toUpperCase(),
      style: _body(
        size * .31,
        color: isMe || black ? Colors.white : _ink,
        weight: FontWeight.w800,
      ),
    ),
  );
}

class _RatingRange extends StatelessWidget {
  const _RatingRange({
    required this.minimum,
    required this.maximum,
    required this.average,
    this.mine,
  });
  final int minimum;
  final int maximum;
  final int average;
  final int? mine;
  double _position(int value) => maximum == minimum
      ? .5
      : ((value - minimum) / (maximum - minimum)).clamp(0, 1);
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 16,
    child: LayoutBuilder(
      builder: (_, box) => Stack(
        alignment: Alignment.centerLeft,
        children: [
          Container(
            height: 6,
            decoration: BoxDecoration(
              color: _wash,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          Positioned(
            left: _position(average) * (box.maxWidth - 6),
            child: Container(
              width: 6,
              height: 14,
              decoration: BoxDecoration(
                color: _muted,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (mine != null)
            Positioned(
              left: _position(mine!) * (box.maxWidth - 10),
              child: Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: _green,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _TeamPitch extends StatelessWidget {
  const _TeamPitch({required this.players, required this.onPlayer});
  final List<OpenQueuePlayer> players;
  final ValueChanged<String> onPlayer;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: SizedBox(
      height: 248,
      child: LayoutBuilder(
        builder: (_, box) => Stack(
          children: [
            const Positioned.fill(child: CustomPaint(painter: _PitchPainter())),
            for (final team in [openQueueWhiteTeamId, openQueueBlackTeamId])
              ..._tokens(team, box.maxWidth),
          ],
        ),
      ),
    ),
  );

  List<Widget> _tokens(String team, double width) {
    final result = <Widget>[];
    final black = team == openQueueBlackTeamId;
    final roles = [
      OpenQueueRole.goalkeeper,
      OpenQueueRole.defender,
      if (players.any((p) => p.role == OpenQueueRole.midfielder))
        OpenQueueRole.midfielder,
      OpenQueueRole.attacker,
    ];
    for (var r = 0; r < roles.length; r++) {
      final members = players
          .where((p) => p.team == team && p.role == roles[r])
          .toList();
      final fraction = .07 + r * .35 / math.max(1, roles.length - 1);
      final x = (black ? 1 - fraction : fraction) * width;
      for (var i = 0; i < members.length; i++) {
        final player = members[i];
        final y = (i + 1) / (members.length + 1) * 216;
        result.add(
          Positioned(
            left: (x - 23).clamp(0, width - 46),
            top: y - 9,
            width: 46,
            child: Semantics(
              label: player.displayName,
              button: true,
              child: InkWell(
                onTap: () => onPlayer(player.id),
                child: Column(
                  children: [
                    _PlayerBadge(
                      name: player.displayName,
                      isMe: player.isMe,
                      black: black,
                      size: 28,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      player.isMe ? 'You' : player.displayName.split(' ').first,
                      style: _body(8, color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    }
    return result;
  }
}

class _PitchPainter extends CustomPainter {
  const _PitchPainter();
  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0.0; x < size.width; x += 22) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 22, size.height),
        Paint()
          ..color = (x ~/ 22).isEven
              ? const Color(0xFF3B7448)
              : const Color(0xFF3F7A4C),
      );
    }
    final line = Paint()
      ..color = Colors.white.withValues(alpha: .5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(
      Rect.fromLTWH(10, 10, size.width - 20, size.height - 20),
      line,
    );
    canvas.drawLine(
      Offset(size.width / 2, 10),
      Offset(size.width / 2, size.height - 10),
      line,
    );
    canvas.drawCircle(Offset(size.width / 2, size.height / 2), 26, line);
    for (final x in [10.0, size.width - 50]) {
      canvas.drawRect(Rect.fromLTWH(x, size.height / 2 - 50, 40, 100), line);
    }
  }

  @override
  bool shouldRepaint(covariant _PitchPainter oldDelegate) => false;
}

class _GameWatch extends StatefulWidget {
  const _GameWatch({
    required this.detail,
    required this.onClips,
    required this.onReplay,
    required this.onHighlights,
  });
  final OpenQueueMatchDetail detail;
  final Future<void> Function(Duration) onClips;
  final Future<void> Function(Duration) onReplay;
  final Future<void> Function() onHighlights;
  @override
  State<_GameWatch> createState() => _GameWatchState();
}

class _GameWatchState extends State<_GameWatch> {
  VideoPlayerController? _controller;
  String? _controllerUrl;
  bool _loading = false;
  bool _openingClips = false;
  bool _fullscreen = false;
  bool _pendingSourceChange = false;
  int _playGeneration = 0;
  String? _error;
  bool get _live =>
      widget.detail.game.status == 'LIVE' &&
      widget.detail.broadcast?.isLive == true;
  String? get _url => _live
      ? widget.detail.toFixture().livePlaybackUrl
      : widget.detail.toFixture().fullGamePlaybackUrl;
  @override
  void didUpdateWidget(covariant _GameWatch oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldUrl =
        oldWidget.detail.game.status == 'LIVE' &&
            oldWidget.detail.broadcast?.isLive == true
        ? oldWidget.detail.toFixture().livePlaybackUrl
        : oldWidget.detail.toFixture().fullGamePlaybackUrl;
    if (oldUrl != _url) {
      _pendingSourceChange = true;
      _applyPendingSourceChange();
    }
  }

  void _applyPendingSourceChange() {
    if (!_pendingSourceChange || _fullscreen || _openingClips) return;
    _pendingSourceChange = false;
    // A refresh can briefly replace a playback URL and then restore it while
    // the viewer is in fullscreen or the editor. Keep that controller/position.
    if (_controller != null && _controllerUrl == _url) return;
    _playGeneration++;
    final previous = _controller;
    _controller = null;
    _controllerUrl = null;
    _loading = false;
    _error = null;
    unawaited(previous?.dispose());
  }

  void _fullscreenChanged(bool fullscreen) {
    if (!mounted) return;
    setState(() {
      _fullscreen = fullscreen;
      if (!fullscreen) _applyPendingSourceChange();
    });
  }

  @override
  void dispose() {
    _playGeneration++;
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    if (_loading || _openingClips) return;
    if (widget.detail.game.status == 'FINAL') {
      setState(() => _openingClips = true);
      try {
        final controller = _controller;
        final position = controller?.value.position ?? Duration.zero;
        if (controller?.value.isInitialized == true) {
          await controller!.pause();
        }
        if (mounted) await widget.onReplay(position);
      } finally {
        if (mounted) {
          setState(() {
            _openingClips = false;
            _applyPendingSourceChange();
          });
        }
      }
      return;
    }
    final existing = _controller;
    if (existing != null && existing.value.isInitialized) {
      existing.value.isPlaying ? await existing.pause() : await existing.play();
      return;
    }
    final url = _url;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return;
    final generation = ++_playGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    final controller = VideoPlayerController.networkUrl(uri);
    _controller = controller;
    _controllerUrl = url;
    try {
      await controller.initialize();
      if (!mounted ||
          generation != _playGeneration ||
          !identical(_controller, controller)) {
        return;
      }
      await controller.play();
    } catch (_) {
      if (mounted && identical(_controller, controller)) {
        _error = 'The video could not be played. Please try again.';
        _controller = null;
        _controllerUrl = null;
        await controller.dispose();
      }
    } finally {
      if (mounted && generation == _playGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openClips({bool highlights = false}) async {
    if (_loading || _openingClips) return;
    setState(() => _openingClips = true);
    try {
      final controller = _controller;
      final position = controller?.value.position ?? Duration.zero;
      if (controller?.value.isInitialized == true) {
        await controller!.pause();
      }
      if (mounted) {
        if (highlights) {
          await widget.onHighlights();
        } else {
          await widget.onClips(position);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _openingClips = false;
          _applyPendingSourceChange();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasUrl = _url != null;
    final canClip = hasUrl && widget.detail.game.status == 'FINAL';
    final status = widget.detail.broadcast;
    final title = _live
        ? 'Live from the pitch'
        : hasUrl
        ? 'Full match replay'
        : status?.isProcessing == true || status?.isStopping == true
        ? 'Replay processing'
        : widget.detail.game.status == 'CANCELLED'
        ? 'Game cancelled'
        : 'No video available yet';
    return _Card(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _controller != null
                ? FieldrushVideoPlayer(
                    controller: _controller!,
                    isLive: _live,
                    label: title,
                    onTogglePlayback: _play,
                    onFullscreenChanged: _fullscreenChanged,
                  )
                : ColoredBox(
                    color: const Color(0xFF1D2A1B),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned(
                          top: 13,
                          left: 14,
                          child: Text(
                            _live
                                ? '● LIVE'
                                : hasUrl
                                ? 'REPLAY'
                                : 'WATCH',
                            style: _body(10, color: _lime),
                          ),
                        ),
                        if (_loading)
                          const FieldLoadingIndicator(
                            label: 'Loading video',
                            color: Colors.white54,
                          )
                        else
                          IconButton(
                            key: const ValueKey('solo-watch-play'),
                            onPressed: hasUrl ? _play : null,
                            tooltip: hasUrl
                                ? _error != null
                                      ? 'Retry video'
                                      : _live
                                      ? 'Watch live'
                                      : 'Watch replay'
                                : 'Video unavailable',
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white.withValues(
                                alpha: .16,
                              ),
                              disabledBackgroundColor: Colors.white.withValues(
                                alpha: .08,
                              ),
                              foregroundColor: Colors.white,
                              disabledForegroundColor: Colors.white54,
                              minimumSize: const Size(58, 58),
                              side: const BorderSide(color: Colors.white54),
                            ),
                            icon: Icon(
                              hasUrl
                                  ? Icons.play_arrow_rounded
                                  : Icons.videocam_off_outlined,
                              size: 30,
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(17),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: _display(18)),
                if (canClip) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('solo-watch-highlights'),
                        onPressed: _loading || _openingClips
                            ? null
                            : () => _openClips(highlights: true),
                        icon: const Icon(
                          Icons.play_circle_outline_rounded,
                          size: 18,
                        ),
                        label: const Text('Highlights'),
                        style: FilledButton.styleFrom(
                          backgroundColor: _green,
                          foregroundColor: Colors.white,
                          textStyle: _body(12, color: Colors.white),
                          shape: const StadiumBorder(),
                        ),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('solo-watch-clip'),
                        onPressed: _loading || _openingClips
                            ? null
                            : _openClips,
                        icon: const Icon(Icons.content_cut_rounded, size: 16),
                        label: Text(_openingClips ? 'Opening…' : 'Clip'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _green,
                          backgroundColor: _wash,
                          side: const BorderSide(color: _border),
                          textStyle: _body(12, color: _green),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 9),
                Text(
                  _error ??
                      (hasUrl
                          ? _live
                                ? 'Follow the game live. Tap the video for sound and fullscreen controls.'
                                : 'Watch the goals or clip your own moment.'
                          : status?.isProcessing == true
                          ? 'The recording will appear here when processing finishes.'
                          : 'A stream or recording will appear here when published. Pull down to refresh.'),
                  style: _body(11.5, weight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _localClock(DateTime value) =>
    '${value.hour % 12 == 0 ? 12 : value.hour % 12}:${value.minute.toString().padLeft(2, '0')} ${value.hour < 12 ? 'AM' : 'PM'}';
