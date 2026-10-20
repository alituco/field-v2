import 'fixture.dart';

/// One recorded match event projected onto the finished recording.
class MatchReplayMoment {
  const MatchReplayMoment({
    required this.event,
    required this.position,
    required this.matchSeconds,
    required this.homeScore,
    required this.awayScore,
    required this.isGoal,
    required this.isBlueCard,
    required this.isRedCard,
    required this.isHome,
    required this.isMeGoal,
    required this.isMeAssist,
    required this.description,
  });

  final FixtureTimelineEvent event;

  /// Null when the recording cannot be aligned or does not contain this event.
  final Duration? position;
  final int matchSeconds;
  final int homeScore;
  final int awayScore;
  final bool isGoal;
  final bool isBlueCard;
  final bool isRedCard;
  final bool isHome;
  final bool isMeGoal;
  final bool isMeAssist;
  final String description;

  String get eventType => event.eventType.trim().toUpperCase();
  bool get isOwnGoal => eventType == 'OWN_GOAL';
  bool get isYellowCard => eventType == 'YELLOW_CARD';
  bool get canSeek => position != null;
}

/// A pure projection of existing public events; it never invents match events
/// or adjusts goal counts to manufacture the fixture's published final score.
class MatchReplayTimeline {
  const MatchReplayTimeline._({
    required this.moments,
    required this.halftimeMatchSeconds,
    required this.halftimeVideoPosition,
    required this.hasVerifiedScore,
  });

  final List<MatchReplayMoment> moments;
  final int halftimeMatchSeconds;

  /// Only populated when an actual half-time event or a pause at half-time was
  /// recorded and maps inside the recording. The match-clock midpoint alone
  /// does not prove where a break appears in a video.
  final Duration? halftimeVideoPosition;
  final bool hasVerifiedScore;

  factory MatchReplayTimeline.fromFixture(
    Fixture fixture, {
    String? currentUserId,
    Duration? videoDuration,
  }) {
    final matchDuration = fixture.clock?.durationSeconds ?? 3600;
    final halftime = (matchDuration > 0 ? matchDuration : 3600) ~/ 2;
    final origin = _recordingOrigin(fixture, videoDuration);
    final source = <_RecordedEvent>[
      for (var index = 0; index < fixture.timeline.length; index++)
        _RecordedEvent(fixture.timeline[index], index, origin),
    ];
    // A recorded kickoff/resume anchors the clock fallback on the correct side
    // of a pause, rather than dropping the pause duration out of the video.
    final anchors =
        source
            .where((entry) => entry.wallPosition != null && entry.isClockStart)
            .toList()
          ..sort((a, b) {
            final clock = a.matchSeconds.compareTo(b.matchSeconds);
            return clock != 0
                ? clock
                : a.wallPosition!.compareTo(b.wallPosition!);
          });
    for (final entry in source) {
      entry.clockPosition = _clockPosition(entry.matchSeconds, anchors);
      entry.position = _insideRecording(
        entry.timestamp == null ? entry.clockPosition : entry.wallPosition,
        videoDuration,
      );
    }
    source.sort((a, b) {
      final order = (a.wallPosition ?? a.clockPosition).compareTo(
        b.wallPosition ?? b.clockPosition,
      );
      if (order != 0) return order;
      if (a.timestamp != null && b.timestamp != null) {
        final wallTime = a.timestamp!.compareTo(b.timestamp!);
        if (wallTime != 0) return wallTime;
      }
      return a.index.compareTo(b.index);
    });

    var homeScore = 0;
    var awayScore = 0;
    Duration? halftimePosition;
    final moments = <MatchReplayMoment>[];
    for (final entry in source) {
      final event = entry.event;
      final type = entry.type;
      final correction = event.note?.trim().toLowerCase() == 'admin correction';
      final isGoal = (type == 'GOAL' || type == 'OWN_GOAL') && !correction;
      final side = _homeSide(fixture, event.clanId);
      // An own-goal event belongs to the offending player's side; its score
      // is credited to the opposing side. Current GOAL rows already identify
      // the side receiving the goal and are left unchanged.
      final isHome = type == 'OWN_GOAL' && side != null ? !side : side == true;
      if (isGoal && side != null) {
        if (isHome) {
          homeScore++;
        } else {
          awayScore++;
        }
      }
      if (halftimePosition == null && _isHalftime(entry, halftime)) {
        halftimePosition = entry.position;
      }
      moments.add(
        MatchReplayMoment(
          event: event,
          position: entry.position,
          matchSeconds: entry.matchSeconds,
          homeScore: homeScore,
          awayScore: awayScore,
          isGoal: isGoal,
          isBlueCard: type == 'BLUE_CARD',
          isRedCard: type == 'RED_CARD',
          isHome: isHome,
          isMeGoal:
              isGoal &&
              type != 'OWN_GOAL' &&
              currentUserId != null &&
              event.profileId == currentUserId,
          isMeAssist:
              isGoal &&
              type != 'OWN_GOAL' &&
              currentUserId != null &&
              event.assistProfileId == currentUserId,
          description: _description(event, halftime),
        ),
      );
    }
    return MatchReplayTimeline._(
      moments: List.unmodifiable(moments),
      halftimeMatchSeconds: halftime,
      halftimeVideoPosition: halftimePosition,
      hasVerifiedScore: fixture.shouldDisplayScore,
    );
  }

