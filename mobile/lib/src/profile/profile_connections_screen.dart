import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import 'profile.dart';
import 'profile_repository.dart';

class ProfileConnectionsScreen extends StatefulWidget {
  const ProfileConnectionsScreen({
    super.key,
    required this.profileRepository,
    required this.initialTab,
    required this.onOpenProfile,
  });

  final ProfileRepository profileRepository;
  final ProfileConnectionTab initialTab;
  final Future<void> Function(String profileId) onOpenProfile;

  @override
  State<ProfileConnectionsScreen> createState() =>
      _ProfileConnectionsScreenState();
}

class _ProfileConnectionsScreenState extends State<ProfileConnectionsScreen> {
  late ProfileConnectionTab _tab;
  ProfileConnections? _connections;
  Object? _error;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    _loadConnections(showLoading: true);
  }

  Future<void> _loadConnections({bool showLoading = false}) async {
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final connections = await widget.profileRepository.getConnections();
      if (!mounted) return;
      setState(() {
        _connections = connections;
        _error = null;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _isLoading = false;
      });
    }
  }

  Future<void> _refresh() async {
    await _loadConnections();
  }

  Future<void> _toggleFollow(ProfileConnection connection) async {
    final previous = _connections;
    if (previous == null) return;

    setState(() {
      _connections = _optimisticToggle(previous, connection);
    });

    try {
      if (connection.isFollowedByMe) {
        await widget.profileRepository.unfollowProfile(connection.id);
      } else {
        await widget.profileRepository.followProfile(connection.id);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _connections = previous;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'We could not update that follow. Try again.',
            ),
          ),
        ),
      );
    }
  }

  void _close() {
    final connections = _connections;
    Navigator.of(context).pop(
      connections == null
          ? null
          : ProfileConnectionCounts(
              followingCount: connections.following.length,
              fansCount: connections.fans.length,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: FieldPageHeader(
          title: 'People',
          showBack: true,
          onBack: _close,
        ),
        child: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final connections = _connections;
    final error = _error;

    if (_isLoading && connections == null) {
      return const _ConnectionsLoadingView();
    }

    if (error != null && connections == null) {
      return _ConnectionsErrorView(
        message: userFacingError(
          error,
          fallback: 'We could not load these people. Try again.',
        ),
        onRetry: () => _loadConnections(showLoading: true),
      );
    }

    if (connections == null) {
      return _ConnectionsErrorView(
        message: 'Could not load people.',
        onRetry: () => _loadConnections(showLoading: true),
      );
    }

    final list = _tab == ProfileConnectionTab.following
        ? connections.following
        : connections.fans;

    return RefreshIndicator(
      color: fieldEmerald600,
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: fieldHeaderAwarePadding(context, top: 16, bottom: 36),
        children: [
          _ConnectionTabs(
            tab: _tab,
            followingCount: connections.following.length,
            fansCount: connections.fans.length,
            onChanged: (tab) => setState(() => _tab = tab),
          ),
          const SizedBox(height: 18),
          _PeopleCard(
            emptyTitle: _tab == ProfileConnectionTab.following
                ? "You're not following anyone yet"
                : 'No fans yet',
            emptySubtitle: _tab == ProfileConnectionTab.following
                ? 'Discover players below to build your network.'
                : 'Keep playing to grow your fanbase.',
            people: list,
            onToggleFollow: _toggleFollow,
            onOpenProfile: widget.onOpenProfile,
          ),
          if (connections.discover.isNotEmpty) ...[
            const SizedBox(height: 22),
            const _DiscoverHeader(),
            const SizedBox(height: 8),
            _PeopleCard(
              people: connections.discover,
              onToggleFollow: _toggleFollow,
              onOpenProfile: widget.onOpenProfile,
            ),
          ],
        ],
      ),
    );
  }
}

