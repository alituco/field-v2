import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
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
  DateTime? _selectedMatchDate;
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
      final fixtures = results[0] as List<Fixture>;
      setState(() {
        _fixtures = fixtures;
        _myClanMembership = results[1] as MyClanMembership?;
        _selectedMatchDate ??= _defaultMatchDate(fixtures);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = userFacingError(
          error,
          fallback: 'We could not load matches. Pull down to try again.',
        );
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<DateTime> get _calendarDates => _matchCalendarDates(_fixtures);

  List<Fixture> get _selectedDateFixtures {
    final selectedDate = _selectedMatchDate;
    if (selectedDate == null) return const [];

    return _fixtures
        .where((fixture) => _sameDay(fixture.matchDate, selectedDate))
        .toList();
  }

  List<Fixture> get _filteredFixtures {
    final fixtures = _selectedDateFixtures;
    if (_selectedStatus == null) return fixtures;
    return fixtures
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
    final calendarDates = _calendarDates;
    final selectedDate =
        _selectedMatchDate ??
        (calendarDates.isEmpty ? null : calendarDates.first);
    final selectedDateFixtures = _selectedDateFixtures;
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
            const _SectionLabel('Match Calendar'),
            const SizedBox(height: 10),
            _MatchDayCalendar(
              dates: calendarDates,
              selectedDate: selectedDate,
              fixtures: _fixtures,
              onSelected: (date) {
                setState(() {
                  _selectedMatchDate = date;
                  _selectedStatus = null;
                });
              },
            ),
            const SizedBox(height: 24),
            const _SectionLabel('Filter Matches'),
            const SizedBox(height: 10),
            FixtureStatusFilters(
              selectedStatus: _selectedStatus,
              fixtures: selectedDateFixtures,
              onSelected: (status) {
                setState(() => _selectedStatus = status);
              },
            ),
            const SizedBox(height: 24),
            _SectionLabel(
              selectedDate == null
                  ? 'No Match Day Selected'
                  : '${_longDateLabel(selectedDate)} - ${filteredFixtures.length} Match${filteredFixtures.length == 1 ? '' : 'es'}',
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

class _MatchDayCalendar extends StatefulWidget {
  const _MatchDayCalendar({
    required this.dates,
    required this.selectedDate,
    required this.fixtures,
    required this.onSelected,
  });

  final List<DateTime> dates;
  final DateTime? selectedDate;
  final List<Fixture> fixtures;
  final ValueChanged<DateTime> onSelected;

  @override
  State<_MatchDayCalendar> createState() => _MatchDayCalendarState();
}

class _MatchDayCalendarState extends State<_MatchDayCalendar> {
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _scrollSelectedIntoView(animated: false);
  }

  @override
  void didUpdateWidget(covariant _MatchDayCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameNullableDay(widget.selectedDate, oldWidget.selectedDate) ||
        widget.dates.length != oldWidget.dates.length) {
      _scrollSelectedIntoView(animated: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scrollSelectedIntoView({required bool animated}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients || widget.selectedDate == null) {
        return;
      }

      final index = widget.dates.indexWhere(
        (date) => _sameDay(date, widget.selectedDate!),
      );
      if (index < 0) return;

      final target = ((index - 1).clamp(0, widget.dates.length) * 92.0).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      );

      if (animated) {
        _controller.animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      } else {
        _controller.jumpTo(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.dates.isEmpty) {
      return const _StatePanel(
        icon: Icons.calendar_month_rounded,
        title: 'No match days',
        message: 'Tuesday and Thursday match days will show here.',
      );
    }

    return SizedBox(
      height: 104,
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: widget.dates.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final date = widget.dates[index];
          final selected =
              widget.selectedDate != null &&
              _sameDay(date, widget.selectedDate!);
          final count = widget.fixtures
              .where((fixture) => _sameDay(fixture.matchDate, date))
              .length;

          return _MatchDayChip(
            date: date,
            selected: selected,
            matchCount: count,
            onTap: () => widget.onSelected(date),
          );
        },
      ),
    );
  }
}

class _MatchDayChip extends StatelessWidget {
  const _MatchDayChip({
    required this.date,
    required this.selected,
    required this.matchCount,
    required this.onTap,
  });

  final DateTime date;
  final bool selected;
  final int matchCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 82,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            gradient: selected
                ? const LinearGradient(colors: [fieldEmerald500, fieldBlue600])
                : null,
            color: selected ? null : Colors.white,
            border: Border.all(
              color: selected ? Colors.transparent : fieldGray100,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: selected
                    ? fieldEmerald500.withValues(alpha: 0.22)
                    : fieldGray900.withValues(alpha: 0.035),
                blurRadius: selected ? 18 : 10,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _weekdayShort(date).toUpperCase(),
                style: TextStyle(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.82)
                      : fieldGray500,
                  fontSize: 10,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.7,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                date.day.toString(),
                style: TextStyle(
                  color: selected ? Colors.white : fieldGray900,
                  fontSize: 28,
                  height: 0.9,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _monthShort(date).toUpperCase(),
                    style: TextStyle(
                      color: selected
                          ? Colors.white.withValues(alpha: 0.82)
                          : fieldGray400,
                      fontSize: 10,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.7,
                    ),
                  ),
                  if (matchCount > 0) ...[
                    const SizedBox(width: 5),
                    Container(
                      width: 18,
                      height: 18,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? Colors.white.withValues(alpha: 0.20)
                            : fieldGray100,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        matchCount.toString(),
                        style: TextStyle(
                          color: selected ? Colors.white : fieldGray700,
                          fontSize: 10,
                          height: 1,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
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

DateTime? _defaultMatchDate(List<Fixture> fixtures) {
  final calendarDates = _matchCalendarDates(fixtures);
  if (calendarDates.isEmpty) return null;

  final today = _dateOnly(DateTime.now());
  final upcomingMatchDays =
      calendarDates
          .where((date) => _isEnabledMatchDay(date) && !date.isBefore(today))
          .toList()
        ..sort();
  if (upcomingMatchDays.isNotEmpty) return upcomingMatchDays.first;

  return calendarDates.first;
}

List<DateTime> _matchCalendarDates(List<Fixture> fixtures) {
  final datesByKey = <String, DateTime>{};
  final today = _dateOnly(DateTime.now());

  for (final fixture in fixtures) {
    final date = _dateOnly(fixture.matchDate);
    if (_isEnabledMatchDay(date)) {
      datesByKey[_dateKey(date)] = date;
    }
  }

  var cursor = today.subtract(const Duration(days: 1));
  var addedPast = 0;
  while (addedPast < 24) {
    if (_isEnabledMatchDay(cursor)) {
      datesByKey[_dateKey(cursor)] = cursor;
      addedPast += 1;
    }
    cursor = cursor.subtract(const Duration(days: 1));
  }

  cursor = today;
  var addedUpcoming = 0;
  while (addedUpcoming < 12) {
    if (_isEnabledMatchDay(cursor)) {
      datesByKey[_dateKey(cursor)] = cursor;
      addedUpcoming += 1;
    }
    cursor = cursor.add(const Duration(days: 1));
  }

  final dates = datesByKey.values.toList()..sort();
  return dates;
}

bool _isEnabledMatchDay(DateTime date) {
  return date.weekday == DateTime.tuesday || date.weekday == DateTime.thursday;
}

bool _sameNullableDay(DateTime? a, DateTime? b) {
  if (a == null || b == null) return a == b;
  return _sameDay(a, b);
}

bool _sameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

DateTime _dateOnly(DateTime date) {
  return DateTime(date.year, date.month, date.day);
}

String _dateKey(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

String _longDateLabel(DateTime date) {
  return '${_weekdayName(date)}, ${_monthShort(date)} ${date.day}';
}

String _weekdayShort(DateTime date) {
  return _weekdayName(date).substring(0, 3);
}

String _weekdayName(DateTime date) {
  const weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  return weekdays[date.weekday - 1];
}

String _monthShort(DateTime date) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return months[date.month - 1];
}
