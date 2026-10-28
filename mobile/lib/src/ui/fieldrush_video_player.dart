import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../auth/fieldrush_auth_theme.dart';
import 'field_loading.dart';

/// Shared match/clip player. The caller owns and initializes [controller].
/// Place the default player in a bounded video area. With
/// [controlsBelowVideo], it sizes itself for use in a scrolling post.
class FieldrushVideoPlayer extends StatefulWidget {
  const FieldrushVideoPlayer({
    super.key,
    required this.controller,
    this.isLive = false,
    this.label = '',
    this.rangeStart = Duration.zero,
    this.rangeEnd,
    this.seekKey,
    this.onTogglePlayback,
    this.onOpenFullscreen,
    this.actionOverlay,
    this.onPlaybackStarted,
    this.onFullscreenChanged,
    this.controlsBelowVideo = false,
    this.timelineBuilder,
    this.showSkipButtons = false,
    this.showTimeInControls = true,
  }) : _fullscreen = false;

  const FieldrushVideoPlayer.fullscreen({
    super.key,
    required this.controller,
    required this.isLive,
    required this.label,
    required this.rangeStart,
    required this.rangeEnd,
    required this.onTogglePlayback,
    required this.onPlaybackStarted,
  }) : _fullscreen = true,
       seekKey = null,
       onOpenFullscreen = null,
       actionOverlay = null,
       onFullscreenChanged = null,
       controlsBelowVideo = false,
       timelineBuilder = null,
       showSkipButtons = false,
       showTimeInControls = true;

  final VideoPlayerController controller;
  final bool isLive;
  final String label;
  final Duration rangeStart;
  final Duration? rangeEnd;
  final Key? seekKey;
  final Future<void> Function()? onTogglePlayback;
  final VoidCallback? onOpenFullscreen;
  final Widget? actionOverlay;
  final VoidCallback? onPlaybackStarted;

  /// Sizes the inline video to its original ratio and places persistent
  /// playback controls beneath it, suitable for a scrolling clip post.
  final bool controlsBelowVideo;

  /// Replaces the inline progress track beneath the video when
  /// [controlsBelowVideo] is enabled. The builder shares this player's value.
  final Widget Function(BuildContext context, VideoPlayerValue value)?
  timelineBuilder;

  /// Adds ten-second skip buttons to the controls beneath the video.
  final bool showSkipButtons;

  /// The timeline can provide its own time labels in place of this readout.
  final bool showTimeInControls;

  /// Allows owners to defer controller replacement while fullscreen is open.
  final ValueChanged<bool>? onFullscreenChanged;
  final bool _fullscreen;

  @override
  State<FieldrushVideoPlayer> createState() => _FieldrushVideoPlayerState();
}

class _FieldrushVideoPlayerState extends State<FieldrushVideoPlayer> {
  static const _lime = Color(0xFFB8D969);
  static const _progressGreen = FieldrushAuthTheme.forest;
  static const _textStyle = TextStyle(
    fontFamily: 'PlusJakartaSans',
    color: Colors.white,
    fontSize: 11,
    fontWeight: FontWeight.w700,
  );

  Timer? _hideTimer;
  bool _controlsVisible = true;
  bool _wasPlaying = false;
  bool _wasBuffering = false;
  bool _openingFullscreen = false;
  bool _busy = false;
  String? _operationError;
  double? _dragMilliseconds;
  bool _resumeAfterDrag = false;
  Future<void>? _pauseBeforeDrag;
  int _operationVersion = 0;

  String get _prefix => widget._fullscreen ? 'fullscreen' : 'inline';

  @override
  void initState() {
    super.initState();
    _attachController();
  }

  void _attachController() {
    _wasPlaying = widget.controller.value.isPlaying;
    _wasBuffering = widget.controller.value.isBuffering;
    widget.controller.addListener(_onControllerChanged);
    _scheduleHide();
  }

