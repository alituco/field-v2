import 'package:flutter/material.dart';

import 'clan.dart';
import 'clan_widgets.dart';

class ClanDetailScreen extends StatelessWidget {
  const ClanDetailScreen({super.key, required this.clan});

  final Clan clan;

  @override
  Widget build(BuildContext context) {
    final rank = clan.rank;
    return Scaffold(
      backgroundColor: fieldBackground,
      body: Column(
        children: [
          FieldPageHeader(title: clan.name, showBack: true),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _ClanHero(clan: clan),
                const SizedBox(height: 20),
                _RatingPanel(clan: clan, rank: rank),
                const SizedBox(height: 16),
                _KitIdentityPanel(clan: clan),
                const SizedBox(height: 16),
                _MembersPanel(clan: clan),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ClanHero extends StatelessWidget {
  const _ClanHero({required this.clan});

  final Clan clan;

  @override
  Widget build(BuildContext context) {
    final rank = clan.rank;
    final tier = rank.tier;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-1, -1),
          radius: 1.35,
          colors: [
            tierStartColor(tier),
            tierMiddleColor(tier),
            tierEndColor(tier),
          ],
          stops: const [0, 0.45, 1],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: tierMiddleColor(tier).withValues(alpha: 0.34),
            blurRadius: 26,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          const Positioned.fill(
            child: CustomPaint(painter: _HeroPitchPainter()),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.20),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.30),
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Center(
                      child: Text(
                        clan.emblem,
                        style: const TextStyle(fontSize: 38),
                      ),
                    ),
                  ),
                  TierBadge(rank: rank),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      clan.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        height: 1.05,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.20),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      clan.tag,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(
                    Icons.group_rounded,
                    color: Color(0xFFD1FAE5),
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${clan.memberCount} ${clan.memberCount == 1 ? 'member' : 'members'}',
                    style: const TextStyle(
                      color: Color(0xFFD1FAE5),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _HeroStat(
                      value: clan.wins.toString(),
                      label: 'Wins',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _HeroStat(
                      value: clan.losses.toString(),
                      label: 'Losses',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _HeroStat(value: '${clan.winRate}%', label: 'Win %'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _HeroStat(
                      value: rank.label.split(' ').first,
                      label: 'Tier',
                      compact: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({
    required this.value,
    required this.label,
    this.compact = false,
  });

  final String value;
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                color: Colors.white,
                fontSize: compact ? 14 : 18,
                height: 1,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.9,
            ),
          ),
        ],
      ),
    );
  }
}

class _RatingPanel extends StatelessWidget {
  const _RatingPanel({required this.clan, required this.rank});

  final Clan clan;
  final ClanRank rank;

  @override
  Widget build(BuildContext context) {
    final nextDivision = _srToNextDivision(clan.skillRating);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Skill Rating',
                  style: TextStyle(
                    color: fieldGray900,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                clan.skillRating.toString(),
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 30,
                  height: 1,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 10),
              TierBadge(rank: rank, small: true),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            nextDivision == null
                ? 'Champion — Max Tier'
                : '$nextDivision SR to next division',
            style: TextStyle(
              color: nextDivision == null
                  ? const Color(0xFFF59E0B)
                  : fieldGray500,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: 10,
              child: Stack(
                children: [
                  const DecoratedBox(
                    decoration: BoxDecoration(color: fieldGray100),
                    child: SizedBox.expand(),
                  ),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: clan.ratingProgress),
                    duration: const Duration(milliseconds: 520),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, child) {
                      return FractionallySizedBox(
                        widthFactor: value,
                        child: child,
                      );
                    },
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [fieldEmerald500, fieldBlue600],
                        ),
                      ),
                      child: SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  int? _srToNextDivision(int rating) {
    if (rating >= 2700) return null;
    final next = (((rating ~/ 300) + 1) * 300);
    return next - rating;
  }
}

class _KitIdentityPanel extends StatelessWidget {
  const _KitIdentityPanel({required this.clan});

  final Clan clan;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Kit Identity',
            style: TextStyle(
              color: fieldGray900,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 14),
          KitCard(
            clanName: clan.name,
            clanTag: clan.tag,
            motto: clan.motto,
            emblem: clan.emblem,
            theme: clan.theme,
            pattern: clan.patternId,
          ),
        ],
      ),
    );
  }
}

class _MembersPanel extends StatelessWidget {
  const _MembersPanel({required this.clan});

  final Clan clan;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: fieldGray100,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.group_rounded, color: fieldEmerald600),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Roster',
                  style: TextStyle(
                    color: fieldGray900,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${clan.memberCount}/11 players',
                  style: const TextStyle(
                    color: fieldGray500,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: null,
            child: Text(clan.memberCount >= 11 ? 'Full' : 'Join soon'),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _HeroPitchPainter extends CustomPainter {
  const _HeroPitchPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.16)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawLine(
      Offset(size.width / 2, -20),
      Offset(size.width / 2, size.height + 20),
      paint,
    );
    canvas.drawCircle(center, size.shortestSide * 0.24, paint);
  }

  @override
  bool shouldRepaint(covariant _HeroPitchPainter oldDelegate) => false;
}
