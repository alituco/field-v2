import 'dart:async';

import 'package:flutter/material.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_avatar_image.dart';
import '../ui/fieldrush_toast.dart';
import '../ui/fieldrush_video_player.dart';
import '../ui/fieldrush_modal.dart';
import 'package:video_player/video_player.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/field_confirmation_dialog.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture.dart';
import '../fixtures/fixture_repository.dart';
import '../open_queue/open_queue_repository.dart';
import 'goal_clip_downloader.dart';
import 'profile.dart';
import 'profile_clip_actions.dart';
import 'profile_repository.dart';
import 'player_safety_repository.dart';
import 'blocked_players_screen.dart';
import '../core/read_timeout.dart';

class ProfileClipScreen extends StatefulWidget {
  const ProfileClipScreen({
    super.key,
    required this.highlight,
    required this.profileRepository,
    required this.canManage,
    this.downloader,
    this.ownerLabel,
    this.ownerAvatarUrl,
    this.ownerInitials,
    this.fixtureRepository,
    this.openQueueRepository,
    this.playerSafetyRepository,
  });

  final ProfileHighlight highlight;
  final ProfileRepository profileRepository;
  final PlayerSafetyRepository? playerSafetyRepository;
  final bool canManage;
  final GoalClipDownloader? downloader;
  final String? ownerLabel;
  final String? ownerAvatarUrl;
  final String? ownerInitials;
  final FixtureRepository? fixtureRepository;
  final OpenQueueRepository? openQueueRepository;

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
  bool _isUpdatingVisibility = false;
  bool _isDeleting = false;
  double? _downloadProgress;
  int _loadGeneration = 0;
  List<ProfileClipRecommendation> _recommendations = const [];
  bool _loadingRecommendations = true;
  bool _recommendationsFailed = false;
  Fixture? _sourceFixture;
  bool _openingNext = false;
  bool _openingFullMatch = false;
  bool _playbackSuspended = false;

  bool _checkingSafety = true;
  bool _contentAllowed = false;
  String? _contentError;
  int _safetyGeneration = 0;
  String? _safetyViewerId;

  @override
  void initState() {
    super.initState();
    unawaited(_authorizeContent());
  }

  bool get _mayDisplayContent =>
      _contentAllowed &&
      !_checkingSafety &&
      _safetyViewerId == widget.profileRepository.currentUserId;

  Future<void> _invalidateClipContent() async {
    _safetyGeneration++;
    _loadGeneration++;
    _statusTimer?.cancel();
    _statusTimer = null;
    final controller = _controller;
    setState(() {
      _checkingSafety = true;
      _contentAllowed = false;
      _contentError = null;
      _controller = null;
      _loadedVideoUrl = null;
      _isLoadingVideo = false;
      _isRefreshing = false;
      _recommendations = const [];
      _loadingRecommendations = true;
      _recommendationsFailed = false;
      _sourceFixture = null;
    });
    try {
      await controller?.pause();
    } catch (_) {
      // Always attempt disposal even when the native player cannot pause.
    }
    try {
      await controller?.dispose();
    } catch (_) {
      // The player is already detached; a failed native disposal must not
      // restore the old clip while its safety state is unknown.
    }
  }

