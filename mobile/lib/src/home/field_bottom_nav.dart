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
    return Material(
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: fieldGray200)),
          ),
          child: Row(
            children: [
              for (var index = 0; index < _items.length; index++)
                Expanded(
                  child: _FieldBottomNavButton(
                    item: _items[index],
                    isActive: selectedIndex == index,
                    onTap: () => onSelected(index),
                  ),
                ),
            ],
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
    required this.item,
    required this.isActive,
    required this.onTap,
  });

  final _FieldBottomNavItem item;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isActive ? fieldEmerald600 : fieldGray500;
    return Semantics(
      selected: isActive,
      button: true,
      label: item.label,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isActive ? item.selectedIcon : item.icon,
              size: 24,
              color: color,
              weight: isActive ? 2.5 : 2,
            ),
            const SizedBox(height: 2),
            Text(
              item.label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
