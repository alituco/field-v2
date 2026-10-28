import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/read_timeout.dart';
import '../core/user_facing_error.dart';
import '../home/field_bottom_nav.dart';
import '../open_queue/open_queue.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_toast.dart';
import 'reliability.dart';
import 'reliability_repository.dart';

class FieldrushReliabilityScreen extends StatefulWidget {
  const FieldrushReliabilityScreen({
    super.key,
    required this.repository,
    this.onNavigateTab,
  });

  final ReliabilityRepository repository;
  final ValueChanged<int>? onNavigateTab;

  @override
  State<FieldrushReliabilityScreen> createState() =>
      _FieldrushReliabilityScreenState();
}

class _FieldrushReliabilityScreenState
    extends State<FieldrushReliabilityScreen> {
  ReliabilityStatus? _status;
  String? _error;
  bool _loading = true;
  bool _excusedOpen = false;
  bool _pastOpen = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant FieldrushReliabilityScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      _status = null;
      _excusedOpen = false;
      _pastOpen = false;
      _load();
    }
  }

  @override
  void dispose() {
    _request++;
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await widget.repository.getMyStatus().timeout(
        fieldReadTimeout,
      );
      if (!mounted || request != _request) return;
      setState(() => _status = status);
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(
        () => _error = userFacingError(
          error,
          fallback: 'Could not load your reliability record. Try again.',
        ),
      );
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _appeal(ReliabilityIncident incident) async {
    if (!incident.canAppeal ||
        incident.appealPending ||
        incident.attendanceRecordId.isEmpty) {
      return;
    }
    final submitted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _ReliabilityAppealScreen(
          repository: widget.repository,
          incident: incident,
          onNavigateTab: widget.onNavigateTab,
        ),
      ),
    );
    if (!mounted || submitted != true) return;
    showFieldrushToast(
      context,
      'Appeal sent. We’ll let you know when it’s reviewed.',
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Scaffold(
      extendBody: true,
      backgroundColor: FieldrushAuthTheme.cream,
      bottomNavigationBar: widget.onNavigateTab == null
          ? null
          : FieldBottomNav(
              selectedIndex: 4,
              onSelected: (index) =>
                  _navigateTab(context, widget.onNavigateTab!, index),
            ),
      body: SafeArea(
        bottom: false,
        child: FieldRefreshIndicator(
          onRefresh: _load,
          color: FieldrushAuthTheme.forest,
          child: ListView(
            key: const ValueKey('reliability-page-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 18, bottom: 132),
            children: [
              _header(context, 'Reliability'),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: Row(
                    children: [
                      Expanded(child: Text(_error!, style: _jakarta(12))),
                      TextButton(
                        onPressed: _loading ? null : _load,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              if (_status case final status?)
                ..._record(status)
              else if (_loading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: Semantics(
                    label: 'Loading reliability record',
                    liveRegion: true,
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FieldSkeleton(height: 176, radius: 22),
                        SizedBox(height: 22),
                        FieldSkeleton(width: 140, height: 12),
                        SizedBox(height: 12),
                        FieldSkeleton(height: 100, radius: 20),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  List<Widget> _record(ReliabilityStatus status) {
    final now = status.serverNow ?? DateTime.now().toUtc();
    final active = status.incidents.where((i) => i.isActiveAt(now)).toList();
    final excused = status.incidents.where((i) => i.excused).toList();
    final past = status.incidents
        .where(
          (i) =>
              !i.excused &&
              !i.isActiveAt(now) &&
              (i.strikeDelta > 0 || i.originalOutcome != null),
        )
        .toList();
    return [
      _StandingCard(status: status),
      if (status.activeStrikes > 0) ...[
        _section('ACTIVE STRIKES', trailing: '${status.activeStrikes}'),
        if (active.isNotEmpty)
          _group([
            for (final incident in active)
              _IncidentRow(
                incident: incident,
                onAppeal: () => _appeal(incident),
              ),
          ])
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 11, 20, 0),
            child: Text(
              'Your total includes earlier active attendance decisions.',
              style: _jakarta(11.5),
            ),
          ),
        if (active.fold(0, (total, i) => total + i.strikeDelta) <
                status.activeStrikes &&
            active.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Text(
              'Recent decisions are shown here. Your total includes all active strikes.',
              style: _jakarta(11.5),
            ),
          ),
      ],
      if (excused.isNotEmpty)
        _historyGroup(
          'Excused',
          excused,
          _excusedOpen,
          () => setState(() => _excusedOpen = !_excusedOpen),
          excused: true,
        ),
      if (past.isNotEmpty)
        _historyGroup(
          'Past strikes',
          past,
          _pastOpen,
          () => setState(() => _pastOpen = !_pastOpen),
        ),
      if (status.policyDisplay case final policy?)
        ..._rules(policy)
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
          child: Text(
            'Each booking shows its attendance and cancellation terms before you pay.',
            style: _jakarta(11.5),
          ),
        ),
    ];
  }

  Widget _historyGroup(
    String title,
    List<ReliabilityIncident> incidents,
    bool open,
    VoidCallback toggle, {
    bool excused = false,
  }) => Container(
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    decoration: _cardDecoration(),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        Semantics(
          expanded: open,
          child: InkWell(
            onTap: toggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: _jakarta(
                          13,
                          weight: FontWeight.w700,
                          color: FieldrushAuthTheme.ink,
                        ),
                      ),
                    ),
                    Text('${incidents.length}', style: _jakarta(11.5)),
                    const SizedBox(width: 10),
                    Icon(
                      open ? Icons.keyboard_arrow_down : Icons.chevron_right,
                      size: 16,
                      color: FieldrushAuthTheme.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (open)
          for (final incident in incidents) ...[
            const Divider(height: 1, thickness: 1, color: _divider),
            _IncidentRow(incident: incident, inactive: true, excused: excused),
          ],
      ],
    ),
  );

  List<Widget> _rules(ReliabilityPolicyDisplay policy) {
    final cancellations = [...policy.cancellationRules];
    final late = cancellations.where((r) => r.code == 'late').firstOrNull;
    final veryLate = cancellations
        .where((r) => r.code == 'veryLate')
        .firstOrNull;
    final combineLate =
        late != null && veryLate != null && late.strikes == veryLate.strikes;
    final sanctions = policy.sanctions
        .where((r) => r.kind != 'WARNING')
        .toList();
    final bookingRestrictions = sanctions
        .where((r) => r.kind == 'BOOKING_RESTRICTION')
        .toList();
    final retainBookings =
        bookingRestrictions.isNotEmpty &&
        bookingRestrictions.every((r) => !r.releaseFutureBookings);
    return [
      _section('WHAT GETS A STRIKE'),
      _group([
        _rule(
          'Arriving at or after check-in closes',
          _strikes(policy.lateStrikes),
          danger: true,
        ),
        _rule('No-show', _strikes(policy.noShowStrikes), danger: true),
        for (final rule in cancellations)
          if (!(combineLate && rule.code == 'veryLate'))
            _rule(
              rule.code == 'afterKickoff'
                  ? 'Cancelling after kickoff'
                  : rule.code == 'late' && !combineLate
                  ? 'Cancelling ${rule.minimumHoursBeforeKickoff}–${rule.maximumHoursBeforeKickoff} hours before kickoff'
                  : 'Cancelling inside ${rule.maximumHoursBeforeKickoff} hours',
              _strikes(rule.strikes),
              danger: true,
            ),
      ]),
      _section('WHAT HAPPENS', top: 16),
      _group([
        if (policy.depositThreshold > 0 && policy.depositBps > 0)
          _rule(
            '${policy.depositThreshold} strikes',
            '${_percentage(policy.depositBps)} refundable deposit',
          ),
        for (final rule in sanctions)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 46),
              child: Row(
                children: [
                  ExcludeSemantics(
                    child: _dots(rule.threshold, _meterSize(policy)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${rule.threshold} strikes',
                      style: _jakarta(
                        13,
                        color: FieldrushAuthTheme.ink,
                        weight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    flex: 2,
                    child: Text(
                      _sanctionLabel(rule),
                      textAlign: TextAlign.end,
                      style: _jakarta(
                        12,
                        color: rule.kind == 'INDEFINITE_SUSPENSION'
                            ? FieldrushAuthTheme.danger
                            : FieldrushAuthTheme.ink,
                        weight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
          color: const Color(0xFFFBFAF4),
          child: Text(
            '${policy.strikeLifetimeDays > 0 ? 'Strikes clear after ${policy.strikeLifetimeDays} days. ' : ''}'
            '${retainBookings ? 'A booking restriction keeps existing bookings active. ' : ''}'
            'Each booking retains the rules shown when you joined.',
            style: _jakarta(11.5).copyWith(height: 1.5),
          ),
        ),
      ]),
    ];
  }
}

class _StandingCard extends StatelessWidget {
  const _StandingCard({required this.status});
  final ReliabilityStatus status;

  @override
  Widget build(BuildContext context) {
    final indefinite = status.indefiniteSuspension;
    final until =
        status.participationSuspendedUntil ?? status.bookingRestrictedUntil;
    final restricted = until != null || indefinite;
    final meterSize = _meterSize(status.policyDisplay);
    final title = indefinite
        ? 'Your participation is suspended'
        : status.participationSuspendedUntil != null
        ? 'You can’t play right now'
        : status.bookingRestrictedUntil != null
        ? 'You can’t book new games'
        : status.depositRequired
        ? 'Reliability deposit required'
        : status.activeStrikes > 0
        ? 'Good standing'
        : 'Spotless';
    final eyebrow = indefinite
        ? 'PENDING MANUAL REVIEW'
        : until != null
        ? 'RESTRICTED UNTIL ${_date(until, status.timezone).toUpperCase()}'
        : 'YOUR STANDING';
    return Container(
      key: const ValueKey('reliability-standing-card'),
      margin: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      decoration: BoxDecoration(
        color: indefinite
            ? FieldrushAuthTheme.ink
            : restricted
            ? FieldrushAuthTheme.danger
            : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: restricted
            ? null
            : Border.all(color: FieldrushAuthTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow,
            style: _jakarta(
              10,
              weight: FontWeight.w800,
              color: indefinite
                  ? const Color(0xFFF2A7A9)
                  : restricted
                  ? const Color(0xFFF7D9D9)
                  : FieldrushAuthTheme.muted,
            ).copyWith(letterSpacing: 1.4),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            style: _outfit(
              restricted ? 23 : 24,
              color: restricted ? Colors.white : const Color(0xFF24472C),
            ).copyWith(height: 1.1, letterSpacing: -.48),
          ),
          const SizedBox(height: 8),
          Text(
            status.supportingText,
            style: _jakarta(
              12.5,
              color: indefinite
                  ? const Color(0xFFD5DCD2)
                  : restricted
                  ? const Color(0xFFF7E3E3)
                  : const Color(0xFF3C4A38),
            ).copyWith(height: 1.45),
          ),
          const SizedBox(height: 16),
          Semantics(
            label: '${status.activeStrikes} active strikes',
            child: ExcludeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < meterSize; i++) ...[
                    if (i > 0) const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Container(
                            height: 8,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              color: i < status.activeStrikes
                                  ? indefinite
                                        ? const Color(0xFFE5484D)
                                        : restricted
                                        ? Colors.white
                                        : FieldrushAuthTheme.danger
                                  : restricted
                                  ? Colors.white.withValues(alpha: .2)
                                  : FieldrushAuthTheme.border,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _meterLabel(status.policyDisplay, i + 1),
                            maxLines: 1,
                            style: _jakarta(
                              8.5,
                              weight: FontWeight.w800,
                              color: restricted
                                  ? const Color(0xFFF2C4C5)
                                  : const Color(0xFF8E897A),
                            ).copyWith(height: 1, letterSpacing: .2),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IncidentRow extends StatelessWidget {
  const _IncidentRow({
    required this.incident,
    this.onAppeal,
    this.inactive = false,
    this.excused = false,
  });
  final ReliabilityIncident incident;
  final VoidCallback? onAppeal;
  final bool inactive;
  final bool excused;

  @override
  Widget build(BuildContext context) {
    final title = _incidentTitle(incident);
    final detail = _incidentDetail(incident);
    final strikes = excused
        ? incident.originalStrikeDelta ?? incident.strikeDelta
        : incident.strikeDelta;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: inactive
                  ? const Color(0xFFF2EFE3)
                  : const Color(0xFFF7E3E3),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Text(
              strikes > 0 ? '+$strikes' : '—',
              style:
                  _outfit(
                    13,
                    color: inactive
                        ? const Color(0xFF8E897A)
                        : FieldrushAuthTheme.danger,
                  ).copyWith(
                    decoration: excused ? TextDecoration.lineThrough : null,
                  ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: _jakarta(
                    13.5,
                    weight: FontWeight.w700,
                    color: FieldrushAuthTheme.ink,
                  ).copyWith(height: 1.25),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(detail, style: _jakarta(11).copyWith(height: 1.35)),
                ],
                if (incident.strikeExpiresAt case final clears?
                    when !inactive) ...[
                  const SizedBox(height: 5),
                  Text(
                    'Clears ${_date(clears, incident.timezone)}',
                    style: _jakarta(
                      11,
                      weight: FontWeight.w700,
                      color: const Color(0xFF3C4A38),
                    ),
                  ),
                ],
                if (incident.appealPending) ...[
                  const SizedBox(height: 6),
                  Text(
                    incident.appealSubmittedAt == null
                        ? 'Appeal sent'
                        : 'Appeal sent ${_date(incident.appealSubmittedAt!, incident.timezone)}',
                    style: _jakarta(
                      11,
                      weight: FontWeight.w700,
                      color: const Color(0xFF8A6516),
                    ).copyWith(height: 1.3),
                  ),
                ],
                if (incident.appealStatus?.toUpperCase() == 'UPHELD') ...[
                  const SizedBox(height: 6),
                  Text(
                    'Appeal reviewed · strike upheld',
                    style: _jakarta(11, weight: FontWeight.w700),
                  ),
                ],
                if (incident.appealResolutionNote case final note?) ...[
                  const SizedBox(height: 5),
                  Text(note, style: _jakarta(11).copyWith(height: 1.35)),
                ],
              ],
            ),
          ),
          if (!inactive &&
              (incident.appealPending ||
                  (incident.canAppeal && onAppeal != null))) ...[
            const SizedBox(width: 12),
            if (incident.appealPending)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7EED6),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'UNDER REVIEW',
                  style: _jakarta(
                    9,
                    color: const Color(0xFF8A6516),
                    weight: FontWeight.w800,
                  ).copyWith(letterSpacing: .9),
                ),
              )
            else
              OutlinedButton(
                key: ValueKey(
                  'appeal-reliability-${incident.attendanceRecordId}',
                ),
                onPressed: onAppeal,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  side: const BorderSide(color: FieldrushAuthTheme.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  foregroundColor: FieldrushAuthTheme.forest,
                  backgroundColor: Colors.white,
                ),
                child: Text(
                  'Appeal',
                  style: _jakarta(
                    11.5,
                    color: FieldrushAuthTheme.forest,
                    weight: FontWeight.w800,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ReliabilityAppealScreen extends StatefulWidget {
  const _ReliabilityAppealScreen({
    required this.repository,
    required this.incident,
    this.onNavigateTab,
  });
  final ReliabilityRepository repository;
  final ReliabilityIncident incident;
  final ValueChanged<int>? onNavigateTab;
  @override
  State<_ReliabilityAppealScreen> createState() =>
      _ReliabilityAppealScreenState();
}

class _ReliabilityAppealScreenState extends State<_ReliabilityAppealScreen> {
  final _details = TextEditingController();
  ReliabilityAppealCategory? _category;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final category = _category;
    if (_submitting || category == null) return;
    final text = _details.text.trim();
    if (text.length < 10) {
      setState(
        () => _error = 'Add at least 10 characters explaining what happened.',
      );
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.repository.submitAppeal(
        attendanceRecordId: widget.incident.attendanceRecordId,
        category: category,
        message: text,
      );
      if (!mounted) return;
      setState(() => _submitting = false);
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = userFacingError(
          error,
          fallback: 'Could not send your appeal. Try again.',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: PopScope(
      canPop: !_submitting,
      child: Scaffold(
        extendBody: true,
        backgroundColor: FieldrushAuthTheme.cream,
        bottomNavigationBar:
            widget.onNavigateTab == null ||
                MediaQuery.viewInsetsOf(context).bottom > 0
            ? null
            : IgnorePointer(
                ignoring: _submitting,
                child: Opacity(
                  opacity: _submitting ? .5 : 1,
                  child: FieldBottomNav(
                    selectedIndex: 4,
                    onSelected: (index) {
                      if (!_submitting) {
                        _navigateTab(context, widget.onNavigateTab!, index);
                      }
                    },
                  ),
                ),
              ),
        body: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.only(top: 18, bottom: 132),
            children: [
              _header(context, 'Appeal a strike', disabled: _submitting),
              Container(
                margin: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                decoration: _cardDecoration(),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _IncidentRow(incident: widget.incident),
                    if (widget.incident.appealDeadlineAt case final deadline?)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(16, 11, 16, 12),
                        decoration: const BoxDecoration(
                          color: Color(0xFFFBFAF4),
                          border: Border(top: BorderSide(color: _divider)),
                        ),
                        child: Text(
                          'Appeal by ${_date(deadline, widget.incident.timezone)} · ${_clock(deadline, widget.incident.timezone)}',
                          style: _jakarta(
                            11.5,
                            color: const Color(0xFF8A6516),
                            weight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              _section('WHAT HAPPENED?'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 11, 16, 0),
                child: Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final category
                        in widget.incident.allowedAppealCategories)
                      ChoiceChip(
                        label: Text(category.label),
                        selected: _category == category,
                        onSelected: _submitting
                            ? null
                            : (_) => setState(() => _category = category),
                        showCheckmark: false,
                        backgroundColor: Colors.white,
                        selectedColor: FieldrushAuthTheme.forest,
                        side: BorderSide(
                          color: _category == category
                              ? FieldrushAuthTheme.forest
                              : FieldrushAuthTheme.border,
                        ),
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        labelStyle: _jakarta(
                          12,
                          weight: FontWeight.w800,
                          color: _category == category
                              ? Colors.white
                              : const Color(0xFF3C4A38),
                        ),
                      ),
                  ],
                ),
              ),
              _section('TELL US MORE'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 11, 16, 0),
                child: TextField(
                  key: const ValueKey('reliability-appeal-details'),
                  controller: _details,
                  enabled: !_submitting,
                  minLines: 4,
                  maxLines: 8,
                  maxLength: 2000,
                  style: _jakarta(
                    13,
                    color: FieldrushAuthTheme.ink,
                  ).copyWith(height: 1.5),
                  decoration: InputDecoration(
                    hintText:
                        'Anything the ref or another player can confirm helps.',
                    counterText: '',
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 13,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(
                        color: FieldrushAuthTheme.ink,
                        width: 1.5,
                      ),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                  child: Text(
                    _error!,
                    style: _jakarta(12, color: FieldrushAuthTheme.danger),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: FilledButton(
                  key: const ValueKey('submit-reliability-appeal'),
                  onPressed: _submitting || _category == null ? null : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                    backgroundColor: FieldrushAuthTheme.forest,
                    disabledBackgroundColor: FieldrushAuthTheme.border,
                  ),
                  child: _submitting
                      ? const FieldLoadingIndicator(
                          label: 'Sending appeal',
                          color: Colors.white,
                        )
                      : Text(
                          'Send appeal',
                          style: _jakarta(
                            14,
                            color: _category == null
                                ? const Color(0xFF8E897A)
                                : Colors.white,
                            weight: FontWeight.w800,
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(
                  'You can appeal each strike once. We’ll let you know when it’s been reviewed.',
                  style: _jakarta(11.5).copyWith(height: 1.45),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

const _divider = Color(0xFFF0ECE0);
void _navigateTab(BuildContext context, ValueChanged<int> navigate, int index) {
  Navigator.of(context).popUntil((route) => route.isFirst);
  navigate(index);
}

BoxDecoration _cardDecoration() => BoxDecoration(
  color: Colors.white,
  border: Border.all(color: FieldrushAuthTheme.border),
  borderRadius: BorderRadius.circular(20),
);
TextStyle _jakarta(
  double size, {
  Color color = FieldrushAuthTheme.muted,
  FontWeight weight = FontWeight.w600,
}) => TextStyle(
  fontFamily: 'PlusJakartaSans',
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: 1,
);
TextStyle _outfit(double size, {Color color = FieldrushAuthTheme.ink}) =>
    TextStyle(
      fontFamily: 'Outfit',
      fontSize: size,
      fontWeight: FontWeight.w800,
      color: color,
      height: 1,
      letterSpacing: -size * .01,
    );

Widget _header(BuildContext context, String title, {bool disabled = false}) =>
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: 'Back',
            enabled: !disabled,
            child: SizedBox(
              width: 36,
              height: 36,
              child: Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: FieldrushAuthTheme.border),
                ),
                child: InkWell(
                  onTap: disabled
                      ? null
                      : () => Navigator.of(context).maybePop(),
                  borderRadius: BorderRadius.circular(12),
                  child: const ExcludeSemantics(
                    child: Icon(
                      Icons.chevron_left_rounded,
                      size: 23,
                      color: Color(0xFF3C4A38),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: _outfit(18))),
        ],
      ),
    );
Widget _section(String title, {String? trailing, double top = 22}) => Padding(
  padding: EdgeInsets.fromLTRB(20, top, 20, 0),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Expanded(
        child: Text(
          title,
          style: _jakarta(
            11,
            weight: FontWeight.w800,
          ).copyWith(letterSpacing: 1.54),
        ),
      ),
      if (trailing != null)
        Text(trailing, style: _jakarta(11, weight: FontWeight.w700)),
    ],
  ),
);
Widget _group(List<Widget> children) => Container(
  margin: const EdgeInsets.fromLTRB(16, 11, 16, 0),
  decoration: _cardDecoration(),
  clipBehavior: Clip.antiAlias,
  child: Column(
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const Divider(height: 1, thickness: 1, color: _divider),
        children[i],
      ],
    ],
  ),
);
Widget _rule(String label, String value, {bool danger = false}) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
  child: ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 26),
    child: LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: _jakarta(
                13,
                color: FieldrushAuthTheme.ink,
                weight: FontWeight.w700,
              ).copyWith(height: 1.25),
            ),
          ),
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * .55),
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: _jakarta(
                12,
                color: danger
                    ? FieldrushAuthTheme.danger
                    : FieldrushAuthTheme.ink,
                weight: FontWeight.w800,
              ).copyWith(height: 1.25),
            ),
          ),
        ],
      ),
    ),
  ),
);
Widget _dots(int filled, int count) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    for (var i = 0; i < count; i++)
      Container(
        width: 7,
        height: 7,
        margin: EdgeInsets.only(right: i == count - 1 ? 0 : 3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: i < filled
              ? FieldrushAuthTheme.danger
              : const Color(0xFFDED8C6),
        ),
      ),
  ],
);
int _meterSize(ReliabilityPolicyDisplay? policy) => math.max(
  5,
  math.min(
    12,
    policy?.sanctions.fold<int>(
          0,
          (max, rule) => math.max(max, rule.threshold),
        ) ??
        5,
  ),
);
String _meterLabel(ReliabilityPolicyDisplay? policy, int threshold) {
  final rule = policy?.sanctions
      .where((s) => s.threshold == threshold && s.kind != 'WARNING')
      .firstOrNull;
  if (rule == null) {
    return policy?.depositThreshold == threshold &&
            (policy?.depositBps ?? 0) > 0
        ? 'DEPOSIT'
        : '';
  }
  if (rule.kind == 'INDEFINITE_SUSPENSION') return 'REVIEW';
  final days = rule.durationDays;
  if (days == null || days <= 0) return '';
  return days % 7 == 0
      ? '${days ~/ 7} ${days == 7 ? 'WEEK' : 'WEEKS'}'
      : '$days DAYS';
}

String _sanctionLabel(ReliabilitySanctionRule rule) => switch (rule.kind) {
  'INDEFINITE_SUSPENSION' => 'Indefinite suspension',
  'PARTICIPATION_SUSPENSION' =>
    '${rule.durationDays}-day participation suspension',
  'BOOKING_RESTRICTION' => '${rule.durationDays}-day booking restriction',
  _ => rule.kind.toLowerCase().replaceAll('_', ' '),
};
String _strikes(int count) => '$count ${count == 1 ? 'strike' : 'strikes'}';
String _percentage(int bps) =>
    '${bps % 100 == 0 ? bps ~/ 100 : (bps / 100).toStringAsFixed(bps % 10 == 0 ? 1 : 2)}%';
DateTime _local(DateTime instant, String zone) {
  try {
    return gameLocalDateTime(instant, zone);
  } catch (_) {
    return instant.toUtc();
  }
}

String _date(DateTime instant, String zone) {
  final local = _local(instant, zone);
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
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
  return '${days[local.weekday - 1]}, ${months[local.month - 1]} ${local.day}';
}

String _clock(DateTime instant, String zone) {
  final local = _local(instant, zone);
  return '${local.hour % 12 == 0 ? 12 : local.hour % 12}:${local.minute.toString().padLeft(2, '0')} ${local.hour < 12 ? 'AM' : 'PM'}';
}

String _incidentTitle(ReliabilityIncident incident) {
  final outcome = incident.originalOutcome ?? incident.outcome;
  final label = switch (outcome.toUpperCase()) {
    'LATE' => 'Late arrival',
    'NO_SHOW' => 'No-show',
    'CANCELLED_LATE' || 'CANCELLED_VERY_LATE' => 'Cancelled late',
    _ => incident.outcomeLabel,
  };
  return '$label${incident.occurredAt == null ? '' : ' · ${_date(incident.occurredAt!, incident.timezone)}'}';
}

String _incidentDetail(ReliabilityIncident incident) => [
  if (incident.checkedInAt case final arrival?)
    'Checked in at ${_clock(arrival, incident.timezone)}'
  else if (incident.outcome.toUpperCase() == 'NO_SHOW')
    'Didn’t check in',
  if (incident.matchLabel case final match?) match,
  if (incident.excused) 'Excused after review.',
].join(' · ');
