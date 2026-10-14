import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../fixtures/fixture.dart';
import '../ranking/rating_division.dart';

enum OpenQueueRole { goalkeeper, defender, midfielder, attacker }

/// Midfielder is retained in the enum for legacy 6v6 match history only.
const fieldrushOpenQueueRoles = [
  OpenQueueRole.goalkeeper,
  OpenQueueRole.defender,
  OpenQueueRole.attacker,
];

bool _timezonesInitialized = false;

/// Returns wall-clock components in the game's IANA zone. The UTC-shaped
/// value is for display/calendar grouping, not for comparing actual instants.
DateTime gameLocalDateTime(DateTime instant, String timezone) {
  if (!_timezonesInitialized) {
    tz_data.initializeTimeZones();
    _timezonesInitialized = true;
  }
  final local = tz.TZDateTime.from(instant, tz.getLocation(timezone));
  return DateTime.utc(
    local.year,
    local.month,
    local.day,
    local.hour,
    local.minute,
    local.second,
    local.millisecond,
    local.microsecond,
  );
}

class OpenQueueBookingCostPreview {
  const OpenQueueBookingCostPreview({
    required this.currency,
    required this.standardMatchFeeFils,
    required this.replacementDiscountBps,
    required this.discountAmountFils,
    required this.matchFeeFils,
    required this.reliabilityDepositRequired,
    required this.reliabilityDepositBps,
    required this.reliabilityDepositFils,
    required this.totalFils,
    this.policyVersionId,
    this.replacementOfferExpiresAt,
  });

  final String currency;
  final int standardMatchFeeFils;
  final int replacementDiscountBps;
  final int discountAmountFils;
  final int matchFeeFils;
  final bool reliabilityDepositRequired;
  final int reliabilityDepositBps;
  final int reliabilityDepositFils;
  final int totalFils;
  final String? policyVersionId;
  final DateTime? replacementOfferExpiresAt;

  String get standardMatchFeeLabel =>
      _moneyLabel(standardMatchFeeFils, currency);
  String get matchFeeLabel => _moneyLabel(matchFeeFils, currency);
  String get discountLabel => _moneyLabel(discountAmountFils, currency);
  String get depositLabel => _moneyLabel(reliabilityDepositFils, currency);
  String get totalLabel => _moneyLabel(totalFils, currency);
  int get discountPercent => (replacementDiscountBps / 100).round();
  int get depositPercent => (reliabilityDepositBps / 100).round();

  bool hasSameCheckoutTermsAs(OpenQueueBookingCostPreview other) {
    return currency == other.currency &&
        standardMatchFeeFils == other.standardMatchFeeFils &&
        replacementDiscountBps == other.replacementDiscountBps &&
        discountAmountFils == other.discountAmountFils &&
        matchFeeFils == other.matchFeeFils &&
        reliabilityDepositRequired == other.reliabilityDepositRequired &&
        reliabilityDepositBps == other.reliabilityDepositBps &&
        reliabilityDepositFils == other.reliabilityDepositFils &&
        totalFils == other.totalFils &&
        policyVersionId == other.policyVersionId;
  }

  factory OpenQueueBookingCostPreview.fromJson(Map<String, dynamic> json) {
    return OpenQueueBookingCostPreview(
      currency: (json['currency'] as String? ?? 'BHD').trim(),
      standardMatchFeeFils: _asInt(json['standard_match_fee_fils']),
      replacementDiscountBps: _asInt(json['replacement_discount_bps']),
      discountAmountFils: _asInt(json['discount_amount_fils']),
      matchFeeFils: _asInt(json['match_fee_fils']),
      reliabilityDepositRequired:
          json['reliability_deposit_required'] as bool? ?? false,
      reliabilityDepositBps: _asInt(json['reliability_deposit_bps']),
      reliabilityDepositFils: _asInt(json['reliability_deposit_fils']),
      totalFils: _asInt(json['total_fils']),
      policyVersionId: _nonEmptyString(json['policy_version_id']),
      replacementOfferExpiresAt: _asDate(json['replacement_offer_expires_at']),
    );
  }
}

String _moneyLabel(int fils, String currency) {
  if (currency == 'USD') {
    return '\$${(fils / 1000).toStringAsFixed(fils % 10 == 0 ? 2 : 3)}';
  }
  final dinars = fils / 1000;
  final amount = dinars == dinars.roundToDouble()
      ? dinars.toInt().toString()
      : dinars.toStringAsFixed(3);
  return '$amount $currency';
}

extension OpenQueueRoleX on OpenQueueRole {
  String get code => switch (this) {
    OpenQueueRole.goalkeeper => 'GK',
    OpenQueueRole.defender => 'DEF',
    OpenQueueRole.midfielder => 'MID',
    OpenQueueRole.attacker => 'ATT',
  };

  String get label => switch (this) {
    OpenQueueRole.goalkeeper => 'Goalkeeper',
    OpenQueueRole.defender => 'Defender',
    OpenQueueRole.midfielder => 'Midfielder',
    OpenQueueRole.attacker => 'Attacker',
  };

  /// Compatibility formation for 7v7 games returned by older servers.
  /// Active game capacities must come from [OpenQueueGame.capacityFor].
  int get matchCapacity => switch (this) {
    OpenQueueRole.goalkeeper => 2,
    OpenQueueRole.defender || OpenQueueRole.attacker => 6,
    OpenQueueRole.midfielder => 0,
  };

  int get legacyMatchCapacity => switch (this) {
    OpenQueueRole.goalkeeper || OpenQueueRole.attacker => 2,
    OpenQueueRole.defender || OpenQueueRole.midfielder => 4,
  };

  static OpenQueueRole fromCode(String value) {
    return switch (value.toUpperCase()) {
      'GK' => OpenQueueRole.goalkeeper,
      'DEF' => OpenQueueRole.defender,
      'MID' => OpenQueueRole.midfielder,
      'ATT' => OpenQueueRole.attacker,
      _ => OpenQueueRole.midfielder,
    };
  }
}

