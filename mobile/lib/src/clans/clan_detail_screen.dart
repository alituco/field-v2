import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../fixtures/create_fixture_screen.dart';
import '../fixtures/fixture.dart';
import '../fixtures/fixture_repository.dart';
import 'clan.dart';
import 'clan_repository.dart';
import 'clan_widgets.dart';
import 'customize_clan_screen.dart';

class ClanDetailScreen extends StatefulWidget {
  const ClanDetailScreen({
    super.key,
    required this.clan,
    required this.clanRepository,
    required this.fixtureRepository,
    this.currentMembership,
  });

  final Clan clan;
  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;
  final ClanMembership? currentMembership;

  @override
  State<ClanDetailScreen> createState() => _ClanDetailScreenState();
}

class _ClanDetailScreenState extends State<ClanDetailScreen> {
  int _tabIndex = 0;
  late Clan _clan;
  List<ClanMember> _members = const [];
  List<Fixture> _fixtures = const [];
  bool _isLoadingMembers = true;
  String? _membersErrorText;

  Clan get clan => _clan;

  bool get _isCurrentClan => widget.currentMembership?.clanId == clan.id;

  bool get _hasClan => widget.currentMembership != null;

  bool get _isOwner {
    final membership = widget.currentMembership;
    if (membership != null) {
      return membership.clanId == clan.id && membership.isOwner;
    }

    final userId = Supabase.instance.client.auth.currentUser?.id;
    return userId != null && clan.createdBy == userId;
  }

  @override
  void initState() {
    super.initState();
    _clan = widget.clan;
    _loadClanData();
  }

  Future<void> _openCustomize() async {
    final updated = await Navigator.of(context).push<Clan>(
      MaterialPageRoute(
        builder: (context) => CustomizeClanScreen(
          clan: clan,
          clanRepository: widget.clanRepository,
        ),
      ),
    );
    if (updated == null || !mounted) return;
    setState(() => _clan = updated);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Clan identity updated.')));
  }

