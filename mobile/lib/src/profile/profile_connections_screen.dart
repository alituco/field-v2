import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_toast.dart';
import 'profile.dart';
import 'profile_repository.dart';

const _cream = Color(0xFFFAF7EF);
const _wash = Color(0xFFF2EFE3);
const _ink = FieldrushAuthTheme.ink;
const _muted = FieldrushAuthTheme.muted;
const _border = FieldrushAuthTheme.border;
const _green = FieldrushAuthTheme.forest;

TextStyle _jakarta(
  double size, {
  Color color = _ink,
  FontWeight weight = FontWeight.w700,
}) => TextStyle(
  fontFamily: 'PlusJakartaSans',
  fontSize: size,
  fontWeight: weight,
  height: 1.3,
  color: color,
);

class ProfileConnectionsScreen extends StatefulWidget {
  const ProfileConnectionsScreen({
    super.key,
    required this.profileRepository,
    required this.initialTab,
    required this.onOpenProfile,
    this.username,
  });

  final ProfileRepository profileRepository;
  final ProfileConnectionTab initialTab;
  final Future<void> Function(String profileId) onOpenProfile;

  /// An already-loaded account handle; no private account query for the header.
  final String? username;

  @override
  State<ProfileConnectionsScreen> createState() =>
      _ProfileConnectionsScreenState();
}

class _ProfileConnectionsScreenState extends State<ProfileConnectionsScreen> {
  late ProfileConnectionTab _tab;
  final _searchController = TextEditingController();
  final _busyIds = <String>{};
  ProfileConnections? _connections;
  Object? _error;
  bool _isLoading = true;
  bool _openingProfile = false;
  bool _refreshWhenIdle = false;
  int _loadRequest = 0;
  int _mutationRevision = 0;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    _loadConnections(showLoading: true);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadConnections({bool showLoading = false}) async {
    // A read during a write can return the pre-write relationship. Defer it
    // until every row has settled instead of erasing optimistic state.
    if (_busyIds.isNotEmpty) {
      _refreshWhenIdle = true;
      return;
    }
    final request = ++_loadRequest;
    final revision = _mutationRevision;
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      final connections = await widget.profileRepository.getConnections();
      if (!mounted || request != _loadRequest) return;
      if (revision != _mutationRevision) {
        await _loadConnections();
        return;
      }
      setState(() {
        _connections = connections;
        _error = null;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted || request != _loadRequest) return;
      if (revision != _mutationRevision) {
        await _loadConnections();
        return;
      }
      setState(() {
        _error = error;
        _isLoading = false;
      });
    }
  }