class OpenQueueGame {
  const OpenQueueGame({
    required this.id,
    required this.status,
    required this.venue,
    required this.startsAt,
    required this.endsAt,
    required this.timezone,
    required this.priceFils,
    required this.ageLabel,
    required this.capacity,
    required this.confirmedCount,
    required this.spots,
    this.goalkeeperCapacity,
    this.defenderCapacity,
    this.midfielderCapacity,
    this.attackerCapacity,
    this.currency = 'BHD',
    this.highestDivision = 1,
    this.lowestDivision = 5,
    this.fieldId,
    this.marketCityId,
    this.locationAddress,
    this.locationCity,
    this.locationState,
    this.locationCountryCode,
    this.locationLatitude,
    this.locationLongitude,
    this.whiteScore,
    this.blackScore,
    this.myBookingId,
    this.myBookingRole,
    this.myBookingTeam,
    this.whiteAverageSr,
    this.blackAverageSr,
    this.matchAverageSr,
    this.teamSrSpread,
    this.teamsAssignedAt,
    this.policyVersionId,
    this.teamAssignmentAt,
    this.partyLockAt,
    this.teamAssignmentLeadMinutes,
    this.partyLockLeadMinutes,
    this.maxPartySize,
    this.operationalState = MatchOperationalState.normal,
    this.operationalStateUpdatedAt,
    this.operationalReasonCode,
  });

  final String id;
  final String status;
  final String venue;
  final DateTime startsAt;
  final DateTime endsAt;
  final String timezone;
  final int priceFils;
  final String ageLabel;
  final int capacity;
  final int confirmedCount;
  final Map<OpenQueueRole, int> spots;

  /// Saved whole-match position capacities. Older payloads may omit them.
  final int? goalkeeperCapacity;
  final int? defenderCapacity;
  final int? midfielderCapacity;
  final int? attackerCapacity;
  final String currency;
  final int highestDivision;
  final int lowestDivision;

  bool get acceptsPlacementPlayers =>
      highestDivision == 1 && lowestDivision == 5;

  String get divisionRangeLabel => highestDivision == lowestDivision
      ? 'DIV $highestDivision'
      : 'DIV $highestDivision–$lowestDivision';

  List<int> get allowedDivisions => [
    for (var division = highestDivision; division <= lowestDivision; division++)
      division,
  ];

  bool allowsPlayerDivision({
    required int skillRating,
    required int matchesPlayed,
  }) {
    if (matchesPlayed < 2) return acceptsPlacementPlayers;
    final division = divisionFromRating(skillRating).number;
    return division >= highestDivision && division <= lowestDivision;
  }

  final String? fieldId;
  final String? marketCityId;

  bool belongsToCity(String cityId, String cityTimezone) => marketCityId != null
      ? marketCityId == cityId
      : cityId == 'phoenix' && timezone == cityTimezone;
  final String? locationAddress;
  final String? locationCity;
  final String? locationState;
  final String? locationCountryCode;
  final double? locationLatitude;
  final double? locationLongitude;
  final int? whiteScore;
  final int? blackScore;
  final String? myBookingId;
  final OpenQueueRole? myBookingRole;
  final String? myBookingTeam;
  final int? whiteAverageSr;
  final int? blackAverageSr;
  final int? matchAverageSr;
  final int? teamSrSpread;
  final DateTime? teamsAssignedAt;
  final String? policyVersionId;
  final DateTime? teamAssignmentAt;
  final DateTime? partyLockAt;
  final int? teamAssignmentLeadMinutes;
  final int? partyLockLeadMinutes;
  final int? maxPartySize;
  final MatchOperationalState operationalState;
  final DateTime? operationalStateUpdatedAt;
  final String? operationalReasonCode;

