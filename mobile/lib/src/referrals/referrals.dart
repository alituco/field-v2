/// Referral decisions and timestamps come from the server, never device age or
/// a locally cached booking/payment flag.
class ReferralPerson {
  const ReferralPerson({
    required this.id,
    required this.name,
    required this.username,
    this.division,
    this.ratingVisible = false,
  });

  final String id;
  final String name;
  final String username;
  final int? division;
  final bool ratingVisible;
  String get code => username.toUpperCase();
  String get firstName => name.trim().split(RegExp(r'\s+')).first;
  String get initials => name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .take(2)
      .map((part) => String.fromCharCode(part.runes.first))
      .join()
      .toUpperCase();

  factory ReferralPerson.fromJson(Map<String, dynamic> json) => ReferralPerson(
    id: json['id'] as String,
    name: json['name'] as String,
    username: json['username'] as String? ?? '',
    division: (json['division'] as num?)?.toInt(),
    ratingVisible: json['rating_visible'] == true,
  );
}

class ReferralSeason {
  const ReferralSeason({
    required this.id,
    required this.label,
    required this.ended,
  });
  final String id;
  final String label;
  final bool ended;
  String get displayLabel =>
      RegExp(r'^S\d+$', caseSensitive: false).hasMatch(label)
      ? 'Season ${label.substring(1)}'
      : label;
  factory ReferralSeason.fromJson(Map<String, dynamic> json) => ReferralSeason(
    id: json['id'] as String,
    label: json['label'] as String,
    ended: json['ended'] == true,
  );
}

class ReferralFriend {
  const ReferralFriend({
    required this.person,
    required this.qualified,
    this.gamesPlayed = 0,
  });
  final ReferralPerson person;
  final bool qualified;
  final int gamesPlayed;
  factory ReferralFriend.fromJson(Map<String, dynamic> json) => ReferralFriend(
    person: ReferralPerson.fromJson(json),
    qualified: json['qualified'] == true,
    gamesPlayed: (json['games_played'] as num?)?.toInt() ?? 0,
  );
}

class ReferralSummary {
  const ReferralSummary({
    required this.serverNow,
    required this.entryExpiresAt,
    required this.canAddCode,
    required this.ownCode,
    this.referrer,
    this.referrerCredited = false,
    required this.season,
    this.referralCount = 0,
    this.waitingCount = 0,
    this.rank,
    this.needsReview = false,
    this.gamesPlayed = 0,
    this.referredGamesPlayed = 0,
    this.referrals = const [],
    this.referralsTotal = 0,
    this.referralsNextOffset,
    this.prizePoolMinor = 25000,
    this.prizeEachMinor = 5000,
    this.minimumReferrals = 2,
    this.prizePlaces = 5,
  });

  final DateTime serverNow;
  final DateTime entryExpiresAt;
  final bool canAddCode;
  final String ownCode;
  final ReferralPerson? referrer;
  final bool referrerCredited;
  final ReferralSeason season;
  final int referralCount;
  final int waitingCount;
  final int? rank;
  final bool needsReview;
  final int gamesPlayed;
  final int referredGamesPlayed;
  final List<ReferralFriend> referrals;
  final int referralsTotal;
  final int? referralsNextOffset;
  final int prizePoolMinor;
  final int prizeEachMinor;
  final int minimumReferrals;
  final int prizePlaces;

  int get daysLeft => entryExpiresAt.difference(serverNow).inMilliseconds <= 0
      ? 0
      : (entryExpiresAt.difference(serverNow).inMilliseconds /
                Duration.millisecondsPerDay)
            .ceil();