  Future<void> _authorizeContent() async {
    await _invalidateClipContent();
    if (!mounted) {
      return;
    }
    final generation = _safetyGeneration;
    final repository = widget.profileRepository;
    final viewerId = _safetyViewerId = repository.currentUserId;
    final safety = widget.playerSafetyRepository ?? playerSafetyFor(repository);
    bool current() =>
        mounted &&
        generation == _safetyGeneration &&
        identical(widget.profileRepository, repository) &&
        repository.currentUserId == viewerId;
    setState(() {
      _checkingSafety = true;
      _contentAllowed = false;
      _contentError = null;
    });
    try {
      if (safety != null) {
        var owner = _highlight.profileId?.trim();
        if (owner == null || owner.isEmpty) {
          final refreshed = await repository
              .refreshHighlight(_highlight.id)
              .timeout(fieldReadTimeout);
          if (!current()) {
            return;
          }
          if (refreshed.id != _highlight.id) {
            throw const FormatException('Clip unavailable.');
          }
          _highlight = refreshed;
          owner = refreshed.profileId?.trim();
        }
        if (owner == null || owner.isEmpty) {
          throw const FormatException('Clip owner unavailable.');
        }
        if (owner != viewerId) {
          if (!_highlight.isPublic) {
            throw const FormatException('Clip unavailable.');
          }
          final state = await safety.getState(owner).timeout(fieldReadTimeout);
          if (!current()) {
            return;
          }
          if (state.interactionBlocked) {
            setState(() => _checkingSafety = false);
            return;
          }
        }
      }
      if (!current()) {
        return;
      }
      setState(() {
        _checkingSafety = false;
        _contentAllowed = true;
      });
      unawaited(_loadRecommendations());
      unawaited(_loadSourceMatch());
      if (_highlight.isProcessing) {
        _startStatusPolling();
        unawaited(_refreshHighlight());
      } else {
        unawaited(_syncVideoPlayer());
      }
    } catch (error) {
      if (current()) {
        setState(() {
          _checkingSafety = false;
          _contentError = userFacingError(
            error,
            fallback: 'We could not open this clip. Try again.',
          );
        });
      }
    }
  }

  Future<void> _loadRecommendations() async {
    if (!_mayDisplayContent) {
      return;
    }
    final safetyGeneration = _safetyGeneration;
    try {
      final clips = await widget.profileRepository.getClipRecommendations(
        highlightId: _highlight.id,
      );
      if (!mounted ||
          safetyGeneration != _safetyGeneration ||
          !_mayDisplayContent) {
        return;
      }
      setState(() {
        _recommendations = clips;
        _loadingRecommendations = false;
        _recommendationsFailed = false;
      });
    } catch (_) {
      if (!mounted ||
          safetyGeneration != _safetyGeneration ||
          !_mayDisplayContent) {
        return;
      }
      setState(() {
        _loadingRecommendations = false;
        _recommendationsFailed = true;
      });
    }
  }

  Future<void> _loadSourceMatch() async {
    if (!_mayDisplayContent) {
      return;
    }
    final safetyGeneration = _safetyGeneration;
    try {
      final fixture = await loadProfileClipFixture(
        _highlight,
        fixtureRepository: widget.fixtureRepository,
        openQueueRepository: widget.openQueueRepository,
      );
      if (mounted &&
          safetyGeneration == _safetyGeneration &&
          _mayDisplayContent) {
        setState(() => _sourceFixture = fixture);
      }
    } catch (_) {
      // The clip remains watchable when its original match cannot be loaded.
    }
  }

