import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/field_confirmation_dialog.dart';
import '../core/user_facing_error.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_avatar_image.dart';
import '../ui/fieldrush_modal.dart';
import '../ui/fieldrush_toast.dart';
import 'profile.dart';
import 'profile_repository.dart';

Future<void> showDevUserSwitcher({
  required BuildContext context,
  required ProfileRepository profileRepository,
  required String currentUserId,
  required Future<void> Function(String profileId) onSwitchUser,
}) {
  return showFieldrushModal<void>(
    context: context,
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
      eyebrow: 'Swap profile',
      title: 'Continue as ${profile.displayName}?',
      message:
          'Open this staging account for up to 15 minutes. Actions affect its staging data. Restart the app or choose your admin profile to return.',
      detail: profile.username.isEmpty
          ? profile.displayName
          : '@${profile.username}',
      cancelLabel: 'Stay here',
      confirmLabel: 'Swap profile',
    );
    if (!confirmed || !mounted) return;

    setState(() => _switchingUserId = profile.id);
    try {
      await widget.onSwitchUser(profile.id);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _switchingUserId = null);
      showFieldrushToast(
        context,
        userFacingError(
          error,
          fallback: 'We could not switch to that user. Try again.',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FieldrushModal(
      key: const ValueKey('dev-user-switcher-sheet'),
      title: 'Swap profile',
      eyebrow: 'Staging admin only',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('dev-user-search'),
            controller: _searchController,
            autofocus: false,
            textInputAction: TextInputAction.search,
            style: FieldrushModal.bodyStyle.copyWith(
              color: FieldrushAuthTheme.ink,
            ),
            decoration: InputDecoration(
              hintText: 'Search profiles',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: _searchController.clear,
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
          const SizedBox(height: 14),
          FutureBuilder<List<DevProfileOption>>(
            future: _profilesFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const FieldLoadingContent(
                  label: 'Loading profiles',
                  rows: 4,
                  compact: true,
                );
              }
              if (snapshot.hasError || !snapshot.hasData) {
                return _SwitcherError(onRetry: _retry);
              }
              final profiles = snapshot.data!;
              final filtered = _query.isEmpty
                  ? profiles
                  : profiles
                        .where(
                          (profile) => profile.searchableText.contains(_query),
                        )
                        .toList();
              if (filtered.isEmpty) return const _EmptySearch();
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: FieldrushAuthTheme.border),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var index = 0; index < filtered.length; index++) ...[
                      if (index > 0)
                        const Divider(
                          height: 1,
                          color: FieldrushAuthTheme.border,
                        ),
                      _ProfileOptionRow(
                        profile: filtered[index],
                        isCurrent: filtered[index].id == widget.currentUserId,
                        isSwitching: filtered[index].id == _switchingUserId,
                        enabled: _switchingUserId == null,
                        onTap: () => _switchUser(filtered[index]),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
      actions: [
        OutlinedButton(
          key: const ValueKey('dev-user-switcher-close'),
          onPressed: _switchingUserId == null
              ? () => Navigator.of(context).pop()
              : null,
          style: FieldrushModal.secondaryButtonStyle(),
          child: const Text('Close'),
        ),
      ],
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
      color: isCurrent ? FieldrushAuthTheme.watermark : Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        key: ValueKey('dev-user-option-${profile.id}'),
        onTap: enabled && !isCurrent ? onTap : null,
        borderRadius: BorderRadius.circular(18),
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
                          fontFamily: 'PlusJakartaSans',
                          color: FieldrushAuthTheme.ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'PlusJakartaSans',
                          color: FieldrushAuthTheme.muted,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
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
                      fontFamily: 'PlusJakartaSans',
                      color: FieldrushAuthTheme.forest,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  )
                else
                  Icon(
                    isSwitching
                        ? Icons.hourglass_top_rounded
                        : Icons.login_rounded,
                    color: isSwitching
                        ? FieldrushAuthTheme.forest
                        : FieldrushAuthTheme.muted,
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
        color: FieldrushAuthTheme.forest,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          profile.initials,
          style: const TextStyle(
            fontFamily: 'Outfit',
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
        child: FieldrushAvatarImage(
          size: 44,
          url: profile.avatarUrl,
          fallback: fallback,
        ),
      ),
    );
  }
}

class _SwitcherError extends StatelessWidget {
  const _SwitcherError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onRetry,
      style: FieldrushModal.secondaryButtonStyle(),
      icon: const Icon(Icons.refresh_rounded),
      label: const Text('Retry loading users'),
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
          fontFamily: 'PlusJakartaSans',
          color: FieldrushAuthTheme.muted,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
