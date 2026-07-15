import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import 'goal_clip_downloader.dart';
import 'profile.dart';
import 'profile_repository.dart';

class ProfileClipScreen extends StatefulWidget {
  const ProfileClipScreen({
    super.key,
    required this.highlight,
    required this.profileRepository,
    this.downloader,
  });

  final ProfileHighlight highlight;
  final ProfileRepository profileRepository;
  final GoalClipDownloader? downloader;

  @override
  State<ProfileClipScreen> createState() => _ProfileClipScreenState();
}

class _ProfileClipScreenState extends State<ProfileClipScreen> {
  late ProfileHighlight _highlight = widget.highlight;
  late final GoalClipDownloader _downloader =
      widget.downloader ?? DeviceGoalClipDownloader();
  VideoPlayerController? _controller;
  Timer? _statusTimer;
  String? _loadedVideoUrl;
  String? _playerError;
  bool _isLoadingVideo = false;
  bool _isRefreshing = false;
  bool _viewRecorded = false;
  bool _isDownloading = false;
  double? _downloadProgress;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    if (_highlight.isProcessing) {
      _startStatusPolling();
      unawaited(_refreshHighlight());
    } else {
      unawaited(_syncVideoPlayer());
    }
  }

  @override
  void dispose() {
    _loadGeneration += 1;
    _statusTimer?.cancel();
    final controller = _controller;
    controller?.removeListener(_handleVideoTick);
    unawaited(controller?.dispose());
    super.dispose();
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => unawaited(_refreshHighlight()),
    );
  }

  Future<ProfileHighlight?> _refreshHighlight({bool showError = false}) async {
    if (_isRefreshing) return null;
    _isRefreshing = true;
    try {
      final next = await widget.profileRepository.refreshHighlight(
        _highlight.id,
      );
      if (!mounted) return null;
      setState(() => _highlight = next);
      if (!next.isProcessing) _statusTimer?.cancel();
      await _syncVideoPlayer();
      return next;
    } catch (error) {
      if (mounted && showError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              userFacingError(
                error,
                fallback: 'We could not refresh this clip. Try again.',
              ),
            ),
          ),
        );
      }
      return null;
    } finally {
      _isRefreshing = false;
    }
  }

  Future<void> _syncVideoPlayer() async {
    final videoUrl = _highlight.videoUrl?.trim();
    if (!_highlight.isReady || videoUrl == null || videoUrl.isEmpty) return;
    if (_loadedVideoUrl == videoUrl &&
        _controller?.value.isInitialized == true) {
      return;
    }

    final generation = ++_loadGeneration;
    final previous = _controller;
    previous?.removeListener(_handleVideoTick);
    _controller = null;
    _loadedVideoUrl = null;
    if (previous != null) await previous.dispose();
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _isLoadingVideo = true;
      _playerError = null;
    });

    final next = VideoPlayerController.networkUrl(Uri.parse(videoUrl));
    try {
      await next.initialize();
      await next.setLooping(false);
      if (!mounted || generation != _loadGeneration) {
        await next.dispose();
        return;
      }
      next.addListener(_handleVideoTick);
      setState(() {
        _controller = next;
        _loadedVideoUrl = videoUrl;
        _isLoadingVideo = false;
      });
    } catch (_) {
      await next.dispose();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _isLoadingVideo = false;
        _playerError = 'This clip could not be loaded.';
      });
    }
  }

  void _handleVideoTick() {
    if (mounted) setState(() {});
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      if (controller.value.duration > Duration.zero &&
          controller.value.position + const Duration(milliseconds: 250) >=
              controller.value.duration) {
        await controller.seekTo(Duration.zero);
      }
      await controller.play();
      unawaited(_recordViewOnce());
    }
    if (mounted) setState(() {});
  }

  Future<void> _recordViewOnce() async {
    if (_viewRecorded) return;
    _viewRecorded = true;
    try {
      final views = await widget.profileRepository.recordHighlightView(
        _highlight.id,
      );
      if (mounted) {
        setState(() => _highlight = _highlight.copyWith(views: views));
      }
    } catch (_) {
      // Playback should never be interrupted because analytics could not save.
    }
  }

  Future<void> _seek(double milliseconds) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    await controller.seekTo(Duration(milliseconds: milliseconds.round()));
    if (mounted) setState(() {});
  }

  Future<void> _downloadClip() async {
    if (_isDownloading) return;
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
    });
    try {
      var downloadUrl = _highlight.downloadUrl?.trim();
      for (
        var attempt = 0;
        (downloadUrl == null || downloadUrl.isEmpty) && attempt < 8;
        attempt++
      ) {
        final next = await _refreshHighlight(showError: attempt == 7);
        if (!mounted) return;
        downloadUrl = next?.downloadUrl?.trim();
        if (downloadUrl == null || downloadUrl.isEmpty) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      if (downloadUrl == null || downloadUrl.isEmpty) {
        throw StateError(
          'Your download is still being prepared. Try again in a moment.',
        );
      }

      await _downloader.downloadToGallery(
        url: downloadUrl,
        fileName: _downloadFileName(_highlight.title),
        onProgress: (progress) {
          if (mounted) setState(() => _downloadProgress = progress);
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Goal saved to your Photos.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'We could not save this goal. Try again.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadProgress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) return;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F9FC),
        appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          leading: IconButton(
            onPressed: () => Navigator.of(context).pop(_highlight),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: const Text(
            'CLIP',
            style: TextStyle(
              color: fieldGray900,
              fontSize: 16,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.8,
            ),
          ),
          centerTitle: true,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: fieldGray100),
                boxShadow: [
                  BoxShadow(
                    color: fieldGray900.withValues(alpha: 0.05),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildVideo(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 17, 18, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _highlight.title,
                          style: const TextStyle(
                            color: fieldGray900,
                            fontSize: 21,
                            height: 1.15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            const Icon(
                              Icons.remove_red_eye_outlined,
                              color: fieldGray400,
                              size: 17,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${_highlight.views} ${_highlight.views == 1 ? 'view' : 'views'}',
                              style: const TextStyle(
                                color: fieldGray500,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (_highlight.clanTag case final tag?) ...[
                              const SizedBox(width: 9),
                              const Text(
                                '·',
                                style: TextStyle(color: fieldGray300),
                              ),
                              const SizedBox(width: 9),
                              Text(
                                tag,
                                style: const TextStyle(
                                  color: fieldGray500,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: FilledButton.icon(
                            key: const ValueKey('download-goal-clip'),
                            onPressed:
                                _highlight.hasPlayableVideo && !_isDownloading
                                ? _downloadClip
                                : null,
                            icon: _isDownloading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.download_rounded),
                            label: Text(
                              _isDownloading
                                  ? _downloadLabel(_downloadProgress)
                                  : 'Save to Photos',
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: fieldEmerald600,
                              foregroundColor: Colors.white,
                              textStyle: const TextStyle(
                                fontSize: 14,
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo() {
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      final duration = controller.value.duration;
      final position = controller.value.position;
      final max = duration.inMilliseconds <= 0
          ? 1.0
          : duration.inMilliseconds.toDouble();
      final value = position.inMilliseconds.clamp(0, max.toInt()).toDouble();
      return AspectRatio(
        aspectRatio: controller.value.aspectRatio > 0
            ? controller.value.aspectRatio
            : 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Colors.black, child: VideoPlayer(controller)),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _togglePlayback,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: controller.value.isPlaying ? 0 : 1,
                    duration: const Duration(milliseconds: 160),
                    child: Container(
                      width: 62,
                      height: 62,
                      decoration: BoxDecoration(
                        color: fieldGray900.withValues(alpha: 0.78),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.22),
                        ),
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 38,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 9,
              right: 9,
              bottom: 6,
              child: Row(
                children: [
                  Text(
                    _formatDuration(position),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                        activeTrackColor: fieldEmerald500,
                        inactiveTrackColor: Colors.white38,
                        thumbColor: Colors.white,
                      ),
                      child: Slider(
                        key: const ValueKey('profile-clip-seek'),
                        min: 0,
                        max: max,
                        value: value,
                        onChanged: _seek,
                      ),
                    ),
                  ),
                  Text(
                    _formatDuration(duration),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: fieldGray900,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_highlight.thumbnailUrl.trim().isNotEmpty)
              Image.network(
                _highlight.thumbnailUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ColoredBox(color: Colors.black.withValues(alpha: 0.42)),
            Center(
              child: _highlight.isProcessing || _isLoadingVideo
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 12),
                        Text(
                          'Preparing your goal clip...',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _highlight.status == ProfileHighlightStatus.failed
                              ? Icons.error_outline_rounded
                              : Icons.movie_creation_outlined,
                          color: Colors.white,
                          size: 38,
                        ),
                        const SizedBox(height: 9),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            _highlight.errorMessage ??
                                _playerError ??
                                'This clip is not available yet.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

String _downloadFileName(String title) {
  final safe = title
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
      .replaceAll(RegExp(r'\s+'), '_');
  final base = safe.isEmpty ? 'field_goal' : safe;
  return '${base}_${DateTime.now().millisecondsSinceEpoch}.mp4';
}

String _downloadLabel(double? progress) {
  if (progress == null || progress <= 0) return 'Preparing download...';
  return 'Saving ${(progress.clamp(0, 1) * 100).round()}%';
}

String _formatDuration(Duration value) {
  final totalSeconds = value.inSeconds.clamp(0, 1 << 31);
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
