import 'leaderboard.dart';

/// The authoritative season calendar and prize-qualification requirements.
/// Catalog entries may include future seasons managed by administrators.
class FieldrushSeasonCatalog {
  FieldrushSeasonCatalog({
    required List<LeaderboardSeason> seasons,
    required this.currentSeasonId,
    DateTime? today,
  }) : seasons = List.unmodifiable(
         [...seasons]..sort((a, b) => a.startsOn.compareTo(b.startsOn)),
       ),
       _today = today ?? _phoenixToday();

  final List<LeaderboardSeason> seasons;
  final String? currentSeasonId;
  final DateTime _today;

  /// Hidden and unpublished ladders are not selectable. A scheduled season
  /// must actually activate, even if its date arrived during a blocked rollover.
  /// Older catalogs without lifecycle flags retain their date-based behavior.
  List<LeaderboardSeason> get visibleSeasons {
    final day = _today.toIso8601String().substring(0, 10);
    return [
      for (final season in seasons)
        if (season.visibleToPlayers &&
            season.lifecycle != LeaderboardSeasonLifecycle.draft &&
            season.lifecycle != LeaderboardSeasonLifecycle.scheduled &&
            season.startsOn.compareTo(day) <= 0)
          season,
    ];
  }

  /// The server decides which season is current. During a deliberate gap in
  /// the calendar, show the most recently started season, not a made-up quarter.
  LeaderboardSeason get currentSeason {
    if (currentSeasonId != null) {
      final matches = seasons.where((season) => season.id == currentSeasonId);
      if (matches.isNotEmpty) {
        final current = matches.single;
        if (!visibleSeasons.any((season) => season.id == current.id)) {
          throw const FormatException(
            'Current season is not available to players.',
          );
        }
        return current;
      }
      throw const FormatException(
        'Current season is missing from the catalog.',
      );
    }
    final started = visibleSeasons;
    if (started.isEmpty) {
      throw StateError('There is no available leaderboard season yet.');
    }
    return started.last;
  }

  /// Retain a player's historical selection after refresh only while it is
  /// still visible. Fresh objects also pick up an admin's renamed label.
  LeaderboardSeason seasonForSelection(String? selectedSeasonId) =>
      visibleSeasons
          .where((season) => season.id == selectedSeasonId)
          .firstOrNull ??
      currentSeason;

  factory FieldrushSeasonCatalog.fromJson(
    Map<String, dynamic> json, {
    DateTime? today,
  }) => FieldrushSeasonCatalog(
    seasons: [
      for (final season in json['seasons'] as List<dynamic>? ?? const [])
        LeaderboardSeason.fromJson(Map<String, dynamic>.from(season as Map)),
    ],
    currentSeasonId: json['current_season_id'] as String?,
    // The server's Phoenix day keeps season selection correct even when a
    // device clock is wrong or the device is in a different timezone.
    today: json['today'] is String
        ? DateTime.parse(json['today'] as String)
        : today,
  );
}

abstract interface class SeasonLeaderboardRepository {
  Future<FieldrushSeasonCatalog> loadSeasons();
}

/// Older repository fakes keep their historical calendar. A live repository
/// implementing the catalog must never silently fall back after an RPC failure.
Future<LeaderboardSeason> loadActiveLeaderboardSeason(Object repository) async {
  if (repository is SeasonLeaderboardRepository) {
    return (await repository.loadSeasons()).currentSeason;
  }
  return activeLeaderboardSeason;
}

DateTime _phoenixToday() {
  final now = DateTime.now().toUtc().subtract(const Duration(hours: 7));
  return DateTime.utc(now.year, now.month, now.day);
}