ProfileConnections _optimisticToggle(
  ProfileConnections current,
  ProfileConnection connection,
) {
  final isNowFollowed = !connection.isFollowedByMe;
  final updatedConnection = connection.copyWith(isFollowedByMe: isNowFollowed);

  List<ProfileConnection> updateFollowState(List<ProfileConnection> people) {
    return [
      for (final person in people)
        person.id == connection.id
            ? person.copyWith(isFollowedByMe: isNowFollowed)
            : person,
    ];
  }

  var following = updateFollowState(current.following);
  final fans = updateFollowState(current.fans);
  var discover = updateFollowState(current.discover);

  if (isNowFollowed) {
    discover = [
      for (final person in discover)
        if (person.id != connection.id) person,
    ];

    if (!following.any((person) => person.id == connection.id)) {
      following = [updatedConnection, ...following];
    }
  } else {
    following = [
      for (final person in following)
        if (person.id != connection.id) person,
    ];

    if (!discover.any((person) => person.id == connection.id)) {
      discover = [updatedConnection, ...discover];
    }
  }

  return ProfileConnections(
    following: following,
    fans: fans,
    discover: discover,
  );
}

class _ConnectionTabs extends StatelessWidget {
  const _ConnectionTabs({
    required this.tab,
    required this.followingCount,
    required this.fansCount,
    required this.onChanged,
  });