  String? get locationLabel {
    final parts = [
      for (final part in [
        locationAddress,
        locationCity,
        locationState,
        locationCountryCode,
      ])
        if (part?.trim().isNotEmpty == true) part!.trim(),
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// New games use the saved pitch coordinates, never a guessed map pin.
  /// Historic venue-only games retain their original text-search fallback.
  Uri? get directionsUri {
    final latitude = locationLatitude;
    final longitude = locationLongitude;
    final hasCoordinates =
        latitude != null &&
        longitude != null &&
        latitude.isFinite &&
        longitude.isFinite &&
        latitude.abs() <= 90 &&
        longitude.abs() <= 180;
    final String query;
    if (hasCoordinates) {
      query = '$latitude,$longitude';
    } else if (locationLabel case final String address) {
      query = address;
    } else {
      if (venue.trim().isEmpty) return null;
      final market = switch (timezone) {
        'America/Phoenix' => 'Phoenix AZ',
        'Asia/Bahrain' => 'Bahrain',
        _ => '',
      };
      query = '${venue.trim()} $market'.trim();
    }
    return Uri.https('www.google.com', '/maps/search/', {
      'api': '1',
      'query': query,
    });
  }

  bool get isFull => status == 'FULL' || confirmedCount >= capacity;

  bool get hasRecordedScore => whiteScore != null || blackScore != null;

  bool get hasPendingOperationalResolution =>
      operationalState.isPendingResolution;

  String? get operationalStatusLabel => operationalState.pendingLabel;

  String? get operationalStatusDetail {
    if (!hasPendingOperationalResolution) return null;
    return switch (operationalReasonCode?.trim().toUpperCase()) {
      'RESULT_MISSING' => 'Result missing',
      'REFEREE_REPORT_MISSING' => 'Referee report missing',
      'DISPUTED' => 'Resolution disputed',
      'REFUND_FAILED' => 'Refund needs attention',
      'NO_ACTIVITY' => 'Match data missing',
      _ =>
        operationalState == MatchOperationalState.underReview
            ? 'Admin review in progress'
            : 'Match data missing',
    };
  }

  bool get shouldDisplayScore {
    final normalizedStatus = status.toUpperCase();
    return !hasPendingOperationalResolution &&
        (normalizedStatus == 'LIVE' ||
            normalizedStatus == 'FINAL' ||
            hasRecordedScore);
  }

  String get statusLabel {
    final operationalLabel = operationalStatusLabel;
    if (operationalLabel != null) return operationalLabel;
    return switch (status.toUpperCase()) {
      'OPEN' when isFull => 'Full',
      'OPEN' => 'Spots available',
      'FULL' => 'Full',
      'LIVE' => 'Live Now',
      'FINAL' => 'Final',
      'CANCELLED' => 'Cancelled',
      _ => 'Scheduled',
    };
  }

  bool get isUpcomingReservation => isUpcomingReservationAt(DateTime.now());

  bool isUpcomingReservationAt(DateTime now) {
    return (status == 'OPEN' || status == 'FULL') &&
        !hasRecordedScore &&
        startsAt.isAfter(now);
  }

  bool get isUpcomingMatchConfirmed {
    return status == 'FULL' && confirmedCount >= capacity && !hasRecordedScore;
  }

  bool get isTeamAssignmentDue => isTeamAssignmentDueAt(DateTime.now());

  bool isTeamAssignmentDueAt(DateTime now) {
    final cutoff = teamAssignmentAt;
    if (cutoff == null) return teamsAssignedAt != null;
    return !now.isBefore(cutoff);
  }

  String get teamAssignmentLeadLabel =>
      openQueueLeadTimeLabel(teamAssignmentLeadMinutes);

  String get partyLockLeadLabel => openQueueLeadTimeLabel(partyLockLeadMinutes);

  bool get hasActiveTeamAssignment {
    return isUpcomingMatchConfirmed &&
        isTeamAssignmentDue &&
        teamsAssignedAt != null &&
        whiteAverageSr != null &&
        blackAverageSr != null &&
        matchAverageSr != null;
  }

  bool get hasMyBooking => myBookingId != null;

  // Both formats are constrained server-side. Capacity is included in all
  // existing feed/booking contracts, including older deployed RPC versions.
  bool get isFieldrushFormat => capacity == 14;

  List<OpenQueueRole> get supportedRoles =>
      isFieldrushFormat ? fieldrushOpenQueueRoles : OpenQueueRole.values;

  int capacityFor(OpenQueueRole role) {
    final saved = switch (role) {
      OpenQueueRole.goalkeeper => goalkeeperCapacity,
      OpenQueueRole.defender => defenderCapacity,
      OpenQueueRole.midfielder => midfielderCapacity,
      OpenQueueRole.attacker => attackerCapacity,
    };
    return saved ??
        (isFieldrushFormat ? role.matchCapacity : role.legacyMatchCapacity);
  }

  int spotsFor(OpenQueueRole role) => spots[role] ?? 0;

  bool canBook(OpenQueueRole role) => canBookAt(role, DateTime.now());

  bool canBookAt(OpenQueueRole role, DateTime now) =>
      status == 'OPEN' &&
      startsAt.isAfter(now) &&
      !hasMyBooking &&
      !hasRecordedScore &&
      !hasPendingOperationalResolution &&
      !isFull &&
      capacityFor(role) > 0 &&
      spotsFor(role) > 0;

  /// Wall-clock values use the game's immutable IANA timezone snapshot.
  DateTime localDateTime(DateTime instant) =>
      gameLocalDateTime(instant, timezone);

  DateTime get localStartsAt => localDateTime(startsAt);
  DateTime get localEndsAt => localDateTime(endsAt);

  // Compatibility aliases for existing fixture screens. The game, not the
  // device or a hardcoded market, now determines the displayed wall clock.
  DateTime get bahrainStartsAt => localStartsAt;

  DateTime get bahrainEndsAt => localEndsAt;

  bool get isToday {
    final value = bahrainStartsAt;
    final now = localDateTime(DateTime.now());
    return value.year == now.year &&
        value.month == now.month &&
        value.day == now.day;
  }

  bool get isTomorrow {
    final value = bahrainStartsAt;
    final now = localDateTime(DateTime.now());
    final tomorrow = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 1));
    return value.year == tomorrow.year &&
        value.month == tomorrow.month &&
        value.day == tomorrow.day;
  }

  String get calendarDateLabel {
    final value = bahrainStartsAt;
    return '${_weekday(value.weekday)}, ${value.day} ${_month(value.month)}';
  }

  String get prominentDateLabel {
    if (isToday) return 'TODAY · $calendarDateLabel';
    if (isTomorrow) return 'TOMORROW · $calendarDateLabel';
    return calendarDateLabel;
  }

  String get dateGroup {
    if (isToday) return 'TODAY';
    if (isTomorrow) return 'TOMORROW';
    return calendarDateLabel;
  }

  String get timeLabel => '${_clock(bahrainStartsAt)}–${_clock(bahrainEndsAt)}';

  String get startTimeLabel => _clock(bahrainStartsAt);

  String get priceLabel {
    return _moneyLabel(priceFils, currency);
  }

