import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../home/field_bottom_nav.dart';
import 'open_queue.dart';
import 'open_queue_games_screen.dart';
import 'open_queue_repository.dart';

const _queueRoleOrder = [
  OpenQueueRole.attacker,
  OpenQueueRole.midfielder,
  OpenQueueRole.defender,
  OpenQueueRole.goalkeeper,
];

class OpenQueueScreen extends StatefulWidget {
  const OpenQueueScreen({
    super.key,
    required this.repository,
    this.initialMainRole,
    this.initialBackupRoles = const {},
    this.onNavigateTab,
  });

  final OpenQueueRepository repository;
  final OpenQueueRole? initialMainRole;
  final Set<OpenQueueRole> initialBackupRoles;
  final ValueChanged<int>? onNavigateTab;

  @override
  State<OpenQueueScreen> createState() => _OpenQueueScreenState();
}

class _OpenQueueScreenState extends State<OpenQueueScreen> {
  OpenQueueRole? _mainRole;
  late Set<OpenQueueRole> _backupRoles;
  List<OpenQueueGame> _games = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _mainRole = widget.initialMainRole;
    _backupRoles = {...widget.initialBackupRoles};
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final games = await widget.repository.listGames();
      if (!mounted) return;
      setState(() => _games = games);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = userFacingError(
          error,
          fallback: 'We could not load Open Queue games.',
        );
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectMain(OpenQueueRole role) {
    setState(() {
      final wasAnywhere = _isAnywhere;
      _mainRole = _mainRole == role ? null : role;
      _backupRoles.remove(role);
      if (wasAnywhere && _mainRole != null) {
        _backupRoles = _queueRoleOrder.where((item) => item != role).toSet();
      }
    });
  }

  bool get _isAnywhere =>
      _mainRole != null && _backupRoles.length == _queueRoleOrder.length - 1;

  void _toggleBackup(OpenQueueRole role) {
    setState(() {
      if (_isAnywhere) _backupRoles.clear();
      if (_backupRoles.contains(role)) {
        _backupRoles.remove(role);
      } else if (_backupRoles.length < 2) {
        _backupRoles.add(role);
      }
    });
  }

  void _toggleAnywhere() {
    final main = _mainRole;
    if (main == null) return;
    setState(() {
      if (_isAnywhere) {
        _backupRoles.clear();
      } else {
        _backupRoles = _queueRoleOrder.where((role) => role != main).toSet();
      }
    });
  }

  int _gameCount(OpenQueueRole role) {
    return _games.where((game) => game.canBook(role)).length;
  }