  Future<void> _openNext(ProfileClipRecommendation next) async {
    if (_openingNext || !_mayDisplayContent) {
      return;
    }
    _openingNext = true;
    _playbackSuspended = true;
    try {
      await _invalidateClipContent();
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ProfileClipScreen(
            highlight: next.highlight,
            profileRepository: widget.profileRepository,
            playerSafetyRepository: widget.playerSafetyRepository,
            canManage: next.profileId == widget.profileRepository.currentUserId,
            ownerLabel: next.username.isEmpty
                ? next.displayName
                : '@${next.username}',
            ownerAvatarUrl: next.avatarUrl,
            ownerInitials: _initials(next.displayName),
            fixtureRepository: widget.fixtureRepository,
            openQueueRepository: widget.openQueueRepository,
            downloader: widget.downloader,
          ),
        ),
      );
    } finally {
      _openingNext = false;
      _playbackSuspended = false;
      if (mounted) await _authorizeContent();
    }
  }

  Future<void> _openFullMatch() async {
    if (_openingFullMatch || !_mayDisplayContent) {
      return;
    }
    _playbackSuspended = true;
    setState(() => _openingFullMatch = true);
    try {
      final sourceFixture = _sourceFixture;
      await _invalidateClipContent();
      if (!mounted) return;
      await openProfileClipFullMatch(
        context,
        highlight: _highlight,
        initialFixture: sourceFixture,
        fixtureRepository: widget.fixtureRepository,
        openQueueRepository: widget.openQueueRepository,
        profileRepository: widget.profileRepository,
        goalClipDownloader: widget.downloader,
      );
    } finally {
      _playbackSuspended = false;
      if (mounted) {
        setState(() => _openingFullMatch = false);
        await _authorizeContent();
      }
    }
  }

  @override
  void dispose() {
    _loadGeneration += 1;
    _safetyGeneration++;
    _statusTimer?.cancel();
    final controller = _controller;
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
    if (_isRefreshing || !_mayDisplayContent) {
      return null;
    }
    final safetyGeneration = _safetyGeneration;
    _isRefreshing = true;
    try {
      final next = await widget.profileRepository.refreshHighlight(
        _highlight.id,
      );
      if (!mounted ||
          safetyGeneration != _safetyGeneration ||
          !_mayDisplayContent) {
        return null;
      }
      setState(() => _highlight = next);
      if (!next.isProcessing) _statusTimer?.cancel();
      await _syncVideoPlayer();
      return next;
    } catch (error) {
      if (mounted && showError) {
        showFieldrushToast(
          context,
          userFacingError(
            error,
            fallback: 'We could not refresh this clip. Try again.',
          ),
        );
      }
      return null;
    } finally {
      if (safetyGeneration == _safetyGeneration) _isRefreshing = false;
    }
  }

  Future<void> _syncVideoPlayer() async {
    if (!_mayDisplayContent) {
      return;
    }
    final videoUrl = _highlight.videoUrl?.trim();
    if (!_highlight.isReady || videoUrl == null || videoUrl.isEmpty) return;
    if (_loadedVideoUrl == videoUrl &&
        _controller?.value.isInitialized == true) {
      return;
    }

    final generation = ++_loadGeneration;
    final previous = _controller;
    _controller = null;
    _loadedVideoUrl = null;
    if (previous != null) await previous.dispose();
    if (!mounted || generation != _loadGeneration || !_mayDisplayContent) {
      return;
    }
    setState(() {
      _isLoadingVideo = true;
      _playerError = null;
    });

    final next = VideoPlayerController.networkUrl(Uri.parse(videoUrl));
    try {
      await next.initialize();
      await next.setLooping(false);
      if (!mounted || generation != _loadGeneration || !_mayDisplayContent) {
        await next.dispose();
        return;
      }
      setState(() {
        _controller = next;
        _loadedVideoUrl = videoUrl;
        _isLoadingVideo = false;
      });
      // The user explicitly opened this post. Start just this clip; the gallery
      // itself never creates players or records views for unseen tiles.
      try {
        if (_playbackSuspended || !_mayDisplayContent) {
          return;
        }
        await next.play();
        if (mounted && generation == _loadGeneration) {
          unawaited(_recordViewOnce());
        }
      } catch (_) {
        // If autoplay is unavailable, keep the ready player and its Play action.
      }
    } catch (_) {
      await next.dispose();
      if (!mounted || generation != _loadGeneration || !_mayDisplayContent) {
        return;
      }
      setState(() {
        _isLoadingVideo = false;
        _playerError = 'This clip could not be loaded.';
      });
    }
  }

  Future<void> _togglePlayback() async {
    if (_playbackSuspended || !_mayDisplayContent) {
      return;
    }
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
    if (_viewRecorded || !_mayDisplayContent) {
      return;
    }
    final safetyGeneration = _safetyGeneration;
    _viewRecorded = true;
    try {
      final views = await widget.profileRepository.recordHighlightView(
        _highlight.id,
      );
      if (mounted &&
          safetyGeneration == _safetyGeneration &&
          _mayDisplayContent) {
        setState(() => _highlight = _highlight.copyWith(views: views));
      }
    } catch (_) {
      // Playback should never be interrupted because analytics could not save.
    }
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
      showFieldrushToast(context, 'Goal saved to your Photos.');
    } catch (error) {
      if (!mounted) return;
      showFieldrushToast(
        context,
        userFacingError(
          error,
          fallback: 'We could not save this goal. Try again.',
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

  Future<void> _setVisibility(bool isPublic) async {
    if (!widget.canManage ||
        _isUpdatingVisibility ||
        _isDeleting ||
        _highlight.isPublic == isPublic) {
      return;
    }
    setState(() => _isUpdatingVisibility = true);
    try {
      final next = await widget.profileRepository.updateHighlightVisibility(
        highlightId: _highlight.id,
        isPublic: isPublic,
      );
      if (!mounted) return;
      setState(() => _highlight = next);
      showFieldrushToast(
        context,
        isPublic
            ? 'Clip is now public on your profile.'
            : 'Clip is now private. Only you can see it.',
      );
    } catch (error) {
      if (!mounted) return;
      showFieldrushToast(
        context,
        userFacingError(
          error,
          fallback: 'We could not change this clip’s visibility.',
        ),
      );
    } finally {
      if (mounted) setState(() => _isUpdatingVisibility = false);
    }
  }

  Future<void> _deleteClip() async {
    if (!widget.canManage || _isDeleting || _isUpdatingVisibility) return;
    final confirmed = await showFieldConfirmDialog(
      context: context,
      icon: Icons.delete_outline_rounded,
      eyebrow: 'Clip',
      title: 'Delete this clip?',
      message:
          '“${_highlight.title}” will be removed from your profile. The original match recording will not be affected.',
      detail: 'This cannot be undone.',
      cancelLabel: 'Keep clip',
      confirmLabel: 'Delete clip',
      destructive: true,
    );
    if (!mounted || confirmed != true) return;
    setState(() => _isDeleting = true);
    try {
      await widget.profileRepository.deleteHighlight(_highlight.id);
      if (!mounted) return;
      showFieldrushToast(context, 'Clip deleted.');
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _isDeleting = false);
      showFieldrushToast(
        context,
        userFacingError(
          error,
          fallback: 'We could not delete this clip. Try again.',
        ),
      );
    }
  }

  Future<void> _shareClip() async {
    _playbackSuspended = true;
    try {
      await _controller?.pause();
      if (mounted) await shareProfileClip(context, _highlight);
    } finally {
      _playbackSuspended = false;
    }
  }

  Future<void> _showOptions() async {
    _playbackSuspended = true;
    try {
      await _controller?.pause();
      if (mounted) await _presentOptions();
    } finally {
      _playbackSuspended = false;
    }
  }

  Future<void> _presentOptions() async {
    final shouldDelete = await showFieldrushModal<bool>(
      context: context,
      builder: (modalContext) => StatefulBuilder(
        builder: (context, updateModal) => FieldrushModal(
          title: 'Clip options',
          content: _ClipVisibilityCard(
            isPublic: _highlight.isPublic,
            isLoading: _isUpdatingVisibility,
            onChanged: (value) async {
              final update = _setVisibility(value);
              updateModal(() {});
              await update;
              if (context.mounted) updateModal(() {});
            },
          ),
          actions: [
            OutlinedButton.icon(
              key: const ValueKey('delete-profile-clip'),
              onPressed: _isUpdatingVisibility
                  ? null
                  : () => Navigator.of(modalContext).pop(true),
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Delete clip'),
              style: FieldrushModal.secondaryButtonStyle().copyWith(
                foregroundColor: const WidgetStatePropertyAll(
                  FieldrushAuthTheme.danger,
                ),
              ),
            ),
            OutlinedButton(
              onPressed: _isUpdatingVisibility
                  ? null
                  : () => Navigator.of(modalContext).pop(false),
              style: FieldrushModal.secondaryButtonStyle(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (shouldDelete == true && mounted) await _deleteClip();
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSafety ||
        !_contentAllowed ||
        _safetyViewerId != widget.profileRepository.currentUserId) {
      return Theme(
        data: FieldrushAuthTheme.theme(context),
        child: Scaffold(
          key: const ValueKey('profile-clip-safety'),
          appBar: AppBar(title: const Text('Clip')),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _checkingSafety
                  ? const FieldLoadingIndicator(label: 'Loading clip')
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _contentError ?? 'This clip is unavailable.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          playerBlockScope,
                          textAlign: TextAlign.center,
                        ),
                        if (_contentError != null)
                          TextButton(
                            onPressed: _authorizeContent,
                            child: const Text('Try again'),
                          ),
                      ],
                    ),
            ),
          ),
        ),
      );
    }
    final isMutating = _isUpdatingVisibility || _isDeleting;
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: PopScope(
        canPop: !isMutating,
        child: Scaffold(
          key: const ValueKey('fieldrush-profile-clip-screen'),
          backgroundColor: FieldrushAuthTheme.cream,
          appBar: AppBar(
            backgroundColor: FieldrushAuthTheme.cream,
            surfaceTintColor: Colors.transparent,
            foregroundColor: FieldrushAuthTheme.ink,
            titleSpacing: 0,
            leadingWidth: 52,
            leading: IconButton(
              tooltip: 'Back',
              onPressed: isMutating
                  ? null
                  : () => Navigator.of(context).pop(_highlight),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            title: Row(
              children: [
                _ClipOwnerAvatar(
                  avatarUrl: widget.ownerAvatarUrl,
                  initials:
                      widget.ownerInitials ??
                      _initials(
                        widget.ownerLabel?.replaceFirst('@', '') ?? 'Clip',
                      ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.ownerLabel ?? 'Clip',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Outfit',
                      color: FieldrushAuthTheme.ink,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            centerTitle: false,
            actions: [
              if (widget.canManage)
                IconButton(
                  key: const ValueKey('profile-clip-options'),
                  tooltip: 'Clip options',
                  onPressed: isMutating ? null : _showOptions,
                  icon: const Icon(
                    Icons.more_horiz_rounded,
                    color: FieldrushAuthTheme.ink,
                  ),
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                KeyedSubtree(
                  key: const ValueKey('profile-clip-post-media'),
                  child: _buildVideo(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 15, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _highlight.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Outfit',
                          color: FieldrushAuthTheme.ink,
                          fontSize: 25,
                          height: 1.15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        _clipMetadata(_highlight),
                        style: const TextStyle(
                          color: FieldrushAuthTheme.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _ClipAction(
                            key: const ValueKey('download-goal-clip'),
                            icon: Icons.download_rounded,
                            label: _isDownloading
                                ? _downloadLabel(_downloadProgress)
                                : 'Save',
                            onPressed:
                                _highlight.hasPlayableVideo && !_isDownloading
                                ? _downloadClip
                                : null,
                          ),
                          const SizedBox(width: 16),
                          _ClipAction(
                            key: const ValueKey('share-profile-clip'),
                            icon: Icons.ios_share_rounded,
                            label: 'Share',
                            onPressed: _highlight.hasPlayableVideo
                                ? _shareClip
                                : null,
                          ),
                          const SizedBox(width: 16),
                          _ClipAction(
                            key: const ValueKey('profile-clip-full-match'),
                            icon: Icons.smart_display_outlined,
                            label: _openingFullMatch
                                ? 'Opening…'
                                : 'Full match',
                            onPressed:
                                _highlight.sourceType != null &&
                                    _highlight.sourceMatchId != null &&
                                    !_openingFullMatch
                                ? _openFullMatch
                                : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const Divider(
                        height: 1,
                        color: FieldrushAuthTheme.border,
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'UP NEXT',
                        style: TextStyle(
                          color: FieldrushAuthTheme.muted,
                          fontSize: 12,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 17),
                      ..._buildUpNext(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildUpNext() {
    final fixture = _sourceFixture;
    final hasReplay = fixture?.fullGamePlaybackUrl != null;
    return [
      if (_loadingRecommendations)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: FieldLoadingIndicator(label: 'Loading clips'),
        )
      else if (_recommendationsFailed)
        TextButton.icon(
          onPressed: () {
            setState(() => _loadingRecommendations = true);
            unawaited(_loadRecommendations());
          },
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Try loading clips again'),
        )
      else if (_recommendations.isEmpty && !hasReplay)
        const Text(
          'You’re all caught up.',
          style: TextStyle(color: FieldrushAuthTheme.muted, fontSize: 13),
        ),
      for (final next in _recommendations)
        Padding(
          padding: const EdgeInsets.only(bottom: 13),
          child: _ClipNextRow(
            key: ValueKey('up-next-clip-${next.highlight.id}'),
            title: next.highlight.title,
            subtitle: _clipMetadata(next.highlight),
            thumbnailUrl: next.highlight.thumbnailUrl,
            duration: next.highlight.duration,
            onTap: () => _openNext(next),
          ),
        ),
      if (hasReplay)
        _ClipNextRow(
          key: const ValueKey('up-next-full-match'),
          title: 'Full match replay',
          subtitle:
              '${fixture!.homeClan.name} ${fixture.homeScore ?? 0}–${fixture.awayScore ?? 0} ${fixture.awayClan?.name ?? 'Away'} · ${_clipDate(fixture.matchDate)}',
          thumbnailUrl: _replayThumbnail(
            fixture,
            fallback: _highlight.thumbnailUrl,
          ),
          duration: _replayDuration(fixture),
          onTap: _openFullMatch,
        ),
    ];
  }

  Widget _buildVideo() {
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      return FieldrushVideoPlayer(
        controller: controller,
        controlsBelowVideo: true,
        isLive: false,
        label: _highlight.title,
        seekKey: const ValueKey('profile-clip-seek'),
        onTogglePlayback: _togglePlayback,
        onPlaybackStarted: () => unawaited(_recordViewOnce()),
      );
    }

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: FieldrushAuthTheme.ink,
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
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const FieldLoadingIndicator(
                          label: 'Loading video',
                          color: Colors.white38,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _highlight.isProcessing
                              ? 'Preparing your goal clip...'
                              : 'Loading your clip...',
                          style: const TextStyle(
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
                        if (_playerError != null) ...[
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: () => unawaited(_syncVideoPlayer()),
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: const Text('Try again'),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

String _initials(String name) {
  final words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty);
  return words.isEmpty
      ? '?'
      : words.take(2).map((part) => part.substring(0, 1).toUpperCase()).join();
}

String _clipDate(DateTime date) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
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
  return '${weekdays[local.weekday - 1]}, ${months[local.month - 1]} ${local.day}';
}

String _clipMetadata(ProfileHighlight clip) =>
    '${clip.views} ${clip.views == 1 ? 'view' : 'views'}${clip.createdAt == null ? '' : ' · ${_clipDate(clip.createdAt!)}'}';

String _replayDuration(Fixture fixture) {
  final broadcast = fixture.broadcast;
  final seconds =
      broadcast?.streamStartedAt != null && broadcast?.streamStoppedAt != null
      ? broadcast!.streamStoppedAt!
            .difference(broadcast.streamStartedAt!)
            .inSeconds
      : fixture.clock?.durationSeconds;
  if (seconds == null || seconds <= 0) return 'Replay';
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String _replayThumbnail(Fixture fixture, {required String fallback}) {
  final uri = Uri.tryParse(fixture.fullGamePlaybackUrl ?? '');
  final id = fixture.broadcast?.activeVideoId;
  if (uri == null ||
      id == null ||
      !(uri.host.endsWith('cloudflarestream.com') ||
          uri.host.endsWith('videodelivery.net'))) {
    return fallback;
  }
  return uri
      .replace(
        path: '/$id/thumbnails/thumbnail.jpg',
        queryParameters: {'height': '200', 'fit': 'crop'},
      )
      .toString();
}

class _ClipOwnerAvatar extends StatelessWidget {
  const _ClipOwnerAvatar({required this.avatarUrl, required this.initials});
  final String? avatarUrl;
  final String initials;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: SizedBox.square(
      dimension: 29,
      child: ColoredBox(
        color: const Color(0xFFEAE1C5),
        child: FieldrushAvatarImage(
          size: 29,
          url: avatarUrl,
          fallback: _label(),
        ),
      ),
    ),
  );

  Widget _label() => Center(
    child: Text(
      initials,
      style: const TextStyle(
        fontFamily: 'Outfit',
        fontWeight: FontWeight.w800,
        fontSize: 14,
        color: Color(0xFF625429),
      ),
    ),
  );
}

class _ClipAction extends StatelessWidget {
  const _ClipAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 64,
    child: Column(
      children: [
        SizedBox.square(
          dimension: 50,
          child: IconButton(
            tooltip: label,
            onPressed: onPressed,
            style: IconButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: FieldrushAuthTheme.ink,
              disabledForegroundColor: FieldrushAuthTheme.muted.withValues(
                alpha: 0.5,
              ),
              shape: const CircleBorder(
                side: BorderSide(color: FieldrushAuthTheme.border, width: 1.3),
              ),
            ),
            icon: Icon(icon, size: 20),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: FieldrushAuthTheme.muted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _ClipNextRow extends StatelessWidget {
  const _ClipNextRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.thumbnailUrl,
    required this.duration,
    required this.onTap,
  });
  final String title;
  final String subtitle;
  final String thumbnailUrl;
  final String duration;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(9),
    onTap: onTap,
    child: Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(
            width: 132,
            height: 74,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: FieldrushAuthTheme.watermark),
                if (thumbnailUrl.isNotEmpty)
                  Image.network(
                    thumbnailUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.smart_display_outlined,
                      color: FieldrushAuthTheme.muted,
                    ),
                  )
                else
                  const Icon(
                    Icons.smart_display_outlined,
                    color: FieldrushAuthTheme.muted,
                  ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      duration,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 17,
                  height: 1.15,
                  color: FieldrushAuthTheme.ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: FieldrushAuthTheme.muted,
                  fontSize: 11.5,
                  height: 1.35,
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

class _ClipVisibilityCard extends StatelessWidget {
  const _ClipVisibilityCard({
    required this.isPublic,
    required this.isLoading,
    required this.onChanged,
  });

  final bool isPublic;
  final bool isLoading;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: FieldrushAuthTheme.cream,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: FieldrushAuthTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isPublic ? Icons.public_rounded : Icons.lock_rounded,
                color: isPublic
                    ? FieldrushAuthTheme.forest
                    : FieldrushAuthTheme.muted,
                size: 18,
              ),
              const SizedBox(width: 7),
              const Text(
                'VISIBILITY',
                style: TextStyle(
                  color: FieldrushAuthTheme.ink,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.8,
                ),
              ),
              if (isLoading) ...[
                const Spacer(),
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: FieldLoadingIndicator(
                    label: 'Saving video visibility',
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 11),
          Container(
            key: const ValueKey('clip-visibility-selector'),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: FieldrushAuthTheme.border.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                for (final option in [true, false])
                  Expanded(
                    child: Semantics(
                      selected: isPublic == option,
                      child: TextButton.icon(
                        onPressed: isLoading ? null : () => onChanged(option),
                        icon: Icon(
                          option ? Icons.public_rounded : Icons.lock_rounded,
                          size: 16,
                        ),
                        label: Text(option ? 'Public' : 'Private'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 44),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          backgroundColor: isPublic == option
                              ? FieldrushAuthTheme.forest
                              : Colors.transparent,
                          foregroundColor: isPublic == option
                              ? Colors.white
                              : FieldrushAuthTheme.muted,
                          disabledForegroundColor: isPublic == option
                              ? Colors.white70
                              : FieldrushAuthTheme.muted,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          textStyle: const TextStyle(
                            fontFamily: 'PlusJakartaSans',
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 9),
          Text(
            isPublic
                ? 'Anyone can watch this clip from your profile.'
                : 'Only you can see this clip on your profile.',
            style: const TextStyle(
              color: FieldrushAuthTheme.muted,
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