  Future<void> _openFixtureFlow() async {
    if (!_isOwner) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Join requests are next.')));
      return;
    }

    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => CreateFixtureScreen(
          fixtureRepository: widget.fixtureRepository,
          myClanMembership: MyClanMembership(
            clan: FixtureClan(
              id: clan.id,
              name: clan.name,
              tag: clan.tag,
              emblem: clan.emblem,
              themeId: clan.themeId,
              patternId: clan.patternId,
              skillRating: clan.skillRating,
            ),
            role: widget.currentMembership?.clanId == clan.id
                ? widget.currentMembership!.role
                : 'owner',
          ),
        ),
      ),
    );

    if (changed == true && mounted) {
      await _loadClanData();
    }
  }

  Future<void> _loadClanData() async {
    setState(() {
      _isLoadingMembers = true;
      _membersErrorText = null;
    });

    try {
      final members = await widget.clanRepository.listClanMembers(clan.id);
      final fixtures = await widget.clanRepository.listClanFixtures(clan.id);
      if (!mounted) return;
      setState(() {
        _members = members;
        _fixtures = fixtures;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _membersErrorText = 'Could not load clan data.';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoadingMembers = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _ClanDetailData.fromClan(
      clan,
      members: _members,
      fixtures: _fixtures,
    );

    return Scaffold(
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: FieldPageHeader(
          title: clan.name,
          showBack: true,
          rightAction: _isOwner
              ? HeaderActionButton(
                  icon: Icons.tune_rounded,
                  label: 'Edit',
                  onPressed: _openCustomize,
                )
              : null,
        ),
        child: ListView(
          padding: fieldHeaderAwarePadding(context, bottom: 116),
          children: [
            _ClanHero(clan: clan, detail: detail),
            const SizedBox(height: 24),
            _SegmentedTabs(
              selectedIndex: _tabIndex,
              onChanged: (index) => setState(() => _tabIndex = index),
            ),
            const SizedBox(height: 16),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.03),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: _tabIndex == 0
                  ? _OverviewTab(
                      key: const ValueKey('overview'),
                      clan: clan,
                      detail: detail,
                      isLoadingMembers: _isLoadingMembers,
                      membersErrorText: _membersErrorText,
                      onRetryMembers: _loadClanData,
                    )
                  : _MatchesTab(
                      key: const ValueKey('matches'),
                      clan: clan,
                      detail: detail,
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _ClanActionBar(
        isOwner: _isOwner,
        isCurrentClan: _isCurrentClan,
        hasClan: _hasClan,
        onPressed: _openFixtureFlow,
      ),
    );
  }
}

class _ClanHero extends StatelessWidget {
  const _ClanHero({required this.clan, required this.detail});

  final Clan clan;
  final _ClanDetailData detail;

  @override
  Widget build(BuildContext context) {
    final rank = clan.rank;
    final theme = clan.theme;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [theme.from, theme.to],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: theme.from.withValues(alpha: 0.34),
            blurRadius: 26,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: PatternPainter(
                pattern: clan.patternId,
                color: theme.accent,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
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
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.16),
                            blurRadius: 12,
                            offset: const Offset(0, 5),
                          ),
                        ],
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
                const SizedBox(height: 14),
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
                      margin: const EdgeInsets.only(top: 2),
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
                if (detail.recentForm.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(right: 10),
                        child: Text(
                          'FORM',
                          style: TextStyle(
                            color: Color(0xFFD1FAE5),
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.4,
                          ),
                        ),
                      ),
                      for (final result in detail.recentForm) ...[
                        _FormPill(result: result),
                        const SizedBox(width: 6),
                      ],
                    ],
                  ),
                ],
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
                      child: _HeroStat(
                        value: '${clan.winRate}%',
                        label: 'Win %',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _HeroStat(
                        value: detail.goalDiffLabel,
                        label: 'GD',
                        accent: detail.goalDiff > 0
                            ? const Color(0xFFA7F3D0)
                            : detail.goalDiff < 0
                            ? const Color(0xFFFECACA)
                            : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FormPill extends StatelessWidget {
  const _FormPill({required this.result});

  final String result;

  @override
  Widget build(BuildContext context) {
    final background = switch (result) {
      'W' => const Color(0xFFA7F3D0),
      'L' => const Color(0xFFFCA5A5),
      _ => Colors.white.withValues(alpha: 0.40),
    };
    final foreground = switch (result) {
      'W' => const Color(0xFF064E3B),
      'L' => const Color(0xFF7F1D1D),
      _ => Colors.white,
    };

    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        result,
        style: TextStyle(
          color: foreground,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.value, required this.label, this.accent});

  final String value;
  final String label;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                color: accent ?? Colors.white,
                fontSize: 20,
                height: 1,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Color(0xFFD1FAE5),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _SegmentedTabs extends StatelessWidget {
  const _SegmentedTabs({required this.selectedIndex, required this.onChanged});

  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: fieldGray200.withValues(alpha: 0.60),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _SegmentedTabButton(
            label: 'Overview',
            selected: selectedIndex == 0,
            onTap: () => onChanged(0),
          ),
          _SegmentedTabButton(
            label: 'Matches',
            selected: selectedIndex == 1,
            onTap: () => onChanged(1),
          ),
        ],
      ),
    );
  }
}

