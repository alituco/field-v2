import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import '../core/field_confirmation_dialog.dart';
import '../core/user_facing_error.dart';
import 'profile.dart';
import 'profile_repository.dart';

Future<void> showDevUserSwitcher({
  required BuildContext context,
  required ProfileRepository profileRepository,
  required String currentUserId,
  required Future<void> Function(String profileId) onSwitchUser,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _DevUserSwitcherSheet(
      profileRepository: profileRepository,
      currentUserId: currentUserId,
      onSwitchUser: onSwitchUser,
    ),
  );
}

class _DevUserSwitcherSheet extends StatefulWidget {
  const _DevUserSwitcherSheet({
    required this.profileRepository,
    required this.currentUserId,
    required this.onSwitchUser,
  });

  final ProfileRepository profileRepository;
  final String currentUserId;
  final Future<void> Function(String profileId) onSwitchUser;

  @override
  State<_DevUserSwitcherSheet> createState() => _DevUserSwitcherSheetState();
}

class _DevUserSwitcherSheetState extends State<_DevUserSwitcherSheet> {
  final TextEditingController _searchController = TextEditingController();
  late Future<List<DevProfileOption>> _profilesFuture;
  String _query = '';
  String? _switchingUserId;

  @override
  void initState() {
    super.initState();
    _profilesFuture = widget.profileRepository.listProfilesForDevelopment();
    _searchController.addListener(_updateQuery);
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_updateQuery)
      ..dispose();
    super.dispose();
  }

  void _updateQuery() {
    final query = _searchController.text.trim().toLowerCase();
    if (query == _query) return;
    setState(() => _query = query);
  }

  void _retry() {
    setState(() {
      _profilesFuture = widget.profileRepository.listProfilesForDevelopment();
    });
  }

  Future<void> _switchUser(DevProfileOption profile) async {
    if (_switchingUserId != null || profile.id == widget.currentUserId) return;

    final confirmed = await showFieldConfirmDialog(
      context: context,
      icon: Icons.switch_account_rounded,
      eyebrow: 'Switch user',
      title: 'Continue as ${profile.displayName}?',
      message:
          'The app will reload this user’s profile, bookings, and clan access.',
      detail: profile.username.isEmpty
          ? profile.displayName
          : '@${profile.username}',
      cancelLabel: 'Stay here',
      confirmLabel: 'Switch user',
    );
    if (!confirmed || !mounted) return;

    setState(() => _switchingUserId = profile.id);
    try {
      await widget.onSwitchUser(profile.id);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _switchingUserId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'We could not switch to that user. Try again.',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    return FractionallySizedBox(
      heightFactor: 0.88,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0xFFF8FAFC),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: fieldGray300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Switch User',
                      style: TextStyle(
                        color: fieldGray900,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _switchingUserId == null
                        ? () => Navigator.of(context).pop()
                        : null,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                controller: _searchController,
                autofocus: false,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search users',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: _searchController.clear,
                          icon: const Icon(Icons.close_rounded),
                        ),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: fieldGray200),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: fieldGray200),
                  ),
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<DevProfileOption>>(
                future: _profilesFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const _SwitcherSkeleton();
                  }
                  if (snapshot.hasError || !snapshot.hasData) {
                    return _SwitcherError(onRetry: _retry);
                  }

                  final profiles = snapshot.data!;
                  final filtered = _query.isEmpty
                      ? profiles
                      : profiles
                            .where(
                              (profile) =>
                                  profile.searchableText.contains(_query),
                            )
                            .toList();
                  if (filtered.isEmpty) {
                    return const _EmptySearch();
                  }

                  return ListView.separated(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: EdgeInsets.fromLTRB(12, 0, 12, 16 + keyboardInset),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 68),
                    itemBuilder: (context, index) {
                      final profile = filtered[index];
                      return _ProfileOptionRow(
                        profile: profile,
                        isCurrent: profile.id == widget.currentUserId,
                        isSwitching: profile.id == _switchingUserId,
                        enabled: _switchingUserId == null,
                        onTap: () => _switchUser(profile),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileOptionRow extends StatelessWidget {
  const _ProfileOptionRow({
    required this.profile,
    required this.isCurrent,
    required this.isSwitching,
    required this.enabled,
    required this.onTap,
  });

  final DevProfileOption profile;
  final bool isCurrent;
  final bool isSwitching;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final username = profile.username.isEmpty
        ? 'No username'
        : '@${profile.username}';
    final detail = [
      username,
      if (profile.clan case final clan?) clan.tag,
      if (profile.phone case final phone? when phone.isNotEmpty) phone,
    ].join('  |  ');

    return Material(
      color: isCurrent ? fieldGray100 : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: enabled && !isCurrent ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 72,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                _SwitchAvatar(profile: profile),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: fieldGray900,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: fieldGray500,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isCurrent)
                  const Text(
                    'CURRENT',
                    style: TextStyle(
                      color: fieldEmerald600,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  )
                else
                  Icon(
                    isSwitching
                        ? Icons.hourglass_top_rounded
                        : Icons.login_rounded,
                    color: isSwitching ? fieldEmerald600 : fieldGray400,
                    size: 21,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SwitchAvatar extends StatelessWidget {
  const _SwitchAvatar({required this.profile});

  final DevProfileOption profile;

  @override
  Widget build(BuildContext context) {
    final fallback = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [fieldEmerald500, fieldBlue600]),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          profile.initials,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );

    return SizedBox(
      width: 44,
      height: 44,
      child: ClipOval(
        child: profile.avatarUrl == null || profile.avatarUrl!.isEmpty
            ? fallback
            : Image.network(
                profile.avatarUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => fallback,
              ),
      ),
    );
  }
}

class _SwitcherSkeleton extends StatelessWidget {
  const _SwitcherSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: 7,
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (_, __) => const Row(
        children: [
          FieldSkeletonBox(width: 44, height: 44, borderRadius: 999),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FieldSkeletonBox(height: 15, borderRadius: 5),
                SizedBox(height: 8),
                FieldSkeletonBox(width: 170, height: 11, borderRadius: 5),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitcherError extends StatelessWidget {
  const _SwitcherError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: IconButton.filledTonal(
        tooltip: 'Retry loading users',
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
      ),
    );
  }
}

class _EmptySearch extends StatelessWidget {
  const _EmptySearch();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'No users found',
        style: TextStyle(
          color: fieldGray500,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
