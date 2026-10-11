import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../clans/clan_repository.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture_repository.dart';
import '../home/home_discovery_repository.dart';
import '../home/home_discovery_screen.dart';
import '../profile/profile.dart';
import '../profile/profile_repository.dart';
import '../profile/profile_screen.dart';
import 'fieldrush_leaderboard_widgets.dart';
import 'leaderboard.dart';
import 'leaderboard_repository.dart';

class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({
    super.key,
    required this.clanRepository,
    required this.fixtureRepository,
    required this.leaderboardRepository,
    this.profileRepository,
    this.discoveryRepository,
    this.onOpenYou,
    this.activationTick = 0,
    this.playerActivationTick = 0,
  });

  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;
  final LeaderboardRepository leaderboardRepository;
  final ProfileRepository? profileRepository;
  final HomeDiscoveryRepository? discoveryRepository;
  final VoidCallback? onOpenYou;
  final int activationTick;
  final int playerActivationTick;

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  late final ProfileRepository _profiles =
      widget.profileRepository ?? SupabaseProfileRepository();
  late final HomeDiscoveryRepository _discovery =
      widget.discoveryRepository ?? SupabaseHomeDiscoveryRepository();
  LeaderboardSeason _season = activeLeaderboardSeason;
  String _lastActiveSeasonId = activeLeaderboardSeason.id;
  List<PlayerRatingLeaderboardEntry> _players = const [];
  List<PlayerRatingLeaderboardEntry> _neighbors = const [];
  PlayerRatingLeaderboardEntry? _rating;
  String? _profileId;
  String? _error;
  String? _pageError;
  int? _total;
  int? _nextOffset;
  int _visibleCount = 0;
  int _generation = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _clans = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LeaderboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final players =
        oldWidget.playerActivationTick != widget.playerActivationTick;
    if (players || oldWidget.activationTick != widget.activationTick) {
      if (players) _clans = false;
      if (players || _lastActiveSeasonId != activeLeaderboardSeason.id) {
        _season = activeLeaderboardSeason;
      }
      _lastActiveSeasonId = activeLeaderboardSeason.id;
      _load();
    }
  }

  Future<T?> _optional<T>(Future<T> Function() load) async {
    try {
      return await load();
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final season = _season;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _pageError = null;
      _visibleCount = 0;
    });
    try {
      final repository = widget.leaderboardRepository;
      final results = await Future.wait<Object?>([
        repository is PagedLeaderboardRepository
            ? (repository as PagedLeaderboardRepository).loadPlayerRatingPage(
                season: season,
              )
            : repository.loadPlayerRatingLeaderboard(
                season: season,
                region: 'phoenix',
              ),
        _optional(() => repository.loadCurrentPlayerRating(season)),
        _optional(_profiles.getCurrentProfile),
      ]);
      if (!mounted || generation != _generation) return;
      final page = results[0] is PlayerRatingLeaderboardPage
          ? results[0] as PlayerRatingLeaderboardPage
          : null;
      final players =
          page?.players ?? results[0] as List<PlayerRatingLeaderboardEntry>;
      final profile = results[2] as PlayerProfile?;
      setState(() {
        _players = _validPlayers(players);
        _neighbors = _validPlayers(page?.aroundMe ?? const []);
        _total = page?.totalCount;
        _nextOffset = page?.nextOffset;
        _rating = results[1] as PlayerRatingLeaderboardEntry?;
        // Current-season data must never fall back to lifetime profile totals.
        _profileId = _rating?.profileId ?? profile?.id;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = userFacingError(
          error,
          fallback: 'We could not load the leaderboard. Try again.',
        );
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  List<PlayerRatingLeaderboardEntry> _validPlayers(
    List<PlayerRatingLeaderboardEntry> players,
  ) =>
      players
          .where(
            (p) => p.isRanked && p.region.trim().toLowerCase() == 'phoenix',
          )
          .toList()
        ..sort((a, b) => a.rank.compareTo(b.rank));

  Future<void> _more() async {
    if (_loadingMore) return;
    final desired = _visibleCount + 20;
    final remaining = _players.length - 3;
    if (desired <= remaining || _nextOffset == null) {
      setState(() => _visibleCount = desired);
      return;
    }
    final repository = widget.leaderboardRepository;
    if (repository is! PagedLeaderboardRepository) return;
    final generation = _generation;
    setState(() {
      _loadingMore = true;
      _pageError = null;
    });
    try {
      final page = await (repository as PagedLeaderboardRepository)
          .loadPlayerRatingPage(
            season: _season,
            offset: _nextOffset!,
            pageSize: 20,
          );
      if (!mounted || generation != _generation) return;
      setState(() {
        final all = {for (final p in _players) p.profileId: p};
        for (final p in page.players) {
          all[p.profileId] = p;
        }
        _players = _validPlayers(all.values.toList());
        _neighbors = _validPlayers(page.aroundMe);
        _total = page.totalCount;
        _nextOffset = page.nextOffset;
        _visibleCount = desired;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(
        () => _pageError = userFacingError(
          error,
          fallback: 'Could not load more players. Try again.',
        ),
      );
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _openProfile(String id) async {
    if (id.trim().isEmpty) return;
    if (id == _profileId && widget.onOpenYou != null) {
      widget.onOpenYou!();
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: FieldrushAuthTheme.cream,
          body: ProfileScreen(
            profileRepository: _profiles,
            clanRepository: widget.clanRepository,
            fixtureRepository: widget.fixtureRepository,
            profileId: id,
          ),
        ),
      ),
    );
  }

  void _openSearch() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (searchContext) => HomeDiscoveryScreen(
          repository: _discovery,
          search: true,
          onPlayer: (id) async {
            if (id == _profileId && widget.onOpenYou != null) {
              Navigator.of(searchContext).pop();
              widget.onOpenYou!();
            } else {
              await _openProfile(id);
            }
          },
          onNotification: (_) async {},
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: FieldrushLeaderboardContent(
      season: _season,
      onSeason: (season) {
        setState(() => _season = season);
        _load();
      },
      players: _players,
      neighbors: _neighbors,
      currentRating: _rating,
      currentProfileId: _profileId,
      totalCount: _total,
      hasMore: _nextOffset != null,
      visibleCount: _visibleCount,
      loading: _loading,
      loadingMore: _loadingMore,
      error: _error,
      pageError: _pageError,
      clans: _clans,
      onBoard: (clans) => setState(() => _clans = clans),
      onPlayer: _openProfile,
      onSearch: _openSearch,
      onRefresh: _load,
      onMore: _more,
      onCollapse: () => setState(() => _visibleCount = 0),
    ),
  );
}