class _SegmentedTabButton extends StatelessWidget {
  const _SegmentedTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? const Color(0xFF047857) : fieldGray600,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    super.key,
    required this.clan,
    required this.detail,
    required this.isLoadingMembers,
    required this.membersErrorText,
    required this.onRetryMembers,
  });

  final Clan clan;
  final _ClanDetailData detail;
  final bool isLoadingMembers;
  final String? membersErrorText;
  final VoidCallback onRetryMembers;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _RatingPanel(clan: clan),
        if (detail.nextMatch != null) ...[
          const SizedBox(height: 16),
          _NextMatchCard(match: detail.nextMatch!),
        ],
        if (detail.topScorer != null || detail.topAssister != null) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _TopPerformerCard(
                  icon: Icons.sports_soccer_rounded,
                  label: 'Top Scorer',
                  player: detail.topScorer?.playerName,
                  value: detail.topScorer?.value ?? '—',
                  colors: const [Color(0xFFF97316), Color(0xFFDB2777)],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _TopPerformerCard(
                  icon: Icons.auto_awesome_rounded,
                  label: 'Top Assister',
                  player: detail.topAssister?.playerName,
                  value: detail.topAssister?.value ?? '—',
                  colors: const [Color(0xFF3B82F6), Color(0xFF7C3AED)],
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        _ScoringPanel(detail: detail),
        const SizedBox(height: 16),
        _KitIdentityPanel(clan: clan),
        const SizedBox(height: 16),
        _RosterPanel(
          members: detail.members,
          expectedCount: clan.memberCount,
          isLoading: isLoadingMembers,
          errorText: membersErrorText,
          onRetry: onRetryMembers,
        ),
      ],
    );
  }
}

class _RatingPanel extends StatelessWidget {
  const _RatingPanel({required this.clan});

  final Clan clan;