  /// The current event is the latest event already reached, never a future
  /// event selected merely because its timestamp is closest to the playhead.
  MatchReplayMoment? currentMomentAt(Duration position) {
    MatchReplayMoment? current;
    for (final moment in moments) {
      final eventPosition = moment.position;
      if (eventPosition != null &&
          eventPosition <= position &&
          (current == null || eventPosition >= current.position!)) {
        current = moment;
      }
    }
    return current;
  }
}

class _RecordedEvent {
  _RecordedEvent(this.event, this.index, DateTime? origin)
    : matchSeconds = (event.minute * 60 + event.second).clamp(0, 1 << 31),
      timestamp = event.highlightTimestamp,
      wallPosition = origin == null
          ? null
          : event.highlightTimestamp?.difference(origin);

  final FixtureTimelineEvent event;
  final int index;
  final int matchSeconds;
  final DateTime? timestamp;
  final Duration? wallPosition;
  late Duration clockPosition;
  Duration? position;
  String get type => event.eventType.trim().toUpperCase();
  bool get isClockStart => switch (type) {
    'MATCH_STARTED' ||
    'MATCH_RESUMED' ||
    'KICK_OFF' ||
    'KICKOFF' ||
    'SECOND_HALF_STARTED' ||
    'HALF_TIME_ENDED' ||
    'RESUME' => true,
    _ => false,
  };
}

DateTime? _recordingOrigin(Fixture fixture, Duration? videoDuration) {
  final highlights = videoDuration != null && videoDuration > Duration.zero
      ? fixture.highlightMomentsForReplay(videoDuration)
      : fixture.highlightMoments;
  // Existing highlight alignment chooses between delayed live-start and stale
  // stop metadata. The end is never clamped, so it preserves the exact offset.
  if (highlights.isNotEmpty) {
    final selected = highlights.first;
    return selected.event.highlightTimestamp!.subtract(
      selected.end - const Duration(seconds: 20),
    );
  }
  final stopped = fixture.broadcast?.streamStoppedAt;
  if (stopped != null &&
      videoDuration != null &&
      videoDuration > Duration.zero) {
    return stopped.subtract(videoDuration);
  }
  return fixture.broadcast?.streamStartedAt;
}

