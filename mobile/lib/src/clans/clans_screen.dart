import 'package:flutter/material.dart';

import '../ui/field_loading.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture_repository.dart';
import 'clan.dart';
import 'clan_detail_screen.dart';
import 'clan_repository.dart';
import 'clan_widgets.dart';
import 'create_clan_screen.dart';

enum _ClansViewMode { mine, browse }

class ClansScreen extends StatefulWidget {
  const ClansScreen({
    super.key,
    required this.clanRepository,
    required this.fixtureRepository,
    this.activationTick = 0,
  });

  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;
  final int activationTick;

  @override
  State<ClansScreen> createState() => _ClansScreenState();
}

class _ClansScreenState extends State<ClansScreen> {
  final _searchController = TextEditingController();
  List<Clan> _clans = const [];
  ClanMembership? _myMembership;
  _ClansViewMode? _viewMode;
  bool _isLoading = true;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _loadClans();
  }

  @override
  void didUpdateWidget(covariant ClansScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activationTick != oldWidget.activationTick) {
      _defaultToMyClan();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadClans() async {
    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final clans = await widget.clanRepository.listClans();
      final membership = await widget.clanRepository.getMyClanMembership();
      if (!mounted) return;
      setState(() {
        final previousMembership = _myMembership;
        _clans = clans;
        _myMembership = membership;
        if (membership == null) {
          _viewMode = _ClansViewMode.browse;
        } else if (previousMembership?.clanId != membership.clanId) {
          _viewMode = _ClansViewMode.mine;
        } else {
          _viewMode ??= _ClansViewMode.mine;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = userFacingError(
          error,
          fallback: 'We could not load clans. Pull down to try again.',
        );
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _openCreateClan() async {
    final created = await Navigator.of(context).push<Clan>(
      MaterialPageRoute(
        builder: (context) =>
            CreateClanScreen(clanRepository: widget.clanRepository),
      ),
    );
    if (created == null || !mounted) return;
    setState(() {
      _clans = [created, ..._clans];
      _myMembership = ClanMembership(clanId: created.id, role: 'owner');
      _viewMode = _ClansViewMode.mine;
    });
  }

  List<Clan> get _filteredClans {
    final query = _searchController.text.trim().toLowerCase();
    final browseClans = [
      for (final clan in _clans)
        if (clan.id != _myMembership?.clanId) clan,
    ];
    if (query.isEmpty) return browseClans;
    return browseClans.where((clan) {
      return clan.name.toLowerCase().contains(query) ||
          clan.tag.toLowerCase().contains(query);
    }).toList();
  }

  Clan? get _myClan {
    final membership = _myMembership;
    if (membership == null) return null;
    for (final clan in _clans) {
      if (clan.id == membership.clanId) return clan;
    }
    return null;
  }

  void _defaultToMyClan() {
    if (_myMembership == null || _myClan == null) return;
    setState(() => _viewMode = _ClansViewMode.mine);
  }

  Future<void> _openClan(Clan clan) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ClanDetailScreen(
          clan: clan,
          clanRepository: widget.clanRepository,
          fixtureRepository: widget.fixtureRepository,
          currentMembership: _myMembership,
        ),
      ),
    );
    if (mounted) {
      await _loadClans();
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredClans = _filteredClans;
    final myClan = _myClan;
    final hasClan = _myMembership != null;
    final viewMode = myClan == null
        ? _ClansViewMode.browse
        : (_viewMode ?? _ClansViewMode.mine);
    final showingMyClan = viewMode == _ClansViewMode.mine && myClan != null;
    final recruitingCount = _clans
        .where((clan) => clan.memberCount < 11)
        .length;

    return FieldHeaderOverlay(
      header: FieldPageHeader(
        title: 'Clans',
        rightAction: hasClan
            ? null
            : HeaderActionButton(
                icon: Icons.add_rounded,
                label: 'New',
                onPressed: _openCreateClan,
              ),
      ),
      child: FieldRefreshIndicator(
        color: fieldEmerald600,
        edgeOffset: fieldPageHeaderExtent(context),
        onRefresh: _loadClans,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: fieldHeaderAwarePadding(context, top: 24, bottom: 124),
          children: [
            if (_isLoading)
              const _ClansLoadingState()
            else if (_errorText != null)
              _ClansErrorState(message: _errorText!, onRetry: _loadClans)
            else ...[
              if (!showingMyClan) ...[
                FieldHeroBanner(
                  eyebrow: myClan == null
                      ? 'Squads · Brotherhoods · Rivals'
                      : 'Your Squad · Your Record · Your Identity',
                  title: myClan == null ? 'Find your tribe.' : myClan.name,
                  subtitle: myClan == null
                      ? 'Join an elite squad or forge a new dynasty of your own.'
                      : myClan.motto.isEmpty
                      ? 'Your clan hub is ready.'
                      : myClan.motto,
                  icon: Icons.shield_rounded,
                  chips: [
                    HeroChip(label: 'Clans', value: _clans.length.toString()),
                    if (myClan != null)
                      HeroChip(
                        label: 'SR',
                        value: myClan.skillRating.toString(),
                      )
                    else
                      HeroChip(
                        label: 'Recruiting',
                        value: recruitingCount.toString(),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
              ],
              if (myClan != null) ...[
                _ClanViewSwitcher(
                  selectedMode: viewMode,
                  onChanged: (mode) => setState(() => _viewMode = mode),
                ),
                const SizedBox(height: 20),
              ],
              if (viewMode == _ClansViewMode.mine && myClan != null)
                _MyClanPanel(
                  clan: myClan,
                  membership: _myMembership!,
                  onOpen: () => _openClan(myClan),
                )
              else ...[
                _SearchBox(controller: _searchController),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${filteredClans.length} Clan${filteredClans.length == 1 ? '' : 's'}'
                          .toUpperCase(),
                      style: const TextStyle(
                        color: fieldGray600,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.7,
                      ),
                    ),
                    if (myClan != null)
                      const Text(
                        '',
                        style: TextStyle(
                          color: fieldGray400,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (filteredClans.isEmpty)
                  _ClansEmptyState(
                    hasSearch: _searchController.text.trim().isNotEmpty,
                    onCreate: _openCreateClan,
                    canCreate: !hasClan,
                  )
                else
                  for (var i = 0; i < filteredClans.length; i++) ...[
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: Duration(milliseconds: 280 + (i * 45)),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, child) {
                        return Opacity(
                          opacity: value,
                          child: Transform.translate(
                            offset: Offset(0, 10 * (1 - value)),
                            child: child,
                          ),
                        );
                      },
                      child: ClanCard(
                        clan: filteredClans[i],
                        onTap: () => _openClan(filteredClans[i]),
                      ),
                    ),
                    if (i != filteredClans.length - 1)
                      const SizedBox(height: 12),
                  ],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search clans...',
        prefixIcon: const Icon(Icons.search_rounded, color: fieldGray400),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                onPressed: controller.clear,
                icon: const Icon(Icons.close_rounded, color: fieldGray500),
                tooltip: 'Clear search',
              ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderSide: const BorderSide(color: fieldGray200),
          borderRadius: BorderRadius.circular(12),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: fieldGray200),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

class _ClanViewSwitcher extends StatelessWidget {
  const _ClanViewSwitcher({
    required this.selectedMode,
    required this.onChanged,
  });

  final _ClansViewMode selectedMode;
  final ValueChanged<_ClansViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.78),
        border: Border.all(color: fieldGray200),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: fieldGray900.withValues(alpha: 0.04),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          _ClanViewSwitcherButton(
            icon: Icons.shield_rounded,
            label: 'My Clan',
            selected: selectedMode == _ClansViewMode.mine,
            onTap: () => onChanged(_ClansViewMode.mine),
          ),
          _ClanViewSwitcherButton(
            icon: Icons.travel_explore_rounded,
            label: 'Browse Clans',
            selected: selectedMode == _ClansViewMode.browse,
            onTap: () => onChanged(_ClansViewMode.browse),
          ),
        ],
      ),
    );
  }
}

class _ClanViewSwitcherButton extends StatelessWidget {
  const _ClanViewSwitcherButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: selected
                ? const LinearGradient(colors: [fieldEmerald500, fieldBlue600])
                : null,
            color: selected ? null : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: fieldEmerald600.withValues(alpha: 0.20),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? Colors.white : fieldGray500,
              ),
              const SizedBox(width: 7),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? Colors.white : fieldGray600,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MyClanPanel extends StatelessWidget {
  const _MyClanPanel({
    required this.clan,
    required this.membership,
    required this.onOpen,
  });

  final Clan clan;
  final ClanMembership membership;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final rank = clan.rank;
    final height =
        (MediaQuery.sizeOf(context).height -
                fieldPageHeaderExtent(context) -
                210)
            .clamp(500.0, 620.0)
            .toDouble();

    return SizedBox(
      height: height,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(26),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(26),
          child: Ink(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: fieldGray200),
              borderRadius: BorderRadius.circular(26),
              boxShadow: [
                BoxShadow(
                  color: fieldGray900.withValues(alpha: 0.07),
                  blurRadius: 26,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: Column(
                children: [
                  Expanded(
                    flex: 6,
                    child: Container(
                      width: double.infinity,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            fieldGray900,
                            Color(0xFF172033),
                            Color(0xFF0F172A),
                          ],
                        ),
                      ),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _NeutralFieldLinePainter(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                          ),
                          Positioned(
                            top: -84,
                            right: -42,
                            child: Container(
                              width: 210,
                              height: 210,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 92,
                                      height: 92,
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: 0.12,
                                        ),
                                        border: Border.all(
                                          color: Colors.white.withValues(
                                            alpha: 0.18,
                                          ),
                                          width: 1.2,
                                        ),
                                        borderRadius: BorderRadius.circular(24),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withValues(
                                              alpha: 0.12,
                                            ),
                                            blurRadius: 18,
                                            offset: const Offset(0, 10),
                                          ),
                                        ],
                                      ),
                                      child: Center(
                                        child: Text(
                                          clan.emblem,
                                          style: const TextStyle(fontSize: 52),
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        DivisionCrest(division: rank, size: 52),
                                        const SizedBox(height: 10),
                                        _MyClanRoleBadge(
                                          role: membership.role,
                                          onDark: true,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const Spacer(),
                                _OpenClanIndicator(onDark: true),
                                const SizedBox(height: 16),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        clan.name,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 36,
                                          height: 0.98,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 0,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 7,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: 0.12,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: Colors.white.withValues(
                                            alpha: 0.18,
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        clan.tag,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 1.1,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  clan.motto.isEmpty ? 'Clan hub' : clan.motto,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.72),
                                    fontSize: 15,
                                    height: 1.3,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _MyClanRatingStrip(clan: clan, rank: rank),
                          Row(
                            children: [
                              Expanded(
                                child: _MyClanStat(
                                  value: clan.memberCount.toString(),
                                  label: clan.memberCount == 1
                                      ? 'Member'
                                      : 'Members',
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _MyClanStat(
                                  value: clan.wins.toString(),
                                  label: 'Wins',
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _MyClanStat(
                                  value: '${clan.winRate}%',
                                  label: 'Win %',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NeutralFieldLinePainter extends CustomPainter {
  const _NeutralFieldLinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawLine(
      Offset(size.width * 0.5, 0),
      Offset(size.width * 0.5, size.height),
      paint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.5, size.height * 0.5),
      size.width * 0.18,
      paint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.5, size.height * 0.5),
      3,
      paint..style = PaintingStyle.fill,
    );
    paint.style = PaintingStyle.stroke;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-24, size.height * 0.22, 92, size.height * 0.56),
        const Radius.circular(24),
      ),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width - 68,
          size.height * 0.22,
          92,
          size.height * 0.56,
        ),
        const Radius.circular(24),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _NeutralFieldLinePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _MyClanRatingStrip extends StatelessWidget {
  const _MyClanRatingStrip({required this.clan, required this.rank});

  final Clan clan;
  final RatingDivision rank;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: fieldGray100,
        border: Border.all(color: fieldGray200),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: fieldGray200),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.trending_up_rounded,
              color: fieldEmerald600,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Skill Rating',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fieldGray900,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Text(
                      clan.skillRating.toString(),
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 20,
                        height: 1,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: SizedBox(
                    height: 7,
                    child: Stack(
                      children: [
                        const DecoratedBox(
                          decoration: BoxDecoration(color: fieldGray200),
                          child: SizedBox.expand(),
                        ),
                        FractionallySizedBox(
                          widthFactor: clan.ratingProgress,
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
                const SizedBox(height: 8),
                DivisionLabelBadge(division: rank, small: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OpenClanIndicator extends StatelessWidget {
  const _OpenClanIndicator({this.onDark = false});

  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final foreground = onDark ? fieldGray900 : Colors.white;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: onDark ? Colors.white : fieldGray900,
          border: Border.all(
            color: onDark ? Colors.white.withValues(alpha: 0.28) : fieldGray900,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'TAP TO OPEN',
              style: TextStyle(
                color: foreground,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.9,
              ),
            ),
            const SizedBox(width: 5),
            Icon(
              Icons.arrow_forward_rounded,
              color: foreground.withValues(alpha: 0.92),
              size: 17,
            ),
          ],
        ),
      ),
    );
  }
}

class _MyClanRoleBadge extends StatelessWidget {
  const _MyClanRoleBadge({required this.role, this.onDark = false});

  final String role;
  final bool onDark;

  String get label => switch (role) {
    'owner' => 'OWNER',
    'leader' => 'LEADER',
    _ => 'MEMBER',
  };

  @override
  Widget build(BuildContext context) {
    if (onDark) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.8,
          ),
        ),
      );
    }

    final isManager = role == 'owner' || role == 'leader';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isManager ? const Color(0xFFECFDF5) : fieldGray100,
        border: Border.all(
          color: isManager ? const Color(0xFFA7F3D0) : fieldGray200,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isManager ? fieldEmerald600 : fieldGray600,
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _MyClanStat extends StatelessWidget {
  const _MyClanStat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 76,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fieldGray100,
        border: Border.all(color: fieldGray200),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: const TextStyle(
                color: fieldGray900,
                fontSize: 26,
                height: 1,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _ClansLoadingState extends StatelessWidget {
  const _ClansLoadingState();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 3; i++) ...[
          FieldSkeletonCard(
            height: 94,
            borderRadius: 14,
            children: const [
              Row(
                children: [
                  FieldSkeletonBox(width: 50, height: 50, borderRadius: 14),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FieldSkeletonBox(height: 16, borderRadius: 6),
                        SizedBox(height: 9),
                        FieldSkeletonBox(
                          width: 120,
                          height: 12,
                          borderRadius: 6,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 12),
                  FieldSkeletonBox(width: 46, height: 30, borderRadius: 10),
                ],
              ),
            ],
          ),
          if (i != 2) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _ClansErrorState extends StatelessWidget {
  const _ClansErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _StatePanel(
      icon: Icons.warning_amber_rounded,
      title: 'Clans are not ready yet',
      message: message,
      actionLabel: 'Try again',
      onAction: onRetry,
    );
  }
}

class _ClansEmptyState extends StatelessWidget {
  const _ClansEmptyState({
    required this.hasSearch,
    required this.onCreate,
    required this.canCreate,
  });

  final bool hasSearch;
  final VoidCallback onCreate;
  final bool canCreate;

  @override
  Widget build(BuildContext context) {
    final isBrowseOnly = !hasSearch && !canCreate;

    return _StatePanel(
      icon: hasSearch
          ? Icons.search_off_rounded
          : isBrowseOnly
          ? Icons.visibility_rounded
          : Icons.shield_outlined,
      title: hasSearch
          ? 'No clans found'
          : isBrowseOnly
          ? 'No other clans'
          : 'No clans yet',
      message: hasSearch
          ? 'Try a different name or tag.'
          : isBrowseOnly
          ? 'You are already in a clan, so browsing is view only.'
          : 'Forge the first clan and take the top of the table.',
      actionLabel: hasSearch ? null : 'Create clan',
      onAction: hasSearch || !canCreate ? null : onCreate,
    );
  }
}

class _StatePanel extends StatelessWidget {
  const _StatePanel({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray200),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, color: fieldEmerald600, size: 34),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 14,
              height: 1.35,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.add_rounded),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
