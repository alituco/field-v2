import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'open_queue.dart';

const _cream = Color(0xFFFAF7EF);
const _white = Color(0xFFF6F3EA);
const _black = Color(0xFF141714);
const _ink = Color(0xFF22301F);
const _green = Color(0xFF386641);
const _muted = Color(0xFF55654A);
const _lime = Color(0xFFC7DD9B);

/// The saved assignment deadline is a countdown, never proof that teams exist.
/// Only an active server assignment and the player's actual side unlock the
/// team action. The optional due callback lets the owner refresh its data once.
class FieldrushTeamAssignmentNotice extends StatefulWidget {
  const FieldrushTeamAssignmentNotice({
    super.key,
    required this.game,
    this.team,
    this.onSeeTeam,
    this.onAssignmentDue,
    this.now,
    this.captionColor = _muted,
  });

  final OpenQueueGame game;
  final String? team;
  final VoidCallback? onSeeTeam;
  final VoidCallback? onAssignmentDue;
  final DateTime Function()? now;
  final Color captionColor;

  @override
  State<FieldrushTeamAssignmentNotice> createState() =>
      _FieldrushTeamAssignmentNoticeState();
}

class _FieldrushTeamAssignmentNoticeState
    extends State<FieldrushTeamAssignmentNotice> {
  Timer? _timer;
  late DateTime _now;
  bool _dueNotified = false;

  String? get _assignedTeam {
    if (!widget.game.hasActiveTeamAssignment) return null;
    return switch (widget.team?.trim().toUpperCase()) {
      openQueueWhiteTeamId => openQueueWhiteTeamId,
      openQueueBlackTeamId => openQueueBlackTeamId,
      _ => null,
    };
  }

  DateTime _readNow() => widget.now?.call() ?? DateTime.now();

  bool get _waitingForPlayers =>
      widget.game.confirmedCount <
      (widget.game.hasConfigurableMinimum
          ? widget.game.requiredMinimumPlayers
          : widget.game.capacity);

  @override
  void initState() {
    super.initState();
    _configureClock();
  }

  @override
  void didUpdateWidget(covariant FieldrushTeamAssignmentNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.game.id != oldWidget.game.id ||
        widget.game.teamAssignmentAt != oldWidget.game.teamAssignmentAt) {
      _dueNotified = false;
    }
    _configureClock();
  }

  void _configureClock() {
    _timer?.cancel();
    _now = _readNow();
    final cutoff = widget.game.teamAssignmentAt;
    if (_assignedTeam != null || cutoff == null) return;
    if (!_now.isBefore(cutoff)) {
      _notifyDue();
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _now = _readNow());
      if (!_now.isBefore(cutoff)) {
        timer.cancel();
        _notifyDue();
      }
    });
  }

  void _notifyDue() {
    if (_dueNotified || widget.onAssignmentDue == null) return;
    _dueNotified = true;
    final gameId = widget.game.id;
    final cutoff = widget.game.teamAssignmentAt;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          widget.game.id == gameId &&
          widget.game.teamAssignmentAt == cutoff &&
          _assignedTeam == null) {
        widget.onAssignmentDue?.call();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final assigned = _assignedTeam;
    final cutoff = widget.game.teamAssignmentAt;
    final beforeCutoff = cutoff != null && _now.isBefore(cutoff);
    final caption = assigned != null
        ? null
        : beforeCutoff
        ? "You'll be assigned White or Black at ${_clock(widget.game.localDateTime(cutoff))}"
        : cutoff == null
        ? 'Your team will appear here once it is assigned.'
        : _waitingForPlayers
        ? 'Waiting for enough players before teams can be assigned.'
        : 'Your team assignment is updating.';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (caption != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
            child: Text(
              caption,
              textAlign: TextAlign.center,
              style: _jakarta(
                11,
                color: widget.captionColor,
              ).copyWith(fontWeight: FontWeight.w700, height: 1.3),
            ),
          ),
        Stack(
          key: const ValueKey('team-assignment-ticket'),
          fit: StackFit.passthrough,
          children: [
            if (assigned == null)
              _pendingTicket(context, beforeCutoff: beforeCutoff)
            else
              _assignedTicket(context, assigned),
            for (final left in [true, false])
              Positioned(
                top: -10,
                left: left ? -10 : null,
                right: left ? null : -10,
                child: const ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _cream,
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox(width: 20, height: 20),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _pendingTicket(BuildContext context, {required bool beforeCutoff}) {
    final cutoff = widget.game.teamAssignmentAt;
    final seconds = cutoff == null
        ? 0
        : math.max(0, (cutoff.difference(_now).inMilliseconds / 1000).ceil());
    final status = cutoff == null
        ? 'TEAMS PENDING'
        : _waitingForPlayers
        ? 'WAITING FOR PLAYERS'
        : 'ASSIGNMENT UPDATING';
    final badge = Container(
      key: const ValueKey('team-assignment-countdown'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _green,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (beforeCutoff) ...[
            Text(
              '${seconds ~/ 3600}:${_two(seconds ~/ 60 % 60)}:${_two(seconds % 60)}',
              style: const TextStyle(
                fontFamily: 'Outfit',
                fontWeight: FontWeight.w800,
                fontSize: 17,
                height: 1,
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 5),
          ],
          Text(
            beforeCutoff ? 'UNTIL ASSIGNED' : status,
            textAlign: TextAlign.center,
            style: _jakarta(8.5, color: _lime, tracking: 1.02),
          ),
        ],
      ),
    );
    return Semantics(
      label: beforeCutoff
          ? 'Teams will be assigned at ${_clock(widget.game.localDateTime(cutoff!))}'
          : status.toLowerCase(),
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final expanded =
                constraints.maxWidth < 300 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.2;
            final sides = Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('WHITE', style: _jakarta(11, color: _ink, tracking: 1.54)),
                Text(
                  'BLACK',
                  style: _jakarta(11, color: _white, tracking: 1.54),
                ),
              ],
            );
            return Stack(
              children: [
                Positioned.fill(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: const [
                      Expanded(
                        child: ColoredBox(
                          key: ValueKey('team-assignment-white-half'),
                          color: _white,
                        ),
                      ),
                      Expanded(
                        child: ColoredBox(
                          key: ValueKey('team-assignment-black-half'),
                          color: _black,
                        ),
                      ),
                    ],
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 66),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: expanded ? 12 : 8,
                    ),
                    child: expanded
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              sides,
                              const SizedBox(height: 10),
                              badge,
                            ],
                          )
                        : Stack(
                            alignment: Alignment.center,
                            children: [
                              sides,
                              Center(child: badge),
                            ],
                          ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _assignedTicket(BuildContext context, String team) {
    final white = team == openQueueWhiteTeamId;
    final heading = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "YOU'RE ON",
          style: _jakarta(
            9,
            color: white ? _muted : const Color(0xFFA9B3A6),
            tracking: 1.26,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          team,
          style: TextStyle(
            fontFamily: 'Outfit',
            fontWeight: FontWeight.w800,
            fontSize: 24,
            height: .9,
            letterSpacing: .96,
            color: white ? _ink : const Color(0xFFF3EBD6),
          ),
        ),
      ],
    );
    final link = Text(
      'See your team ›',
      style: _jakarta(11.5, color: white ? _green : const Color(0xFFA7C957)),
    );
    return Semantics(
      label: "You're on ${white ? 'White' : 'Black'}. See your team",
      button: widget.onSeeTeam != null,
      onTap: widget.onSeeTeam,
      child: ExcludeSemantics(
        child: Material(
          color: white ? _white : _black,
          child: InkWell(
            key: const ValueKey('team-assignment-see-team'),
            onTap: widget.onSeeTeam,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 66),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 12,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) =>
                      constraints.maxWidth < 270 &&
                          MediaQuery.textScalerOf(context).scale(1) > 1.2
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [heading, const SizedBox(height: 12), link],
                        )
                      : Row(
                          children: [
                            heading,
                            const Spacer(),
                            const SizedBox(width: 12),
                            Flexible(flex: 2, child: link),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

TextStyle _jakarta(double size, {required Color color, double? tracking}) =>
    TextStyle(
      fontFamily: 'PlusJakartaSans',
      fontWeight: FontWeight.w800,
      fontSize: size,
      height: 1,
      color: color,
      letterSpacing: tracking,
    );

String _two(int value) => value.toString().padLeft(2, '0');

String _clock(DateTime value) =>
    '${value.hour % 12 == 0 ? 12 : value.hour % 12}:${_two(value.minute)} ${value.hour < 12 ? 'AM' : 'PM'}';