  final ProfileConnectionTab tab;
  final int followingCount;
  final int fansCount;
  final ValueChanged<ProfileConnectionTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: fieldGray100,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Expanded(
            child: _TabButton(
              active: tab == ProfileConnectionTab.following,
              icon: Icons.people_alt_outlined,
              label: 'Following $followingCount',
              onTap: () => onChanged(ProfileConnectionTab.following),
            ),
          ),
          Expanded(
            child: _TabButton(
              active: tab == ProfileConnectionTab.fans,
              icon: Icons.favorite_border_rounded,
              label: 'Fans $fansCount',
              onTap: () => onChanged(ProfileConnectionTab.fans),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.active,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool active;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: active
              ? const LinearGradient(colors: [fieldEmerald500, fieldBlue600])
              : null,
          boxShadow: active
              ? [
                  BoxShadow(
                    color: fieldEmerald500.withValues(alpha: 0.28),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: active ? Colors.white : fieldGray500),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? Colors.white : fieldGray500,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PeopleCard extends StatelessWidget {
  const _PeopleCard({
    required this.people,
    required this.onToggleFollow,
    required this.onOpenProfile,
    this.emptyTitle,
    this.emptySubtitle,
  });

  final List<ProfileConnection> people;
  final ValueChanged<ProfileConnection> onToggleFollow;
  final Future<void> Function(String profileId) onOpenProfile;
  final String? emptyTitle;
  final String? emptySubtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: fieldGray900.withValues(alpha: 0.035),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: people.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 34),
              child: Column(
                children: [
                  Text(
                    emptyTitle ?? 'No players yet',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: fieldGray500,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (emptySubtitle != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      emptySubtitle!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: fieldGray400,
                        fontSize: 12,
                        height: 1.35,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            )
          : Column(
              children: [
                for (var index = 0; index < people.length; index++) ...[
                  if (index > 0)
                    const Divider(height: 1, indent: 72, color: fieldGray100),
                  _PlayerRow(
                    connection: people[index],
                    onToggleFollow: () => onToggleFollow(people[index]),
                    onOpenProfile: () => onOpenProfile(people[index].id),
                  ),
                ],
              ],
            ),
    );
  }
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({
    required this.connection,
    required this.onToggleFollow,
    required this.onOpenProfile,
  });

  final ProfileConnection connection;
  final VoidCallback onToggleFollow;
  final VoidCallback onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final clan = connection.clan;

    return InkWell(
      onTap: onOpenProfile,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            _ConnectionAvatar(connection: connection, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    connection.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: fieldGray900,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      '@${connection.username}',
                      if (clan != null) clan.name,
                    ].join(' - '),
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
            const SizedBox(width: 10),
            _FollowButton(
              following: connection.isFollowedByMe,
              onTap: onToggleFollow,
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.chevron_right_rounded,
              color: fieldGray300,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _FollowButton extends StatelessWidget {
  const _FollowButton({required this.following, required this.onTap});

  final bool following;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: following ? fieldGray100 : null,
          gradient: following
              ? null
              : const LinearGradient(colors: [fieldEmerald500, fieldBlue600]),
          border: Border.all(color: following ? fieldGray200 : Colors.white),
          borderRadius: BorderRadius.circular(999),
          boxShadow: following
              ? null
              : [
                  BoxShadow(
                    color: fieldEmerald500.withValues(alpha: 0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              following ? Icons.check_rounded : Icons.person_add_alt_1_rounded,
              size: 15,
              color: following ? fieldGray600 : Colors.white,
            ),
            const SizedBox(width: 5),
            Text(
              following ? 'FOLLOWING' : 'FOLLOW',
              style: TextStyle(
                color: following ? fieldGray600 : Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionAvatar extends StatelessWidget {
  const _ConnectionAvatar({required this.connection, required this.size});

  final ProfileConnection connection;
  final double size;

  @override
  Widget build(BuildContext context) {
    final avatarUrl = connection.avatarUrl;

    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [fieldEmerald500, fieldBlue600]),
      ),
      child: ClipOval(
        child: avatarUrl == null || avatarUrl.isEmpty
            ? Center(
                child: Text(
                  connection.initials,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: size * 0.34,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              )
            : Image.network(
                avatarUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Center(
                  child: Text(
                    connection.initials,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: size * 0.34,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _DiscoverHeader extends StatelessWidget {
  const _DiscoverHeader();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(
          width: 4,
          height: 20,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [fieldEmerald500, fieldBlue600],
              ),
              borderRadius: BorderRadius.all(Radius.circular(99)),
            ),
          ),
        ),
        SizedBox(width: 8),
        Icon(Icons.search_rounded, color: fieldEmerald600, size: 16),
        SizedBox(width: 6),
        Text(
          'DISCOVER PLAYERS',
          style: TextStyle(
            color: fieldGray700,
            fontSize: 12,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }
}

class _ConnectionsLoadingView extends StatelessWidget {
  const _ConnectionsLoadingView();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: fieldHeaderAwarePadding(context, top: 16, bottom: 36),
      children: const [
        FieldSkeletonBox(height: 48, borderRadius: 999),
        SizedBox(height: 18),
        FieldSkeletonCard(
          height: 224,
          borderRadius: 20,
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          children: [
            _ConnectionSkeletonRow(),
            Divider(height: 21, indent: 58, color: fieldGray100),
            _ConnectionSkeletonRow(),
            Divider(height: 21, indent: 58, color: fieldGray100),
            _ConnectionSkeletonRow(),
          ],
        ),
        SizedBox(height: 22),
        Row(
          children: [
            FieldSkeletonBox(width: 4, height: 20, borderRadius: 99),
            SizedBox(width: 10),
            FieldSkeletonBox(width: 160, height: 16, borderRadius: 6),
          ],
        ),
        SizedBox(height: 8),
        FieldSkeletonCard(
          height: 150,
          borderRadius: 20,
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          children: [
            _ConnectionSkeletonRow(),
            Divider(height: 21, indent: 58, color: fieldGray100),
            _ConnectionSkeletonRow(),
          ],
        ),
      ],
    );
  }
}

class _ConnectionSkeletonRow extends StatelessWidget {
  const _ConnectionSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        FieldSkeletonBox(width: 44, height: 44, borderRadius: 999),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FieldSkeletonBox(height: 14, borderRadius: 6),
              SizedBox(height: 8),
              FieldSkeletonBox(width: 130, height: 12, borderRadius: 6),
            ],
          ),
        ),
        SizedBox(width: 10),
        FieldSkeletonBox(width: 86, height: 36, borderRadius: 999),
      ],
    );
  }
}

class _ConnectionsErrorView extends StatelessWidget {
  const _ConnectionsErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: fieldHeaderAwarePadding(context, top: 16, bottom: 36),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: fieldGray100),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Could not load people',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(message, style: const TextStyle(color: fieldGray500)),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
