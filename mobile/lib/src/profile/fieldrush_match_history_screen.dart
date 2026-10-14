import 'package:flutter/material.dart';
import '../ui/field_loading.dart';

import '../auth/fieldrush_auth_theme.dart';
import 'profile.dart';

class FieldrushMatchHistoryScreen extends StatefulWidget {
  const FieldrushMatchHistoryScreen({
    super.key,
    required this.profile,
    required this.onOpenGame,
    this.ratingEvents,
    this.playerName,
  });

  final PlayerProfile profile;
  final Future<void> Function(ProfilePreviousGame) onOpenGame;
  final List<ProfileRatingEvent>? ratingEvents;
  final String? playerName;

  @override
  State<FieldrushMatchHistoryScreen> createState() =>
      _FieldrushMatchHistoryScreenState();
}

class _FieldrushMatchHistoryScreenState
    extends State<FieldrushMatchHistoryScreen> {
  int _visible = 10;
  String? _opening;

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
    final groups = <String, List<ProfilePreviousGame>>{};
    for (final game in games.take(_visible)) {
      final date = game.localPlayedAt;
      final group = date == null
          ? 'Date unavailable'
          : '${_months[date.month - 1]} ${date.year}';
      groups.putIfAbsent(group, () => []).add(game);
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
              if (games.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 40, 20, 0),
                  child: Text(
                    widget.playerName == null
                        ? 'Your finished games will appear here.'
                        : 'No finished games yet.',
                    style: _jakarta(13),
                  ),
                ),
              for (final group in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 11),
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
                          _gameRow(group.value[i]),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
              if (_visible < games.length)
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
                    onPressed: () => setState(() => _visible += 10),
                    child: const Text('Show older games'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gameRow(ProfilePreviousGame game) {
    final event = (widget.ratingEvents ?? widget.profile.playerRating?.events)
        ?.where((e) => e.sourceId == game.id && e.isSolo == game.isSolo)
        .firstOrNull;
    final (result, background, foreground) = switch (game.outcome) {
      ProfileGameOutcome.win => (
        'W',
        const Color(0xFFEFF6E4),
        FieldrushAuthTheme.forest,
      ),
      ProfileGameOutcome.draw => (
        'D',
        const Color(0xFFF2EFE3),
        FieldrushAuthTheme.muted,
      ),
      ProfileGameOutcome.loss => (
        'L',
        const Color(0xFFF8E8E4),
        FieldrushAuthTheme.danger,
      ),
      null => ('—', const Color(0xFFF2EFE3), FieldrushAuthTheme.muted),
    };
    final isHome = ['HOME', 'WHITE'].contains(game.playerSide.toUpperCase());
    final opponent = isHome ? game.awayName : game.homeName;
    final delta = event?.ratingChange;
    final date = game.localPlayedAt;
    final dateLabel = date == null
        ? 'Date unavailable'
        : '${_months[date.month - 1].substring(0, 3)} ${date.day}';
    final scoreLabel = game.hasFinalScore
        ? '${game.homeScore}–${game.awayScore}'
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
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$dateLabel · ${game.isSolo ? '' : 'Clan · '}$scoreLabel',
                    style: _jakarta(10.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (_opening == '${game.type.name}:${game.id}')
              const SizedBox(
                width: 18,
                height: 18,
                child: FieldLoadingIndicator(label: 'Opening match'),
              )
            else ...[
              if (delta != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      delta > 0 ? '+$delta' : '$delta',
                      style: _outfit(16).copyWith(
                        color: delta > 0
                            ? FieldrushAuthTheme.forest
                            : delta < 0
                            ? FieldrushAuthTheme.danger
                            : FieldrushAuthTheme.muted,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'PLAYER SR',
                      style: _jakarta(8).copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: .8,
                      ),
                    ),
                  ],
                ),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right,
                size: 16,
                color: FieldrushAuthTheme.muted,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 44,
    height: 44,
    child: IconButton(
      tooltip: 'Back',
      onPressed: () => Navigator.of(context).pop(),
      style: IconButton.styleFrom(
        backgroundColor: Colors.white,
        side: const BorderSide(color: FieldrushAuthTheme.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: const Icon(Icons.chevron_left, color: FieldrushAuthTheme.ink),
    ),
  );
}

TextStyle _outfit(double size) => TextStyle(
  fontFamily: 'Outfit',
  fontSize: size,
  fontWeight: FontWeight.w800,
  height: 1,
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
