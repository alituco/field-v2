import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../fixtures/fixture_repository.dart';
import '../open_queue/open_queue_repository.dart';
import '../ui/field_loading.dart';
import 'profile.dart';
import 'profile_clip_screen.dart';
import 'profile_repository.dart';
import 'player_safety_repository.dart';
import 'blocked_players_screen.dart';
import '../core/read_timeout.dart';

/// One shared gallery for your own clips and other players' public clips.
class ProfileClipsScreen extends StatefulWidget {
  const ProfileClipsScreen({
    super.key,
    required this.profile,
    required this.repository,
    required this.canManage,
    this.fixtureRepository,
    this.openQueueRepository,
  });

  final PlayerProfile profile;
  final ProfileRepository repository;
  final bool canManage;
  final FixtureRepository? fixtureRepository;
  final OpenQueueRepository? openQueueRepository;

  @override
  State<ProfileClipsScreen> createState() => _ProfileClipsScreenState();
}

class _ProfileClipsScreenState extends State<ProfileClipsScreen> {
  late PlayerProfile _profile = widget.profile;
  bool _refreshing = false;
  bool _mustRefreshIdentity = false;
  String? _refreshError;
  int _refreshRequest = 0;

  @override
  void initState() {
    super.initState();
    if (playerSafetyFor(widget.repository) != null) {
      _mustRefreshIdentity = true;
      _refresh();
    }
  }

  Future<void> _refresh({bool requireFresh = false}) async {
    if (requireFresh) {
      _refreshRequest++;
      _refreshing = false;
    }
    if (_refreshing) return;
    final request = ++_refreshRequest;
    final repository = widget.repository;
    final viewer = repository.currentUserId;
    setState(() {
      _refreshing = true;
      _mustRefreshIdentity = true;
      _refreshError = null;
    });
    bool current() =>
        mounted &&
        request == _refreshRequest &&
        identical(widget.repository, repository) &&
        viewer == repository.currentUserId;
    try {
      final profile = await repository
          .getProfile(_profile.id)
          .timeout(fieldReadTimeout);
      if (current()) {
        setState(() {
          _profile = profile;
          _mustRefreshIdentity = false;
        });
      }
    } catch (_) {
      if (current()) {
        setState(() => _refreshError = 'Could not refresh clips. Try again.');
      }
    } finally {
      if (current()) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _open(ProfileHighlight clip) async {
    setState(() {
      _mustRefreshIdentity = true;
      _refreshError = null;
      _refreshRequest++;
    });
    await Navigator.of(context).push<ProfileHighlight>(
      MaterialPageRoute(
        builder: (_) => ProfileClipScreen(
          highlight: clip,
          profileRepository: widget.repository,
          canManage: widget.canManage,
          ownerLabel: _profile.username.isEmpty
              ? _profile.displayName
              : '@${_profile.username}',
          ownerAvatarUrl: _profile.avatarUrl,
          ownerInitials: _profile.initials,
          fixtureRepository: widget.fixtureRepository,
          openQueueRepository: widget.openQueueRepository,
        ),
      ),
    );
    if (mounted) await _refresh(requireFresh: true);
  }

  @override
  Widget build(BuildContext context) {
    if (_mustRefreshIdentity || _profile.contentHidden) {
      return PlayerContentRefreshScreen(
        error:
            _refreshError ??
            (_profile.contentHidden
                ? 'This player’s clips are unavailable.'
                : null),
        onRetry: () => _refresh(requireFresh: true),
      );
    }
    final clips = _profile.highlights
        .where((clip) => widget.canManage || clip.isPublic)
        .toList();
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: Scaffold(
        key: const ValueKey('profile-clips-gallery'),
        backgroundColor: FieldrushAuthTheme.cream,
        appBar: AppBar(
          backgroundColor: FieldrushAuthTheme.cream,
          surfaceTintColor: Colors.transparent,
          title: const Text(
            'Clips',
            style: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w800),
          ),
        ),
        body: FieldRefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _profile.username.isEmpty
                              ? _profile.displayName
                              : '@${_profile.username}',
                          style: const TextStyle(
                            fontFamily: 'Outfit',
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: FieldrushAuthTheme.ink,
                          ),
                        ),
                      ),
                      Text(
                        '${clips.length} ${clips.length == 1 ? 'clip' : 'clips'}',
                        style: const TextStyle(
                          color: FieldrushAuthTheme.muted,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (clips.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text(
                      'No clips yet.',
                      style: TextStyle(color: FieldrushAuthTheme.muted),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(3, 0, 3, 24),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 3,
                          mainAxisSpacing: 3,
                        ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final clip = clips[index];
                      return Semantics(
                        button: true,
                        label:
                            '${clip.title}, ${clip.duration}, ${clip.views} views',
                        child: Material(
                          color: FieldrushAuthTheme.ink,
                          child: InkWell(
                            key: ValueKey('profile-grid-clip-${clip.id}'),
                            onTap: () => _open(clip),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (clip.thumbnailUrl.isNotEmpty)
                                  Image.network(
                                    clip.thumbnailUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const Icon(
                                      Icons.videocam_outlined,
                                      color: Colors.white38,
                                    ),
                                  )
                                else
                                  const Icon(
                                    Icons.videocam_outlined,
                                    color: Colors.white38,
                                  ),
                                const DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.center,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.transparent,
                                        Colors.black54,
                                      ],
                                    ),
                                  ),
                                ),
                                const Positioned(
                                  top: 8,
                                  right: 8,
                                  child: Icon(
                                    Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                ),
                                Positioned(
                                  bottom: 8,
                                  left: 8,
                                  right: 8,
                                  child: DefaultTextStyle(
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.visibility_outlined,
                                          color: Colors.white,
                                          size: 14,
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            '${clip.views} ${clip.views == 1 ? 'view' : 'views'}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          clip.isProcessing
                                              ? 'Processing'
                                              : clip.duration,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }, childCount: clips.length),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