  Future<void> _toggleFollow(ProfileConnection connection) async {
    final previous = _connections;
    if (previous == null || _busyIds.contains(connection.id)) return;
    setState(() {
      _busyIds.add(connection.id);
      _mutationRevision++;
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
        // A failed row must not roll back another person's successful update.
        _connections = _restoreConnection(
          _connections!,
          previous,
          connection.id,
        );
      });
      showFieldrushToast(
        context,
        userFacingError(
          error,
          fallback: 'We could not update that follow. Try again.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyIds.remove(connection.id);
          _mutationRevision++;
        });
        if (_busyIds.isEmpty && _refreshWhenIdle) {
          _refreshWhenIdle = false;
          await _loadConnections();
        }
      }
    }
  }

  Future<void> _openProfile(String profileId) async {
    if (_openingProfile) return;
    _openingProfile = true;
    try {
      await widget.onOpenProfile(profileId);
      if (mounted) await _loadConnections();
    } finally {
      _openingProfile = false;
    }
  }

  void _changeTab(ProfileConnectionTab tab) {
    setState(() {
      _tab = tab;
      _searchController.clear();
    });
  }

  void _close() {
    if (_busyIds.isNotEmpty) return;
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
    final username = widget.username?.trim().replaceFirst(RegExp(r'^@'), '');
    return PopScope<ProfileConnectionCounts>(
      canPop: _busyIds.isEmpty,
      child: Scaffold(
        backgroundColor: _cream,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 36,
                      height: 44,
                      child: Center(
                        child: IconButton(
                          onPressed: _busyIds.isEmpty ? _close : null,
                          tooltip: 'Back',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 36,
                          ),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: const Color(0xFF3C4A38),
                            side: const BorderSide(color: _border),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: const Icon(
                            Icons.chevron_left_rounded,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        username == null || username.isEmpty
                            ? 'People'
                            : '@$username',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Outfit',
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.18,
                          color: _ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildBody(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final connections = _connections;
    final error = _error;
    if (_isLoading && connections == null) {
      return const _ConnectionsLoadingView();
    }
    if (connections == null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ConnectionsErrorView(
            message: userFacingError(
              error ?? StateError('Connections unavailable'),
              fallback: 'We could not load these people. Try again.',
            ),
            onRetry: () => _loadConnections(showLoading: true),
          ),
        ],
      );
    }
    final followingTab = _tab == ProfileConnectionTab.following;
    final allPeople = followingTab ? connections.following : connections.fans;
    final listedIds = allPeople.map((person) => person.id).toSet();
    final discover = connections.discover
        .where((person) => !listedIds.contains(person.id))
        .toList();
    final query = _searchController.text.trim().toLowerCase().replaceFirst(
      RegExp(r'^@'),
      '',
    );
    final hasSearch = _searchController.text.trim().isNotEmpty;
    final people = allPeople
        .where(
          (person) =>
              person.displayName.toLowerCase().contains(query) ||
              person.username.toLowerCase().contains(query),
        )
        .toList();
    final searchLabel = followingTab
        ? 'Search ${allPeople.length} following'
        : 'Search ${allPeople.length} fans';

    return FieldRefreshIndicator(
      color: _green,
      onRefresh: _loadConnections,
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          36 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          _ConnectionTabs(
            tab: _tab,
            followingCount: connections.following.length,
            fansCount: connections.fans.length,
            onChanged: _changeTab,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            cursorColor: _green,
            onChanged: (_) => setState(() {}),
            style: _jakarta(13.5, weight: FontWeight.w600),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: searchLabel,
              hintStyle: _jakarta(13.5, color: _muted, weight: FontWeight.w600),
              filled: true,
              fillColor: Colors.white,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              prefixIcon: const Icon(
                Icons.search_rounded,
                size: 19,
                color: _muted,
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 42),
              suffixIcon: hasSearch
                  ? IconButton(
                      tooltip: 'Clear search',
                      onPressed: () => setState(_searchController.clear),
                      icon: const Icon(Icons.close_rounded, size: 17),
                      color: _muted,
                    )
                  : null,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: _border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: _green),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 12),
            child: Text(
              hasSearch
                  ? '${people.length} ${people.length == 1 ? 'match' : 'matches'}'
                  : followingTab
                  ? 'Players you follow. Tap anyone to see their profile.'
                  : 'Players who follow you. Follow them back to stay connected.',
              style: _jakarta(11.5, color: _muted, weight: FontWeight.w600),
            ),
          ),
          if (error != null) ...[
            _ConnectionsErrorView(
              message: userFacingError(
                error,
                fallback: 'We could not refresh these people. Try again.',
              ),
              onRetry: _loadConnections,
            ),
            const SizedBox(height: 12),
          ],
          _PeopleCard(
            people: people,
            busyIds: _busyIds,
            onToggleFollow: _toggleFollow,
            onOpenProfile: _openProfile,
            incoming: !followingTab,
            emptyMessage: hasSearch
                ? 'No ${followingTab ? 'players' : 'fans'} match “${_searchController.text.trim()}”'
                : followingTab
                ? discover.isEmpty
                      ? "You're not following anyone yet."
                      : "You're not following anyone yet. Discover players below."
                : 'No fans yet. Keep playing to grow your fanbase.',
          ),
          if (!hasSearch && discover.isNotEmpty) ...[
            const SizedBox(height: 22),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Discover players',
                style: _jakarta(13, weight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 10),
            _PeopleCard(
              people: discover,
              busyIds: _busyIds,
              onToggleFollow: _toggleFollow,
              onOpenProfile: _openProfile,
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
  final updated = connection.copyWith(isFollowedByMe: isNowFollowed);
  List<ProfileConnection> update(List<ProfileConnection> people) => [
    for (final person in people)
      person.id == connection.id
          ? person.copyWith(isFollowedByMe: isNowFollowed)
          : person,
  ];
  var following = update(current.following);
  var discover = update(current.discover);
  if (isNowFollowed) {
    discover = discover.where((person) => person.id != connection.id).toList();
    if (!following.any((person) => person.id == connection.id)) {
      following = [updated, ...following];
    }
  } else {
    following = following
        .where((person) => person.id != connection.id)
        .toList();
    if (!discover.any((person) => person.id == connection.id)) {
      discover = [updated, ...discover];
    }
  }
  return ProfileConnections(
    following: following,
    fans: update(current.fans),
    discover: discover,
  );
}

ProfileConnections _restoreConnection(
  ProfileConnections current,
  ProfileConnections previous,
  String profileId,
) {
  List<ProfileConnection> restore(
    List<ProfileConnection> people,
    List<ProfileConnection> before,
  ) {
    final result = people.where((person) => person.id != profileId).toList();
    final index = before.indexWhere((person) => person.id == profileId);
    if (index >= 0) result.insert(index.clamp(0, result.length), before[index]);
    return result;
  }

  return ProfileConnections(
    following: restore(current.following, previous.following),
    fans: restore(current.fans, previous.fans),
    discover: restore(current.discover, previous.discover),
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
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(5),
    decoration: BoxDecoration(
      color: _wash,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        Expanded(
          child: _TabButton(
            active: tab == ProfileConnectionTab.following,
            label: 'Following · $followingCount',
            onTap: () => onChanged(ProfileConnectionTab.following),
          ),
        ),
        const SizedBox(width: 5),
        Expanded(
          child: _TabButton(
            active: tab == ProfileConnectionTab.fans,
            label: 'Fans · $fansCount',
            onTap: () => onChanged(ProfileConnectionTab.fans),
          ),
        ),
      ],
    ),
  );
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.active,
    required this.label,
    required this.onTap,
  });
  final bool active;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: active,
    button: true,
    child: Material(
      color: active ? Colors.white : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      elevation: active ? 1 : 0,
      shadowColor: _ink.withValues(alpha: .12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 38),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _jakarta(
                12,
                color: active ? _ink : _muted,
                weight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _PeopleCard extends StatelessWidget {
  const _PeopleCard({
    required this.people,
    required this.busyIds,
    required this.onToggleFollow,
    required this.onOpenProfile,
    this.incoming = false,
    this.emptyMessage = 'No players yet',
  });
  final List<ProfileConnection> people;
  final Set<String> busyIds;
  final ValueChanged<ProfileConnection> onToggleFollow;
  final Future<void> Function(String profileId) onOpenProfile;
  final bool incoming;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) => people.isEmpty
      ? CustomPaint(
          painter: const _EmptyConnectionsBorder(),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Text(
              emptyMessage,
              textAlign: TextAlign.center,
              style: _jakarta(12, color: _muted, weight: FontWeight.w600),
            ),
          ),
        )
      : Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: _border),
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var index = 0; index < people.length; index++) ...[
                if (index > 0)
                  const Divider(height: 1, color: Color(0xFFF0ECE0)),
                _PlayerRow(
                  connection: people[index],
                  busy: busyIds.contains(people[index].id),
                  incoming: incoming,
                  onToggleFollow: () => onToggleFollow(people[index]),
                  onOpenProfile: () => onOpenProfile(people[index].id),
                ),
              ],
            ],
          ),
        );
}