  Future<void> _continue() async {
    final role = _mainRole;
    if (role == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => OpenQueueGamesScreen(
          repository: widget.repository,
          mainRole: role,
          backupRoles: _backupRoles,
          onNavigateTab: widget.onNavigateTab,
        ),
      ),
    );
    if (mounted) await _load();
  }

  void _navigateTab(int index) {
    widget.onNavigateTab?.call(index);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: const FieldPageHeader(title: 'Open Queue', showBack: true),
        child: RefreshIndicator(
          color: fieldEmerald600,
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: fieldHeaderAwarePadding(
              context,
              top: 18,
              bottom: _mainRole == null ? 116 : 218,
            ),
            children: [
              const Text(
                'WHERE DO YOU PLAY?',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Choose your main position.',
                style: TextStyle(
                  color: fieldGray500,
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 20),
              _QueuePitch(
                mainRole: _mainRole,
                backupRoles: _backupRoles,
                onSelect: _selectMain,
              ),
              const SizedBox(height: 24),
              const _QueueLabel('MAIN POSITION'),
              const SizedBox(height: 9),
              GridView.count(
                key: const ValueKey('main-position-grid'),
                crossAxisCount: 2,
                shrinkWrap: true,
                primary: false,
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 2.8,
                children: [
                  for (final role in _queueRoleOrder)
                    _RoleButton(
                      role: role,
                      selected: _mainRole == role,
                      onTap: () => _selectMain(role),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                _QueueMessage(
                  icon: Icons.error_outline_rounded,
                  text: _error!,
                  action: 'Retry',
                  onAction: _load,
                ),
              ],
              if (_mainRole case final mainRole?) ...[
                const SizedBox(height: 24),
                const _QueueLabel('WHERE ELSE ARE YOU COMFORTABLE PLAYING?'),
                const SizedBox(height: 3),
                const Text(
                  'Optional · up to 2 backups',
                  style: TextStyle(
                    color: fieldGray400,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final role in _queueRoleOrder)
                      if (role != mainRole)
                        _BackupRoleChip(
                          label: role.label,
                          selected: _backupRoles.contains(role),
                          disabled:
                              !_backupRoles.contains(role) &&
                              !_isAnywhere &&
                              _backupRoles.length >= 2,
                          onTap: () => _toggleBackup(role),
                        ),
                    _BackupRoleChip(
                      label: 'Anywhere',
                      selected: _isAnywhere,
                      onTap: _toggleAnywhere,
                    ),
                  ],
                ),
                if (mainRole == OpenQueueRole.goalkeeper ||
                    _backupRoles.contains(OpenQueueRole.goalkeeper)) ...[
                  const SizedBox(height: 12),
                  const _GoalkeeperNotice(),
                ],
                const SizedBox(height: 14),
                _AvailabilityCard(
                  gameCount: _gameCount(mainRole),
                  role: mainRole,
                ),
              ],
            ],
          ),
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_mainRole != null)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: fieldGray200)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: fieldEmerald500,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          _mainRole!.label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      if (_backupRoles.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '+ ${_isAnywhere ? 'Anywhere' : _backupRoles.map((role) => role.label).join(', ')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: fieldGray500,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 11),
                  FilledButton.icon(
                    onPressed: _loading || _error != null ? null : _continue,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                      backgroundColor: fieldEmerald600,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    icon: const Icon(Icons.chevron_right_rounded),
                    iconAlignment: IconAlignment.end,
                    label: const Text(
                      'See matching games',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          FieldBottomNav(selectedIndex: null, onSelected: _navigateTab),
        ],
      ),
    );
  }
}

class _QueuePitch extends StatelessWidget {
  const _QueuePitch({
    required this.mainRole,
    required this.backupRoles,
    required this.onSelect,
  });

