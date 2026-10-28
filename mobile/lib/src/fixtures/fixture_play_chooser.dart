import 'package:flutter/material.dart';

import '../ui/field_loading.dart';
import '../clans/clan_widgets.dart';
import '../core/field_confirmation_dialog.dart';
import '../core/user_facing_error.dart';
import 'fixture.dart';

enum FixturePlayMode { solo, clan }

class FixturePlaySelection {
  const FixturePlaySelection._(this.mode, this.membership);

  const FixturePlaySelection.solo() : this._(FixturePlayMode.solo, null);

  const FixturePlaySelection.clan(MyClanMembership? membership)
    : this._(FixturePlayMode.clan, membership);

  final FixturePlayMode mode;
  final MyClanMembership? membership;
}

Future<FixturePlaySelection?> showFixturePlayChooser({
  required BuildContext context,
  required Future<MyClanMembership?> Function() loadMembership,
  required Future<bool> Function() loadClanAvailability,
  MyClanMembership? cachedMembership,
}) {
  return showModalBottomSheet<FixturePlaySelection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .48),
    builder: (_) => _FixturePlayChooser(
      cachedMembership: cachedMembership,
      loadMembership: loadMembership,
      loadClanAvailability: loadClanAvailability,
    ),
  );
}

Future<bool> showClanScheduleBlockedDialog({
  required BuildContext context,
  required MyClanMembership? membership,
}) async {
  final hasClan = membership != null;
  final clanName = membership?.clan.name;
  final goToClans = await showFieldConfirmDialog(
    context: context,
    icon: Icons.lock_outline_rounded,
    eyebrow: 'Access required',
    title: hasClan
        ? 'Only owners and leaders can schedule'
        : 'Join a clan first',
    message: hasClan
        ? 'You are a member of $clanName. Only the owner or a leader can schedule or join games for this clan. Ask one of them to schedule the game or promote you.'
        : 'Clan games must be scheduled by a clan owner or leader. Join or create a clan, then come back here to play for it.',
    cancelLabel: 'Got it',
    confirmLabel: 'Go to Clans',
  );
  return goToClans;
}

class _FixturePlayChooser extends StatefulWidget {
  const _FixturePlayChooser({
    required this.cachedMembership,
    required this.loadMembership,
    required this.loadClanAvailability,
  });

  final MyClanMembership? cachedMembership;
  final Future<MyClanMembership?> Function() loadMembership;
  final Future<bool> Function() loadClanAvailability;

  @override
  State<_FixturePlayChooser> createState() => _FixturePlayChooserState();
}

class _FixturePlayChooserState extends State<_FixturePlayChooser> {
  MyClanMembership? _membership;
  bool _checkingClan = true;
  bool _clanEnabled = false;
  String? _clanError;

  @override
  void initState() {
    super.initState();
    _membership = widget.cachedMembership;
    _loadMembership();
  }

  Future<void> _loadMembership() async {
    setState(() {
      _checkingClan = true;
      _clanError = null;
    });
    try {
      final enabled = await widget.loadClanAvailability();
      if (!mounted) return;
      setState(() => _clanEnabled = enabled);
      if (!enabled) return;
      final membership = await widget.loadMembership();
      if (!mounted) return;
      setState(() => _membership = membership);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _clanError = userFacingError(
          error,
          fallback: 'We could not check your clan access. Tap to try again.',
        );
      });
    } finally {
      if (mounted) setState(() => _checkingClan = false);
    }
  }

  void _chooseSolo() {
    Navigator.of(context).pop(const FixturePlaySelection.solo());
  }

  void _chooseClan() {
    if (_checkingClan || !_clanEnabled) return;
    if (_clanError != null) {
      _loadMembership();
      return;
    }
    Navigator.of(context).pop(FixturePlaySelection.clan(_membership));
  }

  @override
  Widget build(BuildContext context) {
    final membership = _membership;
    final isManager = membership?.canManageMatches == true;
    final clanMessage = switch ((
      _checkingClan,
      _clanError,
      membership,
      isManager,
    )) {
      (true, _, _, _) => 'Checking your clan access…',
      (false, final String error, _, _) => error,
      (false, null, final MyClanMembership value, true) =>
        'Tuesdays and Fridays, 7:00–8:00 PM. Schedule or join for ${value.clan.name}.',
      (false, null, final MyClanMembership value, false) =>
        'Clan games run Tuesdays and Fridays, 7:00–8:00 PM. Only owners and leaders can schedule for ${value.clan.name}.',
      _ =>
        'Clan games run Tuesdays and Fridays, 7:00–8:00 PM. Join or create a clan to schedule.',
    };
    final clanStatus = switch ((
      _checkingClan,
      _clanError,
      membership,
      isManager,
    )) {
      (true, _, _, _) => 'CHECKING',
      (false, final String _, _, _) => 'TAP TO RETRY',
      (false, null, final MyClanMembership value, true) =>
        '${value.role.toUpperCase()} · ${value.clan.tag}',
      (false, null, final MyClanMembership _, false) => 'MEMBER · LOCKED',
      _ => 'NO CLAN',
    };

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          18,
          10,
          18,
          18 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        decoration: const BoxDecoration(
          color: fieldBackground,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: fieldGray300,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'HOW DO YOU WANT TO PLAY?',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 23,
                  height: 1.08,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -.4,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Join an upcoming solo game.',
                style: TextStyle(
                  color: fieldGray500,
                  fontSize: 14,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 18),
              _PlayChoiceCard(
                key: const ValueKey('play-solo-choice'),
                icon: Icons.person_rounded,
                iconColor: fieldBlue600,
                iconBackground: const Color(0xFFEFF6FF),
                title: 'Solo game',
                status: 'OPEN QUEUE',
                message:
                    'Tuesdays and Fridays, 8:30–9:30 PM. Choose your positions and join.',
                onTap: _chooseSolo,
              ),
              const SizedBox(height: 12),
              _PlayChoiceCard(
                key: const ValueKey('play-clan-choice'),
                icon: isManager
                    ? Icons.shield_rounded
                    : Icons.lock_outline_rounded,
                iconColor: isManager
                    ? fieldEmerald700
                    : const Color(0xFFEA580C),
                iconBackground: isManager
                    ? fieldEmerald50
                    : const Color(0xFFFFF7ED),
                title: 'Clan game',
                status: _clanEnabled ? clanStatus : 'PAUSED',
                message: _clanEnabled
                    ? clanMessage
                    : 'Clan games are currently unavailable. Existing match history and refunds are still accessible.',
                loading: _checkingClan,
                onTap: _clanEnabled ? _chooseClan : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayChoiceCard extends StatelessWidget {
  const _PlayChoiceCard({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.title,
    required this.status,
    required this.message,
    required this.onTap,
    this.loading = false,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String title;
  final String status;
  final String message;
  final VoidCallback? onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: fieldGray200),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: iconBackground,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: iconColor, size: 27),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 7,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: fieldGray900,
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: fieldGray100,
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            status,
                            style: const TextStyle(
                              color: fieldGray600,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                              letterSpacing: .5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      message,
                      style: const TextStyle(
                        color: fieldGray500,
                        fontSize: 12,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: FieldLoadingIndicator(),
                )
              else
                const Icon(Icons.chevron_right_rounded, color: fieldGray400),
            ],
          ),
        ),
      ),
    );
  }
}