  factory OpenQueueGame.fromJson(Map<String, dynamic> json) {
    return OpenQueueGame(
      id: json['id'] as String? ?? '',
      status: (json['status'] as String? ?? 'OPEN').toUpperCase(),
      venue: (json['venue'] as String? ?? '').trim(),
      startsAt: DateTime.parse(json['starts_at'] as String).toLocal(),
      endsAt: DateTime.parse(json['ends_at'] as String).toLocal(),
      timezone: json['timezone'] as String? ?? 'Asia/Bahrain',
      priceFils: _asInt(json['price_fils'], fallback: 3000),
      currency: json['currency'] as String? ?? 'BHD',
      highestDivision: _asInt(json['highest_division'], fallback: 1),
      lowestDivision: _asInt(json['lowest_division'], fallback: 5),
      fieldId: _nonEmptyString(json['field_id']),
      marketCityId: _nonEmptyString(json['market_city_id']),
      locationAddress: _nonEmptyString(json['location_address']),
      locationCity: _nonEmptyString(json['location_city']),
      locationState: _nonEmptyString(json['location_state']),
      locationCountryCode: _nonEmptyString(json['location_country_code']),
      locationLatitude: _asNullableDouble(json['location_latitude']),
      locationLongitude: _asNullableDouble(json['location_longitude']),
      ageLabel: json['age_label'] as String? ?? 'All ages',
      capacity: _asInt(json['capacity'], fallback: 12),
      confirmedCount: _asInt(json['confirmed_count']),
      goalkeeperCapacity: _asNullableInt(json['goalkeeper_capacity']),
      defenderCapacity: _asNullableInt(json['defender_capacity']),
      midfielderCapacity: _asNullableInt(json['midfielder_capacity']),
      attackerCapacity: _asNullableInt(json['attacker_capacity']),
      spots: {
        OpenQueueRole.goalkeeper: _asInt(json['goalkeeper_spots']),
        OpenQueueRole.defender: _asInt(json['defender_spots']),
        OpenQueueRole.midfielder: _asInt(json['midfielder_spots']),
        OpenQueueRole.attacker: _asInt(json['attacker_spots']),
      },
      whiteScore: _asNullableInt(json['white_score']),
      blackScore: _asNullableInt(json['black_score']),
      myBookingId: json['my_booking_id'] as String?,
      myBookingRole: switch (json['my_booking_role']) {
        final String role => OpenQueueRoleX.fromCode(role),
        _ => null,
      },
      myBookingTeam: json['my_booking_team'] as String?,
      whiteAverageSr: _asNullableRoundedInt(json['white_average_sr']),
      blackAverageSr: _asNullableRoundedInt(json['black_average_sr']),
      matchAverageSr: _asNullableRoundedInt(json['match_average_sr']),
      teamSrSpread: _asNullableRoundedInt(json['team_sr_spread']),
      teamsAssignedAt: _asDate(json['teams_assigned_at']),
      policyVersionId: _nonEmptyString(json['policy_version_id']),
      teamAssignmentAt: _asDate(json['team_assignment_at']),
      partyLockAt: _asDate(json['party_lock_at']),
      teamAssignmentLeadMinutes: _asNullableInt(
        json['team_assignment_lead_minutes'],
      ),
      partyLockLeadMinutes: _asNullableInt(json['party_lock_lead_minutes']),
      maxPartySize: _asNullableInt(json['max_party_size']),
      operationalState: MatchOperationalState.fromWire(
        json['operational_state'],
      ),
      operationalStateUpdatedAt: _asDate(json['operational_state_updated_at']),
      operationalReasonCode: _nonEmptyString(
        json['operational_reason_code'],
      )?.toUpperCase(),
    );
  }

  factory OpenQueueGame.fromBookingJson(Map<String, dynamic> json) {
    return OpenQueueGame(
      id: json['id'] as String? ?? '',
      status: (json['status'] as String? ?? 'OPEN').toUpperCase(),
      venue: (json['venue'] as String? ?? '').trim(),
      startsAt: DateTime.parse(json['starts_at'] as String).toLocal(),
      endsAt: DateTime.parse(json['ends_at'] as String).toLocal(),
      timezone: json['timezone'] as String? ?? 'Asia/Bahrain',
      priceFils: _asInt(json['price_fils'], fallback: 3000),
      currency: json['currency'] as String? ?? 'BHD',
      highestDivision: _asInt(json['highest_division'], fallback: 1),
      lowestDivision: _asInt(json['lowest_division'], fallback: 5),
      fieldId: _nonEmptyString(json['field_id']),
      marketCityId: _nonEmptyString(json['market_city_id']),
      locationAddress: _nonEmptyString(json['location_address']),
      locationCity: _nonEmptyString(json['location_city']),
      locationState: _nonEmptyString(json['location_state']),
      locationCountryCode: _nonEmptyString(json['location_country_code']),
      locationLatitude: _asNullableDouble(json['location_latitude']),
      locationLongitude: _asNullableDouble(json['location_longitude']),
      ageLabel: json['age_label'] as String? ?? 'All ages',
      capacity: _asInt(json['capacity'], fallback: 12),
      confirmedCount: _asInt(json['confirmed_count']),
      goalkeeperCapacity: _asNullableInt(json['goalkeeper_capacity']),
      defenderCapacity: _asNullableInt(json['defender_capacity']),
      midfielderCapacity: _asNullableInt(json['midfielder_capacity']),
      attackerCapacity: _asNullableInt(json['attacker_capacity']),
      spots: const {},
      whiteScore: _asNullableInt(json['white_score']),
      blackScore: _asNullableInt(json['black_score']),
      whiteAverageSr: _asNullableRoundedInt(json['white_average_sr']),
      blackAverageSr: _asNullableRoundedInt(json['black_average_sr']),
      matchAverageSr: _asNullableRoundedInt(json['match_average_sr']),
      teamSrSpread: _asNullableRoundedInt(json['team_sr_spread']),
      teamsAssignedAt: _asDate(json['teams_assigned_at']),
      policyVersionId: _nonEmptyString(json['policy_version_id']),
      teamAssignmentAt: _asDate(json['team_assignment_at']),
      partyLockAt: _asDate(json['party_lock_at']),
      teamAssignmentLeadMinutes: _asNullableInt(
        json['team_assignment_lead_minutes'],
      ),
      partyLockLeadMinutes: _asNullableInt(json['party_lock_lead_minutes']),
      maxPartySize: _asNullableInt(json['max_party_size']),
      operationalState: MatchOperationalState.fromWire(
        json['operational_state'],
      ),
      operationalStateUpdatedAt: _asDate(json['operational_state_updated_at']),
      operationalReasonCode: _nonEmptyString(
        json['operational_reason_code'],
      )?.toUpperCase(),
    );
  }
}