  @override
  Widget build(BuildContext context) {
    final rank = clan.rank;
    final bounds = _divisionBounds(rank);
    final maxLabel = rank.tier == ClanTier.champion
        ? 'MAX'
        : (bounds.max + 1).toString();
    final progress = rank.tier == ClanTier.champion
        ? 1.0
        : ((clan.skillRating - bounds.min) / (bounds.max + 1 - bounds.min))
              .clamp(0, 1)
              .toDouble();
    final srToNext = rank.tier == ClanTier.champion
        ? null
        : (bounds.max + 1) - clan.skillRating;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
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
                        TierLabelBadge(rank: rank, small: true),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text.rich(
                      TextSpan(
                        children: [
                          if (srToNext != null)
                            TextSpan(
                              text: '$srToNext SR',
                              style: const TextStyle(
                                color: fieldEmerald600,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          TextSpan(
                            text: srToNext == null
                                ? 'Champion — Max Tier'
                                : ' to next division',
                          ),
                        ],
                      ),
                      style: TextStyle(
                        color: srToNext == null
                            ? const Color(0xFFF59E0B)
                            : fieldGray500,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
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
              const SizedBox(width: 12),
              TierBadge(rank: rank, small: true),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                bounds.min.toString(),
                style: const TextStyle(
                  color: fieldGray400,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                maxLabel,
                style: const TextStyle(
                  color: fieldGray400,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: 16,
              child: Stack(
                children: [
                  const DecoratedBox(
                    decoration: BoxDecoration(color: fieldGray100),
                    child: SizedBox.expand(),
                  ),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: progress),
                    duration: const Duration(milliseconds: 850),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, child) {
                      return FractionallySizedBox(
                        widthFactor: value,
                        child: child,
                      );
                    },
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            tierStartColor(rank.tier),
                            tierMiddleColor(rank.tier),
                            tierEndColor(rank.tier),
                          ],
                        ),
                      ),
                      child: const SizedBox.expand(),
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
}

class _NextMatchCard extends StatelessWidget {
  const _NextMatchCard({required this.match});

  final _FixtureSummary match;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4F46E5), Color(0xFF2563EB), Color(0xFF06B6D4)],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2563EB).withValues(alpha: 0.30),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            top: -48,
            right: -42,
            child: Container(
              width: 128,
              height: 128,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF67E8F9).withValues(alpha: 0.30),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF67E8F9).withValues(alpha: 0.35),
                    blurRadius: 30,
                    spreadRadius: 12,
                  ),
                ],
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'NEXT MATCH',
                      style: TextStyle(
                        color: Color(0xFFCFFAFE),
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          match.opponentEmblem,
                          style: const TextStyle(fontSize: 25),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'vs ${match.opponentName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        const Icon(
                          Icons.calendar_month_rounded,
                          color: Color(0xFFCFFAFE),
                          size: 13,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${match.dateLabel} · ${match.timeLabel}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFCFFAFE),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    match.daysAway.toString(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 40,
                      height: 0.95,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                  Text(
                    match.daysAway == 1 ? 'DAY' : 'DAYS',
                    style: const TextStyle(
                      color: Color(0xFFCFFAFE),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
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

class _TopPerformerCard extends StatelessWidget {
  const _TopPerformerCard({
    required this.icon,
    required this.label,
    required this.player,
    required this.value,
    required this.colors,
  });

  final IconData icon;
  final String label;
  final String? player;
  final String value;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      padding: const EdgeInsets.all(16),
      child: Stack(
        children: [
          Positioned(
            top: -16,
            left: -16,
            right: -16,
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: colors),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: colors,
                  ),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: Colors.white, size: 15),
              ),
              const SizedBox(height: 10),
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                player ?? '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScoringPanel extends StatelessWidget {
  const _ScoringPanel({required this.detail});

  final _ClanDetailData detail;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle(
            icon: Icons.track_changes_rounded,
            iconColor: Color(0xFFEA580C),
            iconBackground: Color(0xFFFFF7ED),
            title: 'Scoring',
            tracking: true,
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _ScoringStat(
                  value: detail.goalsFor.toString(),
                  label: 'For',
                  color: fieldEmerald600,
                ),
              ),
              Expanded(
                child: _ScoringStat(
                  value: detail.goalsAgainst.toString(),
                  label: 'Against',
                  color: const Color(0xFFEF4444),
                ),
              ),
              Expanded(
                child: _ScoringStat(
                  value: detail.goalDiffLabel,
                  label: 'Diff',
                  color: detail.goalDiff > 0
                      ? fieldEmerald600
                      : detail.goalDiff < 0
                      ? const Color(0xFFEF4444)
                      : fieldGray500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScoringStat extends StatelessWidget {
  const _ScoringStat({
    required this.value,
    required this.label,
    required this.color,
  });

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 26,
            height: 1,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: fieldGray500,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.1,
          ),
        ),
      ],
    );
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
          const _PanelTitle(
            icon: Icons.palette_rounded,
            iconColor: Color(0xFF7C3AED),
            iconBackground: Color(0xFFF5F3FF),
            title: 'Kit Identity',
          ),
          const SizedBox(height: 16),
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

class _RosterPanel extends StatelessWidget {
  const _RosterPanel({
    required this.members,
    required this.expectedCount,
    required this.isLoading,
    required this.errorText,
    required this.onRetry,
  });

  final List<ClanMember> members;
  final int expectedCount;
  final bool isLoading;
  final String? errorText;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final count = isLoading && members.isEmpty ? expectedCount : members.length;

    return _Panel(
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: _PanelTitle(
                  icon: Icons.group_rounded,
                  iconColor: fieldBlue600,
                  iconBackground: Color(0xFFEFF6FF),
                  title: 'Roster',
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: fieldGray100,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  count.toString(),
                  style: const TextStyle(
                    color: fieldGray600,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (isLoading && members.isEmpty)
            const Column(
              children: [
                _RosterSkeletonRow(),
                SizedBox(height: 12),
                _RosterSkeletonRow(),
                SizedBox(height: 12),
                _RosterSkeletonRow(),
              ],
            )
          else if (errorText != null)
            _RosterErrorState(message: errorText!, onRetry: onRetry)
          else if (members.isEmpty)
            const _DashedEmptyState(message: 'No members found yet.')
          else
            for (var i = 0; i < members.length; i++) ...[
              _MemberRow(member: members[i]),
              if (i != members.length - 1) const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member});

  final ClanMember member;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF34D399), Color(0xFF3B82F6)],
              ),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 7,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              member.initials,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        member.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: fieldGray900,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    if (member.isOwner) ...[
                      const SizedBox(width: 7),
                      const _OwnerBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  member.roleLabel,
                  style: const TextStyle(
                    color: fieldGray500,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RosterSkeletonRow extends StatelessWidget {
  const _RosterSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        FieldSkeletonBox(width: 42, height: 42, borderRadius: 999),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FieldSkeletonBox(height: 14, borderRadius: 6),
              SizedBox(height: 8),
              FieldSkeletonBox(width: 120, height: 12, borderRadius: 6),
            ],
          ),
        ),
        SizedBox(width: 12),
        FieldSkeletonBox(width: 58, height: 24, borderRadius: 999),
      ],
    );
  }
}