Duration _clockPosition(int seconds, List<_RecordedEvent> anchors) {
  _RecordedEvent? anchor;
  for (final candidate in anchors) {
    if (candidate.matchSeconds <= seconds) anchor = candidate;
  }
  if (anchor == null) return Duration(seconds: seconds);
  return anchor.wallPosition! +
      Duration(seconds: seconds - anchor.matchSeconds);
}

Duration? _insideRecording(Duration? position, Duration? videoDuration) {
  if (position == null || position.isNegative) return null;
  if (videoDuration != null &&
      videoDuration > Duration.zero &&
      position > videoDuration) {
    return null;
  }
  return position;
}

bool? _homeSide(Fixture fixture, String? side) {
  if (side == null || side.trim().isEmpty) return null;
  if (side == fixture.homeClanId) return true;
  if (side == fixture.awayClanId) return false;
  return switch (side.trim().toUpperCase()) {
    'HOME' => true,
    'AWAY' => false,
    _ => null,
  };
}

bool _isHalftime(_RecordedEvent entry, int midpoint) {
  if (const {'HALF_TIME', 'HALFTIME', 'MATCH_HALF_TIME'}.contains(entry.type)) {
    return true;
  }
  if (entry.type != 'MATCH_PAUSED' && entry.type != 'PAUSE') return false;
  final note = entry.event.note?.trim().toLowerCase() ?? '';
  return entry.matchSeconds == midpoint ||
      note.contains('half-time') ||
      note.contains('halftime') ||
      note.contains('half time');
}

String _description(FixtureTimelineEvent event, int midpoint) {
  final type = event.eventType.trim().toUpperCase();
  final name = event.player?.displayName.trim();
  final player = name == null || name.isEmpty ? null : name;
  String withPlayer(String label) =>
      player == null ? label : '$label · $player';
  if (event.note?.trim().toLowerCase() == 'admin correction') {
    return 'Score correction';
  }
  return switch (type) {
    'GOAL' => withPlayer('Goal'),
    'OWN_GOAL' => withPlayer('Own goal'),
    'BLUE_CARD' => withPlayer('Blue card'),
    'RED_CARD' => withPlayer('Red card'),
    'YELLOW_CARD' => withPlayer('Yellow card'),
    'BLUE_CARD_EXPIRED' || 'BLUE_RETURN' => withPlayer('Returned'),
    'SUBSTITUTION' ||
    'SUBSTITUTION_ON' ||
    'SUBSTITUTION_OFF' => withPlayer('Substitution'),
    'JOIN' || 'PLAYER_JOINED' => withPlayer('Joined play'),
    'RETURN' || 'PLAYER_RETURNED' => withPlayer('Returned'),
    'EXCUSED_LEAVE' || 'PLAYER_LEFT' => withPlayer('Left play'),
    'QUIT' => withPlayer('Left match'),
    'MATCH_STARTED' || 'KICK_OFF' || 'KICKOFF' => 'Kick-off',
    'HALF_TIME' || 'HALFTIME' || 'MATCH_HALF_TIME' => 'Half-time',
    'SECOND_HALF_STARTED' || 'HALF_TIME_ENDED' => 'Second half',
    'MATCH_PAUSED' || 'PAUSE' =>
      event.minute * 60 + event.second == midpoint
          ? 'Half-time'
          : 'Play paused',
    'MATCH_RESUMED' || 'RESUME' =>
      event.minute * 60 + event.second == midpoint
          ? 'Second half'
          : 'Play resumed',
    'MATCH_STOPPED' => 'Match stopped',
    'MATCH_ENDED' => 'Full-time',
    'CORRECTION' => 'Score correction',
    'FORFEIT_PROVISIONAL' => 'Forfeit under review',
    'FORFEIT_CONFIRMED' => 'Forfeit confirmed',
    'FORFEIT_OVERTURNED' => 'Forfeit overturned',
    _ =>
      type
          .split('_')
          .map(
            (part) => part.isEmpty
                ? ''
                : '${part[0]}${part.substring(1).toLowerCase()}',
          )
          .join(' '),
  };
}
