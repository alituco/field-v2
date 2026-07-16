import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import 'fixture.dart';
import 'fixture_repository.dart';
import 'fixture_widgets.dart';

enum _CreateFixtureStep { chooseAction, selectTime, summary, success }

class CreateFixtureScreen extends StatefulWidget {
  const CreateFixtureScreen({
    super.key,
    required this.fixtureRepository,
    required this.myClanMembership,
  });

  final FixtureRepository fixtureRepository;
  final MyClanMembership myClanMembership;

  @override
  State<CreateFixtureScreen> createState() => _CreateFixtureScreenState();
}

class _CreateFixtureScreenState extends State<CreateFixtureScreen>
    with SingleTickerProviderStateMixin {
  _CreateFixtureStep _step = _CreateFixtureStep.chooseAction;
  List<Fixture> _fixtures = const [];
  List<Fixture> _openFixtures = const [];
  Fixture? _selectedFixtureToJoin;
  DateTime? _selectedDate;
  FixtureTimeSlot? _selectedTimeSlot;
  bool _isLoadingOpenFixtures = true;
  bool _isSubmitting = false;
  bool _isCheckingAccess = true;
  bool _accessReady = false;
  String? _errorText;
  String? _accessMessage;
  late MyClanMembership _membership;
  late final AnimationController _successController;

  bool get _canAct => _accessReady && _membership.canManageMatches;

  @override
  void initState() {
    super.initState();
    _membership = widget.myClanMembership;
    _successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    _validateAccess();
    _loadOpenFixtures();
  }

  @override
  void dispose() {
    _successController.dispose();
    super.dispose();
  }

  Future<bool> _validateAccess({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _isCheckingAccess = true;
        _accessMessage = null;
      });
    }

    try {
      final latest = await widget.fixtureRepository.getMyClanMembership();
      if (!mounted) return false;

      final sameClan = latest?.clan.id == widget.myClanMembership.clan.id;
      if (latest == null) {
        setState(() {
          _accessReady = false;
          _accessMessage =
              'You are no longer an active member of ${widget.myClanMembership.clan.name}. Clan games can only be scheduled by a current owner or leader.';
        });
        return false;
      }
      if (!sameClan) {
        setState(() {
          _accessReady = false;
          _accessMessage =
              'Your active clan has changed. Go back to Fixtures and start again so the match is scheduled for the right clan.';
        });
        return false;
      }
      if (!latest.canManageMatches) {
        setState(() {
          _membership = latest;
          _accessReady = false;
          _accessMessage =
              'You are a member of ${latest.clan.name}, but only its owner or a leader can schedule or join clan games.';
        });
        return false;
      }

      setState(() {
        _membership = latest;
        _accessReady = true;
        _accessMessage = null;
      });
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        _accessReady = false;
        _accessMessage = userFacingError(
          error,
          fallback:
              'We could not verify that you can schedule for this clan. Check your connection and try again.',
        );
      });
      return false;
    } finally {
      if (mounted && showLoading) {
        setState(() => _isCheckingAccess = false);
      }
    }
  }

  Future<void> _loadOpenFixtures() async {
    setState(() {
      _isLoadingOpenFixtures = true;
      _errorText = null;
    });

    try {
      final fixtures = await widget.fixtureRepository.listFixtures();
      if (!mounted) return;
      setState(() {
        _fixtures = fixtures;
        _openFixtures = fixtures
            .where(
              (fixture) =>
                  fixture.status == FixtureStatus.open &&
                  fixture.homeClanId != widget.myClanMembership.clan.id &&
                  fixture.timeSlot == FixtureTimeSlot.early.label &&
                  isFixtureMatchDay(fixture.matchDate),
            )
            .toList();
      });
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not load open matches. Try again.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoadingOpenFixtures = false);
      }
    }
  }

  void _startHosting() {
    if (!_canAct) {
      _showOwnerSnack();
      return;
    }
    setState(() {
      _selectedFixtureToJoin = null;
      _selectedDate = null;
      _selectedTimeSlot = null;
      _step = _CreateFixtureStep.selectTime;
    });
  }

  void _startJoining(Fixture fixture) {
    if (!_canAct) {
      _showOwnerSnack();
      return;
    }

    if (fixture.homeClanId == _membership.clan.id) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Your clan is already hosting this match.'),
        ),
      );
      return;
    }

    setState(() {
      _selectedFixtureToJoin = fixture;
      _selectedDate = fixture.matchDate;
      _selectedTimeSlot = FixtureTimeSlot.values.firstWhere(
        (slot) => slot.label == fixture.timeSlot,
        orElse: () => FixtureTimeSlot.early,
      );
      _step = _CreateFixtureStep.summary;
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final firstDate = DateTime(now.year, now.month, now.day);
    final lastDate = firstDate.add(const Duration(days: 90));
    final initialDate =
        _selectedDate != null &&
            !_selectedDate!.isBefore(firstDate) &&
            !_selectedDate!.isAfter(lastDate) &&
            isFixtureMatchDay(_selectedDate!)
        ? _selectedDate!
        : _nextMatchDay(firstDate);
    final picked = await showDialog<DateTime>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.42),
      builder: (context) => _MatchDatePickerDialog(
        initialDate: initialDate,
        selectedDate: _selectedDate,
        firstDate: firstDate,
        lastDate: lastDate,
      ),
    );

    if (picked == null) return;
    setState(() {
      _selectedDate = picked;
      if (_selectedTimeSlot != null &&
          !_isSlotAvailable(picked, _selectedTimeSlot!)) {
        _selectedTimeSlot = null;
      }
    });
  }

  void _continueToSummary() {
    if (_selectedDate == null || _selectedTimeSlot == null) return;
    setState(() => _step = _CreateFixtureStep.summary);
  }

  Future<void> _submit() async {
    final date = _selectedDate;
    final timeSlot = _selectedTimeSlot;
    if (date == null || timeSlot == null) return;

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    final stillAllowed = await _validateAccess(showLoading: false);
    if (!stillAllowed) {
      if (mounted) setState(() => _isSubmitting = false);
      return;
    }
    final membership = _membership;

    try {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (_selectedFixtureToJoin == null) {
        await widget.fixtureRepository.createFixture(
          homeClanId: membership.clan.id,
          venue: 'Central Sports Complex',
          matchDate: date,
          timeSlot: timeSlot,
        );
      } else {
        await widget.fixtureRepository.joinFixture(
          fixtureId: _selectedFixtureToJoin!.id,
          awayClanId: membership.clan.id,
        );
      }
      if (!mounted) return;
      setState(() => _step = _CreateFixtureStep.success);
      _successController.forward(from: 0);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not book this match. Try again.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  bool _isSlotAvailable(DateTime date, FixtureTimeSlot slot) {
    return _activeFixtureCount(_fixtures, date, slot) == 0;
  }

  void _showOwnerSnack() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Only clan owners and leaders can schedule matches.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: FieldPageHeader(
          title: _headerTitle,
          showBack: true,
          onBack: _handleBack,
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 230),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.04, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            );
          },
          child: _buildBody(),
        ),
      ),
      bottomNavigationBar: _accessReady && !_isCheckingAccess
          ? _buildBottomAction()
          : null,
    );
  }

  Widget _buildBody() {
    if (_isCheckingAccess) {
      return const _ClanAccessLoadingStep(key: ValueKey('access-loading'));
    }
    if (!_accessReady) {
      return _ClanAccessBlockedStep(
        key: const ValueKey('access-blocked'),
        clanName: widget.myClanMembership.clan.name,
        message:
            _accessMessage ??
            'Only the clan owner or a leader can schedule this game.',
        onRetry: _validateAccess,
      );
    }
    return _buildStep();
  }

  String get _headerTitle {
    return switch (_step) {
      _CreateFixtureStep.chooseAction => 'Clan Game',
      _CreateFixtureStep.selectTime => 'Select Time',
      _CreateFixtureStep.summary => 'Confirm Match',
      _CreateFixtureStep.success => 'Success',
    };
  }

  void _handleBack() {
    if (!_accessReady || _isCheckingAccess) {
      Navigator.of(context).pop(false);
      return;
    }
    if (_step == _CreateFixtureStep.chooseAction) {
      Navigator.of(context).pop(false);
      return;
    }
    if (_step == _CreateFixtureStep.success) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _errorText = null;
      if (_step == _CreateFixtureStep.summary) {
        _step = _selectedFixtureToJoin == null
            ? _CreateFixtureStep.selectTime
            : _CreateFixtureStep.chooseAction;
      } else {
        _step = _CreateFixtureStep.chooseAction;
      }
    });
  }

  Widget _buildStep() {
    return switch (_step) {
      _CreateFixtureStep.chooseAction => _ChooseActionStep(
        key: const ValueKey('choose'),
        membership: _membership,
        openFixtures: _openFixtures,
        isLoading: _isLoadingOpenFixtures,
        errorText: _errorText,
        onRetry: _loadOpenFixtures,
        onHost: _startHosting,
        onJoin: _startJoining,
      ),
      _CreateFixtureStep.selectTime => _SelectTimeStep(
        key: const ValueKey('time'),
        membership: _membership,
        selectedDate: _selectedDate,
        selectedTimeSlot: _selectedTimeSlot,
        fixtures: _fixtures,
        onPickDate: _pickDate,
        onSelectTimeSlot: (slot) => setState(() => _selectedTimeSlot = slot),
      ),
      _CreateFixtureStep.summary => _SummaryStep(
        key: const ValueKey('summary'),
        fixtureToJoin: _selectedFixtureToJoin,
        membership: _membership,
        myClan: _membership.clan,
        fixtureRepository: widget.fixtureRepository,
        date: _selectedDate!,
        timeSlot: _selectedTimeSlot!,
        errorText: _errorText,
      ),
      _CreateFixtureStep.success => _SuccessStep(
        key: const ValueKey('success'),
        controller: _successController,
        joined: _selectedFixtureToJoin != null,
        clanName: _membership.clan.name,
      ),
    };
  }

  Widget? _buildBottomAction() {
    if (_step == _CreateFixtureStep.selectTime) {
      return _BottomAction(
        child: FilledButton(
          onPressed: _selectedDate == null || _selectedTimeSlot == null
              ? null
              : _continueToSummary,
          style: FilledButton.styleFrom(
            backgroundColor: fieldEmerald600,
            foregroundColor: Colors.white,
          ),
          child: const Text('Continue'),
        ),
      );
    }

    if (_step == _CreateFixtureStep.summary) {
      return _BottomAction(
        child: FilledButton.icon(
          onPressed: _isSubmitting ? null : _submit,
          icon: _isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.apple_rounded),
          label: Text(_isSubmitting ? 'Processing...' : 'Pay 20 BHD'),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
        ),
      );
    }

    if (_step == _CreateFixtureStep.success) {
      return _BottomAction(
        child: FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: fieldEmerald600,
            foregroundColor: Colors.white,
          ),
          child: const Text('Back to Fixtures'),
        ),
      );
    }

    return null;
  }
}