class _RosterErrorState extends StatelessWidget {
  const _RosterErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: fieldGray500,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: const Text('Try Again'),
          style: TextButton.styleFrom(
            foregroundColor: fieldEmerald600,
            textStyle: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }
}

class _OwnerBadge extends StatelessWidget {
  const _OwnerBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFBBF24), Color(0xFFF97316)],
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.workspace_premium_rounded, color: Colors.white, size: 10),
          SizedBox(width: 3),
          Text(
            'OWNER',
            style: TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.7,
            ),
          ),
        ],
      ),
    );
  }
}

class _MatchesTab extends StatelessWidget {
  const _MatchesTab({super.key, required this.clan, required this.detail});

  final Clan clan;
  final _ClanDetailData detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Panel(
          child: Column(
            children: [
              const _PanelTitle(
                icon: Icons.sports_mma_rounded,
                iconColor: fieldEmerald600,
                iconBackground: Color(0xFFECFDF5),
                title: 'Upcoming',
              ),
              const SizedBox(height: 16),
              if (detail.upcomingMatches.isEmpty)
                const _DashedEmptyState(message: 'No upcoming fixtures')
              else
                for (var i = 0; i < detail.upcomingMatches.length; i++) ...[
                  _UpcomingMatchRow(match: detail.upcomingMatches[i]),
                  if (i != detail.upcomingMatches.length - 1)
                    const SizedBox(height: 12),
                ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Panel(
          child: Column(
            children: [
              const _PanelTitle(
                icon: Icons.history_rounded,
                iconColor: fieldBlue600,
                iconBackground: Color(0xFFEFF6FF),
                title: 'History',
              ),
              const SizedBox(height: 16),
              if (detail.pastMatches.isEmpty)
                const _DashedEmptyState(message: 'No past matches yet')
              else
                for (var i = 0; i < detail.pastMatches.length; i++) ...[
                  _PastMatchCard(clan: clan, match: detail.pastMatches[i]),
                  if (i != detail.pastMatches.length - 1)
                    const SizedBox(height: 12),
                ],
            ],
          ),
        ),
      ],
    );
  }
}

class _UpcomingMatchRow extends StatelessWidget {
  const _UpcomingMatchRow({required this.match});

  final _FixtureSummary match;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: fieldGray100.withValues(alpha: 0.72),
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _OpponentAvatar(emblem: match.opponentEmblem),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'vs ${match.opponentName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: fieldGray900,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFECFDF5),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        match.dayShort,
                        style: const TextStyle(
                          color: fieldEmerald600,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(
                      Icons.calendar_month_rounded,
                      color: fieldGray500,
                      size: 12,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        '${match.dateLabel} • ${match.timeLabel}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: fieldGray500,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(
            Icons.chevron_right_rounded,
            color: fieldGray400,
            size: 20,
          ),
        ],
      ),
    );
  }
}

class _PastMatchCard extends StatelessWidget {
  const _PastMatchCard({required this.clan, required this.match});

  final Clan clan;
  final _FixtureSummary match;

