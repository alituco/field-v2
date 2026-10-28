import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import '../profile/goal_clip_downloader.dart';
import '../profile/profile_repository.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_modal.dart';
import '../ui/fieldrush_toast.dart';
import '../ui/fieldrush_video_player.dart';
import 'fixture.dart';
import 'fixture_detail_screen.dart' show openFieldrushMatchClipEditor;
import 'fixture_repository.dart';
import 'match_replay_timeline.dart';

/// The completed match recording, with its real events on the same timeline.
class FieldrushMatchReplayScreen extends StatefulWidget {
  const FieldrushMatchReplayScreen({
    super.key,
    required this.fixture,
    required this.fixtureRepository,
    this.profileRepository,
    this.goalClipDownloader,
    this.refreshFixture,
    this.sourceLabel,
    this.initialPosition = Duration.zero,
    this.openClipEditor = false,
  });

  final Fixture fixture;
  final FixtureRepository fixtureRepository;
  final ProfileRepository? profileRepository;
  final GoalClipDownloader? goalClipDownloader;
  final Future<Fixture> Function()? refreshFixture;
  final String? sourceLabel;
  final Duration initialPosition;
  final bool openClipEditor;

  @override
  State<FieldrushMatchReplayScreen> createState() =>
      _FieldrushMatchReplayScreenState();
}