  @override
  void didUpdateWidget(covariant FieldrushVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      _attachController();
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.rangeStart != widget.rangeStart ||
        oldWidget.rangeEnd != widget.rangeEnd ||
        oldWidget.controlsBelowVideo != widget.controlsBelowVideo) {
      _operationVersion++;
      _dragMilliseconds = null;
      _resumeAfterDrag = false;
      _pauseBeforeDrag = null;
      _busy = false;
      _operationError = null;
      _controlsVisible = true;
      _scheduleHide();
    }
  }

  @override
  void dispose() {
    _operationVersion++;
    _hideTimer?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final value = widget.controller.value;
    if (_wasPlaying == value.isPlaying && _wasBuffering == value.isBuffering) {
      return;
    }
    _wasPlaying = value.isPlaying;
    _wasBuffering = value.isBuffering;
    if (!mounted) return;
    if (!value.isPlaying || value.isBuffering) {
      _hideTimer?.cancel();
      if (!_controlsVisible) setState(() => _controlsVisible = true);
    } else {
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (widget.controlsBelowVideo) return;
    final value = widget.controller.value;
    if (!value.isPlaying ||
        value.isBuffering ||
        _dragMilliseconds != null ||
        _openingFullscreen) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!mounted) return;
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _toggleControls() {
    _hideTimer?.cancel();
    if (!widget.controller.value.isPlaying) {
      _showControls();
      return;
    }
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  Duration _start(VideoPlayerValue value) => Duration(
    milliseconds: widget.rangeStart.inMilliseconds.clamp(
      0,
      value.duration.inMilliseconds,
    ),
  );

  Duration _end(VideoPlayerValue value) => Duration(
    milliseconds: (widget.rangeEnd ?? value.duration).inMilliseconds.clamp(
      _start(value).inMilliseconds,
      value.duration.inMilliseconds,
    ),
  );

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    final version = _operationVersion;
    setState(() {
      _busy = true;
      _operationError = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted && version == _operationVersion) {
        setState(() => _operationError = 'Playback interrupted. Try again.');
      }
    } finally {
      if (mounted && version == _operationVersion) {
        setState(() => _busy = false);
        _showControls();
      }
    }
  }

  Future<void> _togglePlayback() => _run(() async {
    final controller = widget.controller;
    final version = _operationVersion;
    final wasPlaying = controller.value.isPlaying;
    if (widget.onTogglePlayback != null) {
      await widget.onTogglePlayback!();
    } else if (wasPlaying) {
      await controller.pause();
    } else {
      final value = controller.value;
      if (!widget.isLive &&
          (value.position >= _end(value) || value.position < _start(value))) {
        await controller.seekTo(_start(value));
      }
      if (!mounted || version != _operationVersion) return;
      await controller.play();
    }
    if (mounted &&
        version == _operationVersion &&
        !wasPlaying &&
        controller.value.isPlaying) {
      widget.onPlaybackStarted?.call();
    }
  });

  Future<void> _seekBy(int seconds) => _run(() async {
    final controller = widget.controller;
    final value = controller.value;
    final target = (value.position.inMilliseconds + seconds * 1000).clamp(
      _start(value).inMilliseconds,
      _end(value).inMilliseconds,
    );
    await controller.seekTo(Duration(milliseconds: target));
  });

  void _startDrag(double value) {
    _hideTimer?.cancel();
    _resumeAfterDrag = widget.controller.value.isPlaying;
    // Hold playback while the user chooses a position. No network seek is
    // issued until release, so HLS does not restart for every thumb movement.
    final version = _operationVersion;
    _pauseBeforeDrag = _resumeAfterDrag
        ? widget.controller.pause().catchError((Object _) {
            if (mounted && version == _operationVersion) {
              setState(() {
                _resumeAfterDrag = false;
                _operationError = 'Playback interrupted. Try again.';
              });
            }
          })
        : null;
    setState(() {
      _controlsVisible = true;
      _dragMilliseconds = value;
    });
  }

  Future<void> _finishDrag(double value) async {
    final controller = widget.controller;
    final version = _operationVersion;
    final resume = _resumeAfterDrag;
    final pause = _pauseBeforeDrag;
    await _run(() async {
      await pause;
      if (!mounted || version != _operationVersion) return;
      await controller.seekTo(
        Duration(
          milliseconds: value.round().clamp(
            _start(controller.value).inMilliseconds,
            _end(controller.value).inMilliseconds,
          ),
        ),
      );
      if (!mounted || version != _operationVersion) return;
      if (resume) {
        await controller.play();
        if (mounted && version == _operationVersion) {
          widget.onPlaybackStarted?.call();
        }
      }
    });
    if (mounted && version == _operationVersion) {
      setState(() {
        _dragMilliseconds = null;
        _resumeAfterDrag = false;
        _pauseBeforeDrag = null;
      });
      _showControls();
    }
  }

  Future<void> _openFullscreen() async {
    _showControls();
    if (widget._fullscreen) {
      Navigator.of(context).pop();
      return;
    }
    if (widget.onOpenFullscreen != null) {
      widget.onOpenFullscreen!();
      return;
    }
    if (_openingFullscreen) return;
    _openingFullscreen = true;
    _hideTimer?.cancel();
    try {
      widget.onFullscreenChanged?.call(true);
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _FullscreenPlayerPage(
            player: FieldrushVideoPlayer.fullscreen(
              controller: widget.controller,
              isLive: widget.isLive,
              label: widget.label,
              rangeStart: widget.rangeStart,
              rangeEnd: widget.rangeEnd,
              onTogglePlayback: widget.onTogglePlayback,
              onPlaybackStarted: widget.onPlaybackStarted,
            ),
          ),
        ),
      );
    } finally {
      _openingFullscreen = false;
      if (mounted) {
        widget.onFullscreenChanged?.call(false);
        _showControls();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: widget.controller,
        builder: (context, value, _) {
          final ready = value.isInitialized && !value.hasError;
          final start = _start(value);
          final end = _end(value);
          final position = Duration(
            milliseconds:
                (_dragMilliseconds?.round() ?? value.position.inMilliseconds)
                    .clamp(start.inMilliseconds, end.inMilliseconds),
          );
          final allowSeek = ready && !widget.isLive && end > start;
          if (widget.controlsBelowVideo) {
            return _buildPostPlayer(
              value,
              ready,
              start,
              end,
              position,
              allowSeek,
            );
          }
          return Stack(
            key: ValueKey('$_prefix-video-player'),
            fit: StackFit.expand,
            children: [
              if (ready)
                Center(
                  child: AspectRatio(
                    aspectRatio: value.aspectRatio > 0
                        ? value.aspectRatio
                        : 16 / 9,
                    child: VideoPlayer(widget.controller),
                  ),
                ),
              GestureDetector(
                key: ValueKey('$_prefix-video-tap-target'),
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
              ),
              if (!ready)
                Center(
                  child: value.hasError
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.videocam_off_rounded,
                                color: Colors.white70,
                                size: 30,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Video unavailable. Reopen it to try again.',
                                textAlign: TextAlign.center,
                                style: _textStyle,
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.square(
                          dimension: 26,
                          child: FieldLoadingIndicator(
                            color: _lime,
                            label: 'Loading video',
                          ),
                        ),
                ),
              Positioned.fill(
                child: AnimatedOpacity(
                  key: ValueKey(
                    widget._fullscreen
                        ? 'fullscreen-controls-opacity'
                        : 'inline-video-controls-opacity',
                  ),
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Color(0xA6000000),
                                  Color(0x00000000),
                                  Color(0x19000000),
                                  Color(0xE6000000),
                                ],
                                stops: [0, .3, .52, 1],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 4,
                          left: widget._fullscreen ? 4 : 12,
                          right: widget.actionOverlay == null ? 12 : 64,
                          child: Row(
                            children: [
                              if (widget._fullscreen)
                                IconButton(
                                  key: const ValueKey('fullscreen-exit'),
                                  tooltip: 'Exit fullscreen',
                                  color: Colors.white,
                                  onPressed: () => Navigator.of(context).pop(),
                                  icon: const Icon(Icons.arrow_back_rounded),
                                ),
                              if (widget.isLive)
                                const Padding(
                                  padding: EdgeInsets.only(right: 6),
                                  child: Icon(
                                    Icons.circle,
                                    color: Color(0xFFE76464),
                                    size: 7,
                                  ),
                                ),
                              Expanded(
                                child: Text(
                                  widget.label.isEmpty
                                      ? (widget.isLive ? 'LIVE' : 'REPLAY')
                                      : widget.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: _textStyle.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (ready)
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 32),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (allowSeek)
                                    IconButton(
                                      key: ValueKey('$_prefix-skip-back'),
                                      tooltip: 'Back 10 seconds',
                                      color: Colors.white,
                                      iconSize: 28,
                                      onPressed: _busy
                                          ? null
                                          : () => unawaited(_seekBy(-10)),
                                      icon: const Icon(Icons.replay_10_rounded),
                                    ),
                                  const SizedBox(width: 14),
                                  IconButton(
                                    key: ValueKey('$_prefix-playback-toggle'),
                                    tooltip: value.isPlaying ? 'Pause' : 'Play',
                                    iconSize: 38,
                                    style: IconButton.styleFrom(
                                      backgroundColor: const Color(0xB322301F),
                                      foregroundColor: Colors.white,
                                      disabledForegroundColor: Colors.white54,
                                      minimumSize: const Size(60, 60),
                                    ),
                                    onPressed: _busy
                                        ? null
                                        : () => unawaited(_togglePlayback()),
                                    icon: Icon(
                                      value.isPlaying
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  if (allowSeek)
                                    IconButton(
                                      key: ValueKey('$_prefix-skip-forward'),
                                      tooltip: 'Forward 10 seconds',
                                      color: Colors.white,
                                      iconSize: 28,
                                      onPressed: _busy
                                          ? null
                                          : () => unawaited(_seekBy(10)),
                                      icon: const Icon(
                                        Icons.forward_10_rounded,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        if (ready)
                          Positioned(
                            bottom: 0,
                            left: 8,
                            right: 8,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_operationError != null)
                                  Text(_operationError!, style: _textStyle),
                                if (allowSeek)
                                  SizedBox(
                                    height: 28,
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        activeTrackColor: _progressGreen,
                                        disabledActiveTrackColor:
                                            _progressGreen,
                                        inactiveTrackColor: Colors.white30,
                                        thumbColor: _progressGreen,
                                        overlayColor: _progressGreen.withValues(
                                          alpha: .18,
                                        ),
                                        trackHeight: 3,
                                        thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 5,
                                        ),
                                        overlayShape:
                                            const RoundSliderOverlayShape(
                                              overlayRadius: 13,
                                            ),
                                      ),
                                      child: Slider(
                                        key:
                                            widget.seekKey ??
                                            ValueKey('$_prefix-video-seek'),
                                        min: start.inMilliseconds.toDouble(),
                                        max: end.inMilliseconds.toDouble(),
                                        value: position.inMilliseconds
                                            .toDouble(),
                                        semanticFormatterCallback: (value) =>
                                            _formatTime(
                                              Duration(
                                                    milliseconds: value.round(),
                                                  ) -
                                                  start,
                                            ),
                                        onChangeStart: _busy
                                            ? null
                                            : _startDrag,
                                        onChanged: _busy
                                            ? null
                                            : (value) => setState(
                                                () => _dragMilliseconds = value,
                                              ),
                                        onChangeEnd: _busy
                                            ? null
                                            : (value) =>
                                                  unawaited(_finishDrag(value)),
                                      ),
                                    ),
                                  ),
                                Row(
                                  children: [
                                    IconButton(
                                      tooltip: value.volume == 0
                                          ? 'Unmute'
                                          : 'Mute',
                                      color: Colors.white,
                                      iconSize: 21,
                                      onPressed: () => unawaited(
                                        _run(
                                          () => widget.controller.setVolume(
                                            value.volume == 0 ? 1 : 0,
                                          ),
                                        ),
                                      ),
                                      icon: Icon(
                                        value.volume == 0
                                            ? Icons.volume_off_rounded
                                            : Icons.volume_up_rounded,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        widget.isLive
                                            ? 'LIVE'
                                            : '${_formatTime(position - start)} / ${_formatTime(end - start)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: _textStyle,
                                      ),
                                    ),
                                    if (value.isBuffering)
                                      const Padding(
                                        padding: EdgeInsets.all(8),
                                        child: SizedBox.square(
                                          dimension: 16,
                                          child: FieldLoadingIndicator(
                                            color: _lime,
                                            label: 'Buffering video',
                                          ),
                                        ),
                                      ),
                                    IconButton(
                                      tooltip: widget._fullscreen
                                          ? 'Exit fullscreen'
                                          : 'Fullscreen',
                                      color: Colors.white,
                                      iconSize: 25,
                                      onPressed: () =>
                                          unawaited(_openFullscreen()),
                                      icon: Icon(
                                        widget._fullscreen
                                            ? Icons.fullscreen_exit_rounded
                                            : Icons.fullscreen_rounded,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.actionOverlay != null)
                Positioned(top: 4, right: 6, child: widget.actionOverlay!),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPostPlayer(
    VideoPlayerValue value,
    bool ready,
    Duration start,
    Duration end,
    Duration position,
    bool allowSeek,
  ) {
    return Column(
      key: const ValueKey('inline-video-player'),
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          key: const ValueKey('inline-post-video-surface'),
          aspectRatio: ready && value.aspectRatio > 0
              ? value.aspectRatio
              : 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (ready) VideoPlayer(widget.controller),
              if (ready)
                GestureDetector(
                  key: const ValueKey('inline-video-tap-target'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _busy ? null : () => unawaited(_togglePlayback()),
                )
              else
                Center(
                  child: value.hasError
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Video unavailable. Reopen it to try again.',
                            textAlign: TextAlign.center,
                            style: _textStyle,
                          ),
                        )
                      : const SizedBox.square(
                          dimension: 26,
                          child: FieldLoadingIndicator(
                            color: FieldrushAuthTheme.forest,
                            label: 'Loading video',
                          ),
                        ),
                ),
              if (allowSeek && widget.timelineBuilder == null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 28,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: _progressGreen,
                      inactiveTrackColor: FieldrushAuthTheme.border,
                      disabledActiveTrackColor: _progressGreen,
                      disabledInactiveTrackColor: FieldrushAuthTheme.border,
                      trackHeight: 3,
                      trackShape: const _PostProgressTrackShape(),
                      thumbShape: SliderComponentShape.noThumb,
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      key:
                          widget.seekKey ?? const ValueKey('inline-video-seek'),
                      min: start.inMilliseconds.toDouble(),
                      max: end.inMilliseconds.toDouble(),
                      value: position.inMilliseconds.toDouble(),
                      semanticFormatterCallback: (value) => _formatTime(
                        Duration(milliseconds: value.round()) - start,
                      ),
                      onChangeStart: _busy ? null : _startDrag,
                      onChanged: _busy
                          ? null
                          : (value) =>
                                setState(() => _dragMilliseconds = value),
                      onChangeEnd: _busy
                          ? null
                          : (value) => unawaited(_finishDrag(value)),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (widget.timelineBuilder != null)
          Material(
            color: FieldrushAuthTheme.cream,
            child: widget.timelineBuilder!(context, value),
          ),
        Material(
          color: FieldrushAuthTheme.cream,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: const ValueKey('inline-post-video-controls'),
                height: 48,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      IconButton(
                        key: const ValueKey('inline-playback-toggle'),
                        tooltip: value.isPlaying ? 'Pause' : 'Play',
                        color: FieldrushAuthTheme.ink,
                        iconSize: 22,
                        onPressed: !ready || _busy
                            ? null
                            : () => unawaited(_togglePlayback()),
                        icon: Icon(
                          value.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      ),
                      if (widget.showSkipButtons && allowSeek)
                        IconButton(
                          key: const ValueKey('inline-skip-back'),
                          tooltip: 'Back 10 seconds',
                          color: FieldrushAuthTheme.ink,
                          iconSize: 24,
                          onPressed: _busy
                              ? null
                              : () => unawaited(_seekBy(-10)),
                          icon: const Icon(Icons.replay_10_rounded),
                        ),
                      if (widget.showSkipButtons && allowSeek)
                        IconButton(
                          key: const ValueKey('inline-skip-forward'),
                          tooltip: 'Forward 10 seconds',
                          color: FieldrushAuthTheme.ink,
                          iconSize: 24,
                          onPressed: _busy
                              ? null
                              : () => unawaited(_seekBy(10)),
                          icon: const Icon(Icons.forward_10_rounded),
                        ),
                      const SizedBox(width: 4),
                      if (widget.showTimeInControls)
                        Expanded(
                          child: Text(
                            widget.isLive
                                ? 'LIVE'
                                : '${_formatTime(position - start)} / ${_formatTime(end - start)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _textStyle.copyWith(
                              color: FieldrushAuthTheme.muted,
                              fontSize: 13,
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      if (value.isBuffering)
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: SizedBox.square(
                            dimension: 14,
                            child: FieldLoadingIndicator(
                              color: FieldrushAuthTheme.forest,
                              label: 'Buffering video',
                            ),
                          ),
                        ),
                      IconButton(
                        tooltip: value.volume == 0 ? 'Unmute' : 'Mute',
                        color: FieldrushAuthTheme.ink,
                        iconSize: 22,
                        onPressed: !ready || _busy
                            ? null
                            : () => unawaited(
                                _run(
                                  () => widget.controller.setVolume(
                                    value.volume == 0 ? 1 : 0,
                                  ),
                                ),
                              ),
                        icon: Icon(
                          value.volume == 0
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Fullscreen',
                        color: FieldrushAuthTheme.ink,
                        iconSize: 25,
                        onPressed: ready
                            ? () => unawaited(_openFullscreen())
                            : null,
                        icon: const Icon(Icons.fullscreen_rounded),
                      ),
                    ],
                  ),
                ),
              ),
              if (_operationError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                  child: Text(
                    _operationError!,
                    style: _textStyle.copyWith(
                      color: FieldrushAuthTheme.danger,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PostProgressTrackShape extends RectangularSliderTrackShape {
  const _PostProgressTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final height = sliderTheme.trackHeight ?? 3;
    return Rect.fromLTWH(
      offset.dx,
      offset.dy + parentBox.size.height - height,
      parentBox.size.width,
      height,
    );
  }
}

String _formatTime(Duration time) {
  final total = time.inSeconds.clamp(0, 1 << 31);
  final minutes = total ~/ 60;
  final seconds = (total % 60).toString().padLeft(2, '0');
  if (minutes < 60) return '$minutes:$seconds';
  return '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}:$seconds';
}

class _FullscreenPlayerPage extends StatefulWidget {
  const _FullscreenPlayerPage({required this.player});

  final FieldrushVideoPlayer player;

  @override
  State<_FullscreenPlayerPage> createState() => _FullscreenPlayerPageState();
}

class _FullscreenPlayerPageState extends State<_FullscreenPlayerPage> {
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

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(child: widget.player),
  );
}