String openQueueLeadTimeLabel(int? minutes) {
  if (minutes == null) return 'before kickoff';
  if (minutes == 0) return 'at kickoff';
  if (minutes % 60 == 0) {
    final hours = minutes ~/ 60;
    return '$hours ${hours == 1 ? 'hour' : 'hours'} before kickoff';
  }
  if (minutes < 60) {
    return '$minutes ${minutes == 1 ? 'minute' : 'minutes'} before kickoff';
  }
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  return '$hours ${hours == 1 ? 'hour' : 'hours'} $remainder minutes before kickoff';
}

const openQueueWhiteTeamId = 'WHITE';
const openQueueBlackTeamId = 'BLACK';

class OpenQueueMatchDetail {
  const OpenQueueMatchDetail({
    required this.game,
    required this.scorers,
    required this.timeline,
    this.players = const [],
    this.clock,
    this.broadcast,
    this.videoUrl,
  });

  final OpenQueueGame game;
  final FixtureClock? clock;
  final FixtureBroadcast? broadcast;
  final List<FixtureScorer> scorers;
  final List<FixtureTimelineEvent> timeline;
  final List<OpenQueuePlayer> players;
  final String? videoUrl;

  factory OpenQueueMatchDetail.fromJson(Map<String, dynamic> json) {
    final gameJson = _mapFrom(json['game'] ?? json['open_queue_game']) ?? json;
    final game = OpenQueueGame.fromJson(gameJson);
    final clockJson =
        _mapFrom(
          json['clock'] ??
              json['open_queue_clock'] ??
              json['open_queue_game_clock_states'],
        ) ??
        _flatClockJson(json);
    final broadcastJson =
        _mapFrom(
          json['broadcast'] ??
              json['open_queue_broadcast'] ??
              json['open_queue_game_broadcasts'],
        ) ??
        _flatBroadcastJson(json);
    final timeline = _openQueueTimeline(
      json['events'] ??
          json['timeline'] ??
          json['open_queue_events'] ??
          json['open_queue_game_events'],
      game.id,
    );
    final scorerRows =
        json['scorers'] ??
        json['goals'] ??
        json['open_queue_scorers'] ??
        json['open_queue_game_scorers'];
    final scorers = _openQueueScorers(scorerRows, timeline, game.id);

    return OpenQueueMatchDetail(
      game: game,
      clock: clockJson == null ? null : FixtureClock.fromJson(clockJson),
      broadcast: broadcastJson == null
          ? null
          : FixtureBroadcast.fromJson(broadcastJson),
      scorers: scorers,
      timeline: timeline,
      players: _openQueuePlayers(json['players']),
      videoUrl: _nonEmptyString(json['video_url'] ?? gameJson['video_url']),
    );
  }

  FixturePlayerRatingUpdate? get viewerRatingUpdate {
    for (final player in players) {
      if (!player.isMe) continue;
      final ratingBefore = player.displayedRating;
      final ratingChange = player.ratingChange;
      if (ratingBefore == null || ratingChange == null) return null;
      return FixturePlayerRatingUpdate(
        ratingBefore: ratingBefore,
        ratingChange: ratingChange,
        ratingAfter: ratingBefore + ratingChange,
      );
    }
    return null;
  }

  Fixture toFixture() {
    final startsAt = game.bahrainStartsAt;
    return Fixture(
      id: game.id,
      status: _fixtureStatusForOpenQueue(game.status),
      homeClanId: openQueueWhiteTeamId,
      awayClanId: openQueueBlackTeamId,
      venue: game.venue,
      day: _openQueueWeekday(startsAt.weekday),
      timeSlot: game.timeLabel.replaceAll('–', ' - '),
      matchDate: DateTime(startsAt.year, startsAt.month, startsAt.day),
      createdBy: '',
      homeClan: _openQueueTeamClan(
        side: openQueueWhiteTeamId,
        averageRating: game.whiteAverageSr,
      ),
      awayClan: _openQueueTeamClan(
        side: openQueueBlackTeamId,
        averageRating: game.blackAverageSr,
      ),
      homeScore: game.whiteScore ?? _teamGoalCount(openQueueWhiteTeamId),
      awayScore: game.blackScore ?? _teamGoalCount(openQueueBlackTeamId),
      videoUrl: videoUrl,
      clock: clock,
      broadcast: broadcast,
      scorers: scorers,
      timeline: timeline,
      homeAveragePlayerRating: game.whiteAverageSr,
      awayAveragePlayerRating: game.blackAverageSr,
      matchAveragePlayerRating: game.matchAverageSr,
      teamRatingSpread: game.teamSrSpread,
      teamsAssignedAt: game.teamsAssignedAt,
      operationalState: game.operationalState,
      operationalStateUpdatedAt: game.operationalStateUpdatedAt,
      operationalReasonCode: game.operationalReasonCode,
      homeLineup: _fixtureLineup(openQueueWhiteTeamId),
      awayLineup: _fixtureLineup(openQueueBlackTeamId),
    );
  }

  int _teamGoalCount(String team) {
    return scorers.where((scorer) => scorer.clanId == team).length;
  }

  List<FixtureLineupPlayer> _fixtureLineup(String side) {
    final rows = players.where((player) => player.team == side).toList()
      ..sort((left, right) {
        final role = _roleOrder(left.role).compareTo(_roleOrder(right.role));
        if (role != 0) return role;
        return left.displayName.compareTo(right.displayName);
      });
    return [for (final player in rows) player.toFixtureLineupPlayer()];
  }
}