class _ClanAccessLoadingStep extends StatelessWidget {
  const _ClanAccessLoadingStep({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: fieldHeaderAwarePadding(context, top: 72, bottom: 40),
      children: const [
        Center(
          child: Column(
            children: [
              SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                  color: fieldEmerald600,
                  strokeWidth: 3,
                ),
              ),
              SizedBox(height: 18),
              Text(
                'Checking clan access…',
                style: TextStyle(
                  color: fieldGray700,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ClanAccessBlockedStep extends StatelessWidget {
  const _ClanAccessBlockedStep({
    super.key,
    required this.clanName,
    required this.message,
    required this.onRetry,
  });

  final String clanName;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: fieldHeaderAwarePadding(context, top: 28, bottom: 40),
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFFED7AA)),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.lock_outline_rounded,
                  color: Color(0xFFEA580C),
                  size: 30,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'You cannot schedule for $clanName',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 21,
                  height: 1.15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: fieldGray600,
                  fontSize: 14,
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: fieldEmerald600,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Check access again'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ClanSchedulingBanner extends StatelessWidget {
  const _ClanSchedulingBanner({required this.membership, this.compact = false});

  final MyClanMembership? membership;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final membership = this.membership;
    final clan = membership?.clan;
    final roleLabel = switch (membership?.role) {
      'owner' => 'Owner',
      'leader' => 'Leader',
      _ => 'Member',
    };

    return Container(
      key: const ValueKey('clan-scheduling-banner'),
      padding: EdgeInsets.all(compact ? 13 : 16),
      decoration: BoxDecoration(
        color: fieldEmerald50,
        border: Border.all(color: fieldEmerald200),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          if (clan != null)
            FixtureClanAvatar(clan: clan, size: compact ? 42 : 48)
          else
            Container(
              width: compact ? 42 : 48,
              height: compact ? 42 : 48,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.shield_outlined, color: fieldEmerald700),
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
                        'SCHEDULING FOR',
                        style: TextStyle(
                          color: fieldEmerald700,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        roleLabel.toUpperCase(),
                        style: const TextStyle(
                          color: fieldEmerald700,
                          fontSize: 8,
                          fontWeight: FontWeight.w900,
                          letterSpacing: .6,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  clan?.name ?? 'No clan selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: fieldGray900,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 3),
                  Text(
                    clan == null
                        ? 'Choose a clan before scheduling.'
                        : 'This game will be created or joined for ${clan.name}.',
                    style: const TextStyle(
                      color: fieldGray600,
                      fontSize: 11,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.verified_rounded, color: fieldEmerald600, size: 22),
        ],
      ),
    );
  }
}

class _ChooseActionStep extends StatelessWidget {
  const _ChooseActionStep({
    super.key,
    required this.membership,
    required this.openFixtures,
    required this.isLoading,
    required this.errorText,
    required this.onRetry,
    required this.onHost,
    required this.onJoin,
  });

  final MyClanMembership? membership;
  final List<Fixture> openFixtures;
  final bool isLoading;
  final String? errorText;
  final VoidCallback onRetry;
  final VoidCallback onHost;
  final ValueChanged<Fixture> onJoin;

  @override
  Widget build(BuildContext context) {
    final clanName = membership?.clan.name ?? 'your clan';
    return ListView(
      padding: fieldHeaderAwarePadding(context, bottom: 120),
      children: [
        _ClanSchedulingBanner(membership: membership),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF059669), Color(0xFF14B8A6)],
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: fieldEmerald600.withValues(alpha: 0.28),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned(
                right: -22,
                bottom: -26,
                child: Icon(
                  Icons.sports_mma_rounded,
                  color: Colors.white.withValues(alpha: 0.12),
                  size: 112,
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Schedule a clan match',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Host a new match or choose an open opponent below. Every action here is for $clanName.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.86),
                      fontSize: 14,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: onHost,
                      icon: const Icon(Icons.add_rounded),
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Host for $clanName'),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: fieldEmerald600,
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            const Expanded(
              child: Text(
                'OPEN CLAN MATCHES',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                'NEXT 14 DAYS',
                style: TextStyle(
                  color: fieldEmerald600,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (isLoading)
          const Column(
            children: [
              _OpenFixtureSkeletonRow(),
              SizedBox(height: 10),
              _OpenFixtureSkeletonRow(),
              SizedBox(height: 10),
              _OpenFixtureSkeletonRow(),
            ],
          )
        else if (errorText != null)
          _SimplePanel(
            icon: Icons.warning_rounded,
            title: 'Could not load matches',
            message: errorText!,
            actionLabel: 'Try Again',
            onAction: onRetry,
          )
        else if (openFixtures.isEmpty)
          const _SimplePanel(
            icon: Icons.shield_rounded,
            title: 'No open matches',
            message: 'Host one for your clan to get the ball rolling.',
          )
        else
          for (var i = 0; i < openFixtures.length; i++) ...[
            _JoinFixtureCard(
              fixture: openFixtures[i],
              clanName: clanName,
              onJoin: onJoin,
            ),
            if (i != openFixtures.length - 1) const SizedBox(height: 14),
          ],
      ],
    );
  }
}

class _JoinFixtureCard extends StatelessWidget {
  const _JoinFixtureCard({
    required this.fixture,
    required this.clanName,
    required this.onJoin,
  });

  final Fixture fixture;
  final String clanName;
  final ValueChanged<Fixture> onJoin;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          FixtureCard(fixture: fixture),
          Container(
            padding: const EdgeInsets.all(12),
            color: fieldGray100.withValues(alpha: 0.66),
            child: SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                onPressed: () => onJoin(fixture),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Join for $clanName'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectTimeStep extends StatelessWidget {
  const _SelectTimeStep({
    super.key,
    required this.membership,
    required this.selectedDate,
    required this.selectedTimeSlot,
    required this.fixtures,
    required this.onPickDate,
    required this.onSelectTimeSlot,
  });

  final MyClanMembership? membership;
  final DateTime? selectedDate;
  final FixtureTimeSlot? selectedTimeSlot;
  final List<Fixture> fixtures;
  final VoidCallback onPickDate;
  final ValueChanged<FixtureTimeSlot> onSelectTimeSlot;

  @override
  Widget build(BuildContext context) {
    final availableSlots = selectedDate == null
        ? const <FixtureTimeSlot>[]
        : clanFixtureTimeSlots
              .where((slot) => !_isBooked(fixtures, selectedDate!, slot))
              .toList();

    return ListView(
      padding: fieldHeaderAwarePadding(context, top: 18, bottom: 120),
      children: [
        _ClanSchedulingBanner(membership: membership, compact: true),
        const SizedBox(height: 20),
        const Text(
          'Pick a Date',
          style: TextStyle(
            color: fieldGray900,
            fontSize: 21,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Choose a Tuesday or Friday. Clan games always run from 7:00–8:00 PM.',
          style: TextStyle(
            color: fieldGray500,
            fontSize: 14,
            height: 1.35,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 14),
        InkWell(
          onTap: onPickDate,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: fieldGray100),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFECFDF5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.calendar_month_rounded,
                    color: fieldEmerald600,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    selectedDate == null
                        ? 'Choose a match date'
                        : _formatLongDate(selectedDate!),
                    style: const TextStyle(
                      color: fieldGray900,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: fieldGray400),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: selectedDate == null
              ? const _WaitingForDatePanel(key: ValueKey('wait-date'))
              : Column(
                  key: ValueKey('slots-${selectedDate!.toIso8601String()}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Available Options',
                      style: TextStyle(
                        color: fieldGray900,
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      availableSlots.length == 1
                          ? '1 slot open for this date.'
                          : '${availableSlots.length} slots open for this date.',
                      style: const TextStyle(
                        color: fieldGray500,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (availableSlots.isEmpty)
                      const _NoSlotsPanel()
                    else
                      for (final slot in clanFixtureTimeSlots) ...[
                        _TimeSlotTile(
                          slot: slot,
                          selected: selectedTimeSlot == slot,
                          available: availableSlots.contains(slot),
                          activeCount: _activeFixtureCount(
                            fixtures,
                            selectedDate!,
                            slot,
                          ),
                          onTap: () => onSelectTimeSlot(slot),
                        ),
                        if (slot != clanFixtureTimeSlots.last)
                          const SizedBox(height: 10),
                      ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _WaitingForDatePanel extends StatelessWidget {
  const _WaitingForDatePanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Row(
        children: [
          Icon(Icons.touch_app_rounded, color: fieldGray400),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Pick a date to check the available kickoff options.',
              style: TextStyle(
                color: fieldGray500,
                fontSize: 14,
                height: 1.35,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoSlotsPanel extends StatelessWidget {
  const _NoSlotsPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Row(
        children: [
          Icon(Icons.event_busy_rounded, color: Color(0xFFEA580C)),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'The 7:00–8:00 PM clan game is booked. Pick another Tuesday or Friday.',
              style: TextStyle(
                color: Color(0xFF9A3412),
                fontSize: 14,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimeSlotTile extends StatelessWidget {
  const _TimeSlotTile({
    required this.slot,
    required this.selected,
    required this.available,
    required this.activeCount,
    required this.onTap,
  });

  final FixtureTimeSlot slot;
  final bool selected;
  final bool available;
  final int activeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: available ? onTap : null,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 170),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: !available
              ? fieldGray100.withValues(alpha: 0.72)
              : selected
              ? const Color(0xFFECFDF5)
              : Colors.white,
          border: Border.all(
            color: selected ? fieldEmerald500 : fieldGray200,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              Icons.access_time_rounded,
              color: !available
                  ? fieldGray300
                  : selected
                  ? fieldEmerald600
                  : fieldGray400,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    slot.label,
                    style: TextStyle(
                      color: !available
                          ? fieldGray400
                          : selected
                          ? const Color(0xFF064E3B)
                          : fieldGray700,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    activeCount == 0 ? 'Available' : 'Booked',
                    style: TextStyle(
                      color: available ? fieldEmerald600 : fieldGray400,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? fieldEmerald500 : fieldGray300,
                  width: 2,
                ),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: fieldEmerald500,
                        ),
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _MatchDatePickerDialog extends StatefulWidget {
  const _MatchDatePickerDialog({
    required this.initialDate,
    required this.selectedDate,
    required this.firstDate,
    required this.lastDate,
  });

  final DateTime initialDate;
  final DateTime? selectedDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_MatchDatePickerDialog> createState() => _MatchDatePickerDialogState();
}

class _MatchDatePickerDialogState extends State<_MatchDatePickerDialog> {
  late DateTime _visibleMonth;

  @override
  void initState() {
    super.initState();
    _visibleMonth = DateTime(widget.initialDate.year, widget.initialDate.month);
  }

  bool get _canGoPrevious {
    final firstMonth = DateTime(widget.firstDate.year, widget.firstDate.month);
    return _visibleMonth.isAfter(firstMonth);
  }

  bool get _canGoNext {
    final lastMonth = DateTime(widget.lastDate.year, widget.lastDate.month);
    return _visibleMonth.isBefore(lastMonth);
  }

  void _moveMonth(int delta) {
    final next = DateTime(_visibleMonth.year, _visibleMonth.month + delta);
    final firstMonth = DateTime(widget.firstDate.year, widget.firstDate.month);
    final lastMonth = DateTime(widget.lastDate.year, widget.lastDate.month);

    if (next.isBefore(firstMonth) || next.isAfter(lastMonth)) return;
    setState(() => _visibleMonth = next);
  }

  List<DateTime?> _monthCells() {
    final firstOfMonth = DateTime(_visibleMonth.year, _visibleMonth.month);
    final leadingBlanks = firstOfMonth.weekday % 7;
    final dayCount = DateUtils.getDaysInMonth(
      _visibleMonth.year,
      _visibleMonth.month,
    );

    return [
      for (var i = 0; i < 42; i++)
        if (i < leadingBlanks || i >= leadingBlanks + dayCount)
          null
        else
          DateTime(
            _visibleMonth.year,
            _visibleMonth.month,
            i - leadingBlanks + 1,
          ),
    ];
  }

  bool _isEnabled(DateTime date) {
    return !date.isBefore(widget.firstDate) &&
        !date.isAfter(widget.lastDate) &&
        isFixtureMatchDay(date);
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selectedDate;
    final cells = _monthCells();

    return Dialog(
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      backgroundColor: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: fieldGray200),
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: fieldGray900.withValues(alpha: 0.18),
              blurRadius: 32,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [fieldEmerald500, fieldBlue600],
                    ),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(
                    Icons.calendar_month_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Match Date',
                    style: TextStyle(
                      color: fieldGray900,
                      fontSize: 21,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded),
                  color: fieldGray500,
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: fieldGray100,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  _CalendarArrowButton(
                    icon: Icons.chevron_left_rounded,
                    enabled: _canGoPrevious,
                    onPressed: () => _moveMonth(-1),
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 160),
                      child: Text(
                        _formatMonthYear(_visibleMonth),
                        key: ValueKey(
                          '${_visibleMonth.year}-${_visibleMonth.month}',
                        ),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: fieldGray900,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ),
                  _CalendarArrowButton(
                    icon: Icons.chevron_right_rounded,
                    enabled: _canGoNext,
                    onPressed: () => _moveMonth(1),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Row(
              children: [
                _WeekdayLabel('S'),
                _WeekdayLabel('M'),
                _WeekdayLabel('T'),
                _WeekdayLabel('W'),
                _WeekdayLabel('T'),
                _WeekdayLabel('F'),
                _WeekdayLabel('S'),
              ],
            ),
            const SizedBox(height: 8),
            GridView.builder(
              itemCount: cells.length,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisSpacing: 7,
                crossAxisSpacing: 6,
              ),
              itemBuilder: (context, index) {
                final date = cells[index];
                if (date == null) return const SizedBox.shrink();

                return _CalendarDateTile(
                  date: date,
                  selected: selected != null && _sameDay(selected, date),
                  enabled: _isEnabled(date),
                  today: _sameDay(date, DateTime.now()),
                  onTap: () => Navigator.of(context).pop(date),
                );
              },
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const _CalendarDot(color: fieldEmerald500),
                const SizedBox(width: 6),
                const Text(
                  'Match day',
                  style: TextStyle(
                    color: fieldGray500,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarArrowButton extends StatelessWidget {
  const _CalendarArrowButton({
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onPressed : null,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: enabled ? Border.all(color: fieldGray200) : null,
        ),
        child: Icon(
          icon,
          color: enabled ? fieldGray700 : fieldGray300,
          size: 22,
        ),
      ),
    );
  }
}

class _WeekdayLabel extends StatelessWidget {
  const _WeekdayLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Center(
        child: Text(
          label,
          style: const TextStyle(
            color: fieldGray500,
            fontSize: 12,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _CalendarDateTile extends StatelessWidget {
  const _CalendarDateTile({
    required this.date,
    required this.selected,
    required this.enabled,
    required this.today,
    required this.onTap,
  });

  final DateTime date;
  final bool selected;
  final bool enabled;
  final bool today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(13),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(colors: [fieldEmerald500, fieldBlue600])
              : null,
          color: selected
              ? null
              : enabled
              ? const Color(0xFFECFDF5)
              : Colors.transparent,
          border: Border.all(
            color: selected
                ? Colors.transparent
                : today
                ? fieldEmerald500.withValues(alpha: 0.55)
                : enabled
                ? const Color(0xFFA7F3D0)
                : Colors.transparent,
          ),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Text(
          date.day.toString(),
          style: TextStyle(
            color: selected
                ? Colors.white
                : enabled
                ? const Color(0xFF065F46)
                : fieldGray300,
            fontSize: 15,
            fontWeight: selected || enabled ? FontWeight.w900 : FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _CalendarDot extends StatelessWidget {
  const _CalendarDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _SummaryStep extends StatelessWidget {
  const _SummaryStep({
    super.key,
    required this.fixtureToJoin,
    required this.membership,
    required this.myClan,
    required this.fixtureRepository,
    required this.date,
    required this.timeSlot,
    required this.errorText,
  });

  final Fixture? fixtureToJoin;
  final MyClanMembership? membership;
  final FixtureClan? myClan;
  final FixtureRepository fixtureRepository;
  final DateTime date;
  final FixtureTimeSlot timeSlot;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: fieldHeaderAwarePadding(context, top: 18, bottom: 120),
      children: [
        _ClanSchedulingBanner(membership: membership, compact: true),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: fieldGray100),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                fixtureToJoin == null ? 'Match Summary' : 'Join Match Summary',
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              if (fixtureToJoin != null && myClan != null) ...[
                _ConfirmationMatchup(
                  opponent: fixtureToJoin!.homeClan,
                  myClan: myClan!,
                ),
                const SizedBox(height: 18),
                const Divider(color: fieldGray100),
                const SizedBox(height: 16),
              ],
              _SummaryRow(
                icon: Icons.calendar_month_rounded,
                iconColor: fieldBlue600,
                iconBackground: const Color(0xFFEFF6FF),
                label: 'Date',
                value: _formatLongDate(date),
              ),
              const SizedBox(height: 16),
              _SummaryRow(
                icon: Icons.access_time_rounded,
                iconColor: const Color(0xFFEA580C),
                iconBackground: const Color(0xFFFFF7ED),
                label: 'Time',
                value: timeSlot.label,
              ),
              const SizedBox(height: 16),
              _SummaryRow(
                icon: Icons.location_on_rounded,
                iconColor: fieldEmerald600,
                iconBackground: const Color(0xFFECFDF5),
                label: 'Venue',
                value: fixtureToJoin?.venue ?? 'Central Sports Complex',
              ),
              const SizedBox(height: 18),
              const Divider(color: fieldGray100),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Total Amount',
                      style: TextStyle(
                        color: fieldGray500,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      '20 BHD',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (fixtureToJoin != null && myClan != null) ...[
          const SizedBox(height: 14),
          _SrImpactDisclosure(
            key: ValueKey('sr-${fixtureToJoin!.id}-${myClan!.id}'),
            fixtureRepository: fixtureRepository,
            fixture: fixtureToJoin!,
            myClan: myClan!,
          ),
        ],
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFECFDF5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            fixtureToJoin == null
                ? 'This match will be listed as open for other clans to challenge.'
                : 'Your clan will be locked in as the away team for this fixture.',
            style: const TextStyle(
              color: Color(0xFF065F46),
              fontSize: 13,
              height: 1.35,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (errorText != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              errorText!,
              style: const TextStyle(
                color: Color(0xFF991B1B),
                fontSize: 13,
                height: 1.35,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ConfirmationMatchup extends StatelessWidget {
  const _ConfirmationMatchup({required this.opponent, required this.myClan});

  final FixtureClan opponent;
  final FixtureClan myClan;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: _ConfirmationTeam(clan: opponent, label: 'OPPONENT'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: fieldGray100,
              shape: BoxShape.circle,
            ),
            child: const Text(
              'VS',
              style: TextStyle(
                color: fieldGray500,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
        Expanded(
          child: _ConfirmationTeam(clan: myClan, label: 'YOUR CLAN'),
        ),
      ],
    );
  }
}

class _ConfirmationTeam extends StatelessWidget {
  const _ConfirmationTeam({required this.clan, required this.label});

  final FixtureClan clan;
  final String label;

  @override
  Widget build(BuildContext context) {
    final rank = clan.regionRank;
    final rankLabel = rank == null
        ? null
        : '${_displayRegion(clan.region)} #$rank';

    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: fieldGray400,
            fontSize: 9,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        FixtureClanAvatar(clan: clan, size: 56),
        const SizedBox(height: 9),
        Text(
          clan.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: fieldGray900,
            fontSize: 13,
            height: 1.1,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          '${clan.tag} · ${clan.rank.label}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: fieldGray500,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${clan.skillRating} SR',
          style: const TextStyle(
            color: fieldEmerald600,
            fontSize: 13,
            fontWeight: FontWeight.w900,
          ),
        ),
        if (rankLabel != null) ...[
          const SizedBox(height: 3),
          Text(
            rankLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

class _SrImpactDisclosure extends StatefulWidget {
  const _SrImpactDisclosure({
    super.key,
    required this.fixtureRepository,
    required this.fixture,
    required this.myClan,
  });

  final FixtureRepository fixtureRepository;
  final Fixture fixture;
  final FixtureClan myClan;

  @override
  State<_SrImpactDisclosure> createState() => _SrImpactDisclosureState();
}

class _SrImpactDisclosureState extends State<_SrImpactDisclosure> {
  bool _expanded = false;
  Future<List<FixtureSrScenario>>? _scenarios;

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      if (_expanded) _scenarios ??= _loadScenarios();
    });
  }

  Future<List<FixtureSrScenario>> _loadScenarios() {
    return widget.fixtureRepository.previewSrScenarios(
      homeClanId: widget.fixture.homeClan.id,
      awayClanId: widget.myClan.id,
      myClanId: widget.myClan.id,
    );
  }

  void _retry() {
    setState(() => _scenarios = _loadScenarios());
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            child: InkWell(
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      color: fieldGray500,
                      size: 19,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'How could SR change?',
                        style: TextStyle(
                          color: fieldGray700,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      _expanded ? 'Hide' : 'View',
                      style: const TextStyle(
                        color: fieldGray400,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: fieldGray400,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: _expanded
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(15, 0, 15, 15),
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: fieldGray100)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: FutureBuilder<List<FixtureSrScenario>>(
                        future: _scenarios,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const _SrScenarioLoading();
                          }
                          if (snapshot.hasError || !snapshot.hasData) {
                            return Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    'Could not load SR outcomes.',
                                    style: TextStyle(
                                      color: fieldGray500,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  onPressed: _retry,
                                  tooltip: 'Retry',
                                  icon: const Icon(Icons.refresh_rounded),
                                ),
                              ],
                            );
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Based on both teams\' current SR. Any SR movement is at least 5, and goal-margin impact caps at 3 goals.',
                                style: TextStyle(
                                  color: fieldGray500,
                                  fontSize: 11,
                                  height: 1.35,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 11),
                              for (
                                var index = 0;
                                index < snapshot.data!.length;
                                index++
                              ) ...[
                                _SrScenarioRow(scenario: snapshot.data![index]),
                                if (index != snapshot.data!.length - 1)
                                  const Divider(
                                    height: 15,
                                    color: fieldGray100,
                                  ),
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _SrScenarioRow extends StatelessWidget {
  const _SrScenarioRow({required this.scenario});

  final FixtureSrScenario scenario;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            scenario.label,
            style: const TextStyle(
              color: fieldGray700,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        _SrChangeLabel(label: 'You', change: scenario.myChange),
        const SizedBox(width: 10),
        _SrChangeLabel(label: 'Them', change: scenario.opponentChange),
      ],
    );
  }
}

class _SrChangeLabel extends StatelessWidget {
  const _SrChangeLabel({required this.label, required this.change});

  final String label;
  final int change;

  @override
  Widget build(BuildContext context) {
    final color = change > 0
        ? fieldEmerald600
        : change < 0
        ? const Color(0xFFDC2626)
        : fieldGray500;
    final sign = change > 0 ? '+' : '';

    return Text(
      '$label $sign$change',
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800),
    );
  }
}

class _SrScenarioLoading extends StatelessWidget {
  const _SrScenarioLoading();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        FieldSkeletonBox(height: 16, borderRadius: 6),
        SizedBox(height: 10),
        FieldSkeletonBox(height: 16, borderRadius: 6),
        SizedBox(height: 10),
        FieldSkeletonBox(height: 16, borderRadius: 6),
      ],
    );
  }
}

String _displayRegion(String region) {
  if (region.isEmpty) return 'Region';
  return '${region[0].toUpperCase()}${region.substring(1).toLowerCase()}';
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: iconBackground,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SuccessStep extends StatelessWidget {
  const _SuccessStep({
    super.key,
    required this.controller,
    required this.joined,
    required this.clanName,
  });

  final AnimationController controller;
  final bool joined;
  final String clanName;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, child) {
              return CustomPaint(
                painter: _ConfettiPainter(progress: controller.value),
              );
            },
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ScaleTransition(
                  scale: CurvedAnimation(
                    parent: controller,
                    curve: const Interval(0, 0.42, curve: Curves.elasticOut),
                  ),
                  child: Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [fieldEmerald500, Color(0xFF14B8A6)],
                      ),
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: fieldEmerald500.withValues(alpha: 0.32),
                          blurRadius: 24,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.check_circle_rounded,
                      color: Colors.white,
                      size: 50,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  joined ? 'Match Joined!' : 'Match Created!',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: fieldGray900,
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  joined
                      ? '$clanName is confirmed for this game.'
                      : '$clanName is now hosting this match and open for challenges.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: fieldGray500,
                    fontSize: 16,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  const _ConfettiPainter({required this.progress});

  final double progress;

  static const _colors = [
    fieldEmerald500,
    Color(0xFF14B8A6),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFF3B82F6),
    Color(0xFFA855F7),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final eased = Curves.easeOutCubic.transform(progress.clamp(0, 1));
    final fade = (1 - progress).clamp(0, 1).toDouble();

    for (var i = 0; i < 42; i++) {
      final fromLeft = i.isEven;
      final seed = i + 1.0;
      final startX = fromLeft ? size.width * 0.18 : size.width * 0.82;
      final startY = size.height * 0.30;
      final direction = fromLeft ? 1.0 : -1.0;
      final spreadX = direction * (48 + ((i % 7) * 18));
      final lift = 84 + ((i % 5) * 24);
      final fall = 190 * progress * progress;
      final wobble = math.sin(seed * 1.7 + progress * 8) * 18;
      final x = startX + (spreadX * eased) + wobble;
      final y = startY - (lift * eased) + fall;
      final width = 5.0 + (i % 3);
      final height = 9.0 + (i % 4);
      final paint = Paint()
        ..color = _colors[i % _colors.length].withValues(alpha: fade);

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate((seed * 0.7) + (progress * 5));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: width, height: height),
          const Radius.circular(2),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

class _BottomAction extends StatelessWidget {
  const _BottomAction({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.90),
          border: const Border(top: BorderSide(color: fieldGray100)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: SizedBox(width: double.infinity, height: 54, child: child),
      ),
    );
  }
}

class _OpenFixtureSkeletonRow extends StatelessWidget {
  const _OpenFixtureSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const FieldSkeletonCard(
      height: 74,
      borderRadius: 16,
      padding: EdgeInsets.all(14),
      children: [
        Row(
          children: [
            FieldSkeletonBox(width: 42, height: 42, borderRadius: 12),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FieldSkeletonBox(height: 14, borderRadius: 6),
                  SizedBox(height: 8),
                  FieldSkeletonBox(width: 142, height: 12, borderRadius: 6),
                ],
              ),
            ),
            SizedBox(width: 12),
            FieldSkeletonBox(width: 72, height: 30, borderRadius: 999),
          ],
        ),
      ],
    );
  }
}

class _SimplePanel extends StatelessWidget {
  const _SimplePanel({
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
          Icon(icon, color: fieldGray300, size: 38),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 14),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

DateTime _nextMatchDay(DateTime start) {
  var date = start;
  while (!isFixtureMatchDay(date)) {
    date = date.add(const Duration(days: 1));
  }
  return date;
}

bool _isBooked(List<Fixture> fixtures, DateTime date, FixtureTimeSlot slot) {
  return _activeFixtureCount(fixtures, date, slot) >= 1;
}

int _activeFixtureCount(
  List<Fixture> fixtures,
  DateTime date,
  FixtureTimeSlot slot,
) {
  return fixtures.where((fixture) {
    final sameDate =
        fixture.matchDate.year == date.year &&
        fixture.matchDate.month == date.month &&
        fixture.matchDate.day == date.day;
    final active =
        fixture.status == FixtureStatus.open ||
        fixture.status == FixtureStatus.scheduled ||
        fixture.status == FixtureStatus.live;
    return sameDate && active && fixture.timeSlot == slot.label;
  }).length;
}

bool _sameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

String _formatMonthYear(DateTime date) {
  const months = [
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
  return '${months[date.month - 1]} ${date.year}';
}

String _formatLongDate(DateTime date) {
  const weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  const months = [
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
  return '${weekdays[date.weekday - 1]}, ${months[date.month - 1]} ${date.day}, ${date.year}';
}