  factory ReferralSummary.fromJson(Map<String, dynamic> json) =>
      ReferralSummary(
        serverNow: DateTime.parse(json['server_now'] as String),
        entryExpiresAt: DateTime.parse(json['entry_expires_at'] as String),
        canAddCode: json['can_add_code'] == true,
        ownCode: json['own_code'] as String,
        referrer: json['referrer'] == null
            ? null
            : ReferralPerson.fromJson(_object(json['referrer'])),
        referrerCredited: json['referrer_credited'] == true,
        season: ReferralSeason.fromJson(_object(json['season'])),
        referralCount: (json['referral_count'] as num).toInt(),
        waitingCount: (json['waiting_count'] as num).toInt(),
        rank: (json['rank'] as num?)?.toInt(),
        needsReview: json['needs_review'] == true,
        gamesPlayed: (json['games_played'] as num?)?.toInt() ?? 0,
        referredGamesPlayed:
            (json['referred_games_played'] as num?)?.toInt() ?? 0,
        referrals: _objects(
          json['referrals'],
        ).map(ReferralFriend.fromJson).toList(growable: false),
        referralsTotal: (json['referrals_total'] as num?)?.toInt() ?? 0,
        referralsNextOffset: (json['referrals_next_offset'] as num?)?.toInt(),
        prizePoolMinor: (json['prize_pool_minor'] as num?)?.toInt() ?? 25000,
        prizeEachMinor: (json['prize_each_minor'] as num?)?.toInt() ?? 5000,
        minimumReferrals: (json['minimum_referrals'] as num?)?.toInt() ?? 2,
        prizePlaces: (json['prize_places'] as num?)?.toInt() ?? 5,
      );
}

class ReferralEntry {
  const ReferralEntry({
    required this.person,
    this.rank,
    this.referralCount = 0,
    this.gamesPlayed = 0,
    this.referredGamesPlayed = 0,
    this.needsReview = false,
    this.prizeEligible = false,
  });
  final ReferralPerson person;
  final int? rank;
  final int referralCount;
  final int gamesPlayed;
  final int referredGamesPlayed;
  final bool needsReview;
  final bool prizeEligible;
  factory ReferralEntry.fromJson(Map<String, dynamic> json) => ReferralEntry(
    person: ReferralPerson.fromJson(json),
    rank: (json['rank'] as num?)?.toInt(),
    referralCount: (json['referral_count'] as num).toInt(),
    gamesPlayed: (json['games_played'] as num?)?.toInt() ?? 0,
    referredGamesPlayed: (json['referred_games_played'] as num?)?.toInt() ?? 0,
    needsReview: json['needs_review'] == true,
    prizeEligible: json['prize_eligible'] == true,
  );
}

class ReferralLeaderboard {
  const ReferralLeaderboard({
    required this.season,
    this.prizeEntries = const [],
    this.entries = const [],
    required this.me,
    this.qualifiedTotal = 0,
    this.nextOffset,
  });
  final ReferralSeason season;
  final List<ReferralEntry> prizeEntries;
  final List<ReferralEntry> entries;
  final ReferralEntry me;
  final int qualifiedTotal;
  final int? nextOffset;
  factory ReferralLeaderboard.fromJson(Map<String, dynamic> json) =>
      ReferralLeaderboard(
        season: ReferralSeason.fromJson(_object(json['season'])),
        prizeEntries: _objects(
          json['prize_entries'],
        ).map(ReferralEntry.fromJson).toList(growable: false),
        entries: _objects(
          json['entries'],
        ).map(ReferralEntry.fromJson).toList(growable: false),
        me: ReferralEntry.fromJson(_object(json['me'])),
        qualifiedTotal: (json['qualified_total'] as num).toInt(),
        nextOffset: (json['next_offset'] as num?)?.toInt(),
      );
}

class ReferralFriendsPage {
  const ReferralFriendsPage({
    required this.entries,
    required this.total,
    this.nextOffset,
  });
  final List<ReferralFriend> entries;
  final int total;
  final int? nextOffset;
  factory ReferralFriendsPage.fromJson(Map<String, dynamic> json) =>
      ReferralFriendsPage(
        entries: _objects(
          json['entries'],
        ).map(ReferralFriend.fromJson).toList(growable: false),
        total: (json['total'] as num).toInt(),
        nextOffset: (json['next_offset'] as num?)?.toInt(),
      );
}

Map<String, dynamic> _object(dynamic value) =>
    Map<String, dynamic>.from(value as Map);
Iterable<Map<String, dynamic>> _objects(dynamic value) =>
    (value as List<dynamic>? ?? const []).map(_object);