FixtureClan _openQueueTeamClan({
  required String side,
  required int? averageRating,
}) {
  final isWhite = side == openQueueWhiteTeamId;
  return FixtureClan(
    id: side,
    name: isWhite ? 'White Team' : 'Black Team',
    tag: side,
    emblem: isWhite ? '⚪' : '⚫',
    themeId: isWhite ? 'mint' : 'shadow',
    patternId: 'solid',
    skillRating: averageRating ?? 1200,
  );
}

class OpenQueuePlayer {
  const OpenQueuePlayer({
    required this.id,
    required this.displayName,
    required this.role,
    required this.team,
    required this.played,
    required this.isMe,
    this.username,
    this.avatarUrl,
    this.ratingAtTeamAssignment,
    this.ratingAtMatchStart,
    this.ratingChange,
  });

  final String id;
  final String displayName;
  final String? username;
  final String? avatarUrl;
  final OpenQueueRole role;
  final String team;
  final bool played;
  final bool isMe;
  final int? ratingAtTeamAssignment;
  final int? ratingAtMatchStart;
  final int? ratingChange;

  int? get displayedRating => ratingAtMatchStart ?? ratingAtTeamAssignment;

  factory OpenQueuePlayer.fromJson(Map<String, dynamic> json) {
    return OpenQueuePlayer(
      id: json['id'] as String? ?? '',
      displayName: (json['display_name'] as String? ?? 'Player').trim(),
      username: (json['username'] as String?)?.trim(),
      avatarUrl: (json['avatar_url'] as String?)?.trim(),
      role: OpenQueueRoleX.fromCode(json['role'] as String? ?? 'MID'),
      team: _openQueueTeam(json['team']) ?? '',
      played: json['played'] == true,
      isMe: json['is_me'] == true,
      ratingAtTeamAssignment: _asNullableInt(json['rating_at_team_assignment']),
      ratingAtMatchStart: _asNullableInt(json['rating_at_match_start']),
      ratingChange: _asNullableInt(json['rating_change']),
    );
  }

  FixtureLineupPlayer toFixtureLineupPlayer() {
    return FixtureLineupPlayer(
      id: id,
      displayName: displayName,
      username: username,
      avatarUrl: avatarUrl,
      role: role.code,
      side: team,
      played: played,
      isMe: isMe,
      ratingAtTeamAssignment: ratingAtTeamAssignment,
      ratingAtMatchStart: ratingAtMatchStart,
      ratingChange: ratingChange,
    );
  }
}

class OpenQueueBooking {
  const OpenQueueBooking({
    required this.id,
    required this.gameId,
    required this.profileId,
    required this.role,
    required this.status,
    required this.amountPaidFils,
    required this.bookedAt,
    required this.game,
    this.team,
    this.cancelledAt,
    this.refundPercent,
    this.refundAmountFils,
    this.refundDestination,
    this.refundStatus,
  });

  final String id;
  final String gameId;
  final String profileId;
  final OpenQueueRole role;
  final String status;
  final String? team;
  final int amountPaidFils;
  final DateTime bookedAt;
  final DateTime? cancelledAt;
  final int? refundPercent;
  final int? refundAmountFils;
  final String? refundDestination;
  final String? refundStatus;
  final OpenQueueGame game;

  String? get assignedTeam {
    if (!game.hasActiveTeamAssignment) return null;
    return switch (team?.trim().toUpperCase()) {
      openQueueWhiteTeamId => openQueueWhiteTeamId,
      openQueueBlackTeamId => openQueueBlackTeamId,
      _ => null,
    };
  }

  String? get kitInstruction {
    return switch (assignedTeam) {
      openQueueWhiteTeamId => 'WEAR WHITE',
      openQueueBlackTeamId => 'WEAR BLACK',
      _ => null,
    };
  }

  OpenQueueBooking copyWith({OpenQueueGame? game}) {
    return OpenQueueBooking(
      id: id,
      gameId: gameId,
      profileId: profileId,
      role: role,
      status: status,
      team: team,
      amountPaidFils: amountPaidFils,
      bookedAt: bookedAt,
      cancelledAt: cancelledAt,
      refundPercent: refundPercent,
      refundAmountFils: refundAmountFils,
      refundDestination: refundDestination,
      refundStatus: refundStatus,
      game: game ?? this.game,
    );
  }

  factory OpenQueueBooking.fromJson(Map<String, dynamic> json) {
    final rawGame = json['game'] ?? json['open_queue_games'];
    final gameJson = rawGame is List && rawGame.isNotEmpty
        ? Map<String, dynamic>.from(rawGame.first as Map)
        : Map<String, dynamic>.from(rawGame as Map);
    return OpenQueueBooking(
      id: json['id'] as String? ?? '',
      gameId: json['game_id'] as String? ?? '',
      profileId: json['profile_id'] as String? ?? '',
      role: OpenQueueRoleX.fromCode(json['role'] as String? ?? 'MID'),
      status: (json['status'] as String? ?? 'CONFIRMED').toUpperCase(),
      team: _openQueueTeam(json['team']),
      amountPaidFils: _asInt(json['amount_paid_fils']),
      bookedAt: DateTime.parse(json['booked_at'] as String).toLocal(),
      cancelledAt: _asDate(json['cancelled_at']),
      refundPercent: _asNullableInt(json['refund_percent']),
      refundAmountFils: _asNullableInt(json['refund_amount_fils']),
      refundDestination: _nonEmptyString(json['refund_destination']),
      refundStatus: _nonEmptyString(json['refund_status']),
      game: OpenQueueGame.fromBookingJson(gameJson),
    );
  }
}

class OpenQueueCancellationPreview {
  const OpenQueueCancellationPreview({
    required this.canCancel,
    required this.refundPercent,
    required this.refundAmountFils,
    required this.refundCutoffAt,
    this.serverNow,
    this.policyVersionId,
    this.outcomeCode,
    this.strikeDelta = 0,
    this.refundBps,
    this.refundDestination,
    this.depositForfeited = false,
    this.explanation,
    this.checkInDeadlineAt,
    this.noShowCutoffAt,
    this.currency = 'BHD',
  });