class _FieldrushMatchReplayScreenState extends State<FieldrushMatchReplayScreen>
    with WidgetsBindingObserver {
  late Fixture _fixture = widget.fixture;
  VideoPlayerController? _controller;
  VideoPlayerController? _pendingController;
  bool _initializing = false;
  String? _error;
  int _generation = 0;
  bool _covered = false;
  bool _foreground = true;
  bool _editingClip = false;
  bool _openedInitialEditor = false;
  bool _seeking = false;
  double? _scrubMilliseconds;
  bool _resumeAfterScrub = false;
  Future<void>? _pauseBeforeScrub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_controller?.pause());
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller?.dispose());
    if (!identical(_pendingController, _controller)) {
      unawaited(_pendingController?.dispose());
    }
    super.dispose();
  }

  Future<void> _initialize({bool refresh = false}) async {
    if (_initializing) return;
    _initializing = true;
    final generation = ++_generation;
    VideoPlayerController? next;
    try {
      if (refresh) {
        final fixture =
            await (widget.refreshFixture?.call() ??
                widget.fixtureRepository.getFixture(widget.fixture.id));
        if (!mounted || generation != _generation) return;
        if (fixture.id != widget.fixture.id) {
          throw StateError('The match replay could not be confirmed.');
        }
        setState(() => _fixture = fixture);
      }
      final uri = Uri.tryParse(_fixture.fullGamePlaybackUrl ?? '');
      if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
        throw StateError('The match replay is not available yet.');
      }
      next = VideoPlayerController.networkUrl(uri);
      _pendingController = next;
      await next.initialize();
      if (!mounted || generation != _generation) {
        await next.dispose();
        return;
      }
      final initial = widget.initialPosition.inMilliseconds.clamp(
        0,
        next.value.duration.inMilliseconds,
      );
      if (initial > 0) await next.seekTo(Duration(milliseconds: initial));
      if (!mounted || generation != _generation) {
        await next.dispose();
        return;
      }
      final previous = _controller;
      final ready = next;
      setState(() {
        _controller = ready;
        _pendingController = null;
        _error = null;
      });
      await previous?.dispose();
      if (widget.openClipEditor && !_openedInitialEditor) {
        _openedInitialEditor = true;
        _covered = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_createClip());
        });
      } else if (!_covered &&
          _foreground &&
          mounted &&
          generation == _generation) {
        try {
          await next.play();
          if (_covered || !_foreground) await next.pause();
        } catch (_) {
          // A ready replay still offers Play when the system blocks autoplay.
        }
      }
    } catch (error) {
      if (next != null && !identical(_controller, next)) await next.dispose();
      if (mounted && generation == _generation) {
        setState(
          () => _error = userFacingError(
            error,
            fallback: 'Could not load this match replay. Try again.',
          ),
        );
      }
    } finally {
      _initializing = false;
      if (identical(_pendingController, next)) _pendingController = null;
    }
  }

  Future<void> _seek(Duration target, {bool? resume}) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _seeking) {
      return;
    }
    final generation = _generation;
    final shouldResume = resume ?? controller.value.isPlaying;
    setState(() => _seeking = true);
    try {
      await _pauseBeforeScrub;
      await controller.pause();
      if (!mounted || generation != _generation) return;
      await controller.seekTo(
        Duration(
          milliseconds: target.inMilliseconds.clamp(
            0,
            controller.value.duration.inMilliseconds,
          ),
        ),
      );
      if (mounted &&
          generation == _generation &&
          shouldResume &&
          !_covered &&
          _foreground) {
        await controller.play();
      }
    } catch (_) {
      if (mounted) {
        showFieldrushToast(
          context,
          'Could not jump to that moment. Try again.',
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _seeking = false;
          _scrubMilliseconds = null;
          _pauseBeforeScrub = null;
        });
      }
    }
  }

  void _startScrub(double value) {
    final controller = _controller;
    _resumeAfterScrub = controller?.value.isPlaying == true;
    _pauseBeforeScrub = controller?.pause().catchError((Object _) {
      _resumeAfterScrub = false;
    });
    setState(() => _scrubMilliseconds = value);
  }

  Future<void> _options() async {
    if (_editingClip || _covered) return;
    _covered = true;
    try {
      await _controller?.pause();
      if (!mounted) return;
      final createClip = await showFieldrushModal<bool>(
        context: context,
        builder: (modalContext) => FieldrushModal(
          title: 'Match replay',
          actions: [
            FilledButton.icon(
              onPressed: _controller?.value.isInitialized == true && !_seeking
                  ? () => Navigator.of(modalContext).pop(true)
                  : null,
              icon: const Icon(Icons.movie_creation_outlined),
              label: const Text('Create match clip'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.of(modalContext).pop(false),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      if (mounted && createClip == true) {
        await _createClip();
      }
    } catch (error) {
      if (mounted) {
        showFieldrushToast(
          context,
          userFacingError(
            error,
            fallback: 'Could not open the clip editor. Try again.',
          ),
        );
      }
    } finally {
      _covered = false;
    }
  }

  Future<void> _createClip() async {
    final controller = _controller;
    if (_editingClip || controller == null || !controller.value.isInitialized) {
      return;
    }
    setState(() => _editingClip = true);
    _covered = true;
    try {
      await controller.pause();
      if (!mounted) return;
      await openFieldrushMatchClipEditor(
        context,
        controller: controller,
        fixture: _fixture,
        profileRepository:
            widget.profileRepository ?? SupabaseProfileRepository(),
        goalClipDownloader:
            widget.goalClipDownloader ?? DeviceGoalClipDownloader(),
        sourceLabel: widget.sourceLabel,
      );
    } catch (error) {
      if (mounted) {
        showFieldrushToast(
          context,
          userFacingError(
            error,
            fallback: 'Could not open the clip editor. Try again.',
          ),
        );
      }
    } finally {
      _covered = false;
      if (mounted) setState(() => _editingClip = false);
    }
  }

  MatchReplayTimeline _timeline([VideoPlayerValue? value]) =>
      MatchReplayTimeline.fromFixture(
        _fixture,
        currentUserId: widget.profileRepository?.currentUserId,
        videoDuration: value?.isInitialized == true ? value!.duration : null,
      );

  @override
  Widget build(BuildContext context) {
    final fixture = _fixture;
    final controller = _controller;
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: Scaffold(
        key: const ValueKey('fieldrush-match-replay-screen'),
        backgroundColor: FieldrushAuthTheme.cream,
        appBar: AppBar(
          backgroundColor: FieldrushAuthTheme.cream,
          surfaceTintColor: Colors.transparent,
          leadingWidth: 48,
          titleSpacing: 0,
          leading: IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _ReplaySideDot(home: true),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '${fixture.homeClan.name} ${fixture.shouldDisplayScore ? '${fixture.homeScore ?? 0}–${fixture.awayScore ?? 0}' : 'vs'} ${fixture.awayClan?.name ?? 'Away'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const _ReplaySideDot(home: false),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                '${fixture.shouldDisplayScore ? 'Full time' : 'Result under review'} · ${_replayDate(fixture.matchDate)}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: FieldrushAuthTheme.muted,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Replay options',
              onPressed: _options,
              icon: const Icon(Icons.more_horiz_rounded),
            ),
            const SizedBox(width: 5),
          ],
        ),
        body: SafeArea(
          top: false,
          child: controller == null
              ? _body(null)
              : ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: controller,
                  builder: (_, value, _) => _body(value),
                ),
        ),
      ),
    );
  }

  Widget _body(VideoPlayerValue? value) {
    final timeline = _timeline(value);
    final position = Duration(
      milliseconds:
          _scrubMilliseconds?.round() ?? value?.position.inMilliseconds ?? 0,
    );
    final selected = timeline.currentMomentAt(position);
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (_controller != null)
          FieldrushVideoPlayer(
            controller: _controller!,
            controlsBelowVideo: true,
            showSkipButtons: true,
            showTimeInControls: false,
            label:
                '${_fixture.homeClan.name} vs ${_fixture.awayClan?.name ?? 'Away'}',
            timelineBuilder: (_, playerValue) =>
                _buildTimeline(timeline, playerValue),
          )
        else
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(
              color: FieldrushAuthTheme.watermark,
              child: Center(
                child: _error == null
                    ? const FieldLoadingIndicator(label: 'Loading match replay')
                    : Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, textAlign: TextAlign.center),
                            TextButton.icon(
                              onPressed: () {
                                setState(() => _error = null);
                                unawaited(_initialize(refresh: true));
                              },
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('Try again'),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 17, 20, 12),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'THE MATCH',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: FieldrushAuthTheme.muted,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
              Text(
                value == null ? 'Match moments' : 'Tap a moment to jump',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: FieldrushAuthTheme.muted,
                ),
              ),
            ],
          ),
        ),
        if (timeline.moments.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'No match moments were recorded.',
              style: TextStyle(color: FieldrushAuthTheme.muted),
            ),
          ),
        ..._momentRows(timeline, position, selected),
      ],
    );
  }

  List<Widget> _momentRows(
    MatchReplayTimeline timeline,
    Duration position,
    MatchReplayMoment? selected,
  ) {
    var insertedHalfTime = false;
    final rows = <Widget>[];
    for (final moment in timeline.moments) {
      if (!insertedHalfTime &&
          timeline.halftimeVideoPosition != null &&
          moment.position != null &&
          moment.position! >= timeline.halftimeVideoPosition!) {
        insertedHalfTime = true;
        rows.add(const _ReplayHalfTime());
      }
      if (moment.description == 'Half-time' && insertedHalfTime) continue;
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: _ReplayMomentRow(
            moment: moment,
            showScore: timeline.hasVerifiedScore,
            current: selected?.event.id == moment.event.id,
            future: moment.position == null || moment.position! > position,
            onTap: moment.position == null || _controller == null || _seeking
                ? null
                : () => unawaited(_seek(moment.position!)),
          ),
        ),
      );
    }
    return rows;
  }

  Widget _buildTimeline(MatchReplayTimeline timeline, VideoPlayerValue value) {
    final duration = value.duration.inMilliseconds;
    final position =
        (_scrubMilliseconds ?? value.position.inMilliseconds.toDouble()).clamp(
          0.0,
          duration.toDouble(),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 7, 16, 0),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return SizedBox(
                height: 16,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final moment in timeline.moments)
                      if (moment.position != null && duration > 0)
                        Positioned(
                          left:
                              10 +
                              (width - 20) *
                                  (moment.position!.inMilliseconds / duration)
                                      .clamp(0.0, 1.0) -
                              11,
                          top: -3,
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: IconButton(
                              key: ValueKey('replay-marker-${moment.event.id}'),
                              padding: EdgeInsets.zero,
                              tooltip: moment.description,
                              onPressed: _seeking
                                  ? null
                                  : () => unawaited(_seek(moment.position!)),
                              icon: _ReplayEventIcon(
                                moment: moment,
                                future:
                                    moment.position!.inMilliseconds > position,
                                size: 11,
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
              );
            },
          ),
          SizedBox(
            height: 22,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 5,
                activeTrackColor: FieldrushAuthTheme.forest,
                inactiveTrackColor: FieldrushAuthTheme.border,
                disabledActiveTrackColor: FieldrushAuthTheme.forest,
                disabledInactiveTrackColor: FieldrushAuthTheme.border,
                trackShape: const _ReplayTrackShape(),
                thumbShape: const _ReplayThumbShape(),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                key: const ValueKey('match-replay-seek'),
                padding: EdgeInsets.zero,
                min: 0,
                max: duration > 0 ? duration.toDouble() : 1,
                value: position,
                semanticFormatterCallback: (value) =>
                    _replayTime(Duration(milliseconds: value.round())),
                onChangeStart: duration > 0 && !_seeking ? _startScrub : null,
                onChanged: duration > 0 && !_seeking
                    ? (value) => setState(() => _scrubMilliseconds = value)
                    : null,
                onChangeEnd: duration > 0 && !_seeking
                    ? (value) => unawaited(
                        _seek(
                          Duration(milliseconds: value.round()),
                          resume: _resumeAfterScrub,
                        ),
                      )
                    : null,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _replayTime(Duration(milliseconds: position.round())),
                    style: _replayClockStyle,
                  ),
                ),
                if (timeline.halftimeVideoPosition != null)
                  Text(
                    'Half time ${_replayTime(Duration(seconds: timeline.halftimeMatchSeconds))}',
                    style: _replayClockStyle,
                  ),
                Expanded(
                  child: Text(
                    _replayTime(value.duration),
                    textAlign: TextAlign.right,
                    style: _replayClockStyle,
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

const _replayClockStyle = TextStyle(
  color: FieldrushAuthTheme.muted,
  fontSize: 11,
  fontWeight: FontWeight.w700,
);

String _momentDescription(MatchReplayMoment moment) {
  final event = moment.event;
  final player = event.player?.displayName.trim();
  if (moment.isGoal) {
    final scorer = moment.isMeGoal ? 'You' : player;
    final goal = moment.isOwnGoal
        ? (scorer == null || scorer.isEmpty ? 'Own goal' : '$scorer own goal')
        : (scorer == null || scorer.isEmpty ? 'Goal' : '$scorer scored');
    final assist = event.assist?.displayName.trim();
    if (moment.isMeAssist) return '$goal · your assist';
    if (assist != null && assist.isNotEmpty) return '$goal · $assist assist';
    return goal;
  }
  if (player != null && player.isNotEmpty) {
    if (moment.isBlueCard) return '$player blue card';
    if (moment.isRedCard) return '$player red card';
    if (moment.isYellowCard) return '$player yellow card';
  }
  return moment.description;
}

String _replayTime(Duration duration) =>
    '${duration.inSeconds ~/ 60}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

String _replayDate(DateTime date) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
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
  final local = date.toLocal();
  return '${days[local.weekday - 1]}, ${months[local.month - 1]} ${local.day}';
}

class _ReplayMomentRow extends StatelessWidget {
  const _ReplayMomentRow({
    required this.moment,
    required this.showScore,
    required this.current,
    required this.future,
    required this.onTap,
  });
  final MatchReplayMoment moment;
  final bool showScore;
  final bool current;
  final bool future;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = future ? const Color(0xFF9B9886) : FieldrushAuthTheme.ink;
    return Material(
      key: ValueKey('replay-moment-${moment.event.id}'),
      color: current ? const Color(0xFFEDF5E3) : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 46),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Text(
                    "${moment.event.minute}'",
                    style: TextStyle(
                      fontFamily: 'Outfit',
                      color: future ? color : FieldrushAuthTheme.forest,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _ReplayEventIcon(moment: moment, future: future, size: 13),
                const SizedBox(width: 10),
                if (moment.event.clanId != null ||
                    moment.event.profileId != null) ...[
                  _ReplaySideDot(
                    home: moment.isOwnGoal ? !moment.isHome : moment.isHome,
                    faded: future,
                  ),
                  const SizedBox(width: 7),
                ],
                Expanded(
                  child: Text(
                    _momentDescription(moment),
                    style: TextStyle(
                      color: color,
                      fontSize: 12.5,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (moment.isGoal && showScore) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${moment.homeScore}–${moment.awayScore}',
                    style: TextStyle(
                      fontFamily: 'Outfit',
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReplaySideDot extends StatelessWidget {
  const _ReplaySideDot({required this.home, this.faded = false});
  final bool home;
  final bool faded;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: faded ? 0.5 : 1,
    child: Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: home ? Colors.white : const Color(0xFF363A33),
        border: Border.all(color: const Color(0xFFB5AD94), width: 1.3),
      ),
    ),
  );
}

class _ReplayEventIcon extends StatelessWidget {
  const _ReplayEventIcon({
    required this.moment,
    required this.future,
    required this.size,
  });
  final MatchReplayMoment moment;
  final bool future;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (moment.isBlueCard || moment.isRedCard || moment.isYellowCard) {
      return Opacity(
        opacity: future ? 0.45 : 1,
        child: Container(
          width: size * 0.66,
          height: size,
          decoration: BoxDecoration(
            color: moment.isBlueCard
                ? const Color(0xFF3979BD)
                : moment.isYellowCard
                ? const Color(0xFFC79E35)
                : FieldrushAuthTheme.danger,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
    }
    final icon = moment.isGoal
        ? Icons.sports_soccer_outlined
        : switch (moment.eventType) {
            'MATCH_STARTED' ||
            'MATCH_RESUMED' ||
            'KICKOFF' ||
            'KICK_OFF' => Icons.play_arrow_rounded,
            'MATCH_PAUSED' || 'PAUSE' => Icons.pause_rounded,
            'MATCH_ENDED' || 'MATCH_STOPPED' => Icons.sports_score_rounded,
            _ => Icons.swap_horiz_rounded,
          };
    return Icon(
      icon,
      size: size,
      color: future ? const Color(0xFFA3A89A) : FieldrushAuthTheme.ink,
    );
  }
}

class _ReplayHalfTime extends StatelessWidget {
  const _ReplayHalfTime();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 15),
    child: Row(
      children: [
        Expanded(child: Divider(color: FieldrushAuthTheme.border)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            'HALF TIME',
            style: TextStyle(
              color: Color(0xFF9B9886),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Expanded(child: Divider(color: FieldrushAuthTheme.border)),
      ],
    ),
  );
}

class _ReplayTrackShape extends RectangularSliderTrackShape {
  const _ReplayTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) => Rect.fromLTWH(
    offset.dx + 10,
    offset.dy + (parentBox.size.height - 5) / 2,
    (parentBox.size.width - 20).clamp(0, double.infinity),
    5,
  );
}

class _ReplayThumbShape extends SliderComponentShape {
  const _ReplayThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.square(18);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    context.canvas.drawCircle(
      center,
      8,
      Paint()..color = FieldrushAuthTheme.cream,
    );
    context.canvas.drawCircle(
      center,
      8,
      Paint()
        ..color = FieldrushAuthTheme.forest
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }
}
