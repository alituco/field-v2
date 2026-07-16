import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';

class FieldBottomNav extends StatelessWidget {
  const FieldBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  final int? selectedIndex;
  final ValueChanged<int> onSelected;

  static const _items = [
    _FieldBottomNavItem(
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
      label: 'Home',
    ),
    _FieldBottomNavItem(
      icon: Icons.calendar_month_outlined,
      selectedIcon: Icons.calendar_month_rounded,
      label: 'Fixtures',
    ),
    _FieldBottomNavItem(
      icon: Icons.shield_outlined,
      selectedIcon: Icons.shield_rounded,
      label: 'Clans',
    ),
    _FieldBottomNavItem(
      icon: Icons.emoji_events_outlined,
      selectedIcon: Icons.emoji_events_rounded,
      label: 'Ranks',
    ),
    _FieldBottomNavItem(
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
      label: 'Profile',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.shrink();
    }

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              color: fieldGray900.withValues(alpha: 0.16),
              blurRadius: 30,
              spreadRadius: -5,
              offset: const Offset(0, 13),
            ),
            BoxShadow(
              color: fieldEmerald600.withValues(alpha: 0.09),
              blurRadius: 20,
              spreadRadius: -7,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              key: const ValueKey('field-liquid-glass-nav'),
              height: 68,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.82),
                    const Color(0xFFF3FAF7).withValues(alpha: 0.66),
                    Colors.white.withValues(alpha: 0.56),
                  ],
                  stops: const [0, 0.52, 1],
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.88),
                  width: 1.2,
                ),
                borderRadius: BorderRadius.circular(32),
              ),
              child: Stack(
                children: [
                  Positioned(
                    top: 1,
                    left: 24,
                    right: 24,
                    child: Container(
                      height: 1,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            Colors.white.withValues(alpha: 0.95),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(5),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final itemWidth = constraints.maxWidth / _items.length;
                        final index = selectedIndex?.clamp(
                          0,
                          _items.length - 1,
                        );
                        final alignmentX = index == null
                            ? -1.0
                            : -1 + (2 * index / (_items.length - 1));

                        return Stack(
                          children: [
                            AnimatedAlign(
                              key: const ValueKey(
                                'field-liquid-glass-selection',
                              ),
                              duration: const Duration(milliseconds: 360),
                              curve: Curves.easeOutCubic,
                              alignment: Alignment(alignmentX, 0),
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 180),
                                opacity: index == null ? 0 : 1,
                                child: SizedBox(
                                  width: itemWidth,
                                  height: double.infinity,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 3,
                                      vertical: 2,
                                    ),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [
                                            Colors.white.withValues(
                                              alpha: 0.94,
                                            ),
                                            fieldEmerald50.withValues(
                                              alpha: 0.76,
                                            ),
                                            Colors.white.withValues(
                                              alpha: 0.62,
                                            ),
                                          ],
                                        ),
                                        border: Border.all(
                                          color: Colors.white.withValues(
                                            alpha: 0.96,
                                          ),
                                        ),
                                        borderRadius: BorderRadius.circular(25),
                                        boxShadow: [
                                          BoxShadow(
                                            color: fieldEmerald700.withValues(
                                              alpha: 0.13,
                                            ),
                                            blurRadius: 14,
                                            spreadRadius: -5,
                                            offset: const Offset(0, 6),
                                          ),
                                          BoxShadow(
                                            color: Colors.white.withValues(
                                              alpha: 0.80,
                                            ),
                                            blurRadius: 5,
                                            offset: const Offset(-2, -2),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Row(
                              children: [
                                for (
                                  var itemIndex = 0;
                                  itemIndex < _items.length;
                                  itemIndex++
                                )
                                  Expanded(
                                    child: _FieldBottomNavButton(
                                      key: ValueKey(
                                        'field-bottom-nav-item-$itemIndex',
                                      ),
                                      item: _items[itemIndex],
                                      isActive: index == itemIndex,
                                      onTap: () => onSelected(itemIndex),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        );
                      },
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

class _FieldBottomNavItem {
  const _FieldBottomNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _FieldBottomNavButton extends StatelessWidget {
  const _FieldBottomNavButton({
    super.key,
    required this.item,
    required this.isActive,
    required this.onTap,
  });

  final _FieldBottomNavItem item;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isActive ? fieldEmerald700 : fieldGray500;

    return Semantics(
      selected: isActive,
      button: true,
      label: item.label,
      child: Tooltip(
        message: item.label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(25),
            child: SizedBox.expand(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedScale(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutBack,
                    scale: isActive ? 1.08 : 1,
                    child: Icon(
                      isActive ? item.selectedIcon : item.icon,
                      size: isActive ? 24 : 23,
                      color: color,
                      weight: isActive ? 2.8 : 2,
                      shadows: isActive
                          ? [
                              Shadow(
                                color: fieldEmerald500.withValues(alpha: 0.24),
                                blurRadius: 8,
                              ),
                            ]
                          : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 220),
                    style: TextStyle(
                      color: color,
                      fontSize: 9.5,
                      height: 1,
                      fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                    ),
                    child: Text(item.label),
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