  final bool canCancel;
  final int refundPercent;
  final int refundAmountFils;
  final DateTime? refundCutoffAt;

  /// Server time used to classify this cancellation. The client never
  /// decides which policy window applies.
  final DateTime? serverNow;
  final String? policyVersionId;
  final String? outcomeCode;
  final int strikeDelta;
  final int? refundBps;
  final String? refundDestination;
  final bool depositForfeited;
  final String? explanation;
  final DateTime? checkInDeadlineAt;
  final DateTime? noShowCutoffAt;
  final String currency;

  int get effectiveRefundBps => refundBps ?? (refundPercent * 100);

  String get refundPercentLabel {
    final bps = effectiveRefundBps;
    if (bps % 100 == 0) return '${bps ~/ 100}%';
    return '${(bps / 100).toStringAsFixed(2)}%';
  }

  String get outcomeLabel => switch (outcomeCode?.toUpperCase()) {
    'CANCELLED_EARLY' || 'EARLY_CANCELLATION' => 'Early cancellation',
    'CANCELLED_LATE' || 'LATE_CANCELLATION' => 'Late cancellation',
    'CANCELLED_VERY_LATE' ||
    'VERY_LATE_CANCELLATION' => 'Very late cancellation',
    'NO_SHOW' => 'No-show',
    'FIELD_CANCELLED' ||
    'FIELD_CAUSED_CANCELLATION' => 'Field-caused cancellation',
    final String value when value.isNotEmpty =>
      value
          .toLowerCase()
          .split('_')
          .map(
            (word) => word.isEmpty
                ? word
                : '${word[0].toUpperCase()}${word.substring(1)}',
          )
          .join(' '),
    _ => 'Cancellation',
  };

  String get refundDestinationLabel {
    final destination = refundDestination?.trim().toUpperCase();
    if (effectiveRefundBps <= 0) return 'No refund';
    if (destination == null ||
        destination.isEmpty ||
        destination == 'FIELD_WALLET') {
      return '$refundPercentLabel to your Field wallet';
    }
    if (destination == 'ORIGINAL_PAYMENT_METHOD' || destination == 'STRIPE') {
      return '$refundPercentLabel to your original payment method';
    }
    return '$refundPercentLabel to ${destination.replaceAll('_', ' ').toLowerCase()}';
  }

  String get refundLabel {
    if (effectiveRefundBps == 0) return 'No refund';
    final destination = refundDestination?.trim().toUpperCase();
    final label =
        destination == 'ORIGINAL_PAYMENT_METHOD' || destination == 'STRIPE'
        ? 'your original payment method'
        : 'Field wallet';
    return '${_moneyLabel(refundAmountFils, currency)} to $label';
  }

  /// Older policy previews contain wallet wording even when the payment-aware
  /// quote routes the refund back to Stripe. Keep the server policy narrative
  /// intact except for that destination, and retain raw text for quote checks.
  String? get displayExplanation {
    final destination = refundDestination?.trim().toUpperCase();
    if (destination != 'ORIGINAL_PAYMENT_METHOD' && destination != 'STRIPE') {
      return explanation;
    }
    return explanation?.replaceAll(
      RegExp(r'\bto your field wallet\b', caseSensitive: false),
      'to your original payment method',
    );
  }

  bool hasSameConsequencesAs(OpenQueueCancellationPreview other) {
    return canCancel == other.canCancel &&
        currency == other.currency &&
        policyVersionId == other.policyVersionId &&
        outcomeCode == other.outcomeCode &&
        strikeDelta == other.strikeDelta &&
        effectiveRefundBps == other.effectiveRefundBps &&
        refundAmountFils == other.refundAmountFils &&
        refundDestination == other.refundDestination &&
        depositForfeited == other.depositForfeited &&
        explanation == other.explanation &&
        checkInDeadlineAt?.millisecondsSinceEpoch ==
            other.checkInDeadlineAt?.millisecondsSinceEpoch &&
        noShowCutoffAt?.millisecondsSinceEpoch ==
            other.noShowCutoffAt?.millisecondsSinceEpoch;
  }

  factory OpenQueueCancellationPreview.fromJson(Map<String, dynamic> json) {
    return OpenQueueCancellationPreview(
      canCancel: json['can_cancel'] == true,
      refundPercent: _asInt(json['refund_percent']),
      refundAmountFils: _asInt(json['refund_amount_fils']),
      currency: json['currency'] as String? ?? 'BHD',
      refundCutoffAt: _asDate(json['refund_cutoff_at']),
      serverNow: _asDate(json['server_now']),
      policyVersionId: _nonEmptyString(json['policy_version_id']),
      outcomeCode: _nonEmptyString(json['outcome_code']),
      strikeDelta: _asInt(json['strike_delta']),
      refundBps: _asNullableInt(json['refund_bps']),
      refundDestination: _nonEmptyString(json['refund_destination']),
      depositForfeited: json['deposit_forfeited'] == true,
      explanation: _nonEmptyString(json['explanation']),
      checkInDeadlineAt: _asDate(json['check_in_deadline_at']),
      noShowCutoffAt: _asDate(json['no_show_cutoff_at']),
    );
  }
}

int _asInt(Object? value, {int fallback = 0}) {
  return _asNullableInt(value) ?? fallback;
}

int? _asNullableInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

int? _asNullableRoundedInt(Object? value) {
  if (value is num) return value.round();
  if (value is String) return double.tryParse(value)?.round();
  return null;
}

DateTime? _asDate(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}

Map<String, dynamic>? _mapFrom(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is List && value.isNotEmpty) return _mapFrom(value.first);
  return null;
}

Map<String, dynamic>? _flatClockJson(Map<String, dynamic> json) {
  if (!json.containsKey('clock_status')) return null;
  return {
    'status': json['clock_status'],
    'started_at': json['clock_started_at'],
    'accumulated_seconds': json['clock_accumulated_seconds'],
    'duration_seconds': json['clock_duration_seconds'],
  };
}

