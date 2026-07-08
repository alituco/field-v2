import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import 'create_fixture_screen.dart';
import 'fixture.dart';
import 'fixture_detail_screen.dart';
import 'fixture_repository.dart';
import 'fixture_widgets.dart';

class FixturesScreen extends StatefulWidget {
  const FixturesScreen({super.key, required this.fixtureRepository});

  final FixtureRepository fixtureRepository;

  @override
  State<FixturesScreen> createState() => _FixturesScreenState();
}

class _FixturesScreenState extends State<FixturesScreen> {
  List<Fixture> _fixtures = const [];
  MyClanMembership? _myClanMembership;
  FixtureStatus? _selectedStatus;
  bool _isLoading = true;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final results = await Future.wait([
        widget.fixtureRepository.listFixtures(),
        widget.fixtureRepository.getMyClanMembership(),
      ]);
      if (!mounted) return;
      setState(() {
        _fixtures = results[0] as List<Fixture>;
        _myClanMembership = results[1] as MyClanMembership?;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText =
            'Could not load fixtures. Make sure the fixtures migration is applied.';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<Fixture> get _filteredFixtures {
    if (_selectedStatus == null) return _fixtures;
    return _fixtures
        .where((fixture) => fixture.status == _selectedStatus)
        .toList();
  }

  Future<void> _openCreateMatch() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => CreateFixtureScreen(
          fixtureRepository: widget.fixtureRepository,
          myClanMembership: _myClanMembership,
        ),
      ),
    );
    if (changed == true && mounted) {
      await _load();
    }
  }

  Future<void> _openFixture(Fixture fixture) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => FixtureDetailScreen(
          fixture: fixture,
          fixtureRepository: widget.fixtureRepository,
          myClanMembership: _myClanMembership,
        ),
      ),
    );
    if (changed == true && mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredFixtures = _filteredFixtures;

    return FieldHeaderOverlay(
      header: FieldPageHeader(
        title: 'Fixtures',
        rightAction: HeaderActionButton(
          icon: Icons.add_rounded,
          label: 'Host',
          tone: HeaderActionTone.pink,
          onPressed: _openCreateMatch,
        ),
      ),
      child: RefreshIndicator(
        color: fieldEmerald600,
        edgeOffset: fieldPageHeaderExtent(context),
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: fieldHeaderAwarePadding(context, top: 24, bottom: 124),
          children: [
            FixtureHeroBanner(fixtures: _fixtures),
            const SizedBox(height: 24),
            const _SectionLabel('Filter Matches'),
            const SizedBox(height: 10),
            FixtureStatusFilters(
              selectedStatus: _selectedStatus,
              fixtures: _fixtures,
              onSelected: (status) {
                setState(() => _selectedStatus = status);
              },
            ),
            const SizedBox(height: 24),
            _SectionLabel(
              '${filteredFixtures.length} Match${filteredFixtures.length == 1 ? '' : 'es'}',
            ),
            const SizedBox(height: 12),
            if (_isLoading)
              const _FixturesLoadingState()
            else if (_errorText != null)
              _FixturesErrorState(message: _errorText!, onRetry: _load)
            else if (filteredFixtures.isEmpty)
              const _FixturesEmptyState()
            else
              for (var i = 0; i < filteredFixtures.length; i++) ...[
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: Duration(milliseconds: 240 + (i * 50)),
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
                  child: FixtureCard(
                    fixture: filteredFixtures[i],
                    onTap: () => _openFixture(filteredFixtures[i]),
                  ),
                ),
                if (i != filteredFixtures.length - 1)
                  const SizedBox(height: 12),
              ],
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: fieldGray600,
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
    );
  }
}

class _FixturesLoadingState extends StatelessWidget {
  const _FixturesLoadingState();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 3; i++) ...[
          Container(
            height: 156,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: fieldGray100),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: fieldGray900.withValues(alpha: 0.025),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      FieldSkeletonBox(
                        width: 86,
                        height: 24,
                        borderRadius: 999,
                      ),
                      Spacer(),
                      FieldSkeletonBox(
                        width: 74,
                        height: 20,
                        borderRadius: 999,
                      ),
                    ],
                  ),
                  SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: FieldSkeletonBox(height: 18, borderRadius: 6),
                      ),
                      SizedBox(width: 24),
                      FieldSkeletonBox(width: 34, height: 18, borderRadius: 6),
                      SizedBox(width: 24),
                      Expanded(
                        child: FieldSkeletonBox(height: 18, borderRadius: 6),
                      ),
                    ],
                  ),
                  Spacer(),
                  FieldSkeletonBox(height: 14, borderRadius: 6),
                  SizedBox(height: 10),
                  FieldSkeletonBox(width: 180, height: 12, borderRadius: 6),
                ],
              ),
            ),
          ),
          if (i != 2) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _FixturesErrorState extends StatelessWidget {
  const _FixturesErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _StatePanel(
      icon: Icons.warning_rounded,
      title: 'Fixtures unavailable',
      message: message,
      actionLabel: 'Try Again',
      onAction: onRetry,
    );
  }
}

class _FixturesEmptyState extends StatelessWidget {
  const _FixturesEmptyState();

  @override
  Widget build(BuildContext context) {
    return const _StatePanel(
      icon: Icons.sports_mma_rounded,
      title: 'No matches yet',
      message: 'Host a match to put the first fixture on the board.',
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
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray200),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(icon, color: fieldEmerald600, size: 34),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 14,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}