class _EmptyConnectionsBorder extends CustomPainter {
  const _EmptyConnectionsBorder();

  @override
  void paint(Canvas canvas, Size size) {
    final border = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.75),
          const Radius.circular(16),
        ),
      );
    final paint = Paint()
      ..color = const Color(0xFFDED8C6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in border.computeMetrics()) {
      for (double start = 0; start < metric.length; start += 8) {
        canvas.drawPath(metric.extractPath(start, start + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EmptyConnectionsBorder oldDelegate) => false;
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({
    required this.connection,
    required this.busy,
    required this.incoming,
    required this.onToggleFollow,
    required this.onOpenProfile,
  });
  final ProfileConnection connection;
  final bool busy;
  final bool incoming;
  final VoidCallback onToggleFollow;
  final VoidCallback onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final clan = connection.clan;
    final label = connection.isFollowedByMe
        ? incoming
              ? 'Following'
              : 'Unfollow'
        : incoming
        ? 'Follow back'
        : 'Follow';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 7, 14, 7),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onOpenProfile,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Row(
                  children: [
                    _ConnectionAvatar(connection: connection),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            connection.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _jakarta(13),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            [
                              '@${connection.username}',
                              if (clan != null) clan.name,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _jakarta(
                              10.5,
                              color: _muted,
                              weight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Semantics(
            button: true,
            enabled: !busy,
            onTap: busy ? null : onToggleFollow,
            label: busy
                ? 'Updating follow for ${connection.displayName}'
                : '${connection.isFollowedByMe ? 'Unfollow' : label} ${connection.displayName}',
            child: ExcludeSemantics(
              child: OutlinedButton(
                key: ValueKey('follow-${connection.id}'),
                onPressed: busy ? null : onToggleFollow,
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: _ink,
                  disabledForegroundColor: _muted,
                  side: const BorderSide(color: _border),
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 13),
                  shape: const StadiumBorder(),
                  textStyle: _jakarta(11, weight: FontWeight.w800),
                ),
                child: busy
                    ? const SizedBox(
                        width: 44,
                        child: FieldSkeleton(height: 9, radius: 4),
                      )
                    : Text(label),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionAvatar extends StatelessWidget {
  const _ConnectionAvatar({required this.connection});
  final ProfileConnection connection;

  @override
  Widget build(BuildContext context) {
    final avatarUrl = connection.avatarUrl;
    Widget initials() => Center(
      child: Text(
        connection.initials,
        style: const TextStyle(
          fontFamily: 'Outfit',
          color: Color(0xFF3C4A38),
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: _wash,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: avatarUrl == null || avatarUrl.isEmpty
          ? initials()
          : Image.network(
              avatarUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => initials(),
            ),
    );
  }
}

class _ConnectionsLoadingView extends StatelessWidget {
  const _ConnectionsLoadingView();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Semantics(
        label: 'Loading people',
        liveRegion: true,
        child: const Column(
          children: [
            FieldSkeleton(height: 48, radius: 16),
            SizedBox(height: 12),
            FieldSkeleton(height: 46, radius: 14),
            SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FieldSkeleton(width: 220, height: 12),
            ),
            SizedBox(height: 12),
          ],
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const FieldLoadingContent(
          label: 'Loading player connections',
          rows: 5,
          compact: true,
        ),
      ),
    ],
  );
}

class _ConnectionsErrorView extends StatelessWidget {
  const _ConnectionsErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message, style: _jakarta(12, color: _muted)),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: onRetry,
          style: TextButton.styleFrom(foregroundColor: _green),
          icon: const Icon(Icons.refresh_rounded, size: 17),
          label: Text('Retry', style: _jakarta(12, color: _green)),
        ),
      ],
    ),
  );
}