  final OpenQueueRole? mainRole;
  final Set<OpenQueueRole> backupRoles;
  final ValueChanged<OpenQueueRole> onSelect;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        key: const ValueKey('open-queue-pitch'),
        constraints: const BoxConstraints(maxWidth: 300),
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0D9668),
                  Color(0xFF059669),
                  Color(0xFF065F46),
                ],
                stops: [0, 0.4, 1],
              ),
              borderRadius: BorderRadius.circular(32),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x6610B981),
                  blurRadius: 28,
                  offset: Offset(0, 16),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const nodes = [
                    (OpenQueueRole.attacker, .50, .16),
                    (OpenQueueRole.midfielder, .27, .43),
                    (OpenQueueRole.midfielder, .73, .43),
                    (OpenQueueRole.defender, .27, .69),
                    (OpenQueueRole.defender, .73, .69),
                    (OpenQueueRole.goalkeeper, .50, .90),
                  ];
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(painter: _PitchPainter()),
                      ),
                      for (final node in nodes)
                        Positioned(
                          left: constraints.maxWidth * node.$2 - 34,
                          top: constraints.maxHeight * node.$3 - 34,
                          child: _PitchRoleNode(
                            role: node.$1,
                            isMain: mainRole == node.$1,
                            isBackup: backupRoles.contains(node.$1),
                            onTap: onSelect,
                          ),
                        ),
                      if (mainRole == null)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 12,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 13,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: .38),
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: const Text(
                                'Tap your main position',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PitchRoleNode extends StatelessWidget {
  const _PitchRoleNode({
    required this.role,
    required this.isMain,
    required this.isBackup,
    required this.onTap,
  });

  final OpenQueueRole role;
  final bool isMain;
  final bool isBackup;
  final ValueChanged<OpenQueueRole> onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 68,
      height: 82,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          if (isMain)
            Positioned(
              top: 4,
              child: Container(
                width: 58,
                height: 58,
                decoration: const BoxDecoration(
                  color: Color(0xFFBEF264),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: Color(0xAA84CC16), blurRadius: 18),
                  ],
                ),
              ),
            ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onTap(role),
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: isMain
                        ? Colors.white
                        : isBackup
                        ? Colors.white.withValues(alpha: .25)
                        : Colors.white.withValues(alpha: .10),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isMain || isBackup
                          ? Colors.white
                          : Colors.white.withValues(alpha: .50),
                      width: 2,
                    ),
                    boxShadow: isMain
                        ? const [
                            BoxShadow(
                              color: Color(0x55000000),
                              blurRadius: 12,
                              offset: Offset(0, 5),
                            ),
                          ]
                        : null,
                  ),
                  child: Center(
                    child: isMain
                        ? const Icon(
                            Icons.check_rounded,
                            color: fieldEmerald700,
                            size: 29,
                            weight: 900,
                          )
                        : Text(
                            role.code,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: .90),
                              fontWeight: FontWeight.w900,
                              fontSize: 12,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
          if (isMain || isBackup)
            Positioned(
              top: 64,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .42),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  isMain ? 'MAIN' : 'BACKUP',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 8,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PitchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final stripe = Paint()..color = Colors.white.withValues(alpha: .14);
    final stripeHeight = size.height / 6;
    for (var index = 0; index < 6; index += 2) {
      canvas.drawRect(
        Rect.fromLTWH(0, index * stripeHeight, size.width, stripeHeight),
        stripe,
      );
    }
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.34)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final rect = Rect.fromLTWH(12, 12, size.width - 24, size.height - 24);
    canvas.drawLine(
      Offset(12, size.height / 2),
      Offset(size.width - 12, size.height / 2),
      paint,
    );
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width * .153,
      paint,
    );
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      3,
      Paint()..color = Colors.white.withValues(alpha: .5),
    );
    canvas.drawRect(
      Rect.fromLTWH(size.width * .307, 12, size.width * .386, 44),
      paint,
    );
    canvas.drawRect(
      Rect.fromLTWH(size.width * .307, size.height - 56, size.width * .386, 44),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(11)),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _RoleButton extends StatelessWidget {
  const _RoleButton({
    required this.role,
    required this.selected,
    required this.onTap,
  });

  final OpenQueueRole role;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? fieldEmerald500 : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? fieldEmerald500 : fieldGray200,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  role.label,
                  maxLines: 1,
                  style: TextStyle(
                    color: selected ? Colors.white : fieldGray900,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Icon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: selected ? Colors.white : fieldGray200,
                size: 23,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BackupRoleChip extends StatelessWidget {
  const _BackupRoleChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.disabled = false,
  });

  final String label;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? fieldEmerald700
        : disabled
        ? fieldGray300
        : fieldGray600;
    final border = selected
        ? fieldEmerald500
        : disabled
        ? fieldGray100
        : fieldGray200;
    return Material(
      color: selected ? fieldEmerald50 : Colors.white,
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(99),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: border, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                const Icon(
                  Icons.check_rounded,
                  color: fieldEmerald700,
                  size: 16,
                ),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  color: foreground,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoalkeeperNotice extends StatelessWidget {
  const _GoalkeeperNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFEF3C7)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: Color(0xFFD97706), size: 17),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              "Only choose Goalkeeper if you're comfortable playing the full match in goal.",
              style: TextStyle(
                color: Color(0xFF92400E),
                fontSize: 12,
                height: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AvailabilityCard extends StatelessWidget {
  const _AvailabilityCard({required this.gameCount, required this.role});

  final int gameCount;
  final OpenQueueRole role;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: fieldGray100),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D111827),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$gameCount upcoming game${gameCount == 1 ? '' : 's'} can use you as ${role.label.toLowerCase()}',
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          const Text(
            'Pick the position you actually want to play — availability can change.',
            style: TextStyle(
              color: fieldGray400,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueLabel extends StatelessWidget {
  const _QueueLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: fieldGray500,
        fontSize: 11,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _QueueMessage extends StatelessWidget {
  const _QueueMessage({
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: fieldEmerald50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: fieldEmerald100),
      ),
      child: Row(
        children: [
          Icon(icon, color: fieldEmerald700, size: 18),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: fieldGray700,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (action != null)
            TextButton(onPressed: onAction, child: Text(action!)),
        ],
      ),
    );
  }
}
