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
import 'fieldrush_rating_tracks.dart';
import 'fieldrush_placement.dart';
import 'fieldrush_season_rewards.dart';
import 'fieldrush_seasons.dart';
import '../markets/fieldrush_city.dart';
import '../markets/fieldrush_city_repository.dart';

class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({
    super.key,
    required this.clanRepository,
    required this.fixtureRepository,
    required this.leaderboardRepository,
    this.profileRepository,
    this.discoveryRepository,
    this.cityRepository,
    this.ratingTrackController,
    this.onOpenYou,
    this.onFindGame,
    this.activationTick = 0,
    this.playerActivationTick = 0,
  });

  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;
  final LeaderboardRepository leaderboardRepository;
  final ProfileRepository? profileRepository;
  final HomeDiscoveryRepository? discoveryRepository;
  final FieldrushCityRepository? cityRepository;
  final ValueNotifier<RatingTrack>? ratingTrackController;
  final VoidCallback? onOpenYou;
  final VoidCallback? onFindGame;
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
  List<LeaderboardSeason>? _seasons;
  bool _useCurrentSeason = true;
  FieldrushSeasonRewards? _rewards;
  String? _rewardsError;
  List<PlayerRatingLeaderboardEntry> _players = const [];
  List<PlayerRatingLeaderboardEntry> _neighbors = const [];
  List<FieldrushPlacementPlayer> _placements = const [];
  int _placementTotal = 0;
  int? _placementNextOffset;
  bool _allPlacements = false;
  bool _loadingPlacements = false;
  String? _placementError;
  PlayerRatingLeaderboardEntry? _rating;
  FieldrushPlayerRatings? _ratings;
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
  RatingTrack _track = RatingTrack.outfield;
  String? _cityId = 'phoenix';
  bool _scopeChosen = false;
  List<FieldrushCity> _cities = const [FieldrushCity.phoenix];

  @override
  void initState() {
    super.initState();
    _track = widget.ratingTrackController?.value ?? RatingTrack.outfield;
    widget.ratingTrackController?.addListener(_syncRatingTrack);
    _load();
  }

  @override
  void didUpdateWidget(covariant LeaderboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ratingTrackController != widget.ratingTrackController) {
      oldWidget.ratingTrackController?.removeListener(_syncRatingTrack);
      widget.ratingTrackController?.addListener(_syncRatingTrack);
      _syncRatingTrack();
    }
    final players =
        oldWidget.playerActivationTick != widget.playerActivationTick;
    if (players || oldWidget.activationTick != widget.activationTick) {
      if (players) _clans = false;
      _useCurrentSeason = players;
      // Each visit starts in the player's city. Manual browsing remains intact
      // while changing roles/seasons or refreshing within the Ranks screen.
      _scopeChosen = false;
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
    final track = widget.ratingTrackController?.value ?? RatingTrack.outfield;
    if (_track == track) return;
    _track = track;
    _clans = false;
    _load();
  }

  void _chooseRatingTrack(RatingTrack track) {
    if (widget.ratingTrackController != null) {
      widget.ratingTrackController!.value = track;
    } else {
      _track = track;
      _clans = false;
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
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _pageError = null;
      _visibleCount = 0;
      _allPlacements = false;
      _placements = const [];
      _placementTotal = 0;
      _placementNextOffset = null;
      _placementError = null;
      _loadingPlacements = false;
      _rewards = null;
      _rewardsError = null;
      _ratings = null;
    });
    try {
      final repository = widget.leaderboardRepository;
      if (repository is SeasonLeaderboardRepository) {
        final catalog = await (repository as SeasonLeaderboardRepository)
            .loadSeasons();
        if (!mounted || generation != _generation) return;
        _seasons = catalog.visibleSeasons;
        final current = catalog.currentSeason;
        _season = _useCurrentSeason || _lastActiveSeasonId != current.id
            ? current
            : catalog.seasonForSelection(_season.id);
        _lastActiveSeasonId = current.id;
      } else if (_useCurrentSeason ||
          _lastActiveSeasonId != activeLeaderboardSeason.id) {
        _season = activeLeaderboardSeason;
        _lastActiveSeasonId = _season.id;
      }
      _useCurrentSeason = false;
      final season = _season;
      if (_track == RatingTrack.goalkeeper &&
          repository is! TrackLeaderboardRepository) {
        throw StateError('Keeper rankings are unavailable. Try again.');
      }
      FieldrushPlayerRatings? ratings;
      if (repository is TrackLeaderboardRepository) {
        final initial = await Future.wait<Object>([
          (repository as TrackLeaderboardRepository).loadPlayerRatings(
            season: season,
          ),
          (widget.cityRepository ?? SupabaseFieldrushCityRepository())
              .listCities(),
        ]);
        if (!mounted || generation != _generation) return;
        ratings = initial[0] as FieldrushPlayerRatings;
        _cities = initial[1] as List<FieldrushCity>;
        if (!_scopeChosen) {
          _cityId =
              ratings.primaryCityId ?? ratings.preferredCityId ?? 'phoenix';
          _scopeChosen = true;
        }
      }
      FieldrushSeasonRewards? rewards;
      String? rewardsError;
      final rewardsFuture = () async {
        if (repository is! SeasonRewardsRepository || _cityId == null) return;
        try {
          rewards = await (repository as SeasonRewardsRepository)
              .loadSeasonRewards(
                season: season,
                track: _track,
                cityId: _cityId!,
              );
        } catch (error) {
          rewardsError = userFacingError(
            error,
            fallback: 'Could not load season rewards. Pull down to try again.',
          );
        }
      }();
      final results = await Future.wait<Object?>([
        repository is TrackLeaderboardRepository
            ? (repository as TrackLeaderboardRepository).loadRatingPage(
                season: season,
                track: _track,
                cityId: _cityId,
              )
            : repository is PagedLeaderboardRepository
            ? (repository as PagedLeaderboardRepository).loadPlayerRatingPage(
                season: season,
                region: _cityId ?? 'global',
              )
            : repository.loadPlayerRatingLeaderboard(
                season: season,
                region: _cityId ?? 'global',
              ),
        ratings != null
            ? Future.value(ratings.forScope(_track, _cityId))
            : _optional(() => repository.loadCurrentPlayerRating(season)),
        _optional(_profiles.getCurrentProfile),
        rewardsFuture,
      ]);
      if (!mounted || generation != _generation) return;
      final page = results[0] is PlayerRatingLeaderboardPage
          ? results[0] as PlayerRatingLeaderboardPage
          : null;
      final players =
          page?.players ?? results[0] as List<PlayerRatingLeaderboardEntry>;
      final profile = results[2] as PlayerProfile?;
      FieldrushPlacementPage? placementPage;
      String? placementError;
      if ((page?.totalCount ?? players.length) < 3 &&
          repository is PlacementLeaderboardRepository) {
        try {
          placementPage = await (repository as PlacementLeaderboardRepository)
              .loadPlacementPage(
                season: season,
                track: _track,
                cityId: _cityId,
              );
        } catch (error) {
          placementError = userFacingError(
            error,
            fallback: 'Could not load placement players. Try again.',
          );
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _players = _validPlayers(players);
        _neighbors = _validPlayers(page?.aroundMe ?? const []);
        _total = page?.totalCount;
        _nextOffset = page?.nextOffset;
        _rating = results[1] as PlayerRatingLeaderboardEntry?;
        _ratings = ratings;
        // Current-season data must never fall back to lifetime profile totals.
        _profileId = _rating?.profileId ?? profile?.id;
        _placements = placementPage?.players ?? const [];
        _placementTotal = placementPage?.totalCount ?? 0;
        _placementNextOffset = placementPage?.nextOffset;
        _placementError = placementError;
        _rewards = rewards;
        _rewardsError = rewardsError;
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
            (p) =>
                p.isRanked &&
                (_cityId == null || p.region.trim().toLowerCase() == _cityId),
          )
          .toList()
        ..sort((a, b) => a.rank.compareTo(b.rank));

  Future<void> _more() async {
    if (_loadingMore) return;
    final desired = _visibleCount + 20;
    final excluded =
        _rewards?.players
            .where((r) => _players.any((p) => p.profileId == r.profileId))
            .length ??
        3;
    final remaining = _players.length - excluded;
    if (desired <= remaining || _nextOffset == null) {
      setState(() => _visibleCount = desired);
      return;
    }
    final repository = widget.leaderboardRepository;
    if (repository is! PagedLeaderboardRepository &&
        repository is! TrackLeaderboardRepository) {
      return;
    }
    final generation = _generation;
    setState(() {
      _loadingMore = true;
      _pageError = null;
    });
    try {
      final page = repository is TrackLeaderboardRepository
          ? await (repository as TrackLeaderboardRepository).loadRatingPage(
              season: _season,
              track: _track,
              cityId: _cityId,
              offset: _nextOffset!,
              pageSize: 20,
            )
          : await (repository as PagedLeaderboardRepository)
                .loadPlayerRatingPage(
                  season: _season,
                  region: _cityId ?? 'global',
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
    setState(() {
      _players = [];
      _neighbors = [];
      _placements = [];
      _loading = true;
      _generation++;
    });
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
    if (mounted) await _load();
  }

  Future<void> _togglePlacements({bool more = false}) async {
    if (_loadingPlacements) return;
    if (_allPlacements && !more) {
      setState(() => _allPlacements = false);
      return;
    }
    if (_placementNextOffset == null) {
      setState(() => _allPlacements = true);
      return;
    }
    final repository = widget.leaderboardRepository;
    if (repository is! PlacementLeaderboardRepository) return;
    final generation = _generation;
    final track = _track;
    final city = _cityId;
    setState(() {
      _loadingPlacements = true;
      _placementError = null;
    });
    try {
      final page = await (repository as PlacementLeaderboardRepository)
          .loadPlacementPage(
            season: _season,
            track: track,
            cityId: city,
            offset: _placementNextOffset!,
            pageSize: 20,
          );
      if (!mounted || generation != _generation) return;
      setState(() {
        _placements = {
          for (final player in _placements) player.profileId: player,
          for (final player in page.players) player.profileId: player,
        }.values.toList();
        _placementTotal = page.totalCount;
        _placementNextOffset = page.nextOffset;
        _allPlacements = true;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(
        () => _placementError = userFacingError(
          error,
          fallback: 'Could not load more placement players. Try again.',
        ),
      );
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingPlacements = false);
      }
    }
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
      seasons: _seasons,
      rewards: _rewards,
      rewardsError: _rewardsError,
      onSeason: (season) {
        setState(() {
          _season = season;
          _useCurrentSeason = false;
        });
        _load();
      },
      players: _players,
      placementPlayers: _placements,
      placementTotal: _placementTotal,
      placementHasMore: _placementNextOffset != null,
      allPlacements: _allPlacements,
      loadingPlacements: _loadingPlacements,
      placementError: _placementError,
      onTogglePlacements: _togglePlacements,
      onMorePlacements: () => _togglePlacements(more: true),
      onRetryPlacements: _load,
      onFindGame: widget.onFindGame,
      neighbors: _neighbors,
      currentRating: _rating,
      ratings: _ratings,
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
      track: _track,
      onTrack: _chooseRatingTrack,
      cityId: _cityId,
      cities: _cities,
      onCity: (city) {
        setState(() {
          _cityId = city;
          _scopeChosen = true;
        });
        _load();
      },
      onPlayer: _openProfile,
      onSearch: _openSearch,
      onRefresh: _load,
      onMore: _more,
      onCollapse: () => setState(() => _visibleCount = 0),
    ),
  );
}