Map<String, dynamic>? _flatBroadcastJson(Map<String, dynamic> json) {
  if (!json.containsKey('broadcast_status')) return null;
  return {
    'status': json['broadcast_status'],
    'live_input_id': json['live_input_id'],
    'active_video_id': json['active_video_id'],
    'hls_url': json['hls_url'],
    'replay_hls_url': json['replay_hls_url'],
    'stream_started_at': json['stream_started_at'],
    'stream_stopped_at': json['stream_stopped_at'],
    'recording_ready_at': json['recording_ready_at'],
    'error_message': json['broadcast_error_message'] ?? json['error_message'],
  };
}

List<OpenQueuePlayer> _openQueuePlayers(Object? value) {
  if (value is! List) return const [];
  return [
    for (final rawRow in value)
      if (_mapFrom(rawRow) case final row?) OpenQueuePlayer.fromJson(row),
  ];
}

int _roleOrder(OpenQueueRole role) {
  return switch (role) {
    OpenQueueRole.goalkeeper => 0,
    OpenQueueRole.defender => 1,
    OpenQueueRole.midfielder => 2,
    OpenQueueRole.attacker => 3,
  };
}

List<FixtureTimelineEvent> _openQueueTimeline(Object? value, String gameId) {
  if (value is! List) return const [];
  final events = <FixtureTimelineEvent>[];
  for (final rawRow in value) {
    final row = _mapFrom(rawRow);
    if (row == null) continue;
    final player = _mapFrom(row['player'] ?? row['scorer'] ?? row['profiles']);
    final assist = _mapFrom(row['assist']);
    events.add(
      FixtureTimelineEvent(
        id: row['id'] as String? ?? '',
        fixtureId:
            row['game_id'] as String? ?? row['fixture_id'] as String? ?? gameId,
        eventType: (row['event_type'] as String? ?? 'EVENT').toUpperCase(),
        clanId: _openQueueTeam(row['team'] ?? row['side'] ?? row['clan_id']),
        profileId: row['profile_id'] as String?,
        assistProfileId: row['assist_profile_id'] as String?,
        minute: _asInt(row['minute']),
        second: _asInt(row['second']),
        note: _nonEmptyString(row['note']),
        createdAt: _asDate(row['created_at']),
        occurredAt: _asDate(row['occurred_at']),
        player: player == null ? null : FixtureParticipant.fromJson(player),
        assist: assist == null ? null : FixtureParticipant.fromJson(assist),
      ),
    );
  }
  events.sort((left, right) {
    final minute = left.minute.compareTo(right.minute);
    return minute != 0 ? minute : left.second.compareTo(right.second);
  });
  return events;
}

List<FixtureScorer> _openQueueScorers(
  Object? value,
  List<FixtureTimelineEvent> timeline,
  String gameId,
) {
  if (value is List) {
    final scorers = <FixtureScorer>[];
    for (final rawRow in value) {
      final row = _mapFrom(rawRow);
      if (row == null) continue;
      final scorer = _mapFrom(
        row['scorer'] ?? row['player'] ?? row['profiles'],
      );
      final assist = _mapFrom(row['assist']);
      scorers.add(
        FixtureScorer(
          id: row['id'] as String? ?? '',
          fixtureId:
              row['game_id'] as String? ??
              row['fixture_id'] as String? ??
              gameId,
          clanId:
              _openQueueTeam(row['team'] ?? row['side'] ?? row['clan_id']) ??
              '',
          profileId: row['profile_id'] as String? ?? '',
          assistProfileId: row['assist_profile_id'] as String?,
          minute: _asInt(row['minute']),
          createdAt: _asDate(row['occurred_at'] ?? row['created_at']),
          scorer: scorer == null ? null : FixtureParticipant.fromJson(scorer),
          assist: assist == null ? null : FixtureParticipant.fromJson(assist),
        ),
      );
    }
    return scorers;
  }

  return [
    for (final event in timeline)
      if (event.eventType == 'GOAL' && event.clanId != null)
        FixtureScorer(
          id: event.id,
          fixtureId: gameId,
          clanId: event.clanId!,
          profileId: event.profileId ?? '',
          assistProfileId: event.assistProfileId,
          minute: event.minute,
          createdAt: event.highlightTimestamp,
          scorer: event.player,
          assist: event.assist,
        ),
  ];
}

String? _openQueueTeam(Object? value) {
  final team = value?.toString().trim().toUpperCase();
  if (team == openQueueWhiteTeamId || team == 'HOME') {
    return openQueueWhiteTeamId;
  }
  if (team == openQueueBlackTeamId || team == 'AWAY') {
    return openQueueBlackTeamId;
  }
  return team == null || team.isEmpty ? null : team;
}

FixtureStatus _fixtureStatusForOpenQueue(String value) {
  return switch (value.toUpperCase()) {
    'OPEN' => FixtureStatus.open,
    'LIVE' => FixtureStatus.live,
    'FINAL' => FixtureStatus.finalResult,
    'CANCELLED' => FixtureStatus.cancelled,
    _ => FixtureStatus.scheduled,
  };
}

String _openQueueWeekday(int weekday) {
  return const [
    'MONDAY',
    'TUESDAY',
    'WEDNESDAY',
    'THURSDAY',
    'FRIDAY',
    'SATURDAY',
    'SUNDAY',
  ][weekday - 1];
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

double? _asNullableDouble(Object? value) => switch (value) {
  num number => number.toDouble(),
  String number => double.tryParse(number),
  _ => null,
};

String _clock(DateTime value) {
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${value.hour < 12 ? 'AM' : 'PM'}';
}

String _weekday(int value) {
  return const ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'][value - 1];
}

String _month(int value) {
  return const [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC',
  ][value - 1];
}
