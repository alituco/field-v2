import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../ui/field_loading.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/read_timeout.dart';
import 'fieldrush_cancelled_game_screen.dart';
import 'player_history_repository.dart';
import 'profile.dart';

class FieldrushMatchHistoryScreen extends StatefulWidget {
  const FieldrushMatchHistoryScreen({
    super.key,
    required this.profile,
    required this.onOpenGame,
    this.ratingEvents,
    this.playerName,
    this.historyRepository,
    this.onFindAnotherGame,
  });

  final PlayerProfile profile;
  final Future<void> Function(ProfilePreviousGame) onOpenGame;
  final List<ProfileRatingEvent>? ratingEvents;
  final String? playerName;

  /// Only the signed-in You route supplies private cancellation history.
  final PlayerHistoryRepository? historyRepository;
  final VoidCallback? onFindAnotherGame;

  @override
  State<FieldrushMatchHistoryScreen> createState() =>
      _FieldrushMatchHistoryScreenState();
}

class _FieldrushMatchHistoryScreenState
    extends State<FieldrushMatchHistoryScreen> {
  int _visible = 10;
  String? _opening;
  List<PlayerCancelledGame> _cancelled = const [];
  PlayerHistoryCursor? _nextCancellation;
  bool _cancellationsLoaded = false;
  bool _loadingCancellations = false;
  String? _cancellationError;
  int _request = 0;

  bool get _privateHistory =>
      widget.historyRepository != null && widget.playerName == null;

  @override
  void initState() {
    super.initState();
    if (_privateHistory) _loadCancellations();
  }

  @override
  void didUpdateWidget(covariant FieldrushMatchHistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.id != widget.profile.id ||
        oldWidget.historyRepository != widget.historyRepository ||
        oldWidget.playerName != widget.playerName) {
      _request++;
      _cancelled = const [];
      _nextCancellation = null;
      _cancellationsLoaded = false;
      _loadingCancellations = false;
      _cancellationError = null;
      _visible = 10;
      if (_privateHistory) _loadCancellations();
    }
  }

  @override
  void dispose() {
    _request++;
    super.dispose();
  }

  Future<void> _loadCancellations({
    bool restart = false,
    int minimum = 10,
    int? reveal,
  }) async {
    if (!_privateHistory || _loadingCancellations) return;
    final generation = ++_request;
    final owner = widget.profile.id;
    var cursor = restart ? null : _nextCancellation;
    var collected = restart ? <PlayerCancelledGame>[] : [..._cancelled];
    setState(() {
      _loadingCancellations = true;
      _cancellationError = null;
    });
    try {
      do {
        final page = await widget.historyRepository!
            .getCancelledGames(cursor: cursor, limit: 20)
            .timeout(fieldReadTimeout);
        if (!mounted || generation != _request || owner != widget.profile.id) {
          return;
        }
        final next = page.nextCursor;
        if (next != null &&
            cursor != null &&
            next.id == cursor.id &&
            next.createdAt == cursor.createdAt) {
          throw StateError('Cancellation history did not advance.');
        }
        collected = <String, PlayerCancelledGame>{
          for (final game in collected) game.id: game,
          for (final game in page.items) game.id: game,
        }.values.toList();
        cursor = next;
        setState(() {
          _cancelled = collected;
          _nextCancellation = next;
          _cancellationsLoaded = true;
        });
      } while (cursor != null && collected.length < minimum);
      if (reveal != null) setState(() => _visible = reveal);
    } catch (_) {
      if (mounted && generation == _request) {
        setState(() => _cancellationError = 'Could not load cancelled games.');
      }
    } finally {
      if (mounted && generation == _request) {
        setState(() => _loadingCancellations = false);
      }
    }
  }

  Future<void> _showOlder() async {
    final desired = _visible + 10;
    // Load enough cancellations before extending the mixed list so an older
    // played match cannot jump ahead of an as-yet-unloaded cancellation.
    if (_privateHistory &&
        (!_cancellationsLoaded ||
            (_nextCancellation != null && _cancelled.length < desired))) {
      await _loadCancellations(minimum: desired, reveal: desired);
    } else {
      setState(() => _visible = desired);
    }
  }

  Future<void> _openCancelled(PlayerCancelledGame game) async {
    if (_opening != null) return;
    setState(() => _opening = 'cancelled:${game.id}');
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => FieldrushCancelledGameScreen(
            game: game,
            onFindAnotherGame: widget.onFindAnotherGame,
          ),
        ),
      );
      if (mounted && _privateHistory) {
        await _loadCancellations(restart: true, minimum: _visible);
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _open(ProfilePreviousGame game) async {
    if (_opening != null) return;
    setState(() => _opening = '${game.type.name}:${game.id}');
    try {
      await widget.onOpenGame(game);
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final games = <String, ProfilePreviousGame>{
      for (final game in widget.profile.previousGames)
        if (game.id.trim().isNotEmpty) '${game.type.name}:${game.id}': game,
    }.values.toList()..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    final entries = <String, _HistoryEntry>{
      for (final game in games)
        '${game.type.name}:${game.id}': _HistoryEntry.played(game),
      for (final game in _cancelled)
        'solo:${game.id}': _HistoryEntry.cancelled(game),
    }.values.toList()..sort((a, b) => b.sortAt.compareTo(a.sortAt));
    final groups = <String, List<_HistoryEntry>>{};
    final currentYear = DateTime.now().year;
    for (final entry in entries.take(_visible)) {
      final date = entry.localDate;
      final group = date == null
          ? 'Date unavailable'
          : date.year == currentYear
          ? _months[date.month - 1]
          : '${_months[date.month - 1]} ${date.year}';
      groups.putIfAbsent(group, () => []).add(entry);
    }
    final wins = games.where((g) => g.outcome == ProfileGameOutcome.win).length;
    final draws = games
        .where((g) => g.outcome == ProfileGameOutcome.draw)
        .length;
    final losses = games
        .where((g) => g.outcome == ProfileGameOutcome.loss)
        .length;
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: Scaffold(
        backgroundColor: FieldrushAuthTheme.cream,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(top: 18, bottom: 32),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    _BackButton(),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Match history', style: _outfit(18)),
                          const SizedBox(height: 5),
                          if (widget.playerName != null) ...[
                            Text(widget.playerName!, style: _jakarta(12)),
                            const SizedBox(height: 5),
                          ],
                          Text(
                            '${games.length} played · ${wins}W ${draws}D ${losses}L',
                            style: _jakarta(11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (_loadingCancellations)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: FieldLoadingIndicator(
                    label: 'Loading cancelled games',
                  ),
                ),
              if (_cancellationError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(_cancellationError!, style: _jakarta(12)),
                      ),
                      TextButton(
                        key: const Key('retry-cancelled-history'),
                        onPressed: _loadingCancellations
                            ? null
                            : () => _loadCancellations(
                                restart: !_cancellationsLoaded,
                                minimum: _visible,
                              ),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              if (entries.isEmpty &&
                  !_loadingCancellations &&
                  (!_privateHistory || _cancellationsLoaded))
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 40, 20, 0),
                  child: Text(
                    widget.playerName == null
                        ? _privateHistory
                              ? 'Your finished and cancelled games will appear here.'
                              : 'Your finished games will appear here.'
                        : 'No finished games yet.',
                    style: _jakarta(13),
                  ),
                ),
              for (final group in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 11),
                  child: Text(
                    group.key.toUpperCase(),
                    style: _jakarta(
                      11,
                    ).copyWith(fontWeight: FontWeight.w800, letterSpacing: 1.5),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Material(
                    color: Colors.white,
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: const BorderSide(color: FieldrushAuthTheme.border),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < group.value.length; i++) ...[
                          if (i > 0)
                            const Divider(height: 1, color: Color(0xFFF0ECE0)),
                          if (group.value[i].cancellation case final game?)
                            _cancelledRow(game)
                          else
                            _gameRow(group.value[i].played!),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
              if (_visible < entries.length || _nextCancellation != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: FieldrushAuthTheme.ink,
                      side: const BorderSide(color: FieldrushAuthTheme.border),
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: _loadingCancellations ? null : _showOlder,
                    child: const Text('Show older games'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cancelledRow(PlayerCancelledGame game) {
    final date = game.localDisplayStartsAt;
    final dateLabel = date == null
        ? 'Date unavailable'
        : '${_weekdays[date.weekday - 1]}, '
              '${_months[date.month - 1].substring(0, 3)} ${date.day}';
    return InkWell(
      key: ValueKey('you-cancelled-history-${game.id}'),
      onTap: _opening == null ? () => _openCancelled(game) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
        child: Row(
          children: [
            CustomPaint(
              painter: _CancelledBadgeBorder(),
              child: SizedBox(
                width: 36,
                height: 36,
                child: Center(
                  child: Text(
                    '–',
                    style: _outfit(16).copyWith(color: const Color(0xFF8E897A)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Solo game',
                    style: _jakarta(13).copyWith(
                      color: FieldrushAuthTheme.ink,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$dateLabel · Cancelled',
                    style: _jakarta(10.5).copyWith(height: 1),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _ratingColumn(null),
            const SizedBox(width: 12),
            _chevron(),
          ],
        ),
      ),
    );
  }

  Widget _gameRow(ProfilePreviousGame game) {
    final event = (widget.ratingEvents ?? widget.profile.playerRating?.events)
        ?.where((e) => e.sourceId == game.id && e.isSolo == game.isSolo)
        .firstOrNull;
    final (result, background, foreground) = switch (game.outcome) {
      ProfileGameOutcome.win => ('W', FieldrushAuthTheme.forest, Colors.white),
      ProfileGameOutcome.draw => (
        'D',
        const Color(0xFFF2EFE3),
        FieldrushAuthTheme.muted,
      ),
      ProfileGameOutcome.loss => (
        'L',
        const Color(0xFFF7E3E3),
        FieldrushAuthTheme.danger,
      ),
      null => ('—', const Color(0xFFF2EFE3), FieldrushAuthTheme.muted),
    };
    final playerSide = game.playerSide.trim().toUpperCase();
    final isHome = ['HOME', 'WHITE'].contains(playerSide);
    final isAway = ['AWAY', 'BLACK'].contains(playerSide);
    final opponent = isHome ? game.awayName : game.homeName;
    final delta = event?.hasPublicRating == true ? event?.ratingChange : null;
    final date = game.localPlayedAt;
    final dateLabel = date == null
        ? 'Date unavailable'
        : '${_weekdays[date.weekday - 1]}, '
              '${_months[date.month - 1].substring(0, 3)} ${date.day}';
    final scoreLabel = game.hasFinalScore
        ? isAway
              ? '${game.awayScore}–${game.homeScore}'
              : '${game.homeScore}–${game.awayScore}'
        : 'Score unavailable';
    return InkWell(
      key: ValueKey(
        '${widget.playerName == null ? 'you' : 'player'}-history-${game.id}',
      ),
      onTap: _opening == null ? () => _open(game) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                result,
                style: _outfit(13).copyWith(color: foreground),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    game.isSolo ? 'Solo game' : 'vs $opponent',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _jakarta(13).copyWith(
                      color: FieldrushAuthTheme.ink,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$dateLabel · ${game.isSolo ? '' : 'Clan · '}$scoreLabel',
                    style: _jakarta(10.5).copyWith(height: 1),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (_opening == '${game.type.name}:${game.id}')
              const SizedBox(
                width: 18,
                height: 18,
                child: FieldLoadingIndicator(label: 'Opening match'),
              )
            else ...[
              _ratingColumn(delta),
              const SizedBox(width: 12),
              _chevron(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _ratingColumn(int? delta) => Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Text(
        delta == null
            ? '—'
            : delta > 0
            ? '+$delta'
            : '$delta',
        style: _outfit(16).copyWith(
          color: delta == null
              ? const Color(0xFF8E897A)
              : delta > 0
              ? FieldrushAuthTheme.forest
              : delta < 0
              ? FieldrushAuthTheme.danger
              : FieldrushAuthTheme.muted,
        ),
      ),
      const SizedBox(height: 5),
      Text(
        'SR',
        style: _jakarta(
          8.5,
        ).copyWith(fontWeight: FontWeight.w800, letterSpacing: .85, height: 1),
      ),
    ],
  );

  Widget _chevron() => SizedBox(
    width: 10,
    child: Text('›', style: _jakarta(13).copyWith(fontWeight: FontWeight.w700)),
  );
}

class _HistoryEntry {
  const _HistoryEntry.played(this.played) : cancellation = null;
  const _HistoryEntry.cancelled(this.cancellation) : played = null;
  final ProfilePreviousGame? played;
  final PlayerCancelledGame? cancellation;

  DateTime get sortAt => played != null
      ? played!.playedAt
      : cancellation!.checkInAt ??
            cancellation!.startsAt.subtract(const Duration(minutes: 30));
  DateTime? get localDate => played != null
      ? played!.localPlayedAt
      : cancellation!.localDisplayStartsAt;
}

class _CancelledBadgeBorder extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.75),
          const Radius.circular(11),
        ),
      );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xFFC9C2AE);
    for (final metric in path.computeMetrics()) {
      for (double start = 0; start < metric.length; start += 7) {
        canvas.drawPath(
          metric.extractPath(start, math.min(start + 4, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CancelledBadgeBorder oldDelegate) => false;
}

class _BackButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 36,
    height: 36,
    child: IconButton(
      tooltip: 'Back',
      padding: EdgeInsets.zero,
      onPressed: () => Navigator.of(context).pop(),
      style: IconButton.styleFrom(
        backgroundColor: Colors.white,
        side: const BorderSide(color: FieldrushAuthTheme.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: const Icon(
        Icons.chevron_left,
        size: 20,
        color: FieldrushAuthTheme.ink,
      ),
    ),
  );
}

TextStyle _outfit(double size) => TextStyle(
  fontFamily: 'Outfit',
  fontSize: size,
  fontWeight: FontWeight.w800,
  height: 1,
  letterSpacing: -size * .01,
  color: FieldrushAuthTheme.ink,
);
TextStyle _jakarta(double size) => TextStyle(
  fontFamily: 'PlusJakartaSans',
  fontSize: size,
  fontWeight: FontWeight.w600,
  height: 1.35,
  color: FieldrushAuthTheme.muted,
);
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