  @override
  Widget build(BuildContext context) {
    final badgeColor = match.isCancelled
        ? const Color(0xFFB45309)
        : match.outcome == 'Victory'
        ? fieldEmerald600
        : match.outcome == 'Draw'
        ? fieldGray600
        : const Color(0xFFDC2626);
    final badgeBackground = match.isCancelled
        ? const Color(0xFFFFF7ED)
        : match.outcome == 'Victory'
        ? const Color(0xFFECFDF5)
        : match.outcome == 'Draw'
        ? fieldGray100
        : const Color(0xFFFEF2F2);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  match.dateLabel,
                  style: const TextStyle(
                    color: fieldGray400,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeBackground,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  match.outcome.toUpperCase(),
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (match.isCancelled)
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7ED),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.event_busy_rounded,
                    color: Color(0xFFEA580C),
                    size: 19,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    match.note ?? 'Match cancelled.',
                    style: const TextStyle(
                      color: fieldGray600,
                      fontSize: 13,
                      height: 1.3,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      _OpponentAvatar(emblem: clan.emblem, size: 32),
                      const SizedBox(width: 8),
                      Text(
                        match.myScore.toString(),
                        style: TextStyle(
                          color: match.outcome == 'Victory'
                              ? fieldGray900
                              : fieldGray500,
                          fontSize: 22,
                          height: 1,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
                const Text(
                  '-',
                  style: TextStyle(
                    color: fieldGray300,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        match.opponentScore.toString(),
                        style: TextStyle(
                          color: match.outcome == 'Defeat'
                              ? fieldGray900
                              : fieldGray500,
                          fontSize: 22,
                          height: 1,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _OpponentAvatar(emblem: match.opponentEmblem, size: 32),
                    ],
                  ),
                ),
              ],
            ),
          if (!match.isCancelled && match.srChange != null) ...[
            const SizedBox(height: 12),
            const Divider(color: fieldGray100, height: 1),
            const SizedBox(height: 10),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Rating Change',
                    style: TextStyle(
                      color: fieldGray500,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  match.srChange! > 0
                      ? Icons.trending_up_rounded
                      : match.srChange! < 0
                      ? Icons.trending_down_rounded
                      : Icons.remove_rounded,
                  color: match.srChange! > 0
                      ? fieldEmerald600
                      : match.srChange! < 0
                      ? const Color(0xFFEF4444)
                      : fieldGray500,
                  size: 15,
                ),
                const SizedBox(width: 4),
                Text(
                  '${match.srChange! > 0 ? '+' : ''}${match.srChange} SR',
                  style: TextStyle(
                    color: match.srChange! > 0
                        ? fieldEmerald600
                        : match.srChange! < 0
                        ? const Color(0xFFEF4444)
                        : fieldGray500,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _OpponentAvatar extends StatelessWidget {
  const _OpponentAvatar({required this.emblem, this.size = 40});

  final String emblem;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(emblem, style: TextStyle(fontSize: size * 0.52)),
    );
  }
}

class _DashedEmptyState extends StatelessWidget {
  const _DashedEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: fieldGray100.withValues(alpha: 0.66),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: fieldGray500,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle({
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.title,
    this.tracking = false,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String title;
  final bool tracking;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: iconBackground,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        const SizedBox(width: 10),
        Text(
          title.toUpperCase(),
          style: TextStyle(
            color: fieldGray900,
            fontSize: tracking ? 14 : 18,
            fontWeight: FontWeight.w900,
            letterSpacing: tracking ? 1.9 : 0,
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(20)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
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

class _ClanActionBar extends StatelessWidget {
  const _ClanActionBar({
    required this.isOwner,
    required this.isCurrentClan,
    required this.hasClan,
    required this.onPressed,
  });

  final bool isOwner;
  final bool isCurrentClan;
  final bool hasClan;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = isOwner || !hasClan;
    final icon = isOwner
        ? Icons.sports_mma_rounded
        : isCurrentClan
        ? Icons.verified_user_rounded
        : hasClan
        ? Icons.lock_rounded
        : Icons.group_add_rounded;
    final label = isOwner
        ? 'Schedule a Match'
        : isCurrentClan
        ? 'Clan Member'
        : hasClan
        ? 'Already in a Clan'
        : 'Request to Join';

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.88),
          border: const Border(top: BorderSide(color: fieldGray200)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: SizedBox(
          height: 56,
          width: double.infinity,
          child: Material(
            color: enabled ? fieldEmerald600 : fieldGray200,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: enabled ? onPressed : null,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: enabled
                      ? null
                      : Border.all(color: fieldGray300, width: 1.2),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      color: enabled ? Colors.white : fieldGray500,
                      size: 22,
                    ),
                    const SizedBox(width: 9),
                    Text(
                      label.toUpperCase(),
                      style: TextStyle(
                        color: enabled ? Colors.white : fieldGray500,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.9,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = fieldGray200
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    const dash = 7.0;
    const gap = 5.0;
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(14),
    );
    final path = Path()..addRRect(rect);

    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + dash), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) => false;
}

class _DivisionBounds {
  const _DivisionBounds({required this.min, required this.max});

  final int min;
  final int max;
}

_DivisionBounds _divisionBounds(ClanRank rank) {
  final tierMin = switch (rank.tier) {
    ClanTier.silver => 0,
    ClanTier.gold => 900,
    ClanTier.diamond => 1800,
    ClanTier.champion => 2700,
  };
  if (rank.division == null) {
    return _DivisionBounds(min: tierMin, max: 5000);
  }
  final index = 3 - rank.division!;
  return _DivisionBounds(
    min: tierMin + (index * 300),
    max: tierMin + ((index + 1) * 300) - 1,
  );
}

class _ClanDetailData {
  const _ClanDetailData({
    required this.recentForm,
    required this.goalsFor,
    required this.goalsAgainst,
    required this.members,
    required this.upcomingMatches,
    required this.pastMatches,
    this.nextMatch,
    this.topScorer,
    this.topAssister,
  });

  final List<String> recentForm;
  final int goalsFor;
  final int goalsAgainst;
  final List<ClanMember> members;
  final List<_FixtureSummary> upcomingMatches;
  final List<_FixtureSummary> pastMatches;
  final _FixtureSummary? nextMatch;
  final _TopPerformer? topScorer;
  final _TopPerformer? topAssister;

  int get goalDiff => goalsFor - goalsAgainst;

  String get goalDiffLabel => goalDiff > 0 ? '+$goalDiff' : goalDiff.toString();

  factory _ClanDetailData.fromClan(
    Clan clan, {
    required List<ClanMember> members,
    required List<Fixture> fixtures,
  }) {
    final recentForm = _recentFormFor(clan);
    final goalsFor = clan.wins == 0 && clan.losses == 0
        ? 0
        : (clan.wins * 3) + clan.losses;
    final goalsAgainst = clan.wins == 0 && clan.losses == 0
        ? 0
        : (clan.losses * 2) + (clan.wins ~/ 2);
    final upcomingMatches = _upcomingMatchesFor(clan, fixtures);
    final pastMatches = _pastMatchesFor(clan, fixtures);

    return _ClanDetailData(
      recentForm: recentForm,
      goalsFor: goalsFor,
      goalsAgainst: goalsAgainst,
      members: members,
      upcomingMatches: upcomingMatches,
      pastMatches: pastMatches,
      nextMatch: upcomingMatches.isEmpty ? null : upcomingMatches.first,
      topScorer: goalsFor > 0 && members.isNotEmpty
          ? _TopPerformer(
              playerName: members.first.displayName,
              value: '$goalsFor ${goalsFor == 1 ? 'goal' : 'goals'}',
            )
          : null,
      topAssister: goalsFor > 2 && members.isNotEmpty
          ? _TopPerformer(
              playerName: members.length > 1
                  ? members[1].displayName
                  : members.first.displayName,
              value: '${(goalsFor / 2).floor()} assists',
            )
          : null,
    );
  }
}

List<String> _recentFormFor(Clan clan) {
  final results = <String>[];
  var wins = clan.wins;
  var losses = clan.losses;
  while (results.length < 5 && (wins > 0 || losses > 0)) {
    if (wins > 0) {
      results.add('W');
      wins -= 1;
    }
    if (results.length < 5 && losses > 0) {
      results.add('L');
      losses -= 1;
    }
  }
  return results;
}

List<_FixtureSummary> _upcomingMatchesFor(Clan clan, List<Fixture> fixtures) {
  final upcoming =
      fixtures
          .where(
            (fixture) =>
                fixture.status == FixtureStatus.open ||
                fixture.status == FixtureStatus.scheduled ||
                fixture.status == FixtureStatus.live,
          )
          .toList()
        ..sort(_fixtureAscending);

  return [for (final fixture in upcoming) _summaryFromFixture(clan, fixture)];
}

List<_FixtureSummary> _pastMatchesFor(Clan clan, List<Fixture> fixtures) {
  final past =
      fixtures
          .where(
            (fixture) =>
                fixture.status == FixtureStatus.finalResult ||
                fixture.status == FixtureStatus.cancelled,
          )
          .toList()
        ..sort((a, b) => _fixtureAscending(b, a));

  return [for (final fixture in past) _summaryFromFixture(clan, fixture)];
}

int _fixtureAscending(Fixture a, Fixture b) {
  final dateCompare = a.matchDate.compareTo(b.matchDate);
  if (dateCompare != 0) return dateCompare;
  return a.timeSlot.compareTo(b.timeSlot);
}

_FixtureSummary _summaryFromFixture(Clan clan, Fixture fixture) {
  final opponent = fixture.opponentFor(clan.id);
  final isCancelled = fixture.status == FixtureStatus.cancelled;
  final myScore = fixture.scoreFor(clan.id);
  final opponentScore = opponent == null
      ? null
      : (fixture.homeClanId == clan.id ? fixture.awayScore : fixture.homeScore);
  final matchStart = DateTime(
    fixture.matchDate.year,
    fixture.matchDate.month,
    fixture.matchDate.day,
  );
  final today = DateTime.now();
  final todayDate = DateTime(today.year, today.month, today.day);
  final daysAway = matchStart.difference(todayDate).inDays;

  return _FixtureSummary(
    opponentName: opponent?.name ?? 'Awaiting opponent',
    opponentEmblem: opponent?.emblem ?? '?',
    dateLabel: fixture.monthDay,
    timeLabel: fixture.timeSlot,
    dayShort: fixture.dayShort,
    daysAway: daysAway < 0 ? 0 : daysAway,
    myScore: myScore ?? 0,
    opponentScore: opponentScore ?? 0,
    srChange: fixture.srChangeFor(clan.id),
    isCancelled: isCancelled,
    note: isCancelled
        ? fixture.cancellationReason ??
              'No opponent joined before the 24 hour cutoff.'
        : null,
  );
}

class _TopPerformer {
  const _TopPerformer({required this.playerName, required this.value});

  final String playerName;
  final String value;
}

class _FixtureSummary {
  const _FixtureSummary({
    required this.opponentName,
    required this.opponentEmblem,
    required this.dateLabel,
    required this.timeLabel,
    required this.dayShort,
    required this.daysAway,
    this.myScore = 0,
    this.opponentScore = 0,
    this.srChange,
    this.isCancelled = false,
    this.note,
  });

  final String opponentName;
  final String opponentEmblem;
  final String dateLabel;
  final String timeLabel;
  final String dayShort;
  final int daysAway;
  final int myScore;
  final int opponentScore;
  final int? srChange;
  final bool isCancelled;
  final String? note;

  String get outcome {
    if (isCancelled) return 'Cancelled';
    if (myScore > opponentScore) return 'Victory';
    if (myScore == opponentScore) return 'Draw';
    return 'Defeat';
  }
}
